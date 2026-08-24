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
         "model.rkt"
         (only-in "dir-extent.rkt" strictly-inside?)
         racket/list
         racket/path
         racket/string
         racket/file)

(provide trace-probe-dir
         trace-env
         parse-trace-log
         (struct-out task-edge)
         resolve-task-edge
         graph-known-roots
         open-mode-write?
         (struct-out observed-read)
         (struct-out trace-report)
         full-resolve
         path-under?
         classify-read
         build-trace-report
         trace-report->string)

(define-runtime-path trace-probe-dir "probe")

;; ---------------------------------------------------------------- environment

;; trace-env : path-string (listof (cons string string))
;;             -> (listof (cons string string))
;; The two variables that turn the probe on, folded into a task's existing env.
;; PYTHONPATH is PREPENDED to whatever `base' already carries, so a recipe that
;; sets its own still gets its entries and ours only has to win the
;; `sitecustomize' name (the probe chain-loads any real one it shadows). It reads
;; `base' rather than (getenv "PYTHONPATH") deliberately: the subprocess's
;; PYTHONPATH is the one being composed, and consulting Stelis's own environment
;; instead would both miss a recipe's value and silently inherit whatever the
;; operator's shell happened to export into the hermetic runtime.
(define (trace-env log-path [base '()])
  (define existing (cond [(assoc "PYTHONPATH" base) => cdr] [else #f]))
  (define ours (path->string (path->complete-path trace-probe-dir)))
  (append (filter (lambda (kv) (not (string=? (car kv) "PYTHONPATH"))) base)
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
;; Is `p' the root itself, or inside it? The strict half is dir-extent.rkt's
;; `strictly-inside?' — the module that owns this lesson (`/a/bc' is not inside
;; `/a/b' even though one string prefixes the other, and `/a/b' vs `/a/b/' are not
;; `equal?'). Reimplementing the element-wise walk here made a second place for
;; that lesson to be re-learned or half-forgotten.
(define (path-under? p root)
  (or (equal? (explode-path p) (explode-path root))
      (strictly-inside? p root)))

;; ---------------------------------------------------------- what a task's edge is

;; task-edge : one task's DECLARED edge, resolved to real paths — everything the
;; classifier needs, as one value. These six travelled as six keyword arguments
;; through classify-read, build-trace-report and the CLI call site, which is a type
;; asking to be born; more to the point, three of them are only meaningful together
;; (a file set and its companion dir list are one declaration, split by kind).
;;   declared/outputs : sets of resolved paths, for the non-'dir artifacts
;;   declared-dirs/output-dirs : lists of resolved 'dir roots, satisfied by a read
;;     of ANY file inside them — the declaration is of the directory, and no run
;;     reads every member
;;   code : recipe code paths, already hashed into the task's input address
;;   roots : the directories the GRAPH knows about; everything outside is foreign
(struct task-edge (declared declared-dirs outputs output-dirs code roots) #:transparent)

;; resolve-task-edge : graph symbol (symbol -> (or/c path-string #f)) -> task-edge
;; Read the graph and hand back the resolved edge. This lives here rather than at
;; the CLI because it is graph reasoning, not IO — the caller supplies `resolve'
;; and keeps the only impure part, the delta-explain seam idiom. It was ~50 lines
;; inside main.rkt's command clause, where it could not be tested.
(define (resolve-task-edge g name resolve)
  (define t (hash-ref (graph-tasks g) name
                      (lambda () (error 'resolve-task-edge "no task named ~a" name))))
  (define (dir? a)
    (define art (hash-ref (graph-artifacts g) a #f))
    (and art (eq? 'dir (artifact-kind art))))
  (define (resolved-of names)
    (for*/list ([a (in-list names)]
                [p (in-value (resolve a))]
                #:when p)
      (cons a (full-resolve p))))
  (define ins (resolved-of (task-inputs t)))
  (define outs (resolved-of (task-outputs t)))
  (define (paths-of pairs keep?)
    (for/list ([pr (in-list pairs)] #:when (keep? (car pr))) (cdr pr)))
  (task-edge
   (list->set (paths-of ins (lambda (a) (not (dir? a)))))
   (paths-of ins dir?)
   (list->set (paths-of outs (lambda (a) (not (dir? a)))))
   (paths-of outs dir?)
   ;; recipe `code' is NOT an artifact (the uv pin files ride every uv recipe), so
   ;; it comes off the invoke rather than off task-inputs.
   (list->set (for/list ([e (in-list (invoke-code (task-invoke t)))])
                (full-resolve (code-entry-path e))))
   (graph-known-roots g resolve)))

;; graph-known-roots : graph (symbol -> (or/c path-string #f)) -> (listof path)
;; The interesting/uninteresting frontier, DERIVED from the graph rather than
;; hand-kept: a directory the graph already names something in is this build's
;; business, and everything else (the venv, the stdlib, a temp file) is not. A new
;; producer widens it automatically — the dir-extent.rkt move, taken for the same
;; reason: a hand-kept list's failure mode is silent.
(define (graph-known-roots g resolve)
  (remove-duplicates
   (append
    (for*/list ([a (in-list (hash-keys (graph-artifacts g)))]
                [p (in-value (resolve a))]
                #:when p
                [full (in-value (full-resolve p))])
      (define art (hash-ref (graph-artifacts g) a #f))
      (if (and art (eq? 'dir (artifact-kind art))) full (or (path-only full) full)))
    (for*/list ([(tn tt) (in-hash (graph-tasks g))]
                [e (in-list (invoke-code (task-invoke tt)))]
                [full (in-value (full-resolve (code-entry-path e)))])
      (or (path-only full) full)))))

;; ------------------------------------------------------------- classification

;; open-mode-write? : (or/c string #f) -> boolean
;; Did this open ACQUIRE the file's contents, or replace them? The probe records
;; the mode and nothing consulted it, so a mode-"w" open — a WRITE — was reported
;; as an undeclared read, under the words "the task depends on these". That is a
;; false claim about causation, and it collapses the very distinction st-6w9 was
;; filed to keep: an undeclared INPUT is this tool's question, an undeclared
;; OUTPUT is --verify-edges'. An unknown mode (os.open, which reports flags rather
;; than a mode string) counts as a read, because a missed read is the silent
;; failure and a mislabelled write is the loud one.
(define (open-mode-write? mode)
  (and (string? mode)
       (for/or ([ch (in-string "wax+")]) (and (memv ch (string->list mode)) #t))))

;; classify-read : path task-edge -> symbol
;; The PURE core, filesystem-free (its input paths are already resolved), so it is
;; the part unit-tested directly — as with edge-verify.rkt's classify-outputs.
;;
;;   'declared   — a declared input of this task (or a file inside a declared
;;                 'dir input)
;;   'own-output — something this task declares it writes; touching it is not a
;;                 dependency on anyone else
;;   'code       — already hashed into the task's input address as recipe code
;;   'undeclared — under a root the GRAPH knows about, but declared by nobody:
;;                 THE FINDING
;;   'foreign    — outside every root the graph knows. Not this graph's business,
;;                 and deliberately not reported.
(define (classify-read p edge)
  (cond
    [(set-member? (task-edge-declared edge) p) 'declared]
    [(for/or ([d (in-list (task-edge-declared-dirs edge))]) (path-under? p d)) 'declared]
    [(set-member? (task-edge-outputs edge) p) 'own-output]
    [(for/or ([d (in-list (task-edge-output-dirs edge))]) (path-under? p d)) 'own-output]
    [(set-member? (task-edge-code edge) p) 'code]
    [(for/or ([r (in-list (task-edge-roots edge))]) (path-under? p r)) 'undeclared]
    [else 'foreign]))

;; trace-report : one task's verdict.
;;   undeclared — READS nobody declared, each (cons path kind). THE finding.
;;   undeclared-writes — files the task WROTE that it declares no output for.
;;     Reported separately and NOT part of the exit verdict: this command's name
;;     is its contract, and an undeclared output is --verify-edges' question
;;     (st-6w9). Surfacing it silently would be worse than either.
;;   unread     — declared inputs no read touched. WEAK (see the header note).
;;   counts     — classification -> how many, for the "and the rest looked fine"
;;                line, so a clean run shows it observed something rather than
;;                silently observing nothing.
;;   swept?     — did the module sweep complete? #f means the code half is partial.
;;   remarks    — the probe's own log lines (install, chain-load, failures).
(struct trace-report (task undeclared undeclared-writes unread counts swept? remarks)
  #:transparent)

;; build-trace-report : symbol (listof observed-read) (listof string) boolean task-edge
;;                      -> trace-report
(define (build-trace-report task reads remarks swept? edge)
  ;; Resolve every observed path ONCE. The dir-touched pass below needs them too,
  ;; and re-resolving there walked the filesystem a second time for every read.
  (define resolved
    (for/list ([r (in-list reads)])
      (cons (full-resolve (observed-read-path r)) r)))
  (define-values (undeclared undeclared-writes touched counts)
    (for/fold ([undeclared '()] [writes '()] [touched (set)] [counts (hash)])
              ([pr (in-list resolved)])
      (define p (car pr))
      (define r (cdr pr))
      (define c (classify-read p edge))
      (define write? (and (eq? (observed-read-kind r) 'open)
                          (open-mode-write? (observed-read-detail r))))
      (values (if (and (eq? c 'undeclared) (not write?))
                  (cons (cons p (observed-read-kind r)) undeclared)
                  undeclared)
              (if (and (eq? c 'undeclared) write?) (cons p writes) writes)
              (if (eq? c 'declared) (set-add touched p) touched)
              (hash-update counts c add1 0))))
  ;; A declared 'dir input counts as touched when ANY file inside it was read —
  ;; the declaration is of the directory, and no run reads every member.
  (define dir-touched
    (for/set ([d (in-list (task-edge-declared-dirs edge))]
              #:when (for/or ([pr (in-list resolved)]) (path-under? (car pr) d)))
      d))
  (define (sorted-paths xs) (sort xs string<? #:key path->string))
  (trace-report task
                (sort (remove-duplicates undeclared)
                      string<? #:key (lambda (x) (path->string (car x))))
                (sorted-paths (remove-duplicates undeclared-writes))
                (sorted-paths
                 (set->list (set-subtract
                             (set-union (task-edge-declared edge)
                                        (list->set (task-edge-declared-dirs edge)))
                             (set-union touched dir-touched))))
                counts swept? remarks))

;; trace-report->string : trace-report -> string
(define (trace-report->string rep)
  (define (n c) (hash-ref (trace-report-counts rep) c 0))
  (define out (open-output-string))
  ;; Every classification the total counts is also shown. The breakdown used to
  ;; omit 'undeclared while the total included it, so the numbers stopped adding
  ;; up exactly when there was a finding to report — the one moment the report
  ;; most needs to be trusted.
  (fprintf out "~a — observed ~a reads (~a declared, ~a own output, ~a code, ~a undeclared, ~a foreign)\n"
           (trace-report-task rep)
           (+ (n 'declared) (n 'own-output) (n 'code) (n 'undeclared) (n 'foreign))
           (n 'declared) (n 'own-output) (n 'code) (n 'undeclared) (n 'foreign))
  (cond
    [(null? (trace-report-undeclared rep))
     (fprintf out "  ✓ no undeclared reads under any path the graph knows about\n")]
    [else
     (fprintf out "  ✗ ~a UNDECLARED read(s) — the task depends on these and the cache is not watching them:\n"
              (length (trace-report-undeclared rep)))
     (for ([u (in-list (trace-report-undeclared rep))])
       (fprintf out "      ~a  [~a]\n" (path->string (car u)) (cdr u)))])
  (unless (null? (trace-report-undeclared-writes rep))
    (fprintf out "  · ~a undeclared WRITE(s) — the task wrote these and declares no output for\n    them. Not counted in this command's verdict: an undeclared output is\n    --verify-edges' question (st-6w9), and calling it a dependency would be false.\n"
             (length (trace-report-undeclared-writes rep)))
    (for ([w (in-list (trace-report-undeclared-writes rep))])
      (fprintf out "      ~a\n" (path->string w))))
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
