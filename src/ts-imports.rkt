#lang racket/base

;; TypeScript import closure (st-6i2): the local files a node script loads, computed
;; at GRAPH-AUTHORING time so a recipe's code list cannot drift from the script, the
;; way py-imports.rkt does it for beeatlas's Python (st-6ga; see there for why this
;; is authoring time and not a build task).
;;
;; The hand-kept lists drifted both ways. salishsea #664 deleted src/supabase.ts and
;; the eight tasks still naming it could never be skipped, for sixteen days; and two
;; files the page scripts did import were not listed, so an edit to either would have
;; been skipped and the published pages left stale (stelis #13).
;;
;; What the scan follows, from each .ts file, transitively:
;;   - a static import or re-export with a RELATIVE specifier: `import x from
;;     './a.ts'`, `import './a.ts'`, `export { y } from '../b.ts'`. A type-only one
;;     (`import type ...`, `export type ... from`) is skipped: it loads nothing at run
;;     time. An import that names some bindings as `type` still loads the module.
;;   - a dynamic `import('./c.ts')` with a literal specifier;
;;   - a file read as `new URL('./d.json', import.meta.url)` with a literal path.
;; A Vite query (`?raw`, `?url`) is dropped from a specifier. Package imports (no
;; leading `.`) are left to the lockfile, which every node recipe hashes.
;;
;; Honest limits, the same direction py-imports names: a regex scan over the text,
;; not a TypeScript parser. It over-approximates where that is cheap (an import whose
;; bindings are used only as types is followed, though Node's type stripping and
;; esbuild both drop it: an extra rerun, never a stale skip). It cannot see a path
;; built at run time (``new URL(`./derive/${file}`, import.meta.url)``, a readFile of
;; a computed name), so a caller still declares those files, and the scan reports
;; nothing for them. A specifier that resolves to no file is returned as the path it
;; names, so the task's address is unresolvable and the checkout test says which.
;;
;; The scan reads only files, never runs node or esbuild: the graph is authored on
;; every launch.

(require racket/list
         racket/path
         racket/set
         racket/string
         racket/file)

(provide parse-ts-imports
         make-ts-import-closure)

;; --- Pure parse layer -------------------------------------------------------

;; A static import or re-export: the keyword at a line's start, an optional `type`,
;; then (across lines, up to the specifier) either `... from '<spec>'` or the bare
;; side-effect form `import '<spec>'`. Matched only within the stretch from one line
;; that starts with `import` or `export` to the next, so one statement never runs
;; into the next: otherwise `export type T = {...}` with no semicolon would swallow
;; the import after it, and mark that import type-only. Finding the stretches first is
;; also what keeps this cheap: the statement pattern runs once per stretch and stops
;; at the first quote or `;`, instead of being tried at every character.
;; Byte patterns over the file's bytes: everything matched is ASCII syntax, and a
;; pattern over a character string converts it on every call, which cost most of the
;; scan (the graph is authored on every launch).
(define statement-start-rx #px#"(?m:^[ \t]*(?:import|export)[ \t{*])")
(define statement-rx
  #px#"^[ \t]*(?:import|export)[ \t]+(type[ \t]+)?(?:[^'\";]*?[ \t\n]from[ \t]*)?['\"](\\.[^'\"]*)['\"]")
(define dynamic-rx #px#"import\\(\\s*['\"`](\\.[^'\"`$]*)['\"`]\\s*\\)")
(define url-rx #px#"new URL\\(\\s*['\"`](\\.[^'\"`$]*)['\"`]\\s*,\\s*import\\.meta\\.url")

;; parse-ts-imports : (or/c string bytes) -> (values (listof string) (listof string))
;; The relative specifiers `text` loads: (values modules reads). MODULES are the
;; static and dynamic imports, which the closure recurses into; READS are the
;; import.meta.url file reads, which it does not. Query suffixes stripped,
;; duplicates removed, in order of appearance.
(define (parse-ts-imports text*)
  (define text (if (bytes? text*) text* (string->bytes/utf-8 text*)))
  (define (strip b) (car (string-split (bytes->string/utf-8 b #\?) "?" #:trim? #f)))
  (define starts (map car (regexp-match-positions* statement-start-rx text)))
  (define statics
    (for*/list ([(from to) (in-parallel (in-list starts)
                                        (in-list (append (if (pair? starts) (cdr starts) '())
                                                         (list (bytes-length text)))))]
                [m (in-value (regexp-match statement-rx text from to))]
                #:when (and m (not (cadr m))))
      (strip (caddr m))))
  (define dynamics (map (lambda (m) (strip (cadr m)))
                        (regexp-match* dynamic-rx text #:match-select values)))
  (define reads (map (lambda (m) (strip (cadr m)))
                     (regexp-match* url-rx text #:match-select values)))
  (values (remove-duplicates (append statics dynamics))
          (remove-duplicates reads)))

;; --- Resolution and closure -------------------------------------------------

;; resolve : path string -> path
;; A relative specifier from the file `from`: the file as named, else with `.ts`
;; added, else `.js` read as `.ts` (TypeScript's convention), else `<dir>/index.ts`.
;; When none exists, the path as named — so an import of a deleted file shows up as
;; that missing file rather than vanishing.
(define (resolve from spec)
  (define p (simplify-path (build-path (path-only from) spec) #f))
  (define s (path->string p))
  (or (for/first ([c (in-list (list s
                                    (string-append s ".ts")
                                    (regexp-replace #px"\\.js$" s ".ts")
                                    (path->string (build-path s "index.ts"))))]
                  #:when (file-exists? c))
        (string->path c))
      p))

;; make-ts-import-closure : path-string -> (string -> (listof string))
;; For a checkout ROOT, a function from an entry script (relative to ROOT) to the
;; files it loads, entry included, as sorted paths relative to ROOT. Each file is
;; read once however many entries reach it. An entry that isn't there gives just
;; itself: no checkout (CI) degrades to the script alone, which is what an
;; undeclared recipe always had.
(define (make-ts-import-closure root)
  (define base (simplify-path (path->complete-path root)))
  (define parsed (make-hash))   ; path -> (cons modules reads)
  (define (parse-file f)
    (hash-ref! parsed f
               (lambda ()
                 (if (file-exists? f)
                     (let-values ([(mods reads) (parse-ts-imports (file->bytes f))])
                       (cons (map (lambda (s) (resolve f s)) mods)
                             (map (lambda (s) (resolve f s)) reads)))
                     (cons '() '())))))
  (define (rel p) (path->string (find-relative-path base p)))
  (lambda (entry)
    (define start (simplify-path (build-path base entry) #f))
    (let loop ([todo (list start)] [seen (set)])
      (cond
        [(null? todo) (sort (map rel (set->list seen)) string<?)]
        [(set-member? seen (car todo)) (loop (cdr todo) seen)]
        [else
         (define f (car todo))
         (define seen* (set-add seen f))
         (cond
           [(path-has-extension? f #".ts")
            (define p (parse-file f))
            ;; reads are files, not modules: counted, not followed
            (loop (append (car p) (cdr todo)) (set-union seen* (list->set (cdr p))))]
           [else (loop (cdr todo) seen*)])]))))
