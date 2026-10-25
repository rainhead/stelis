#lang racket/base

;; Tests for the TypeScript import closure (ts-imports.rkt, st-6i2). The parse layer
;; is pure; the closure runs on a temporary tree; and when the salishsea checkout and
;; its esbuild are present, every node task's entry script is checked against
;; esbuild's own module graph, the closure the hand-kept lists were transcribed from.

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/set
         racket/string
         racket/system
         "ts-imports.rkt"
         (only-in "salishsea.rkt" SALISHSEA))

(define (parse text)
  (define-values (mods reads) (parse-ts-imports text))
  (list mods reads))

;; --- Parse -------------------------------------------------------------------

(test-equal? "static, side-effect, re-export and dynamic imports; packages ignored"
             (parse (string-append
                     "import { a } from './a.ts';\n"
                     "import b from \"../b.ts\";\n"
                     "import './c.ts';\n"
                     "export { d } from './d.ts';\n"
                     "export * from './e.ts';\n"
                     "import { DuckDBInstance } from '@duckdb/node-api';\n"
                     "const f = await import('./f.ts');\n"))
             '(("./a.ts" "../b.ts" "./c.ts" "./d.ts" "./e.ts" "./f.ts") ()))
(test-equal? "an import spread over lines"
             (parse "import {\n  one,\n  two,\n} from './multi.ts';\n")
             '(("./multi.ts") ()))
(test-equal? "type-only imports load nothing; a mixed one still loads its module"
             (parse (string-append
                     "import type { T } from './types.ts';\n"
                     "export type { U } from './more-types.ts';\n"
                     "import { value, type V } from './mixed.ts';\n"))
             '(("./mixed.ts") ()))
(test-equal? "a type alias with no semicolon does not swallow the import after it"
             (parse "export type Row = {\n  id: number\n}\nimport { b } from './b.ts';\n")
             '(("./b.ts") ()))
(test-equal? "a Vite query is dropped from the specifier"
             (parse "import icon from './assets/pin.svg?url';\n")
             '(("./assets/pin.svg") ()))
(test-equal? "a literal import.meta.url read is a read; a computed one is invisible"
             (parse (string-append
                     "const h = readFileSync(new URL('../../src/assets/h.geojson', import.meta.url));\n"
                     "const s = readFile(new URL(`./derive/${file}`, import.meta.url));\n"))
             '(() ("../../src/assets/h.geojson")))
(test-equal? "an import in a line comment is not one"
             (parse "// import { old } from './old.ts';\nconst x = 1;\n")
             '(() ()))
(test-equal? "a string that mentions from is not an import"
             (parse "export const note = 'copied from ./elsewhere.ts';\n")
             '(() ()))

;; --- Closure on a tree ---------------------------------------------------------

(define tree (make-temporary-directory "stelis-ts-imports-~a"))
(define (put! rel text)
  (define p (build-path tree rel))
  (make-parent-directory* p)
  (display-to-file text p #:exists 'replace))
(put! "scripts/entry.ts"
      (string-append "import { a } from '../src/a.ts';\n"
                     "import type { T } from '../src/types.ts';\n"
                     "const data = new URL('./data.json', import.meta.url);\n"))
(put! "src/a.ts" "import { b } from './b';\nimport { gone } from './deleted.ts';\n")
(put! "src/b.ts" "import { a } from './a.ts';\nexport const b = 1;\n")
(put! "src/types.ts" "export type T = number;\n")
(put! "scripts/data.json" "{}")

(define closure (make-ts-import-closure tree))
(test-equal? "the closure: transitive, cycles once, type-only skipped, reads counted, a missing file named"
             (closure "scripts/entry.ts")
             '("scripts/data.json" "scripts/entry.ts" "src/a.ts" "src/b.ts" "src/deleted.ts"))
(test-equal? "an entry that isn't there is just itself"
             (closure "scripts/absent.ts") '("scripts/absent.ts"))
(delete-directory/files tree)

;; --- Against esbuild, on the real scripts ---------------------------------------
;; The computed closure may be wider than esbuild's (an import used only as a type is
;; followed, which esbuild drops), never narrower: narrower is a stale skip.

(define esbuild
  (for/first ([d (in-list (if (directory-exists? (build-path SALISHSEA "node_modules" ".pnpm"))
                              (directory-list (build-path SALISHSEA "node_modules" ".pnpm") #:build? #t)
                              '()))]
              #:when (regexp-match? #rx"/@esbuild\\+linux-x64@" (path->string d))
              [bin (in-value (build-path d "node_modules" "@esbuild" "linux-x64" "bin" "esbuild"))]
              #:when (file-exists? bin))
    bin))

(define (esbuild-inputs entry)
  (define meta (make-temporary-file "stelis-meta-~a.json"))
  (define out (make-temporary-file "stelis-out-~a.js"))
  (define ok?
    (parameterize ([current-directory SALISHSEA]
                   [current-output-port (open-output-nowhere)]
                   [current-error-port (open-output-nowhere)])
      (system* esbuild entry "--bundle" "--platform=node" "--packages=external" "--format=esm"
               (format "--metafile=~a" meta) (format "--outfile=~a" out) "--log-level=error")))
  (define inputs
    (and ok?
         (for/list ([m (in-list (regexp-match* #px"\"([^\"]+)\": \\{\\s*\"bytes\"" (file->string meta)
                                               #:match-select cadr))])
           m)))
  (delete-file meta) (delete-file out)
  inputs)

(cond
  [(not esbuild)
   (printf "ts-imports-test: no salishsea checkout with esbuild at ~a — skipping the esbuild comparison.\n" SALISHSEA)]
  [else
   (define real (make-ts-import-closure SALISHSEA))
   (define entries
     (for/list ([f (in-list (directory-list (build-path SALISHSEA "scripts" "read-path")))]
                #:when (regexp-match? #rx"\\.ts$" (path->string f))
                #:unless (regexp-match? #rx"\\.test\\.ts$" (path->string f)))
       (string-append "scripts/read-path/" (path->string f))))
   (for ([entry (in-list entries)])
     (define theirs (esbuild-inputs entry))
     (when theirs
       (define ours (list->set (real entry)))
       (test-equal? (format "~a: every module esbuild bundles is in the closure" entry)
                    (sort (set->list (set-subtract (list->set theirs) ours)) string<?)
                    '())))])
