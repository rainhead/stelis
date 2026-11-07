#lang racket/base

;; Tests that need an environment a bare checkout lacks (beeatlas, DuckDB, a
;; reference build, the linked `stelis' collection) are GATED: with the environment
;; missing they cannot check anything. By default that prints a note and the suite
;; still passes, which is right for a laptop or CI. An unattended caller that
;; expects the environment (beeatlas's nightly) sets STELIS_REQUIRE_GATED=1, and
;; then the same situation FAILS the suite, so a gate can never pass by not running.

(provide skip-or-fail
         note-skip
         stelis-reference-dir)

;; Where a prior build left its @export copies. STELIS_REFERENCE_DIR names it (the
;; nightly points it at its own export dir, holding the previous night's build);
;; unset, it is the scratch out-dir a plain `--build' fills.
(define (stelis-reference-dir)
  (cond [(getenv "STELIS_REFERENCE_DIR") => string->path]
        [else (build-path (find-system-path 'temp-dir) "stelis-out")]))

(define (strict?)
  (equal? (getenv "STELIS_REQUIRE_GATED") "1"))

;; skip-or-fail : string format-string any ... -> void
;; WHO is the test, the rest says what was missing. Lax: print that nothing was
;; checked. Strict: raise, so `raco test' exits non-zero.
(define (skip-or-fail who fmt . args)
  (define what (apply format fmt args))
  (cond
    [(strict?)
     (error 'gated-test "~a did not run, and STELIS_REQUIRE_GATED=1 forbids that: ~a" who what)]
    [else (note-skip who what)]))

;; A skip that is legitimate even for an unattended caller (its reason is stated at
;; the call site). Never fails; worded so it cannot be read as a pass.
(define (note-skip who fmt . args)
  (printf "~a: NOT CHECKED — ~a\n" who (apply format fmt args)))
