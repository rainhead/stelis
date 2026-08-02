#lang racket/base

;; Unit tests for the per-task delta-arm policy (st-qxq). The properties that
;; matter — an output store-keyed on the changed input takes the IDENTITY arm
;; (removals prune, via the declared template) and anything else takes the READER
;; arm (removals join the rebuild set and delete nothing); the two arms compose
;; per-input within one task; the notes-harvest partition is BYTE-IDENTICAL to the
;; hardcoded fold this replaces; and a shape whose removals have no safe answer is
;; refused at validation rather than at delta time.

(require rackunit
         racket/list
         "model.rkt"
         "delta.rkt"
         "fan-out-key.rkt"
         "rebuild-policy.rkt")

;; --- fixtures -------------------------------------------------------------------

(define (kd artifact #:added [added '()] #:changed [changed '()] #:removed [removed '()])
  (key-delta artifact 1 'pending
             (+ (length added) (length changed) (length removed))
             added removed changed))

;; a graph with one task, its inputs, and outputs described as (name . keyed-by).
(define (graph-with #:task [task 'harvest] #:inputs [inputs '(store)]
                    #:outputs [outputs (list (cons 'notes (store-keyed 'store "{}.json")))]
                    #:kinds [kinds (hash)])
  (build-graph
   (list (make-task task 'transform
                    #:inputs inputs #:outputs (map car outputs)
                    #:invoke (recipe 'sh (list "true"))))
   (append
    (for/list ([i (in-list inputs)]) (make-artifact i (hash-ref kinds i 'file)))
    (for/list ([o (in-list outputs)])
      (make-artifact (car o) (hash-ref kinds (car o) 'dir) #:keyed-by (cdr o))))))

;; THE ORACLE. main.rkt's fold before st-qxq, inlined verbatim, so the
;; notes-harvest partition is pinned against the code that ran in production —
;; where a real note deletion was verified live. If the new fold ever disagrees on
;; the identity arm, this test says so in the same terms the old code used.
(define (old-fold deltas)
  (cons (remove-duplicates
         (append-map (lambda (d)
                       (append (key-delta-added d) (key-delta-changed d)))
                     deltas))
        (remove-duplicates
         (map (lambda (k) (string-append k ".json"))
              (append-map key-delta-removed deltas)))))

;; --- the identity arm ------------------------------------------------------------

(let* ([g (graph-with)]
       [deltas (list (kd 'store
                         #:added '("andrena angustitarsata")
                         #:changed '("bombus mixtus")
                         #:removed '("bombus vosnesenskii")))]
       [got (deltas->rebuild+prune g 'harvest deltas)])
  (check-equal? (removal-policy g 'harvest 'store) '(prune . "{}.json")
                "an output store-keyed on this input means removals prune")
  (check-equal? (car got) '("andrena angustitarsata" "bombus mixtus")
                "rebuild is added ∪ changed — a removed key is NOT re-harvested")
  (check-equal? (cdr got) '("bombus vosnesenskii.json")
                "the removed key names a file to delete, via the declared template")
  ;; the pin: byte-identical to the fold this replaces
  (check-equal? got (old-fold deltas)
                "identity arm matches the pre-st-qxq fold exactly (notes-harvest, live-verified)"))

;; a key with a space survives the template unchanged — canonical_names have them,
;; and STELIS_REBUILD_KEYS is newline-separated precisely because of that.
(let* ([g (graph-with)]
       [deltas (list (kd 'store #:removed '("bombus vosnesenskii" "andrena angustitarsata")))]
       [got (deltas->rebuild+prune g 'harvest deltas)])
  (check-equal? (cdr got) '("bombus vosnesenskii.json" "andrena angustitarsata.json"))
  (check-equal? got (old-fold deltas) "pure retraction also matches the old fold")
  ;; set-but-empty is the contract: zero keys to rebuild is an ANSWER, not "full"
  (check-equal? (car got) '() "a pure retraction rebuilds nothing, and says so with a list"))

;; --- the reader arm --------------------------------------------------------------
;; The site render's shape: it CONSUMES the keyed notes/ dir, but its own output is
;; keyed by something else entirely (pages). A removed note must re-render the page
;; so it loses its notes section — and must delete nothing.

(let* ([g (graph-with #:task 'render #:inputs '(notes)
                      #:outputs (list (cons 'pages (fan-out 'species '("canonical_name") "{}/index.html")))
                      #:kinds (hash 'notes 'dir))]
       [deltas (list (kd 'notes
                         #:changed '("bombus mixtus.json")
                         #:removed '("bombus vosnesenskii.json")))]
       [got (deltas->rebuild+prune g 'render deltas)])
  (check-equal? (removal-policy g 'render 'notes) 'rebuild
                "an output keyed by something else means this task merely READS the input")
  (check-equal? (car got) '("bombus mixtus.json" "bombus vosnesenskii.json")
                "the removed key JOINS the rebuild set — the page re-renders without it")
  (check-equal? (cdr got) '() "and nothing is deleted: the page still exists")
  ;; the regression this whole module exists for
  (check-not-equal? got (old-fold deltas)
                    "the old fold would have dropped the removal on BOTH sides"))

;; a removal-only delta on the reader arm still produces work. Under the old fold
;; this yielded rebuild='() and a prune path that does not exist — the silent
;; drop-on-both-sides: green build, stale page, nothing reported.
(let* ([g (graph-with #:task 'render #:inputs '(notes)
                      #:outputs (list (cons 'pages #f))
                      #:kinds (hash 'notes 'dir))]
       [got (deltas->rebuild+prune g 'render (list (kd 'notes #:removed '("gone.json"))))])
  (check-equal? (car got) '("gone.json") "an unkeyed 'dir output is a reader too")
  (check-equal? (cdr got) '())
  (check-not-equal? (car got) '()
                    "a pure retraction must produce WORK, not silence"))

;; a manifest-keyed output is a reader as well: its filenames are a transform the
;; exporter owns, so the engine has no template to prune with.
(let ([g (graph-with #:task 'feeds #:inputs '(rel)
                     #:outputs (list (cons 'feeds
                                           (manifest-key "index.json" "filename" "filter_value"
                                                         "filter_type" '() '()))))])
  (check-equal? (removal-policy g 'feeds 'rel) 'rebuild))

;; --- the two arms compose per input ----------------------------------------------
;; One task, two changed keyed inputs: store-keyed on one, reader of the other.
;; Each is resolved on its own terms rather than by a single task-wide rule.

(let* ([g (build-graph
           (list (make-task 'both 'transform
                            #:inputs '(store other) #:outputs '(out)
                            #:invoke (recipe 'sh (list "true"))))
           (list (make-artifact 'store 'file)
                 (make-artifact 'other 'dir)
                 (make-artifact 'out 'dir #:keyed-by (store-keyed 'store "{}.json"))))]
       [got (deltas->rebuild+prune
             g 'both
             (list (kd 'store #:changed '("a") #:removed '("dead"))
                   (kd 'other #:changed '("b") #:removed '("vanished"))))])
  (check-equal? (car got) '("a" "b" "vanished")
                "the store's removal prunes; the other input's removal rebuilds")
  (check-equal? (cdr got) '("dead.json")
                "only the store-keyed input contributes a prune path"))

;; de-duplication across inputs naming the same key
(let* ([g (graph-with #:task 'render #:inputs '(x y)
                      #:outputs (list (cons 'pages #f))
                      #:kinds (hash 'x 'dir 'y 'dir))]
       [got (deltas->rebuild+prune g 'render
                                   (list (kd 'x #:changed '("k")) (kd 'y #:changed '("k"))))])
  (check-equal? (car got) '("k") "a key named by two inputs appears once"))

;; --- the refusal -------------------------------------------------------------------

;; the notes-harvest shape passes
(check-not-exn (lambda () (check-partial-tasks (graph-with) '(harvest)))
               "one store-keyed 'dir output is the shape partial rebuilds are for")

;; a partial-capable task with no 'dir output at all
(let ([g (build-graph
          (list (make-task 'nodir 'transform #:inputs '(in) #:outputs '(out)
                           #:invoke (recipe 'sh (list "true"))))
          (list (make-artifact 'in 'file) (make-artifact 'out 'file)))])
  (check-exn #rx"no 'dir output"
             (lambda () (check-partial-tasks g '(nodir)))
             "there is nothing for a partial rebuild to merge into"))

;; a store-keyed 'dir output ALONGSIDE another 'dir: run-plan applies one prune
;; list to every keyed dir output, so the identity arm's deletes would also be
;; attempted against the other tree (st-1v6).
(let ([g (build-graph
          (list (make-task 'two 'transform #:inputs '(store) #:outputs '(keyed extra)
                           #:invoke (recipe 'sh (list "true"))))
          (list (make-artifact 'store 'file)
                (make-artifact 'keyed 'dir #:keyed-by (store-keyed 'store "{}.json"))
                (make-artifact 'extra 'dir)))])
  (check-exn #rx"alongside"
             (lambda () (check-partial-tasks g '(two)))
             "one prune list across two keyed trees has no safe answer"))

;; TWO 'dir outputs with NO store-keyed one is fine — the reader arm prunes
;; nothing, so the uniformity hazard cannot arise.
(let ([g (build-graph
          (list (make-task 'readers 'transform #:inputs '(in) #:outputs '(a b)
                           #:invoke (recipe 'sh (list "true"))))
          (list (make-artifact 'in 'dir)
                (make-artifact 'a 'dir) (make-artifact 'b 'dir)))])
  (check-not-exn (lambda () (check-partial-tasks g '(readers)))
                 "no pruning means no way to prune the wrong tree"))

;; a name that is not a task at all
(check-exn #rx"not a task"
           (lambda () (check-partial-tasks (graph-with) '(nonesuch))))

;; --- the real graph ----------------------------------------------------------------
;; The property that actually protects production: beeatlas's declared
;; partial-capable tasks pass, and notes-harvest resolves to the identity arm with
;; the template its artifact declares.
(let ()
  (local-require "beeatlas.rkt")
  (check-not-exn (lambda () (check-partial-tasks beeatlas-graph beeatlas-partial-tasks))
                 "the authored graph is a shape partial rebuilds can express")
  (check-equal? (removal-policy beeatlas-graph 'notes-harvest 'notes-store.db)
                '(prune . "{}.json")
                "notes-harvest still prunes, with the template beeatlas.rkt declares"))
