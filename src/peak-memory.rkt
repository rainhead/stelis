#lang racket/base

;; How much memory a task took at its peak (st-1hi.1).
;;
;; The projects' machines are sized for their largest build, and choosing a size
;; needs to know which task sets the peak. The engine starts every task, so it is
;; the one place that can measure each one without an operator sampling /proc by
;; hand over ssh. Two instruments, because neither covers the other:
;;
;;   - The KERNEL's account. getrusage(RUSAGE_CHILDREN) reports the largest
;;     resident size of any process this one has reaped, with its own reaped
;;     descendants (uv's python, bash's command) folded in. It is exact, but it
;;     is a high-water mark over the engine's whole life: it moves only when a
;;     task's largest process is larger than every earlier one. And a child
;;     between fork and exec is a copy of the engine, whose pages count as its
;;     own, so every child's mark is at least the engine's size when it forked.
;;     The figure therefore means something only when it exceeds the engine's own
;;     peak; then it names the task behind a new peak exactly.
;;   - A SAMPLER over the task's process tree in /proc, every INTERVAL-MS: the
;;     sum of the processes' resident sizes (what the machine felt at once, which
;;     the kernel's per-process mark cannot add up) and each process's own
;;     high-water mark (VmHWM, kept by the kernel between samples). A spike in a
;;     process that lives less than one interval, or in the last interval before
;;     it exits, is missed, so a sampled figure is a LOWER BOUND, and says so.
;;
;; A task's peak is the larger of the two, tagged with which one it came from. A
;; task the engine runs in-process (a rule check, a derivation) shares the
;; engine's memory, so its figure is the engine's own peak while it ran, tagged
;; 'engine. Linux has /proc; elsewhere only the kernel's account is available.
;; Sizes are in kilobytes throughout, the unit Linux reports them in.

(require ffi/unsafe
         racket/os
         racket/string
         racket/file)

(provide (struct-out peak)
         rusage-max-kb
         status-field-kb
         process-tree
         start-sampler
         measure-subprocess
         measure-in-process
         peak->string
         peak->datum
         datum->peak)

;; kb    : exact-nonnegative-integer — kilobytes
;; basis : 'process — the largest single process of the task, from the kernel (exact)
;;         'sampled — the task's process tree, sampled from /proc (a lower bound)
;;         'engine  — the engine's own peak while an in-process task ran
(struct peak (kb basis) #:transparent)

;; --- the kernel's account --------------------------------------------------------

(define getrusage
  (get-ffi-obj "getrusage" #f (_fun _int _pointer -> _int) (lambda () #f)))

;; rusage-max-kb : (or/c 'self 'children) -> (or/c exact-nonnegative-integer? #f)
;; ru_maxrss for this process ('self) or for its reaped descendants ('children).
;; struct rusage opens with two struct timevals of 16 bytes each on every 64-bit
;; Unix, so ru_maxrss is the long at byte 32. Linux counts it in kilobytes and
;; macOS in bytes.
(define (rusage-max-kb who)
  (and getrusage
       (let ([buf (malloc 256 'atomic-interior)])
         (memset buf 0 256)
         (and (zero? (getrusage (if (eq? who 'self) 0 -1) buf))
              (let ([v (ptr-ref buf _long 4)])
                (if (eq? (system-type 'os) 'macosx) (quotient v 1024) v))))))

;; --- /proc ----------------------------------------------------------------------

;; status-field-kb : string string -> (or/c exact-nonnegative-integer? #f)
;; One "Name:   1234 kB" line of a /proc/<pid>/status text.
(define (status-field-kb text field)
  (define prefix (string-append field ":"))
  (for/or ([line (in-list (string-split text "\n"))])
    (and (string-prefix? line prefix)
         (let ([words (string-split (substring line (string-length prefix)))])
           (and (pair? words) (string->number (car words)))))))

(define (read-status pid)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (file->string (format "/proc/~a/status" pid))))

(define (proc-numbers dir)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (for*/list ([p (in-list (directory-list dir))]
                [n (in-value (string->number (path->string p)))]
                #:when (exact-nonnegative-integer? n))
      n)))

;; Each thread lists the children it started, when the kernel has
;; CONFIG_PROC_CHILDREN; otherwise every process's parent is read from its stat.
(define children-files?
  (file-exists? (format "/proc/~a/task/~a/children" (getpid) (getpid))))

(define (children-of pid)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (for*/list ([tid (in-list (proc-numbers (format "/proc/~a/task" pid)))]
                [c (in-list (string-split
                             (file->string (format "/proc/~a/task/~a/children" pid tid))))])
      (string->number c))))

;; The parent is the second field after the command name, which is in parentheses
;; and may itself contain spaces or parentheses, so the text is cut at the last ")".
(define (parent-map)
  (for*/hash ([pid (in-list (proc-numbers "/proc"))]
              [stat (in-value (with-handlers ([exn:fail? (lambda (_) #f)])
                                (file->string (format "/proc/~a/stat" pid))))]
              #:when stat
              [after (in-value (let ([i (let loop ([i (sub1 (string-length stat))])
                                          (cond [(< i 0) #f]
                                                [(char=? #\) (string-ref stat i)) i]
                                                [else (loop (sub1 i))]))])
                                 (and i (string-split (substring stat (add1 i))))))]
              #:when (and after (>= (length after) 2)))
    (values pid (string->number (cadr after)))))

;; process-tree : exact-integer -> (listof exact-integer)
;; ROOT and every process descended from it that is alive now.
(define (process-tree root)
  (cond
    [children-files?
     (let loop ([todo (list root)] [seen '()])
       (cond
         [(null? todo) (reverse seen)]
         [(memv (car todo) seen) (loop (cdr todo) seen)]
         [else (loop (append (cdr todo) (children-of (car todo))) (cons (car todo) seen))]))]
    [else
     (define parents (parent-map))
     (let loop ([tree (list root)])
       (define more
         (for/list ([(pid ppid) (in-hash parents)]
                    #:when (and (memv ppid tree) (not (memv pid tree))))
           pid))
       (if (null? more) tree (loop (append tree more))))]))

;; start-sampler : exact-integer #:tree? boolean #:interval-ms number
;;                 -> (-> (values (or/c kb #f) (or/c kb #f)))
;; Sample PID (and, with #:tree?, its descendants) until the returned thunk is
;; called. The thunk stops the sampler and answers two peaks in kilobytes, each #f
;; where there is no /proc or nothing was seen: the largest SUM of the processes'
;; resident sizes at one sample, and the largest single process's high-water mark.
;; They stay apart because the second is per process, like the kernel's account,
;; and the first is not. The sampler is a Racket thread, so it runs while the
;; engine waits on a subprocess or computes in-process.
(define (start-sampler pid #:tree? [tree? #t] #:interval-ms [interval-ms 200])
  (cond
    [(not (directory-exists? "/proc/self")) (lambda () (values #f #f))]
    [else
     (define best-sum 0)
     (define best-one 0)
     ;; a tree's root that is still the engine's forked copy (not yet exec'd)
     ;; would read as the engine's size, so it is passed over until it has exec'd
     (define (engine-copy? p)
       (and tree? (= p pid)
            (equal? (exe-of p) self-exe)))
     (define (sample!)
       (define-values (sum one)
         (for/fold ([sum 0] [one 0])
                   ([p (in-list (if tree? (process-tree pid) (list pid)))]
                    #:unless (engine-copy? p))
           (define s (read-status p))
           (values (+ sum (or (and s (status-field-kb s "VmRSS")) 0))
                   (max one (or (and s (status-field-kb s "VmHWM")) 0)))))
       (set! best-sum (max best-sum sum))
       (set! best-one (max best-one one)))
     (define sampler
       (thread (lambda ()
                 (let loop ()
                   (sample!)
                   (sleep (/ interval-ms 1000.0))
                   (loop)))))
     (lambda ()
       (kill-thread sampler)
       (values (and (positive? best-sum) best-sum)
               (and (positive? best-one) best-one)))]))

;; The program a process is running, or #f once it has gone.
(define (exe-of pid)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (resolve-path (format "/proc/~a/exe" pid))))
(define self-exe (exe-of (getpid)))

;; --- per task --------------------------------------------------------------------

;; The kernel's figure is exact for the task's largest process, so it stands
;; unless the sampled SUM of several processes at once was clearly larger: a
;; launcher or shell around the main process adds a megabyte or two, which is not
;; a reason to give up the exact figure, so the sum must beat it by a tenth.
;; Without the kernel's figure (the task set no new high-water mark, or a smaller
;; one than the engine's own), the sampled figures are what there is, and a lower
;; bound.
(define (combine reaped sum one exact-basis)
  (cond
    [(and reaped (>= (* 11/10 reaped) (or sum 0))) (peak reaped exact-basis)]
    [(or sum one) (peak (max (or sum 0) (or one 0)) 'sampled)]
    [else #f]))

;; measure-subprocess : subprocess (-> any) -> (values any (or/c peak? #f))
;; Run WAIT (which must return once SP has exited and been reaped) while
;; measuring SP's process tree; answers WAIT's results and the task's peak.
(define (measure-subprocess sp wait)
  (define before (rusage-max-kb 'children))
  (define stop (start-sampler (subprocess-pid sp)))
  (define result (wait))
  (define-values (sum one) (stop))
  (define after (rusage-max-kb 'children))
  (define engine (or (rusage-max-kb 'self) 0))
  (values result
          (combine (and before after (> after before) (> after engine) after)
                   sum one 'process)))

;; measure-in-process : (-> any) -> (values any (or/c peak? #f))
;; Run THUNK in the engine, measuring the engine's own memory while it runs.
;; THUNK's results must be a single value; wrap multiple values in a list.
(define (measure-in-process thunk)
  (define before (rusage-max-kb 'self))
  (define stop (start-sampler (getpid) #:tree? #f))
  (define result (thunk))
  (define-values (sum one) (stop))
  (define after (rusage-max-kb 'self))
  (values result
          (let ([p (combine (and before after (> after before) after) sum one 'engine)])
            ;; the sampler watched the engine too, so either figure is the engine's
            (and p (peak (peak-kb p) 'engine)))))

;; --- rendering and the trace --------------------------------------------------------

(define (kb->mb kb) (number->string (quotient (+ kb 512) 1024)))

;; peak->string : peak -> string
;; "peak 412 MB", "peak ≥ 412 MB (sampled)", "engine peak 412 MB", "peak < 1 MB".
(define (peak->string p)
  (define kb (peak-kb p))
  (define size (if (< kb 1024) "< 1 MB" (format "~a MB" (kb->mb kb))))
  (case (peak-basis p)
    [(process) (format "peak ~a" size)]
    [(sampled) (format "peak ~a~a (sampled)" (if (< kb 1024) "" "≥ ") size)]
    [(engine) (format "engine peak ~a" size)]))

(define (peak->datum p) (and p (list (peak-kb p) (peak-basis p))))
(define (datum->peak v)
  (and (list? v) (= 2 (length v))
       (exact-nonnegative-integer? (car v))
       (memq (cadr v) '(process sampled engine))
       (peak (car v) (cadr v))))
