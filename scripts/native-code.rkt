#lang racket/base
;; Convert the installation's packages to this machine's native code (st-3un).
;;
;;   racket scripts/native-code.rkt
;;
;; scripts/install-racket.sh installs catalog packages `--binary-lib`, and the
;; release catalog's built packages carry MACHINE-INDEPENDENT compiled code, with
;; neither the source nor the .dep files `raco setup` would recompile from. Racket
;; loads such a file by compiling it to machine code first, on every launch: on the
;; beeatlas Fly Machine that was ~1 s of a 1.5 s `--last-build`, 103 linklets of
;; datalog and the parser-tools, scheme and compiler libraries it pulls in.
;;
;; So this rewrites each such file, in place, as the native code Racket would have
;; produced at load time (`compiled-expression-recompile`). Files already native
;; are left alone: recompiling one would rewrite it for nothing, and the converted
;; file must be the same code, not a re-optimized one. A file's target is the VM
;; name in its header — `#~`, the version, then the VM, each with a length byte —
;; which is "linklet" for machine-independent code and the machine type (ta6le on
;; x86_64 Linux) for native.
;;
;; Exits 1 if any machine-independent file is left afterwards, so an image build
;; cannot quietly ship the slow form.

(require racket/file racket/path setup/dirs)

(define native-vm (string->bytes/utf-8 (symbol->string (system-type 'target-machine))))

;; vm-of : path -> (or/c bytes #f) — the VM a compiled file targets, #f if not one
(define (vm-of f)
  (call-with-input-file f
    (lambda (in)
      (and (equal? (read-bytes 2 in) #"#~")
           (let* ([vlen (read-byte in)]
                  [_ (and (byte? vlen) (read-bytes vlen in))]
                  [mlen (read-byte in)])
             (and (byte? mlen) (read-bytes mlen in)))))))

(define (foreign-zo-files dir)
  (for/list ([f (in-directory dir)]
             #:when (regexp-match? #rx"[.]zo$" (path->string f))
             #:unless (equal? (vm-of f) native-vm))
    f))

(define pkgs (find-pkgs-dir))
(define converted
  (for/sum ([f (in-list (foreign-zo-files pkgs))])
    ;; <dir>/compiled/<name>_rkt.zo: relative module paths inside resolve from <dir>
    (parameterize ([read-accept-compiled #t]
                   [current-load-relative-directory
                    (simplify-path (build-path (path-only f) 'up))])
      (define native (compiled-expression-recompile (call-with-input-file f read)))
      (call-with-atomic-output-file f (lambda (out _) (write native out))))
    1))

(define left (foreign-zo-files pkgs))
(printf "native-code: ~a file(s) under ~a converted to ~a\n" converted pkgs native-vm)
(unless (null? left)
  (eprintf "native-code: ~a file(s) still not ~a, e.g. ~a\n" (length left) native-vm (car left))
  (exit 1))
