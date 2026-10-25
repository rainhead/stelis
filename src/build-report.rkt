#lang racket/base

;; What a --build hands the script that ran it (st-3un): `--report-dir DIR`.
;;
;; beeatlas's note publish needs two facts about the build it just ran — which build
;; number it appended (for its publish receipt, st-8x1) and which keys of notes/ moved
;; (to scope its render, beeatlas-4oa) — and used to ask for them with two more
;; launches, `--last-build` and `--moved-keys notes`, about 0.7 s each on the beeatlas
;; Fly Machine. The build already holds both answers when it finishes, so it writes
;; them down instead:
;;
;;   DIR/build       `<number> <epoch>`, the line `--last-build` prints
;;   DIR/moved-keys  the target's moved keys, one per line: what `--moved-keys
;;                   <target>` prints. Empty means nothing moved.
;;
;; ABSENCE is always the safe answer, which is why the build clears both before it
;; starts: no `build` means nothing was appended, so there is nothing to mark; no
;; `moved-keys` means no basis for a delta (`--moved-keys` exiting 1), so the caller
;; rebuilds in full. A build that dies part-way therefore leaves the cautious reading
;; behind, never a previous build's answer. Each file is written atomically, so a
;; reader sees all of it or none.
;;
;; The moved keys are the TARGET's only — the artifact the build was asked for. A
;; build of the whole graph has no target and reports only `build`.

(require racket/file
         "history.rkt"
         "delta.rkt")

(provide key-delta-at
         clear-build-report!
         write-build-report!)

;; key-delta-at : path symbol exact-positive-integer
;;                -> (or/c key-delta 'not-produced 'no-basis)
;; ARTIFACT's delta at build NUMBER, against the build before: two points read from
;; the end of the log (st-6gv). `--moved-keys` and the report both answer with this.
(define (key-delta-at state artifact number)
  (build-key-delta artifact (history-key-observations state artifact #:last 2) number))

(define (report-files dir)
  (list (build-path dir "build") (build-path dir "moved-keys")))

;; clear-build-report! : path-string -> void
(define (clear-build-report! dir)
  (make-directory* dir)
  (for ([f (in-list (report-files dir))])
    (when (file-exists? f) (delete-file f))))

;; write-build-report! : path-string path (or/c symbol #f) -> void
;; After the build's history line is appended. TARGET is the built artifact, or #f.
(define (write-build-report! dir state target)
  (define bld (history-last state #:keyed 'none))
  (when bld
    (define (write-lines! name lines)
      (call-with-atomic-output-file (build-path dir name)
        (lambda (out _)
          (for ([l (in-list lines)]) (write-string l out) (newline out)))))
    (define d (and target (key-delta-at state target (build-record-number bld))))
    (cond
      [(key-delta? d) (write-lines! "moved-keys" (key-delta-moved d))]
      [(eq? d 'not-produced) (write-lines! "moved-keys" '())])
    ;; last, so a reader that finds `build` can trust `moved-keys` is settled
    (write-lines! "build" (list (format "~a ~a" (build-record-number bld)
                                        (build-record-epoch bld))))))
