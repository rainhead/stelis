#lang racket/base

;; Unit tests for the read-trace harness's PURE core (st-25h). Running a real
;; task under the probe is an integration concern (see read-trace.rkt's header
;; and --trace-reads); here we test the classification and the log parse, which
;; is where this harness's judgement actually lives — the same split
;; edge-verify-test.rkt makes.

(require rackunit
         racket/set
         racket/file
         racket/list
         "read-trace.rkt")

(define (p s) (string->path s))

;; --- path-under? : element-wise, not string-prefix ---------------------------

(check-true (path-under? (p "/a/b/c") (p "/a/b")) "a descendant is under its root")
(check-true (path-under? (p "/a/b") (p "/a/b")) "a root is under itself")
(check-false (path-under? (p "/a") (p "/a/b")) "an ancestor is not under its child")
;; The reason this is element-wise rather than a string prefix: `/a/bc` shares
;; the text "/a/b" with `/a/b` but is a SIBLING, and a string test would swallow
;; it — silently classifying another producer's tree as this task's business.
(check-false (path-under? (p "/a/bc") (p "/a/b"))
             "a sibling sharing a name prefix is not under the root")

;; --- classify-read : where does one observed read belong? -------------------

(define (classify path
                  #:declared [declared (set)]
                  #:declared-dirs [declared-dirs '()]
                  #:outputs [outputs (set)]
                  #:output-dirs [output-dirs '()]
                  #:code [code (set)]
                  #:roots [roots '()])
  (classify-read path
                 #:declared declared #:declared-dirs declared-dirs
                 #:outputs outputs #:output-dirs output-dirs
                 #:code code #:roots roots))

(check-equal? (classify (p "/w/in.parquet") #:declared (set (p "/w/in.parquet")))
              'declared
              "a declared input reads as declared")

;; A declared 'dir input is satisfied by a read of any file INSIDE it: the
;; declaration is of the directory, and no run reads every member.
(check-equal? (classify (p "/w/notes/Bombus.json") #:declared-dirs (list (p "/w/notes")))
              'declared
              "a file inside a declared 'dir input is declared")

(check-equal? (classify (p "/w/out.json") #:outputs (set (p "/w/out.json")))
              'own-output
              "reading back something this task writes is not a dependency on someone else")

(check-equal? (classify (p "/repo/exporter.py") #:code (set (p "/repo/exporter.py")))
              'code
              "recipe code is already hashed into the input address")

;; THE FINDING: under a root the graph knows, declared by nobody.
(check-equal? (classify (p "/repo/seeds/synonyms.csv") #:roots (list (p "/repo")))
              'undeclared
              "a read under a known root that nobody declared is the finding")

;; Outside every root the graph knows: the venv, the stdlib, a temp file. Not
;; reported, because the filter is DERIVED from the graph rather than hand-kept.
(check-equal? (classify (p "/usr/lib/python3.14/json/__init__.py") #:roots (list (p "/repo")))
              'foreign
              "a read outside every known root is not this graph's business")

;; Precedence: a path that is BOTH declared and under a known root is declared,
;; not a finding. Otherwise every correct edge would report itself as a bug.
(check-equal? (classify (p "/repo/in.parquet")
                        #:declared (set (p "/repo/in.parquet"))
                        #:roots (list (p "/repo")))
              'declared
              "being under a known root does not override an explicit declaration")

;; --- parse-trace-log --------------------------------------------------------

(define (with-log lines proc)
  (define f (make-temporary-file))
  (display-to-file (apply string-append (map (lambda (l) (string-append l "\n")) lines))
                   f #:exists 'truncate)
  (begin0 (proc f) (delete-file f)))

;; `open' names the path in field 2; `module' names it in field 3 (field 2 is the
;; dotted name). Getting that backwards would silently record module NAMES as
;; paths, which classify as foreign — a clean report built on nothing.
(with-log '("probe\tinstalled pid=1 exe=/x/python"
            "open\t/w/in.parquet\tr"
            "module\tdomain\t/repo/domain.py"
            "probe\tsweep-complete")
  (lambda (f)
    (define-values (reads remarks swept?) (parse-trace-log f))
    (check-equal? (length reads) 2 "both a read and a module line are reads")
    (check-equal? (observed-read-kind (first reads)) 'open)
    (check-equal? (observed-read-path (first reads)) "/w/in.parquet")
    (check-equal? (observed-read-kind (second reads)) 'module)
    (check-equal? (observed-read-path (second reads)) "/repo/domain.py"
                  "a module line's PATH is its third field, not its second")
    (check-equal? (observed-read-detail (second reads)) "domain")
    (check-true swept? "sweep-complete sets the swept flag")
    (check-equal? (length remarks) 2 "probe lines are remarks, not reads")))

;; A task killed before exit loses the module sweep but keeps its `open' lines
;; (they are line-buffered). The flag must report that, or a partial trace reads
;; exactly like a task that imports nothing.
(with-log '("probe\tinstalled pid=1 exe=/x/python"
            "open\t/w/in.parquet\tr")
  (lambda (f)
    (define-values (reads remarks swept?) (parse-trace-log f))
    (check-equal? (length reads) 1 "the open half survives")
    (check-false swept? "no sweep-complete means the code half is partial")))

;; No log at all is NOT "no undeclared reads" — it is a probe that never ran.
(let-values ([(reads remarks swept?)
              (parse-trace-log (build-path (find-system-path 'temp-dir)
                                           "stelis-no-such-trace.log"))])
  (check-equal? reads '() "a missing log yields no reads")
  (check-false swept? "a missing log is not a completed sweep")
  (check-equal? (length remarks) 1 "and says so as a remark rather than passing silently"))

;; --- build-trace-report -----------------------------------------------------

;; The end-to-end shape on a task whose edge is right: one declared read, one
;; code read, nothing undeclared, nothing left unread.
(let ([rep (build-trace-report
            'exporter
            (list (observed-read 'open (path->string (p "/repo/in.parquet")) "r")
                  (observed-read 'module (path->string (p "/repo/exporter.py")) "exporter"))
            '() #t
            #:declared (set (p "/repo/in.parquet")) #:declared-dirs '()
            #:outputs (set) #:output-dirs '()
            #:code (set (p "/repo/exporter.py")) #:roots (list (p "/repo")))])
  (check-equal? (trace-report-undeclared rep) '() "a correct edge reports no finding")
  (check-equal? (trace-report-unread rep) '() "and nothing declared went unread"))

;; The finding, and the WEAK signal, are kept apart: an undeclared read is
;; reported as a defect while an unread declaration is reported as a maybe.
;; A caller that merged them would act on a data-dependent branch as if it were
;; a spurious edge.
(let ([rep (build-trace-report
            'gate
            (list (observed-read 'open (path->string (p "/repo/seeds/synonyms.csv")) "r"))
            '() #t
            #:declared (set (p "/repo/declared-but-idle.parquet")) #:declared-dirs '()
            #:outputs (set) #:output-dirs '()
            #:code (set) #:roots (list (p "/repo")))])
  (check-equal? (map car (trace-report-undeclared rep))
                (list (p "/repo/seeds/synonyms.csv"))
                "the undeclared read is the finding")
  (check-equal? (trace-report-unread rep)
                (list (p "/repo/declared-but-idle.parquet"))
                "the untouched declaration is reported separately, as the weak signal"))
