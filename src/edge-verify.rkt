#lang racket/base

;; Edge-verification harness (st-qp7). Every post-dbt edge in beeatlas.rkt is a
;; hand-transcribed guess at what a task's Python actually reads and writes, and
;; it stays subtly wrong until a target exercises it — st-4cm slices 1-3 each
;; found the SAME class of bug (an EXPORT_DIR input or output the edge failed to
;; declare, discovered only by running the task and watching a FileNotFoundError
;; or an undeclared file appear). This mechanizes that discovery loop:
;;
;;   run the task in an EXPORT_DIR seeded with ONLY its declared inputs, and check
;;     (a) it still succeeds        — the declared inputs are SUFFICIENT
;;     (b) it wrote exactly its declared outputs — the outputs are COMPLETE
;;
;; Scope — the tractable "negative space." Only EXPORT_DIR reads/writes are
;; tested. Inputs that resolve to FIXED paths (the dbt sandbox, the DuckDB
;; relations, committed content/seeds) are AMBIENT — left in place, not withheld —
;; because withholding them would mean mutating real files. That is exactly the
;; axis the recurring bug lives on (the @export copies), so it is the axis worth
;; checking; a missing SANDBOX input would not be caught here (a known limit).
;;
;; This is a harness, not a unit test (it shells into the real runtimes against a
;; reference build), mirroring determinism.rkt. The PURE classification core
;; (classify-outputs) is unit-tested in edge-verify-test.rkt; the integration
;; driver (verify-edges) is run against the shipped terminals when a reference
;; EXPORT_DIR is available.

(require racket/file
         racket/path
         racket/set
         racket/list
         racket/format
         "model.rkt"
         "exec.rkt")

(provide (struct-out edge-verdict)
         export-dir-artifact?
         classify-outputs
         verify-edge
         verify-edges)

;; edge-verdict : the outcome of verifying one task's declared edge.
;;   ran?        — the subprocess launched and returned an exit code
;;   exit-code   — 0 iff declared inputs were sufficient to run
;;   seeded      — the declared EXPORT_DIR inputs we placed (basenames)
;;   missing     — declared EXPORT_DIR outputs that did NOT appear (basenames)
;;   undeclared  — files that appeared but were NOT declared outputs (basenames)
;; clean? holds iff exit-code is 0 and both missing and undeclared are empty.
(struct edge-verdict (task ran? exit-code seeded missing undeclared) #:transparent)

(define (edge-verdict-clean? v)
  (and (edge-verdict-ran? v)
       (zero? (edge-verdict-exit-code v))
       (null? (edge-verdict-missing v))
       (null? (edge-verdict-undeclared v))))
(provide edge-verdict-clean?)

;; export-dir-artifact? : (symbol export-dir -> path?/#f) symbol -> boolean
;; An artifact lives under EXPORT_DIR iff its resolved path VARIES with the
;; export-dir. Fixed-path artifacts (sandbox marts, raw inputs) resolve to a
;; constant path; db-relations/tokens/externals resolve to #f. Robust without any
;; path-prefix arithmetic — two probe dirs is enough to tell them apart.
(define (export-dir-artifact? resolve a)
  (define p1 (resolve a (build-path "/stelis-probe-a")))
  (define p2 (resolve a (build-path "/stelis-probe-b")))
  (and p1 p2 (not (equal? p1 p2))))

;; classify-outputs : (setof string) (setof string) -> (values (listof string) (listof string))
;; The PURE core: declared vs appeared output basenames -> (missing, undeclared),
;; each sorted. `missing' = declared but not written; `undeclared' = written but
;; not declared (the place_details.json class). Filesystem-free, so it is the part
;; unit-tested directly.
(define (classify-outputs declared appeared)
  (values (sort (set->list (set-subtract declared appeared)) string<?)
          (sort (set->list (set-subtract appeared declared)) string<?)))

;; verify-edge : graph symbol (hash symbol->runtime)
;;               (symbol export-dir -> path?/#f) path-string -> edge-verdict
;; Run one task against a fresh EXPORT_DIR seeded with only its declared
;; EXPORT_DIR inputs (copied from `reference-dir', a populated prior build), then
;; classify what it wrote. Non-EXPORT_DIR inputs are ambient (read from their real
;; fixed paths). Raises if a declared EXPORT_DIR input is absent from the
;; reference (the reference is incomplete — a harness precondition, not an edge
;; defect).
(define (verify-edge g name runtimes resolve reference-dir)
  (define t (hash-ref (graph-tasks g) name))
  (define work (make-temporary-directory))
  ;; seed: declared inputs that live under EXPORT_DIR, copied from the reference.
  (define seeded
    (for/list ([in (in-list (task-inputs t))]
               #:when (export-dir-artifact? resolve in))
      (define base (file-name-from-path (resolve in work)))
      (define src (build-path reference-dir base))
      (unless (file-exists? src)
        (error 'verify-edge
               "reference build lacks ~a (needed to seed ~a's input ~a)"
               base name in))
      (copy-file src (build-path work base))
      (path->string base)))
  (define seeded-set (list->set seeded))
  ;; declared EXPORT_DIR outputs, by basename.
  (define declared-out
    (list->set
     (for/list ([o (in-list (task-outputs t))]
                #:when (export-dir-artifact? resolve o))
       (path->string (file-name-from-path (resolve o work))))))
  ;; run in the fresh dir; an undeclared EXPORT_DIR read now fails loudly.
  (define code
    (run-task g name runtimes
              #:env (list (cons "EXPORT_DIR" (path->string work)))
              #:label name))
  ;; whatever appeared beyond the seeds is what the task wrote to EXPORT_DIR.
  (define appeared
    (set-subtract
     (list->set (map path->string (map file-name-from-path (directory-list work))))
     seeded-set))
  (define-values (missing undeclared) (classify-outputs declared-out appeared))
  (delete-directory/files work)
  (edge-verdict name #t code seeded missing undeclared))

;; verify-edges : graph (listof symbol) (hash symbol->runtime)
;;                (symbol export-dir -> path?/#f) path-string -> boolean
;; Verify each task's edge and print a report. Returns #t iff all are clean.
(define (verify-edges g tasks runtimes resolve reference-dir)
  (printf "Edge verification — reference ~a\n\n" reference-dir)
  (define verdicts
    (for/list ([name (in-list tasks)])
      (define v (verify-edge g name runtimes resolve reference-dir))
      (printf "~a ~a\n"
              (if (edge-verdict-clean? v) "✓" "✗") name)
      (printf "    inputs   : ~a (seeded ~a)\n"
              (if (zero? (edge-verdict-exit-code v)) "sufficient"
                  (format "INSUFFICIENT — exit ~a (an undeclared EXPORT_DIR read failed)"
                          (edge-verdict-exit-code v)))
              (if (null? (edge-verdict-seeded v)) "none"
                  (string-join* (edge-verdict-seeded v))))
      (printf "    outputs  : ~a\n"
              (cond
                [(and (null? (edge-verdict-missing v))
                      (null? (edge-verdict-undeclared v))) "complete"]
                [else
                 (string-append
                  (if (null? (edge-verdict-missing v)) ""
                      (format "MISSING ~a  " (string-join* (edge-verdict-missing v))))
                  (if (null? (edge-verdict-undeclared v)) ""
                      (format "UNDECLARED ~a" (string-join* (edge-verdict-undeclared v)))))]))
      v))
  (define all-clean? (andmap edge-verdict-clean? verdicts))
  (printf "\n~a ~a/~a edges verify clean\n"
          (if all-clean? "✓" "✗")
          (count edge-verdict-clean? verdicts) (length verdicts))
  all-clean?)

(define (string-join* xs) (apply string-append (add-between xs ", ")))
