#lang racket/base

;; Python import extractor (st-6ga): derive the transitive set of LOCAL modules a
;; script imports, at GRAPH-AUTHORING time, so a recipe's code list is computed
;; rather than hand-transcribed (and so it can't drift as imports change).
;;
;; Why authoring-time and not a build task: a task that scanned imports would have
;; an OUTPUT that IS graph structure (which files a downstream task depends on).
;; The applicative planner assumes a fixed graph, so build-time scanning would need
;; dynamic/monadic dependencies or a two-phase restart. Scanning while the graph is
;; being authored sidesteps that entirely (st-6ga notes / st-top design).
;;
;; What "local" means: a top-level import name that matches the basename (sans
;; `.py') of a file in the scanned directory. This set-membership test is what
;; makes the crude line scan safe:
;;   - installed packages are rejected (`from notes_store.db import ...' → top-
;;     level `notes_store', not a data/ file);
;;   - docstring/comment prose is rejected on two counts — the `from ... import'
;;     shape requires the `import' keyword on the same line (so `from species_maps.py
;;     (RESEARCH ...' never matches), and any survivor must still name a real local
;;     module (so `from the matched result ...' is dropped by the membership test).
;;
;; Honest limitations (documented, not hidden): this is a regex line scan, not a
;; Python AST. It over-approximates conservatively — lazy/conditional imports
;; nested in functions ARE included (a script that imports a helper on one code
;; path still depends on that helper's bytes). Two escapes go the OTHER way — an
;; import the scan MISSES, which risks a stale cache (the failure content-
;; addressing exists to prevent), so both fall to the manual escape hatch:
;;   - dynamic imports (`importlib.import_module', `__import__') and star re-
;;     exports are invisible to any static scan;
;;   - a SECOND import sharing a line with a first — after a `;' (`import os;
;;     import config') or a `\'-continuation — is missed, because both regexes
;;     anchor to the line start (`^'). Vanishingly rare in real source and absent
;;     from beeatlas's data/, but named here so it isn't mistaken for covered.
;; A caller may always name extra files explicitly to cover any of these. The
;; line-start anchoring is also what keeps most string-literal prose out; a rare
;; leading `import <local-name>' inside a docstring would be a spurious include
;; (the safe direction — an over-rebuild, not a stale skip). This matches how the
;; hand list was originally derived (grepping `^import'/`^from' lines), so the
;; derivation reproduces it exactly.

(require racket/set
         racket/string
         racket/list
         racket/file
         racket/path)

(provide parse-local-imports
         import-closure
         make-data-import-closure)

;; --- Pure parse layer -------------------------------------------------------

;; `import a, b.c as d' — capture the whole target list after the keyword.
(define import-rx
  #px"(?m:^[ \t]*import[ \t]+([A-Za-z_][A-Za-z0-9_.]*(?:[ \t]*,[ \t]*[A-Za-z_][A-Za-z0-9_.]*(?:[ \t]+as[ \t]+[A-Za-z_][A-Za-z0-9_]*)?)*))")
;; `from x.y import z' — capture the module path (leading dots = relative import).
;; The trailing `import\b' is load-bearing: it is what keeps prose out.
(define from-rx
  #px"(?m:^[ \t]*from[ \t]+(\\.*[A-Za-z_][A-Za-z0-9_.]*)[ \t]+import[ \t])")

;; top-level : string -> string
;; The package root of a dotted module path, with any leading relative-import dots
;; stripped: "a.b.c" -> "a", ".pkg.mod" -> "pkg". "" when nothing remains.
(define (top-level mod)
  (define stripped (regexp-replace #px"^\\.+" mod ""))
  (car (regexp-split #px"\\." stripped)))

;; import-targets : string -> (listof string)
;; The top-level names named by one `import ...' target list. `import a.b, c as d'
;; -> ("a" "c"): split on commas, drop any `as' alias, keep the package root.
(define (import-targets group)
  (for/list ([tok (in-list (regexp-split #px"[ \t]*,[ \t]*" (string-trim group)))])
    (top-level (car (regexp-split #px"[ \t]+" (string-trim tok))))))

;; parse-local-imports : string (set/c string) -> (listof string)
;; The distinct LOCAL module names directly imported by `text' — every top-level
;; import name that is a member of `local-names'. `import' targets precede
;; `from ... import' modules; duplicates are collapsed. Order is otherwise
;; unspecified and irrelevant: the only consumer (import-closure) sorts.
(define (parse-local-imports text local-names)
  (define named
    (append
     (append-map import-targets
                 (map cadr (regexp-match* import-rx text #:match-select values)))
     (map (lambda (m) (top-level (cadr m)))
          (regexp-match* from-rx text #:match-select values))))
  (for/list ([n (in-list (remove-duplicates named))]
             #:when (set-member? local-names n))
    n))

;; --- Transitive closure -----------------------------------------------------

;; import-closure : (string -> (or/c string #f)) (set/c string) string
;;                  -> (listof string)
;; The transitive local-import closure of `entry', EXCLUDING `entry' itself,
;; sorted. `read-module' maps a local module name to its source text (or #f if the
;; file is absent — treated as importing nothing, the conservative degradation).
;; Injecting the reader keeps this layer pure and testable without a filesystem.
(define (import-closure read-module local-names entry)
  (let loop ([frontier (list entry)] [seen (set)])
    (cond
      [(null? frontier)
       (sort (set->list (set-remove seen entry)) string<?)]
      [else
       (define name (car frontier))
       (cond
         [(set-member? seen name) (loop (cdr frontier) seen)]
         [else
          (define text (read-module name))
          (define deps (if text (parse-local-imports text local-names) '()))
          (loop (append deps (cdr frontier)) (set-add seen name))])])))

;; --- Filesystem wrapper -----------------------------------------------------

;; make-data-import-closure : path-string -> (string -> (listof path-string))
;; Reads `dir' ONCE — listing its *.py files as the local-name set and slurping
;; their text — then returns a per-entry lookup: given an entry module name, the
;; sorted transitive local imports it pulls in (excluding the entry), as
;; "name.py" filenames. The one directory read is shared across every call, so
;; authoring N recipes costs one scan, not N. If `dir' is absent (the beeatlas
;; checkout isn't mounted), every lookup returns '() — no extras derived, which
;; degrades to the same conservative "inputs-unresolvable" rerun a bare recipe
;; already gets.
(define (make-data-import-closure dir)
  (define entries
    (if (directory-exists? dir) (directory-list dir #:build? #f) '()))
  (define py-files
    (for/list ([p (in-list entries)]
               #:when (path-has-extension? p #".py"))
      p))
  (define local-names
    (for/set ([p (in-list py-files)])
      (path->string (path-replace-extension p #""))))
  ;; Slurp each local module's text up front, keyed by its name.
  (define texts
    (for/hash ([p (in-list py-files)])
      (values (path->string (path-replace-extension p #""))
              (file->string (build-path dir p)))))
  (define (read-module name) (hash-ref texts name #f))
  (lambda (entry)
    (for/list ([name (in-list (import-closure read-module local-names entry))])
      (string-append name ".py"))))
