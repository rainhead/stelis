#lang racket/base

;; Observed reads vs. the declared edge (st-25h).
;;
;; --verify-edges asks its question by WITHHOLDING: seed an EXPORT_DIR with only
;; a task's declared inputs and see whether it still runs. That cannot reach the
;; inputs which resolve to FIXED paths — the dbt sandbox, committed seeds and
;; registers, config files — because withholding those would mean mutating real
;; files. Its own scope note concedes it, and that is the category of input most
;; often forgotten.
;;
;; So this half asks the question by OBSERVATION instead: run the task normally,
;; record what it actually opened, and classify each read against the graph.
;; Nothing is withheld, so nothing has to be mutated.
;;
;; THE ASYMMETRY MATTERS. An observed read of an undeclared path is a STRONG
;; signal — the task depends on something the cache is not watching, which is a
;; wrong-skip waiting to happen. A declared input that went UNREAD is a weak one:
;; a data-dependent branch makes any single run a LOWER BOUND on the read set, so
;; an unread declaration may simply not have been needed by today's data. Report
;; both, but they are not the same kind of fact and the caller must not treat
;; them as one.
;;
;; The Python-side probe is src/probe/sitecustomize.py, which documents its own
;; blind spot: reads performed INSIDE a C extension are invisible (duckdb reading
;; a parquet file emits nothing). That half is a SQL problem rather than a
;; syscall problem and wants a separate instrument — it is NOT covered here, and
;; `trace-report` says so rather than presenting its finding as complete.

(require racket/runtime-path
         racket/set
         racket/list
         racket/path
         racket/string
         racket/file)

(provide trace-probe-dir
         trace-env
         parse-trace-log
         (struct-out observed-read)
         (struct-out trace-report)
         full-resolve
         path-under?
         classify-read
         build-trace-report
         trace-report->string)

(define-runtime-path trace-probe-dir "probe")

;; ---------------------------------------------------------------- environment

;; trace-env : path-string (listof (cons string string)) -> (listof (cons string string))
;; The two variables that turn the probe on, prepended to a task's existing env.
;; PYTHONPATH is PREPENDED rather than replaced: a recipe that already sets it
;; still gets its own entries, and ours only has to win the `sitecustomize` name
;; (the probe chain-loads any real one it shadows). A traced run and an untraced
;; run therefore differ by exactly these two variables.
(define (trace-env log-path [base '()])
  (define existing (getenv "PYTHONPATH"))
  (define ours (path->string (path->complete-path trace-probe-dir)))
  (append base
          (list (cons "STELIS_TRACE" (if (path? log-path)
                                         (path->string log-path)
                                         log-path))
                (cons "PYTHONPATH"
                      (if (and existing (not (string=? existing "")))
                          (string-append ours ":" existing)
                          ours)))))

;; ------------------------------------------------------------------- the log

;; observed-read : one line of the probe's log.
;;   kind — 'open (a data read, named at the moment it happened)
;;        | 'module (a code read, recovered from sys.modules at exit — the `open`
;;                  events cannot give this: a warm __pycache__ means the .py is
;;                  never opened, only the .pyc)
;;   path — absolute
;;   detail — the open mode, or the dotted module name
(struct observed-read (kind path detail) #:transparent)

;; parse-trace-log : path-string -> (values (listof observed-read) (listof string) boolean)
;; Returns the reads, the probe's own remarks, and whether the module sweep
;; COMPLETED. The last is not a detail: the sweep runs at normal interpreter exit,
;; so a task killed by a signal loses its whole code half while the `open` half
;; survives (line-buffered). A report built on a partial trace must say so rather
;; than read as "this task imports nothing".
(define (parse-trace-log path)
  (cond
    [(not (file-exists? path)) (values '() (list "no trace log was written") #f)]
    [else
     (define-values (reads remarks swept)
       (for/fold ([reads '()] [remarks '()] [swept #f])
                 ([line (in-list (file->lines path))])
         (define fields (string-split line "\t" #:trim? #f))
         (cond
           [(< (length fields) 2) (values reads remarks swept)]
           [else
            (define kind (car fields))
            (define a (cadr fields))
            (define b (if (>= (length fields) 3) (caddr fields) ""))
            (cond
              [(string=? kind "open")
               (values (cons (observed-read 'open a b) reads) remarks swept)]
              [(string=? kind "module")
               ;; module<TAB>dotted.name<TAB>abspath — the PATH is the third field
               (values (cons (observed-read 'module b a) reads) remarks swept)]
              [(string=? kind "probe")
               (values reads (cons a remarks)
                       (or swept (string=? a "sweep-complete")))]
              [else (values reads remarks swept)])])))
     (values (reverse reads) (reverse remarks) swept)]))

;; ------------------------------------------------------------ path normalizing

;; full-resolve : path-string -> path
;; Every symlink resolved, not just the last element. Both sides of this
;; comparison name the same file through different routes — the probe reports
;; os.path.abspath and Racket's scratch dir arrives via (find-system-path
;; 'temp-dir) — and on macOS /tmp IS a symlink to /private/tmp, so a structural
;; comparison alone would classify a task's own scratch reads as foreign. Walk
;; the path element-wise (the dir-extent.rkt lesson: `/a/b` and `/a/b/` are not
;; `equal?`, and element-wise is the only comparison that is honest about it).
(define (full-resolve p)
  (define complete (path->complete-path (if (string? p) (string->path p) p)))
  (let loop ([elements (explode-path (simplify-path complete #f))] [acc #f])
    (cond
      [(null? elements) (or acc (build-path "/"))]
      [else
       (define next (if acc (build-path acc (car elements)) (car elements)))
       ;; resolve-path resolves ONE link, at the end of the path. So this walks
       ;; twice over: once per element, and once per hop within an element, since
       ;; a link's target may itself be a link (link2 -> link1 -> real). Resolving
       ;; a single hop left chained links half-resolved, and two paths reaching one
       ;; file by chains of different length then failed to compare `equal?` — a
       ;; declared input reading as 'undeclared, or worse as 'foreign, which is the
       ;; SILENT direction. The hop count is bounded because a symlink CYCLE is a
       ;; real filesystem state and an unbounded walk would hang the build rather
       ;; than misreport; at the cap we return what we have and let the comparison
       ;; be conservative.
       (define resolved (resolve-links next (or acc (build-path "/"))))
       (loop (cdr elements) resolved)])))

;; resolve-links : path path -> path
;; Follow a chain of symlinks at `p' to its end, resolving relative targets
;; against `base'. Bounded (32, comfortably past any real chain) so a symlink
;; cycle terminates instead of hanging.
(define (resolve-links p base)
  (let hop ([current p] [fuel 32])
    (cond
      [(zero? fuel) current]
      [(not (or (file-exists? current) (directory-exists? current) (link-exists? current)))
       current]
      [else
       (define r (resolve-path current))
       (define next (if (absolute-path? r)
                        r
                        (simplify-path (build-path (or (path-only current) base) r) #f)))
       ;; resolve-path returns the path unchanged when it is not a link: fixpoint.
       (if (equal? next current) current (hop next (sub1 fuel)))])))

;; path-under? : path path -> boolean
;; Is `p' the root itself, or strictly inside it? Element-wise, so a sibling
;; whose name merely shares a prefix (`/a/bc` under `/a/b`) is not a match.
(define (path-under? p root)
  (define pe (explode-path p))
  (define re (explode-path root))
  (and (>= (length pe) (length re))
       (for/and ([a (in-list (take pe (length re)))]
                 [b (in-list re)])
         (equal? a b))))

;; ------------------------------------------------------------- classification

;; classify-read : path sets... -> symbol
;; The PURE core, filesystem-free (its inputs are already-resolved paths), so it
;; is the part unit-tested directly — as with edge-verify.rkt's classify-outputs.
;;
;;   'declared   — a declared input of this task (or a file inside a declared
;;                 'dir input)
;;   'own-output — something this task declares it writes; reading it back is not
;;                 an undeclared dependency
;;   'code       — already hashed into the task's input address as recipe code
;;   'undeclared — under a root the GRAPH knows about, but declared by nobody:
;;                 THE FINDING
;;   'foreign    — outside every root the graph knows. The venv, the stdlib, a
;;                 temp file. Not this graph's business, and deliberately not
;;                 reported: the filter is derived from the graph rather than
;;                 hand-kept, so a new producer widens it automatically (the
;;                 dir-extent.rkt move — a hand-kept list's failure mode is
;;                 silent).
(define (classify-read p #:declared declared #:declared-dirs declared-dirs
                       #:outputs outputs #:output-dirs output-dirs
                       #:code code #:roots roots)
  (cond
    [(set-member? declared p) 'declared]
    [(for/or ([d (in-list declared-dirs)]) (path-under? p d)) 'declared]
    [(set-member? outputs p) 'own-output]
    [(for/or ([d (in-list output-dirs)]) (path-under? p d)) 'own-output]
    [(set-member? code p) 'code]
    [(for/or ([r (in-list roots)]) (path-under? p r)) 'undeclared]
    [else 'foreign]))

;; trace-report : one task's verdict.
;;   undeclared — reads nobody declared, each (cons path kind). THE finding.
;;   unread     — declared inputs no read touched. WEAK (see the header note).
;;   counts     — an alist of classification -> how many, for the "and the rest
;;                looked fine" line, so a clean run still shows it observed
;;                something rather than silently observing nothing.
;;   swept?     — did the module sweep complete? #f means the code half is partial.
;;   remarks    — the probe's own log lines (install, chain-load, failures).
(struct trace-report (task undeclared unread counts swept? remarks) #:transparent)

;; build-trace-report : symbol (listof observed-read) sets... -> trace-report
(define (build-trace-report task reads remarks swept?
                           #:declared declared #:declared-dirs declared-dirs
                           #:outputs outputs #:output-dirs output-dirs
                           #:code code #:roots roots)
  (define-values (undeclared touched counts)
    (for/fold ([undeclared '()] [touched (set)] [counts (hash)])
              ([r (in-list reads)])
      (define p (full-resolve (observed-read-path r)))
      (define c (classify-read p
                               #:declared declared #:declared-dirs declared-dirs
                               #:outputs outputs #:output-dirs output-dirs
                               #:code code #:roots roots))
      (values (if (eq? c 'undeclared)
                  (cons (cons p (observed-read-kind r)) undeclared)
                  undeclared)
              (if (eq? c 'declared) (set-add touched p) touched)
              (hash-update counts c add1 0))))
  ;; A declared 'dir input counts as touched when ANY file inside it was read —
  ;; the declaration is of the directory, and no run reads every member.
  (define dir-touched
    (for/set ([d (in-list declared-dirs)]
              #:when (for/or ([r (in-list reads)])
                       (path-under? (full-resolve (observed-read-path r)) d)))
      d))
  (trace-report task
                (sort (remove-duplicates undeclared)
                      string<? #:key (lambda (x) (path->string (car x))))
                (sort (for/list ([d (in-set (set-subtract
                                             (set-union declared (list->set declared-dirs))
                                             (set-union touched dir-touched)))])
                        d)
                      string<? #:key path->string)
                counts swept? remarks))

;; trace-report->string : trace-report -> string
(define (trace-report->string rep)
  (define (n c) (hash-ref (trace-report-counts rep) c 0))
  (define out (open-output-string))
  (fprintf out "~a — observed ~a reads (~a declared, ~a own output, ~a code, ~a foreign)\n"
           (trace-report-task rep)
           (+ (n 'declared) (n 'own-output) (n 'code) (n 'undeclared) (n 'foreign))
           (n 'declared) (n 'own-output) (n 'code) (n 'foreign))
  (cond
    [(null? (trace-report-undeclared rep))
     (fprintf out "  ✓ no undeclared reads under any path the graph knows about\n")]
    [else
     (fprintf out "  ✗ ~a UNDECLARED read(s) — the task depends on these and the cache is not watching them:\n"
              (length (trace-report-undeclared rep)))
     (for ([u (in-list (trace-report-undeclared rep))])
       (fprintf out "      ~a  [~a]\n" (path->string (car u)) (cdr u)))])
  (unless (null? (trace-report-unread rep))
    (fprintf out "  · ~a declared input(s) went unread THIS run (weak signal — a data-dependent\n    branch makes one run a lower bound, not proof the declaration is spurious):\n"
             (length (trace-report-unread rep)))
    (for ([u (in-list (trace-report-unread rep))])
      (fprintf out "      ~a\n" (path->string u))))
  (unless (trace-report-swept? rep)
    (fprintf out "  ! the module sweep did NOT complete — the CODE half of this trace is partial\n"))
  (fprintf out "  ! not covered: reads inside a C extension are invisible to this probe\n")
  (fprintf out "    (duckdb reading a parquet file emits nothing). Relation-grain reads need\n")
  (fprintf out "    their own instrument — st-25h ladder step 1b.\n")
  (get-output-string out))
