#lang racket/base

;; Declared fan-out key (st-tul): upgrade a 'dir output from opaque to a verified
;; data-dependent SET.
;;
;; A 'dir artifact's tree digest (tree-digest.rkt) proves the directory is present
;; and content-stable, but says nothing about whether it holds the RIGHT set of
;; files. A producer can now declare that its directory fans out over a column of a
;; named input relation — species-maps writes one genus/<G>.svg per distinct genus,
;; place-maps one <slug>.svg per place — as a list of `fan-out' BRANCHES on the
;; artifact's keyed-by field. This module checks the invariant those declarations
;; assert.
;;
;; SOUNDNESS is gated; COMPLETENESS is reported. The real exporters FILTER (only
;; places with occurrences get a map; only species with occurrence_count>0), so a
;; produced-files set is a strict SUBSET of the unfiltered key column — an `=='
;; check would false-alarm. What always holds, and what actually catches bugs, is:
;;   * SOUNDNESS  {file keys} ⊆ {input keys}: every produced file corresponds to a
;;     real key of a declared input. An ORPHAN (a file whose key isn't in any
;;     input, or that no branch's template even explains) is a stale/misrouted
;;     output — the failure this gates on.
;;   * COMPLETENESS {input keys} \ {file keys}: input keys with no file. Under
;;     data-dependent filtering these are expected (the filtered-out entities), so
;;     they are REPORTED, not failed.
;;
;; H2 reuse: the same keyed-by declaration is what promotes each key to an
;; independently-stale artifact (delta propagation) later — one artifact / one
;; producer / one rebuild here, no dynamic graph nodes.

(require racket/set
         racket/list
         racket/string
         json
         "model.rkt"
         "tree-digest.rkt")   ; dir-relpaths — the shared directory-walk primitive

(provide (struct-out fan-out)
         (struct-out fan-out-verdict)
         fan-out-verdict-sound?
         template-parts
         file->key
         classify-fan-out
         json-column-keys
         dir-relpaths
         verify-fan-out-key
         verify-fan-out-keys)

;; A fan-out BRANCH: the files whose relative path matches `template' are keyed by
;; column `key' of input artifact `input'. `template' is a filename pattern with a
;; single "{}" placeholder for the key, e.g. "{}.svg" (place-maps) or "genus/{}.svg"
;; (species-maps' genus rank). One 'dir may declare several branches.
(struct fan-out (input key template) #:transparent)

;; The outcome of checking one 'dir's declared fan-out.
;;   sound-files: count of produced files that ARE explained — a branch template
;;                matches AND the encoded key is in that branch's input relation
;;                (i.e. total produced files minus the orphans)
;;   orphans    : (listof string) relative file paths that FAIL soundness — either
;;                no branch template matches, or the key isn't in the input relation
;;   incomplete : (listof (cons input-sym string)) input keys with no produced file
;;                (reported; expected under filtering)
(struct fan-out-verdict (dir sound-files orphans incomplete) #:transparent)

;; sound? iff no orphan files — the gated property.
(define (fan-out-verdict-sound? v) (null? (fan-out-verdict-orphans v)))

;; --- pure core --------------------------------------------------------------

;; template-parts : string -> (values string string)
;; Split a "{}" template into its literal (prefix . suffix) around the one
;; placeholder. "genus/{}.svg" -> (values "genus/" ".svg"); "{}.svg" -> ("" ".svg").
(define (template-parts template)
  (define i (let ([m (regexp-match-positions #rx"\\{\\}" template)])
              (unless m (error 'template-parts "template lacks a {} placeholder: ~a" template))
              (car m)))
  (values (substring template 0 (car i))
          (substring template (cdr i))))

;; file->key : string string -> (or/c string #f)
;; The key a relative file path encodes under `template', or #f if it doesn't match
;; (wrong prefix/suffix, or too short to leave a non-empty key). The inverse of
;; substituting a key into the template.
(define (file->key template relpath)
  (define-values (pre post) (template-parts template))
  (and (string-prefix? relpath pre)
       (string-suffix? relpath post)
       (> (string-length relpath) (+ (string-length pre) (string-length post)))
       (substring relpath (string-length pre)
                  (- (string-length relpath) (string-length post)))))

;; classify-fan-out : (setof string) (setof string) -> (values (listof string) (listof string))
;; Single-branch set comparison: file-keys vs input-keys -> (orphans, incomplete),
;; each sorted. orphans = files with no input key (soundness failures); incomplete
;; = input keys with no file (reported). The filesystem-free heart, unit-tested.
(define (classify-fan-out file-keys input-keys)
  (values (sort (set->list (set-subtract file-keys input-keys)) string<?)
          (sort (set->list (set-subtract input-keys file-keys)) string<?)))

;; --- IO: reading the two sets -----------------------------------------------

;; json-column-keys : path-string string -> (setof string)
;; The set of `col' values across a JSON ARRAY-of-objects file (species.json,
;; places.json …). Missing/null values are skipped; every present value is
;; stringified so numeric keys compare against filename-derived keys.
(define (json-column-keys path col)
  (define data (call-with-input-file path read-json))
  (unless (list? data)
    (error 'json-column-keys "~a is not a JSON array" path))
  (define sym (string->symbol col))
  (for/set ([e (in-list data)]
            #:when (and (hash? e) (hash-ref e sym #f)))
    (key->string (hash-ref e sym))))

(define (key->string v) (if (string? v) v (format "~a" v)))

;; --- driver -----------------------------------------------------------------

;; verify-fan-out-key : (listof fan-out) path-string (symbol -> path?/#f) -> fan-out-verdict
;; Check a built directory `dir' against its declared branches. `resolve' maps a
;; branch's input artifact to its on-disk path (the same reference dir the tree was
;; built into). A file is EXPLAINED if ANY branch's template matches it AND the key
;; it encodes is in that branch's input relation; a file no branch explains is an
;; orphan. (A greedy first-template-match would misfile a "genus/<g>.svg" onto the
;; catch-all "{}.svg" slug branch — so every branch gets a look.)
(define (verify-fan-out-key branches dir resolve)
  ;; input keys per branch (parallel to `branches')
  (define branch-keys
    (for/list ([b (in-list branches)])
      (json-column-keys (resolve (fan-out-input b)) (fan-out-key b))))
  ;; matched identity carries the branch's key-COLUMN too, so two branches sharing
  ;; an input (species.json's slug and genus) don't cross-credit each other.
  (define relpaths (dir-relpaths dir))
  (define matched (mutable-set))          ; (list input key-col key) an input key a file covered
  (define orphans '())
  (for ([rel (in-list relpaths)])
    (define explanations
      (for/list ([b (in-list branches)] [ks (in-list branch-keys)]
                 #:when (let ([k (file->key (fan-out-template b) rel)])
                          (and k (set-member? ks k))))
        (list (fan-out-input b) (fan-out-key b) (file->key (fan-out-template b) rel))))
    (cond
      [(null? explanations) (set! orphans (cons rel orphans))]
      [else (for ([e (in-list explanations)]) (set-add! matched e))]))
  ;; completeness: input keys not covered by any produced file, per branch
  (define incomplete
    (append*
     (for/list ([b (in-list branches)] [ks (in-list branch-keys)])
       (for/list ([k (in-list (sort (set->list ks) string<?))]
                  #:unless (set-member? matched (list (fan-out-input b) (fan-out-key b) k)))
         (cons (fan-out-input b) k)))))
  ;; sound-files = produced files that were explained = all files minus orphans.
  (fan-out-verdict dir (- (length relpaths) (length orphans))
                   (sort orphans string<?) incomplete))

;; verify-fan-out-keys : graph (listof symbol) (symbol -> path?/#f) path-string -> boolean
;; For each keyed 'dir output of the given tasks, verify its fan-out against the
;; reference build and print a report. Returns #t iff every keyed dir is SOUND
;; (no orphans). Completeness gaps are printed but do not fail.
(define (verify-fan-out-keys g tasks resolve reference-dir)
  (printf "Fan-out-key verification — reference ~a\n\n" reference-dir)
  (define keyed
    (for*/list ([name (in-list tasks)]
                [t (in-value (hash-ref (graph-tasks g) name))]
                [o (in-list (task-outputs t))]
                [a (in-value (hash-ref (graph-artifacts g) o #f))]
                #:when (and a (artifact-keyed-by a)))
      (list name o (artifact-keyed-by a))))
  (cond
    [(null? keyed)
     (printf "  (no keyed 'dir outputs among these tasks)\n")
     #t]
    [else
     (define verdicts
       (for/list ([entry (in-list keyed)])
         (define-values (name out branches) (apply values entry))
         (define dir ((lambda (a) (resolve a reference-dir)) out))
         (define v (verify-fan-out-key branches dir
                                       (lambda (a) (resolve a reference-dir))))
         (printf "~a ~a → ~a/\n"
                 (if (fan-out-verdict-sound? v) "✓" "✗") name out)
         (printf "    sound    : ~a\n"
                 (if (fan-out-verdict-sound? v)
                     (format "~a files, all keyed to a declared input" (fan-out-verdict-sound-files v))
                     (format "ORPHANS ~a — file(s) with no matching input key"
                             (string-join (fan-out-verdict-orphans v) ", "))))
         (printf "    complete : ~a\n"
                 (let ([n (length (fan-out-verdict-incomplete v))])
                   (if (zero? n) "every input key has a file"
                       (format "~a input key(s) with no file (filtered out — reported, not failed)" n))))
         v))
     (define all-sound? (andmap fan-out-verdict-sound? verdicts))
     (printf "\n~a ~a/~a keyed dirs verify sound\n"
             (if all-sound? "✓" "✗")
             (count fan-out-verdict-sound? verdicts) (length verdicts))
     all-sound?]))
