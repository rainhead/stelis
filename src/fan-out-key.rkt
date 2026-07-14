#lang racket/base

;; Declared fan-out key (st-tul, st-5jt): upgrade a 'dir output from opaque to a
;; verified data-dependent SET.
;;
;; A 'dir artifact's tree digest (tree-digest.rkt) proves the directory is present
;; and content-stable, but says nothing about whether it holds the RIGHT set of
;; files. A producer can declare that its directory fans out over one or more
;; columns of a named input relation — place-maps writes one <slug>.svg per place,
;; species-maps one genus/<G>.svg per genus and one subgenus/<G>/<S>.svg per
;; (genus, subgenus) pair — as a list of `fan-out' BRANCHES on the artifact's
;; keyed-by field. This module checks the invariant those declarations assert.
;;
;; A branch's key can be COMPOSITE: its template carries N "{}" placeholders and
;; its `keys' names N columns, so the key is an N-tuple (a list of strings). Keys
;; are read from JSON-array files (read-json) or parquet files (DuckDB), chosen by
;; the resolved input's extension — verbatim column values, no transform (a key
;; that is a FUNCTION of a column, e.g. feeds' slugify, needs the emitted-manifest
;; approach in st-q6i, not this).
;;
;; SOUNDNESS is gated; COMPLETENESS is reported. The real exporters FILTER (only
;; species with occurrence_count>0 get a per-species map), so a produced-files set
;; is a strict SUBSET of the unfiltered key column — an `==' check would false-alarm.
;; What always holds, and what actually catches bugs, is:
;;   * SOUNDNESS  {file keys} ⊆ {input keys}: every produced file corresponds to a
;;     real key of a declared input. An ORPHAN (a file whose key-tuple isn't in any
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
         "tree-digest.rkt"   ; dir-relpaths — the shared directory-walk primitive
         "duckdb.rkt")       ; duckdb-query — parquet column extraction

(provide (struct-out fan-out)
         (struct-out fan-out-verdict)
         fan-out-verdict-sound?
         template-arity
         file->key
         classify-fan-out
         json-column-keys
         parquet-column-keys
         column-keys
         dir-relpaths
         verify-fan-out-key
         verify-fan-out-keys)

;; A fan-out BRANCH: the files whose relative path matches `template' are keyed by
;; columns `keys' (a list) of input artifact `input'. `template' is a filename
;; pattern with one "{}" per key column, e.g. "{}.svg" keyed by ("slug"), or
;; "subgenus/{}/{}.svg" keyed by ("genus" "subgenus"). One 'dir may declare several.
(struct fan-out (input keys template) #:transparent)

;; The outcome of checking one 'dir's declared fan-out.
;;   sound-files: count of produced files that ARE explained — a branch template
;;                matches AND the encoded key-tuple is in that branch's input
;;                relation (i.e. total produced files minus the orphans)
;;   orphans    : (listof string) relative file paths that FAIL soundness — either
;;                no branch template matches, or the key-tuple isn't in the input
;;   incomplete : (listof (cons input-sym (listof string))) input key-tuples with no
;;                produced file (reported; expected under filtering)
(struct fan-out-verdict (dir sound-files orphans incomplete) #:transparent)

;; sound? iff no orphan files — the gated property.
(define (fan-out-verdict-sound? v) (null? (fan-out-verdict-orphans v)))

;; --- pure core: templates and key-tuples ------------------------------------

;; template-arity : string -> exact-nonnegative-integer
;; How many "{}" placeholders the template carries (= the branch's column count).
(define (template-arity template)
  (sub1 (length (string-split template "{}" #:trim? #f))))

;; template->rx : string -> pregexp
;; An anchored regex with one non-empty capture group per "{}", literals quoted.
;; "subgenus/{}/{}.svg" -> #px"^subgenus/(.+?)/(.+?)\\.svg$".
(define (template->rx template)
  (define lits (string-split template "{}" #:trim? #f))
  (when (< (length lits) 2)
    (error 'template->rx "template has no {} placeholder: ~a" template))
  (pregexp (string-append "^" (string-join (map regexp-quote lits) "(.+?)") "$")))

;; file->key : string string -> (or/c (listof string) #f)
;; The key-TUPLE a relative file path encodes under `template' (one element per
;; "{}"), or #f if the path doesn't match. The inverse of substituting a tuple in.
(define (file->key template relpath)
  (define m (regexp-match (template->rx template) relpath))
  (and m (cdr m)))   ; drop the whole-match; the groups are the tuple

;; classify-fan-out : (setof tuple) (setof tuple) -> (values (listof tuple) (listof tuple))
;; Single-branch set comparison: file-keys vs input-keys -> (orphans, incomplete),
;; each sorted. orphans = file tuples with no input tuple (soundness failures);
;; incomplete = input tuples with no file (reported). Filesystem-free, unit-tested.
(define (classify-fan-out file-keys input-keys)
  (values (sort (set->list (set-subtract file-keys input-keys)) tuple<?)
          (sort (set->list (set-subtract input-keys file-keys)) tuple<?)))

;; a total order on string tuples, for stable output.
(define (tuple<? a b) (string<? (string-join a "") (string-join b "")))

;; --- IO: reading a branch's input key-tuples --------------------------------

;; column-keys : path-string (listof string) -> (setof (listof string))
;; The set of DISTINCT `cols' tuples in the input at `path', dispatched by
;; extension: a JSON array-of-objects (read-json) or a parquet file (DuckDB).
;; Tuples with any missing/empty component are dropped (they key no file).
(define (column-keys path cols)
  (define p (if (path? path) (path->string path) path))
  (cond
    [(string-suffix? p ".json")    (json-column-keys path cols)]
    [(string-suffix? p ".parquet") (parquet-column-keys path cols)]
    [else (error 'column-keys "unsupported key-source (need .json or .parquet): ~a" p)]))

;; json-column-keys : path-string (listof string) -> (setof (listof string))
;; DISTINCT `cols' tuples across a JSON ARRAY-of-objects file. A row missing any
;; column (or with an empty/null value there) is skipped. Values are stringified so
;; numeric columns compare against filename-derived keys.
(define (json-column-keys path cols)
  (define data (call-with-input-file path read-json))
  (unless (list? data)
    (error 'json-column-keys "~a is not a JSON array" path))
  (define syms (map string->symbol cols))
  (for/set ([e (in-list data)]
            #:when (and (hash? e) (andmap (lambda (s) (present? (hash-ref e s #f))) syms)))
    (map (lambda (s) (key->string (hash-ref e s))) syms)))

;; parquet-column-keys : path-string (listof string) -> (setof (listof string))
;; DISTINCT `cols' tuples in a parquet file, read via DuckDB (-list output: rows on
;; newlines, columns on '|'; NULL renders empty). Rows with an empty component are
;; dropped. Raises if the file can't be read — a harness precondition, not a defect.
(define (parquet-column-keys path cols)
  (define src (if (path? path) (path->string path) path))
  (define sql (string-append "SELECT DISTINCT " (string-join cols ", ")
                             " FROM read_parquet('" src "')"))
  (define out (duckdb-query #f sql))
  (unless out (error 'parquet-column-keys "could not read ~a via duckdb" src))
  (for/set ([line (in-list (string-split out "\n"))]
            #:do [(define tup (string-split line "|" #:trim? #f))]
            #:when (and (= (length tup) (length cols))
                        (andmap (lambda (s) (not (string=? s ""))) tup)))
    tup))

(define (present? v) (and v (not (and (string? v) (string=? v "")))))
(define (key->string v) (if (string? v) v (format "~a" v)))

;; --- driver -----------------------------------------------------------------

;; verify-fan-out-key : (listof fan-out) path-string (symbol -> path?/#f) -> fan-out-verdict
;; Check a built directory `dir' against its declared branches. `resolve' maps a
;; branch's input artifact to its on-disk path (the reference the tree was built
;; into). A file is EXPLAINED if ANY branch's template matches it AND the key-tuple
;; it encodes is in that branch's input relation; a file no branch explains is an
;; orphan. (A greedy first-template-match would misfile "genus/<g>.svg" onto the
;; catch-all "{}.svg" per-species branch — so every branch gets a look.)
(define (verify-fan-out-key branches dir resolve)
  (for ([b (in-list branches)])
    (unless (= (length (fan-out-keys b)) (template-arity (fan-out-template b)))
      (error 'verify-fan-out-key "branch ~a: ~a columns but ~a {} in template ~s"
             (fan-out-input b) (length (fan-out-keys b))
             (template-arity (fan-out-template b)) (fan-out-template b))))
  ;; input key-tuples per branch (parallel to `branches')
  (define branch-keys
    (for/list ([b (in-list branches)])
      (column-keys (resolve (fan-out-input b)) (fan-out-keys b))))
  (define relpaths (dir-relpaths dir))
  ;; matched identity carries the branch's key COLUMNS too, so two branches sharing
  ;; an input don't cross-credit each other.
  (define matched (mutable-set))          ; (list input keys tuple) an input tuple a file covered
  (define orphans '())
  (for ([rel (in-list relpaths)])
    (define explanations
      (for/list ([b (in-list branches)] [ks (in-list branch-keys)]
                 #:do [(define tup (file->key (fan-out-template b) rel))]
                 #:when (and tup (set-member? ks tup)))
        (list (fan-out-input b) (fan-out-keys b) tup)))
    (cond
      [(null? explanations) (set! orphans (cons rel orphans))]
      [else (for ([e (in-list explanations)]) (set-add! matched e))]))
  ;; completeness: input key-tuples not covered by any produced file, per branch
  (define incomplete
    (append*
     (for/list ([b (in-list branches)] [ks (in-list branch-keys)])
       (for/list ([tup (in-list (sort (set->list ks) tuple<?))]
                  #:unless (set-member? matched (list (fan-out-input b) (fan-out-keys b) tup)))
         (cons (fan-out-input b) tup)))))
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
         (define v (verify-fan-out-key branches (resolve out reference-dir)
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
