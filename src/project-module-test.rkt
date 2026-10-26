#lang racket/base

;; A project kept in its own repository (st-ab3, ADR 0020): `--project <path>` loads a
;; module that provides `project', built against the engine required by collection.
;; The module here stands in for salishsea's graph living in salishsea-io: it is
;; written to a temporary directory outside this checkout and requires stelis/model
;; and stelis/project, never a relative path into src/. GATED on the collection
;; being linked (scripts/link-collection.sh): a checkout without the link skips.

(require rackunit
         racket/file
         racket/port
         racket/string
         racket/system
         racket/runtime-path)

(define-runtime-path main-rkt "main.rkt")

(define linked?
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (collection-file-path "project.rkt" "stelis") #t)))

(define (cli . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define code
    (parameterize ([current-output-port out] [current-error-port err])
      (apply system*/exit-code (find-executable-path "racket") (path->string main-rkt) args)))
  (values (get-output-string out) (get-output-string err) code))

(cond
  [(not linked?)
   (printf "project-module-test: the stelis collection is not linked (scripts/link-collection.sh) — skipping.\n")]
  [else
   (define tmp (make-temporary-file "stelis-project-module-~a" 'directory))
   (define module-file (build-path tmp "tiny.rkt"))
   (display-to-file
    (string-append
     "#lang racket/base\n"
     "(require stelis/model stelis/project)\n"
     "(provide project)\n"
     "(define g (build-graph\n"
     "  (list (make-task 'pack 'transform #:inputs '(raw) #:outputs '(out)\n"
     "                   #:invoke (recipe 'sh '(\"cat raw > out\"))))\n"
     "  (list (make-artifact 'raw 'file #:provenance 'upstream) (make-artifact 'out 'file))))\n"
     "(define project\n"
     "  (make-project 'tiny #:graph g\n"
     "    #:runtimes (hash 'sh (runtime 'sh '(\"/bin/sh\" \"-c\") \"sh\"))\n"
     "    #:path (lambda (a dir) (case a [(raw) (build-path dir \"raw\")] [(out) (build-path dir \"out\")] [else #f]))\n"
     "    #:source-date-epoch (lambda () \"1700000000\")\n"
     "    #:checkout (current-directory) #:checkout-env \"TINY_DIR\"\n"
     "    #:default-state-dir (build-path (current-directory) \".stelis-tiny\")))\n")
    module-file)

   ;; the plan for the module's one target, by path
   (define-values (out err code) (cli "--project" (path->string module-file) "out"))
   (check-equal? code 0 (string-append "loads: " err))
   (check-true (regexp-match? #rx"1\\. pack" out) "the module's graph is the one planned")

   ;; a path that is not a module, and a module without `project', are refused by name
   (define-values (_o2 err2 code2) (cli "--project" (path->string (build-path tmp "missing.rkt")) "out"))
   (check-equal? code2 1)
   (check-true (regexp-match? #rx"no such module" err2))
   (define bare (build-path tmp "bare.rkt"))
   (display-to-file "#lang racket/base\n(provide x)\n(define x 1)\n" bare)
   (define-values (_o3 err3 code3) (cli "--project" (path->string bare) "out"))
   (check-equal? code3 1)
   (check-true (regexp-match? #rx"provides no `project'" err3))

   ;; and the registry still answers by name: an unknown name is refused with the
   ;; names it knows (loading beeatlas's graph itself needs its checkout, which CI lacks)
   (define-values (_o4 err4 code4) (cli "--project" "nope" "--commands" "--all"))
   (check-equal? code4 1)
   (check-true (regexp-match? #rx"known: beeatlas" err4))

   (delete-directory/files tmp)])
