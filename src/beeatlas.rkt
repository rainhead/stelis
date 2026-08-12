#lang racket/base

;; The beeatlas build graph, authored by hand from data/run.py's STEPS list, the
;; dependency reasons in its comments, and data/dbt/models/sources.yml (which
;; declares exactly what dbt-build reads). See docs/adr/0001-build-graph-model.md.
;;
;; Precision policy (ADR decision 8): edges on the occurrences.db upstream are
;; precise; the post-dbt sibling edges are coarse-but-honest (they exist and stay
;; off any path to occurrences.db). A few pre-dbt edges are marked COARSE where
;; the exact data dependency wasn't verified against the step's module — they are
;; plausible over-approximations, never fabricated links.
;;
;; Key consequence of modelling dbt-build as one opaque task: it consumes nearly
;; every ingestion/resolution output, so most PRE-dbt steps are upstream of
;; occurrences.db. The pruning is the 11 POST-dbt export/render/gate steps.
;;
;; Slice 2 (st-d44.2): each task's `invoke' slot holds its hermetic recipe,
;; transcribed from run.py's imports. Two runtimes cover the pipeline: `uv'
;; (beeatlas's uv project, Python 3.14, where dlt/exporters run) and `dbt'
;; (data/dbt/run.sh, which uvx-pins Python 3.13). Recipes are dry-run only so far.
;;
;; --- Provenance / drift detection -------------------------------------------
;; This graph was transcribed by hand from the beeatlas files below, at the
;; revisions shown. If the file-pinned SHAs no longer match, run.py's steps or
;; dbt's sources may have changed and this graph could be STALE. Re-check with:
;;
;;   git -C ~/dev/beeatlas log -1 --format=%h -- data/run.py
;;   git -C ~/dev/beeatlas log -1 --format=%h -- data/dbt/models/sources.yml
;;
;;   beeatlas HEAD             : e54d80c0  (2026-07-11)
;;   data/run.py              : 938c6ffd  (2026-07-06)   ← the 32 STEPS + reasons
;;   data/dbt/models/sources.yml : eaac92a9  (2026-07-06)   ← dbt-build's inputs

(require racket/format
         racket/list
         racket/string
         racket/system
         racket/port
         racket/runtime-path
         "model.rkt"
         "exec.rkt"
         "relation-digest.rkt"
         "notes-digest.rkt"
         "data-quality.rkt"
         "corrections-drift.rkt"  ; make-corrections-drift-check (st-t4t)
         "taxon-derive.rkt"  ; make-taxon-reasoning (st-ozp)
         "fan-out-key.rkt"
         "rkt-imports.rkt"  ; rkt-import-closure (st-egh)
         "py-imports.rkt") ; make-data-import-scan (st-6ga/st-whi)

(provide beeatlas-graph
         beeatlas-runtimes
         beeatlas-path
         beeatlas-db
         beeatlas-relation-tables
         beeatlas-resolve-relation
         beeatlas-resolve-relation-columns
         beeatlas-resolve-store-keys
         beeatlas-partial-tasks
         beeatlas-edge-verify-tasks
         beeatlas-source-date-epoch
         ;; exported for the drift check in beeatlas-contract-test.rkt (st-ljy):
         ;; this list mirrors beeatlas's own by hand, so something has to compare them
         precompressed-artifacts
         BEEATLAS)

;; --- Hermetic runtimes ------------------------------------------------------
;; beeatlas's data/ is a uv project pinned to Python 3.14; dbt is shelled through
;; data/dbt/run.sh, which uvx-pins Python 3.13. Stelis delegates hermeticity to
;; those existing pins — it just launches the right command per task.
;; Where the beeatlas case-study repo lives. Defaults to the author's checkout;
;; override with BEEATLAS_DIR to run this graph on another host (maderas, CI).
(define BEEATLAS (or (getenv "BEEATLAS_DIR") "/Users/rainhead/dev/beeatlas"))
(define DATA (string-append BEEATLAS "/data"))

;; Every env file Vite loads in PRODUCTION mode, most specific last — the order
;; Vite itself applies them, and the reason all four are the app bundle's inputs
;; whether or not they exist (see the app-bundle task).
(define VITE-ENV-FILES '(".env" ".env.local" ".env.production" ".env.production.local"))

;; Taxon reasoning's three files (st-ozp; see the section further down for what
;; each is for). These are STELIS's own paths, not beeatlas's — the first task
;; whose code is the engine itself — so they resolve relative to this module and
;; exist even where there is no beeatlas checkout.
(define-runtime-path taxon-rules-source "taxon-inherit.rkt")
(define-runtime-path taxon-seam-source "taxon-derive.rkt")
(define-runtime-path taxon-traits-facts "../data/taxon-traits.rktd")

;; --- Deterministic build clock (ADR 0004, st-3mi) ---------------------------
;; SOURCE_DATE_EPOCH: the one build-wide clock a task embeds instead of wall-
;; clock time, so its outputs stay byte-deterministic (DESIGN: determinism is a
;; day-one property). Defined as the committer date of beeatlas's HEAD commit — a
;; function of the source snapshot, so it is identical across the two builds of a
;; --verify. Honors an already-set SOURCE_DATE_EPOCH (the reproducible-builds
;; escape hatch). Stelis injects the result into every task's hermetic env (see
;; main.rkt); a stamping script reads it and falls back to its own clock only when
;; unset, so it stays runnable standalone (the nightly) yet deterministic here.
(define (beeatlas-source-date-epoch)
  (define (epoch? s) (and s (regexp-match? #px"^[0-9]+$" s)))
  (define preset (getenv "SOURCE_DATE_EPOCH"))
  (cond
    [(epoch? preset) preset]
    [else
     (define out
       (with-output-to-string
         (lambda ()
           (parameterize ([current-error-port (open-output-nowhere)])
             (system* (find-executable-path "git")
                      "-C" BEEATLAS "log" "-1" "--format=%ct")))))
     (define trimmed (string-trim out))
     (if (epoch? trimmed)
         trimmed
         (error 'beeatlas-source-date-epoch
                "could not read git committer date for ~a" BEEATLAS))]))

(define beeatlas-runtimes
  ;; `uv': identity probe is STANDALONE (st-kbi) — the launch prefix SYNCS the
  ;; venv at first touch, which planning must never trigger, and the safety flag
  ;; goes mid-launch where an appended probe cannot reach. So the probe re-states
  ;; the launch with `--no-sync': it observes the venv AS IT STANDS (no venv yet
  ;; -> probe fails -> conservative run), and the drift risk against the launch
  ;; one line up is the declared, visible cost. `-VV' over `--version': the build
  ;; string moves with a rebuilt interpreter even inside one version.
  ;;
  ;; `dbt': probe rides the launch — run.sh owns the uvx pins, and its
  ;; `--identity' branch re-invokes them with `--offline' (cache-only: a cold
  ;; cache fails the probe rather than reaching the network at plan time). The
  ;; pin never leaves run.sh, which the dbt recipe already hashes as code.
  (hash 'uv  (runtime 'uv  (list "uv" "run" "--directory" DATA "python") "uv/3.14"
                      (standalone-probe
                       (list "uv" "run" "--no-sync" "--directory" DATA "python" "-VV")))
        'dbt (runtime 'dbt (list "bash" (string-append DATA "/dbt/run.sh")) "uvx/3.13"
                      (list "--identity"))
        ;; `sh': a bare shell for file PLACEMENT (not transformation) — used by
        ;; place-marts to copy derived dbt outputs to their export destination.
        ;; No interpreter pin needed; cp is content-preserving.
        'sh  (runtime 'sh  (list "bash" "-c") "sh")
        ;; `node': the site repo's npm scripts, at beeatlas's PINNED node (st-hdm).
        ;;
        ;; The pin is the whole reason this is a runtime rather than a bare
        ;; command. beeatlas pins node in .nvmrc (24.18) and its own callers —
        ;; data/nightly.sh and data/publish-notes.sh — establish it by sourcing nvm
        ;; and running `nvm use` before any npm call. Nothing about `npm` itself
        ;; carries the pin, so an engine that shelled out directly would build the
        ;; bundle under whatever node happened to be on PATH; on this machine that
        ;; is 26, not 24.18. Same job as `uv run --directory` for the Python tasks:
        ;; declare the interpreter once, by name (ADR 0002).
        ;;
        ;; cwd matters too and is not negotiable — vite.config.ts resolves
        ;; `process.cwd()` for the stashed manifest — so the launch cd's into the
        ;; repo. `exec "$@"` hands the recipe's argv through unchanged, so the
        ;; command a task declares stays readable in --commands.
        ;;
        ;; A missing nvm is a warning, not a failure, matching nightly.sh: on a host
        ;; where node is already the right version there is nothing to source.
        ;;
        ;; The identity probe (st-jkl): `node --version' through this same launch
        ;; prefix, so it resolves the way every task does — nvm sourcing, warning
        ;; fallback and all. Its answer joins each node task's input address (see
        ;; node-runtime-code below for why the interpreter is an input). node only,
        ;; deliberately: uv's launch SYNCS the venv at first touch and dbt's uvx
        ;; resolves over the network, so probing either could mutate or go online
        ;; at plan time — each needs its own decision (a --no-sync variant, say)
        ;; before it gets a probe. Sourcing nvm is read-only.
        'node (runtime 'node
                       (list "bash" "-c"
                             (string-append
                              "set -e; cd " BEEATLAS "; "
                              "if [ -s \"$HOME/.nvm/nvm.sh\" ]; then "
                              ". \"$HOME/.nvm/nvm.sh\"; nvm use --silent; "
                              "else echo \"WARN: no nvm; node may not match .nvmrc\" >&2; fi; "
                              "exec \"$@\"")
                             "stelis-node")
                       "node/.nvmrc"
                       (list "node" "--version"))))

;; The `node' runtime's PIN, as task code (st-top). The interpreter is an input to the
;; BYTES, not just to the behaviour: gzip -9 of the same 33.8 MB database is 5,208,681
;; bytes under node 24.18 and 5,203,283 under 26 (measured 2026-08-02, st-ljy — the zlib
;; builds differ; brotli 1.2.0 was byte-identical across both). Both decode identically,
;; so nothing breaks — the output simply moves for a reason the cache cannot see, which
;; is what content-addressing exists to prevent. The launch prefix sources nvm and runs
;; `nvm use', so none of this is in the argv the recipe hash covers. Every `node' recipe
;; hashes .nvmrc.
;;
;; This file states INTENT; the runtime's identity probe states REALITY (st-jkl).
;; .nvmrc holds `24.18', a RANGE — installing 24.18.1 changes the interpreter with
;; the file unmoved — and on a host with no nvm the runtime warns and uses whatever
;; `node' is on PATH (see the runtime above). Both holes are closed by the probe:
;; the RESOLVED `node --version', observed through the launch prefix at snapshot
;; time, rides each node task's input address as "runtime:node" (an input
;; observation through an injected resolver, like resolve-relation's DuckDB
;; digest — planning observes, it never executes). The file stays hashed anyway:
;; a pin edit should invalidate even on a host whose resolved node can't move.
(define node-runtime-code (list (build-path BEEATLAS ".nvmrc")))

;; The uv runtime's INTENT, as task code (st-kbi — the .nvmrc argument, Python
;; side). The probe above observes the venv as it stands; but the venv only
;; MOVES when something syncs it, and syncing happens inside a task launch — so
;; a pin edit (pyproject, the lock, the interpreter range) with nothing else
;; changed would rerun NOTHING, the sync would never fire, and the edit would
;; sit silently unapplied while every skip stayed "correct" against the stale
;; venv. Hashing the pin files closes that: the edit reads as 'code-changed, a
;; task runs, the launch syncs, and the NEXT plan's probe observes the new
;; interpreter. Intent triggers the change; reality addresses it.
(define uv-runtime-code
  (list (build-path DATA "pyproject.toml")
        (build-path DATA "uv.lock")
        (build-path DATA ".python-version")))

;; --- Physical placement, declared once (st-bft) ------------------------------
;; Where each file artifact lives is one fact per artifact, kept in the four lists
;; below; everything downstream (the @export copies, place-marts' copy edge,
;; dbt-build's outputs, path resolution) derives from them rather than repeating
;; the names. The recurring authoring bug was this placement axis leaking into
;; five different spots; now a new mart or export is a one-line edit.

;; dbt-build writes these nine marts into the sandbox — they ARE its file outputs.
(define sandbox-marts
  '(occurrences.parquet occurrence_places.parquet checklist.parquet
    species.parquet species_traits.parquet higher_taxa.parquet
    counties.geojson ecoregions.geojson wilderness.geojson))

;; place-marts copies these six verbatim into EXPORT_DIR, where the post-dbt
;; exporters read them (Pitfall 5). Each copied mart gets a byte-identical
;; `<name>@export' sibling — its own artifact, so one-producer-per-artifact holds:
;; dbt-build makes the sandbox copy, place-marts makes the @export copy.
;; species.parquet is deliberately absent — species-export writes its OWN enriched
;; @export copy (different bytes), not a verbatim mart copy.
(define placed-marts
  '(occurrences.parquet occurrence_places.parquet counties.geojson
    ecoregions.geojson wilderness.geojson checklist.parquet))

;; the @export sibling name of a placed artifact.
(define (export-name name) (string->symbol (string-append (~a name) "@export")))

;; Single-file terminal exports that land in the build's EXPORT_DIR (species_export
;; etc. write ASSETS_DIR := EXPORT_DIR). Explicit on purpose: being listed here
;; means "a built+verified single-file export target."
(define export-dir-files
  '(occurrences.db species.json collectors.json
    collectors.events.json collector_event_pages.json
    places.json places.geojson place_details.json
    counties.clean.geojson ecoregions.clean.geojson wilderness.clean.geojson
    seasonality.json photos.json species_hosts.json higher_taxa.json
    taxon_presence.json
    species_reasoning.json))

;; The artifacts the CLIENT fetches at runtime, and so the ones worth compressing
;; ahead of the publish (st-ljy). Mirrors the `source' values in beeatlas's
;; lib/runtime-artifacts.js, which is the contract's home — this list is the SET the
;; precompress node declares as inputs and passes on argv, so the graph edge and the
;; work stay the same set. Drift (beeatlas publishes an eighth artifact, this list
;; doesn't) degrades safely: postbuild-data compresses that one in-process, slowly and
;; correctly, rather than this node's output changing without a declared input change.
(define precompressed-artifacts
  '(occurrences.db
    counties.clean.geojson ecoregions.clean.geojson wilderness.clean.geojson
    places.geojson places.json taxon_presence.json))

;; Directory ('dir) terminal exports (st-cly): data-dependent output SETS that each
;; land as a directory of per-entity files under EXPORT_DIR — species_maps writes
;; EXPORT_DIR/species-maps/, places_maps EXPORT_DIR/place-maps/, feeds EXPORT_DIR/
;; feeds/. The directory name is the artifact name. Content-addressed as a whole by
;; an order-independent tree digest (tree-digest.rkt); SET completeness is st-tul.
;; `notes' is the per-canonical_name notes SET (st-pd1): notes-harvest writes
;; EXPORT_DIR/notes/<canonical_name>.json, one per approved species — the keyed
;; unit a targeted rebuild touches, and since beeatlas-6x9 the TERMINAL notes
;; artifact: _data/notes.js reads the dir directly (the notes.json roll-up and
;; its notes-assemble task retired — the monolith's only consumer was that
;; loader).
;; The 11ty render is NOT a Stelis task (ADR 0007 Amendment / Model Y, st-5em):
;; Stelis narrows to the DATA engine, and the site build (11ty/Vite) is
;; top-level, consuming these artifacts via `npm run fetch-data`. The `site`
;; task + site-src leaves that briefly lived here (st-ak1) were reverted; the
;; EXPORT_DIR reader seam (beeatlas lib/build-data-dir.js) is what survives.
;; `compressed' (st-ljy) is the odd one: not a per-entity fan-out but the compressed
;; REPRESENTATIONS of the runtime artifacts, which the site build copies to their hashed
;; names at publish (beeatlas ADR 0024). Still a 'dir for the same reason the others are
;; — a derived output SET with one producer, and the set is data-dependent because a
;; variant is only written when it clears a size threshold.
(define export-dir-dirs '(species-maps place-maps feeds notes compressed))

;; The authoritative notes STORE (st-msn): the SQLite file notes-harvest reads
;; read-only. A fixed absolute path OUTSIDE the beeatlas repo (D-15), from
;; NOTES_DB_PATH — resolved the same way beeatlas does, and the subprocess inherits
;; stelis's NOTES_DB_PATH unchanged, so both see the same file. Input-addressed by
;; the roll-up of its per-key digests (notes-store-keys), NOT its file bytes: a
;; long-running writer keeps committed rows in the SQLite -wal, freezing the main
;; file's bytes at the last checkpoint (cache.rkt's build-env docstring has the
;; full story). Absent (not mounted locally) it reads unresolvable, which only
;; forces a conservative rerun.
(define notes-store-path
  (string->path (or (getenv "NOTES_DB_PATH") "/opt/beeatlas-store/notes.db")))

;; raw/fetched/authoritative inputs at fixed paths (taxa under DATA; the notes
;; store at its absolute NOTES_DB_PATH).
(define (seed-file name) (build-path DATA "dbt" "seeds" name))

(define raw-file-paths (hash 'taxa.csv.gz    (build-path DATA "raw" "taxa.csv.gz")
                             ;; the two seeds the correction drift gate compares
                             ;; (st-t4t): the local overrides and the upstream
                             ;; source they claim to be correcting.
                             'bee_traits_corrections.csv (seed-file "bee_traits_corrections.csv")
                             'bee_traits_beegap.csv      (seed-file "bee_traits_beegap.csv")
                             'bee_parasite_hosts.csv     (seed-file "bee_parasite_hosts.csv")
                             'notes-store.db notes-store-path
                             ;; the curated trait assertions (st-ozp) — checked
                             ;; into STELIS, not beeatlas: they are Stelis's
                             ;; domain knowledge about the taxonomy, not the
                             ;; case study's pipeline data.
                             'taxon-traits.rktd taxon-traits-facts))

;; Where beeatlas's file/dir artifacts physically live — the resolver caching uses
;; to content-hash inputs and to place/verify outputs. #f for artifacts with no
;; known path (duckdb relations, tokens, externals): those aren't content-hashed
;; here. 'dir outputs resolve to a directory under export-dir (st-cly).
(define SANDBOX (string-append DATA "/dbt/target/sandbox"))
(define (beeatlas-path artifact export-dir)
  (define s (~a artifact))
  (cond
    [(hash-ref raw-file-paths artifact #f)]
    ;; a curator-review CSV checklist_dedup writes to data/ at a FIXED path (and a
    ;; different basename, `_pairs`) — a derived output the dedup-gate reads, not an
    ;; EXPORT_DIR artifact. Surfaced by --build --all (dedup-candidates is pruned for
    ;; occurrences.db); the st-6qc guard needs a resolvable path to verify it.
    [(eq? artifact 'dedup_candidates.csv) (build-path DATA "dedup_candidate_pairs.csv")]
    ;; 'code artifacts (st-whi): the shared Python helpers live in data/ at their
    ;; own basenames — fixed paths, so they read as ambient inputs everywhere
    ;; (never seeded, never EXPORT_DIR-relative).
    [(memq artifact py-code-artifact-names) (data-file s)]
    [(memq artifact sandbox-marts) (build-path SANDBOX s)]
    ;; @export copies (place-marts' verbatim copies + species-export's enriched
    ;; parquet): the placed sibling lives under export-dir at the un-suffixed name.
    [(regexp-match #rx"^(.+)@export$" s)
     => (lambda (m) (build-path export-dir (cadr m)))]
    [(memq artifact export-dir-files) (build-path export-dir s)]
    ;; 'dir outputs: a directory named for the artifact, directly under export-dir.
    [(memq artifact export-dir-dirs) (build-path export-dir s)]
    ;; The app bundle (st-hdm step 2) is the first output that is NOT
    ;; EXPORT_DIR-relative. It cannot be: the site build writes it, `_site` is
    ;; where Vite's `outDir` puts it, and Eleventy reads the manifest describing
    ;; it in place. EXPORT_DIR steers the DATA artifacts to a chosen destination;
    ;; the bundle has one home in the site repo, so it resolves at a fixed path
    ;; like the raw inputs above rather than moving with the export.
    [(eq? artifact 'app-bundle) (build-path BEEATLAS "_site" "assets")]
    [else #f]))

;; --- db-relation content-addressing (st-d5d) --------------------------------
;; Each db-relation artifact is a LOGICAL dataset; content-addressing needs the
;; PHYSICAL schema.table(s) it lives in, so a re-ingest of identical content can
;; be recognised and early cutoff (st-8ig) reaches the pre-dbt graph. The mapping
;; was transcribed from the beeatlas loaders (which dlt dataset / which INSERTs)
;; and dbt's sources.yml (which tables dbt actually reads), at the SHAs pinned in
;; the provenance header above.
;;
;; Precision policy (as in the edge comments above): three logical artifacts —
;; canonical_to_taxon_id, checklist_resolved, inactive_remaps — all materialise
;; as rows in the SINGLE table inaturalist_data.canonical_to_taxon_id (resolve_
;; taxon_ids, resolve_checklist_names, and generate_inactive_remaps each INSERT
;; there). They therefore share one digest and co-vary. That is coarse but SAFE:
;; any change to the table changes all three hashes, so a stale input can never
;; read as unchanged — the failure is at worst an over-rebuild, never a false skip.
;; The DuckDB Stelis content-addresses (relation digests, the integrity gate).
;; Honors DB_PATH — the same env var run.py's pipeline reads — so under nightly.sh
;; (DB_PATH=/tmp/beeatlas.duckdb, pulled from S3) Stelis reads the SAME db the
;; pipeline writes, not the local-dev checkout copy. Defaults to the checkout db
;; for local runs (mirrors BEEATLAS_DIR / NOTES_DB_PATH).
(define beeatlas-db
  (let ([p (getenv "DB_PATH")])
    (if p (string->path p) (build-path DATA "beeatlas.duckdb"))))

;; beeatlas-relation-tables : symbol -> (or/c (listof string) #f)
;; The qualified physical tables a db-relation artifact occupies, or #f for an
;; artifact with no known relation (kept conservative: it stays unresolvable).
(define (beeatlas-relation-tables artifact)
  (case artifact
    [(ecdysis_data)   '("ecdysis_data.occurrences" "ecdysis_data.identifications")]
    [(ecdysis_links)  '("ecdysis_data.occurrence_links")]
    [(inat_observations) '("inaturalist_data.observations"
                           "inaturalist_data.observations__ofvs")]
    [(inat_projects)  '("inaturalist_data.observations__observation_projects")]
    [(waba_data)      '("inaturalist_waba_data.observations"
                        "inaturalist_waba_data.observations__ofvs")]
    [(inat_obs_data)  '("inat_obs_data.observations")]
    [(checklist_raw)  '("checklist_data.species" "checklist_data.species_counties"
                        "checklist_data.checklist_records"
                        "checklist_data.checklist_records_full")]
    [(canonical_to_taxon_id checklist_resolved inactive_remaps)
     '("inaturalist_data.canonical_to_taxon_id")] ; shared table — see note above
    [(taxon_lineage_extended) '("inaturalist_data.taxon_lineage_extended")]
    [(host_plant_lineage)     '("inaturalist_data.host_plant_lineage")]
    [(dem_elevations)         '("dem_data.elevations")]
    [(geographies_places)     '("geographies.places")]
    ;; county GEOMETRY species_maps reads straight from the duckdb (st-4cm edge fix)
    [(geographies_us_counties) '("geographies.us_counties")]
    ;; the other three geography tables dbt reads (st-7hw). One artifact per table,
    ;; not one grouped `geographies-geometry': geographies_places already set that
    ;; precedent in this schema, the layers reload independently (padus_wilderness is
    ;; its own manual step), and per-table is what makes `--why counties.geojson' name
    ;; the layer that actually moved.
    [(geographies_ecoregions)       '("geographies.ecoregions")]
    [(geographies_us_states)        '("geographies.us_states")]
    [(geographies_padus_wilderness) '("geographies.padus_wilderness")]
    [else #f]))

;; beeatlas-resolve-relation : symbol -> (or/c string #f)
;; A db-relation's content hash (via DuckDB), or #f when it has no mapping or
;; can't be read — the build-env resolve-relation slot for beeatlas.
(define (beeatlas-resolve-relation artifact)
  (define tables (beeatlas-relation-tables artifact))
  (and tables (relation-digest beeatlas-db tables)))

;; beeatlas-resolve-relation-columns : symbol -> (or/c (listof (cons string string)) #f)
;; The per-column observation (st-7vz) of a db-relation — the build-env
;; resolve-relation-columns slot for beeatlas. Same table mapping as the digest;
;; used only to record the attribute-level refinement, never for the skip decision.
(define (beeatlas-resolve-relation-columns artifact)
  (define tables (beeatlas-relation-tables artifact))
  (and tables (relation-columns beeatlas-db tables)))

;; beeatlas-resolve-store-keys : symbol -> (or/c (listof (cons string string)) #f)
;; The per-canonical_name observation (st-2k9) of the authoritative notes STORE —
;; the build-env resolve-store-keys slot for beeatlas. Only notes-store.db is a
;; keyed store here; every other 'file resolves to #f (no per-key layer). Read
;; read-only from NOTES_DB_PATH; #f when the store isn't mounted (conservative).
(define (beeatlas-resolve-store-keys artifact)
  (and (eq? artifact 'notes-store.db)
       (notes-store-keys notes-store-path)))

;; beeatlas-partial-tasks : (listof symbol) — tasks whose exporter honors
;; STELIS_REBUILD_KEYS, so the engine may run them as a PARTIAL rebuild (st-pd1).
;; notes-harvest re-harvests only the canonical_names a note CRUD touched; every
;; other task rebuilds whole. The engine still only goes partial when the task has
;; an existing 'dir output and a real per-key delta on a keyed input.
(define beeatlas-partial-tasks '(notes-harvest))

;; --- Edge verification coverage (st-qp7, st-8an) ------------------------------
;; Which tasks `--verify-edges' runs. Not every task can be verified this way: the
;; harness re-runs a task in an EXPORT_DIR seeded with ONLY its declared inputs, so
;; it needs a subprocess `recipe' (an in-process derivation or rule-check has no
;; EXPORT_DIR reads to withhold) and at least one EXPORT_DIR output to check for.
;;
;; This list is narrower than that candidate set, deliberately: it is the tasks
;; whose edges have actually been built and verified (st-h4m, st-4cm). It is a
;; CAP, and --verify-edges reports what it does not cover rather than presenting
;; itself as exhaustive — a check that quietly tests a subset reads as coverage it
;; does not have. Widen it by verifying a task, not by adding a name.
(define beeatlas-edge-verify-tasks
  '(generate-sqlite species-export collectors-export places-export
    species-maps places-maps feeds))

;; --- Taxon reasoning (st-ozp) -------------------------------------------------
;; The Horizon 2 substrate beachhead (ADR 0008): a `derivation' node — a
;; transform that runs INSIDE the engine — inheriting curated high-rank trait
;; assertions down the taxonomic rank tree by Datalog closure, and publishing the
;; proof as learner-facing prose.
;;
;; Three files, three roles, deliberately distinct:
;;   taxon-inherit.rkt  the RULES  — engine source, so it is the node's `code'
;;   taxon-derive.rkt   the SEAM   — likewise code (it decides what is read/written)
;;     …and the node's code is the transitive CLOSURE of those two modules' local
;;     requires (rkt-import-closure, st-egh), not the two files alone. Hand-listing
;;     missed duckdb.rkt, through which every taxonomy read passes: an edit there
;;     changed what the node does while leaving its recorded code-hashes untouched,
;;     so it cache-skipped on stale output. Same argument as the Python side's
;;     import scan — and the same fix.
;;   data/taxon-traits.rktd  the FACTS — an input ARTIFACT, not code: curated
;;     data, so it belongs in the graph, shows up in --why, and is content-
;;     addressed like the marts it reasons over.
;; Editing the rules reports 'code-changed; editing the facts, 'input-changed.
;; (The three paths are declared up by BEEATLAS/DATA, where the placement facts
;; live — raw-file-paths needs the facts path before this point in the module.)

;; --- Integrity gate (st-0vz) ------------------------------------------------
;; The default fractional record-count swing that trips an integrity gate: a
;; relation whose row count moves more than this vs. the previous build is a
;; pipeline-integrity alarm (a source broke, a join exploded/collapsed) and blocks
;; before the data is published. Per-relation overrides can join this later.
(define INTEGRITY-THRESHOLD 1/2)

;; integrity-gate : symbol -> rule-check
;; The in-process rule node guarding `relation': its live record count (via
;; DuckDB) against the previous build's (history), blocking downstream on a swing
;; beyond INTEGRITY-THRESHOLD. The current-count thunk closes over beeatlas-db.
(define (integrity-gate relation)
  (rule-check "integrity"
              (make-integrity-check
               relation
               (lambda () (relation-row-count beeatlas-db
                                              (beeatlas-relation-tables relation)))
               INTEGRITY-THRESHOLD)))

;; py: a uv/3.14 recipe that calls `module.fn()' the way run.py imports it.
;; The module's FILE is the recipe's code (st-top): its content joins the task's
;; input address, so editing e.g. notes_harvest.py invalidates the cache the way
;; editing its data would. The shared helpers a script imports are no longer
;; flattened into this code list (st-whi): each helper is a producerless 'code
;; ARTIFACT and the imports are EDGES — `py' registers its entry module here, the
;; add-import-inputs post-pass appends the module's DIRECT local imports as task
;; inputs (task→helper), and py-code-artifacts (below the task list) authors the
;; helper nodes with their own direct imports (helper→helper). Transitive
;; dependence is then the graph's job — model.rkt's code-closure on the cache
;; side, plan-datalog reachability on the Datalog side — while a helper edit
;; still reports 'code-changed (the cache partitions inputs by kind, st-whi).
;; The scan is st-6ga's py-imports.rkt, one directory read for the whole graph;
;; it reproduces the old hand `#:code' lists and fixes their known drift (the
;; places_maps → species_maps → config second hop the hand list missed).
;; `#:code' remains an escape hatch for files the scanner can't see — dynamic
;; imports, or a data file a script bakes in.
(define (data-file rel) (string-append DATA "/" rel))
(define-values (py-direct-imports py-import-closure) (make-data-import-scan DATA))

;; recipe → entry module name, filled as `py' authors each recipe, so the
;; import-edge post-pass can recover which module a task executes without
;; re-parsing its argv. Authoring-time bookkeeping only; never escapes.
(define py-entry-modules (make-hasheq))

(define (py module fn #:code [extra '()])
  (define rec
    (recipe 'uv (list "-c" (~a "from " module " import " fn "; " fn "()"))
            ;; every uv task hashes the runtime's pin files (st-kbi) alongside
            ;; its own module — the same ride node-runtime-code takes
            (append uv-runtime-code
                    (map data-file (remove-duplicates
                                    (cons (string-append module ".py") extra))))))
  (hash-set! py-entry-modules rec module)
  rec)

;; place-marts copies each dbt mart from the sandbox to $EXPORT_DIR (injected by
;; the executor). `set -e' so a missing mart fails the task rather than a partial
;; placement. This is exactly run.py's _run_dbt_build copy loop, split out as its
;; own node (the copy is placement, not the dbt transform).
(define place-marts-script
  (string-append "set -e; for f in " (string-join (map ~a placed-marts) " ")
                 "; do cp \"" SANDBOX "/$f\" \"$EXPORT_DIR/$f\"; done"))

;; --- Artifacts --------------------------------------------------------------
;; kinds: 'file  'db-relation (a schema/table in the shared beeatlas.duckdb)
;;        'external (loaded outside the nightly graph)  'token (a gate result)
(define artifacts
  (append
   ;; the nine dbt sandbox marts — one 'file artifact each, derived from the
   ;; placement list so the mart set lives in exactly one place (st-bft).
   (for/list ([m (in-list sandbox-marts)]) (make-artifact m 'file))
   (list
   (make-artifact 'taxa.csv.gz              'file)
   (make-artifact 'ecdysis_data             'db-relation)
   (make-artifact 'ecdysis_links            'db-relation)
   (make-artifact 'inat_observations        'db-relation)
   (make-artifact 'waba_data                'db-relation)
   (make-artifact 'inat_projects            'db-relation)
   (make-artifact 'checklist_raw            'db-relation)
   (make-artifact 'checklist_resolved       'db-relation)
   (make-artifact 'inat_obs_data            'db-relation)
   (make-artifact 'canonical_to_taxon_id    'db-relation)
   (make-artifact 'inactive_remaps          'db-relation)
   (make-artifact 'taxon_lineage_extended   'db-relation)
   (make-artifact 'host_plant_lineage       'db-relation)
   ;; coordinate -> DEM elevation lookup (beeatlas-sn8). A CACHE that only grows:
   ;; dem_elevation.py samples a coordinate once and never re-reads it, so this
   ;; relation's digest changes exactly when new coordinates enter the sources.
   (make-artifact 'dem_elevations           'db-relation)
   (make-artifact 'geographies_places       'db-relation)
   ;; county geometry (st-4cm), loaded out of band like the three below
   (make-artifact 'geographies_us_counties  'db-relation #:provenance 'upstream)
   ;; The remaining geography tables dbt's stg_geo__* models read (st-7hw). PRODUCERLESS
   ;; on purpose: unlike geographies_places (places-load writes it), these are loaded
   ;; out of band, so the graph names them without claiming to make them — which is
   ;; what 'upstream DECLARES (st-zb9; before it, "on purpose" lived only in this
   ;; comment and check-graph-leaves could not tell it from a forgotten producer).
   ;; What matters is that they
   ;; are db-relations rather than folded into the `geographies' EXTERNAL below: an
   ;; external resolves to #f and can only ever report 'inputs-unresolvable, where a
   ;; relation gets a real digest and can say 'input-changed naming the layer.
   ;; padus_wilderness resolves even where nobody has loaded PAD-US — dbt_project.yml's
   ;; on-run-start hook CREATEs it empty — so this doesn't strand a fresh host on
   ;; 'inputs-unresolvable.
   (make-artifact 'geographies_ecoregions       'db-relation #:provenance 'upstream)
   (make-artifact 'geographies_us_states        'db-relation #:provenance 'upstream)
   (make-artifact 'geographies_padus_wilderness 'db-relation #:provenance 'upstream)
   (make-artifact 'geographies              'external)
   (make-artifact 'anti-entropy-applied     'token)
   (make-artifact 'checklist-resolution-verified 'token)
   (make-artifact 'resolution-verified      'token)
   (make-artifact 'inactive-verified        'token)
   (make-artifact 'places-validated         'token)
   (make-artifact 'dedup-verified           'token)
   (make-artifact 'inat-obs-count-verified  'token) ; integrity gate (st-0vz)
   ;; the correction overlay's two seeds + the gate token they feed (st-t4t).
   ;; None has a producer here, but for two different reasons, and st-zb9 makes the
   ;; graph say which: the corrections file is AUTHORITATIVE — authored,
   ;; forward-only overrides of values an upstream source gets wrong, with git as
   ;; its store — while the other two are the Bee-Gap extracts those corrections
   ;; are written AGAINST, so they are 'upstream: not ours to write forward, and
   ;; replaced wholesale rather than migrated.
   (make-artifact 'bee_traits_corrections.csv 'file #:provenance 'authoritative)
   (make-artifact 'bee_traits_beegap.csv      'file #:provenance 'upstream)
   (make-artifact 'bee_parasite_hosts.csv     'file #:provenance 'upstream)
   (make-artifact 'corrections-verified       'token)
   (make-artifact 'occurrences.db               'file)
   (make-artifact 'dedup_candidates.csv         'file)
   ;; topology-postprocess reads each raw region mart @export copy and writes a
   ;; distinctly-named cleaned sibling (beeatlas-hyq made this non-in-place): the
   ;; raw <name>.geojson stays dbt-build's/place-marts' output, .clean.geojson is
   ;; topology's — one producer per artifact. Replaces the old fictional
   ;; single-output `region-topology-clean' placeholder (st-4cm slice 4).
   (make-artifact 'counties.clean.geojson       'file)
   (make-artifact 'ecoregions.clean.geojson     'file)
   (make-artifact 'wilderness.clean.geojson     'file)
   (make-artifact 'species.json                 'file)
   ;; species_export writes SIX files in one invocation; species.json is the
   ;; headline target but these four are equally real outputs (the edge-verify
   ;; harness, st-qp7, surfaced them as undeclared writes on the slice-1 edge).
   (make-artifact 'seasonality.json             'file)
   ;; county/ecoregion -> taxon presence for the static /species/ pickers
   ;; (beeatlas-0of.2). Derived and rebuildable; published via the slim manifest.
   (make-artifact 'taxon_presence.json          'file)
   (make-artifact 'photos.json                  'file)
   (make-artifact 'species_hosts.json           'file)
   (make-artifact 'higher_taxa.json             'file)
   ;; per-species + per-rank SVG set (st-cly), verified as a data-dependent SET
   ;; (st-5jt). All five fan-out branches key off the species.parquet@export columns
   ;; the exporter's group-membership query reads (genus/subgenus/tribe/subfamily/
   ;; slug) — verbatim, so Racket-verifiable. subgenus is a COMPOSITE (genus,
   ;; subgenus) key. Soundness gated; the exporter's occurrence-count/checklist
   ;; filter means many ranks/species have no map, reported incomplete, not failed.
   (make-artifact 'species-maps                 'dir
                  #:keyed-by
                  (list (fan-out 'species.parquet@export '("slug")              "{}.svg")
                        (fan-out 'species.parquet@export '("genus")             "genus/{}.svg")
                        (fan-out 'species.parquet@export '("genus" "subgenus")  "subgenus/{}/{}.svg")
                        (fan-out 'species.parquet@export '("tribe")             "tribe/{}.svg")
                        (fan-out 'species.parquet@export '("subfamily")         "subfamily/{}.svg")))
   (make-artifact 'places.geojson               'file)
   (make-artifact 'places.json                  'file)
   ;; heavy per-place feed (species + collection timing) written by the same
   ;; places_export invocation as places.json; a build_time_fetch sibling (like
   ;; collectors.json), modelled so the node's third output has a producer (st-4cm).
   (make-artifact 'place_details.json           'file)
   (make-artifact 'collectors.json              'file)
   ;; collectors-events-export reads base collectors.json read-only and writes the
   ;; event-enriched array to a DISTINCT collectors.events.json (beeatlas-hyq); the
   ;; base collectors.json stays collectors-export's sole output. collector_event_
   ;; pages.json is the compact sub-page sidecar written by the same invocation.
   (make-artifact 'collectors.events.json       'file)
   (make-artifact 'collector_event_pages.json   'file)
   ;; the per-canonical_name notes SET (st-pd1): notes-harvest writes one
   ;; EXPORT_DIR/notes/<name>.json per approved species — the KEYED unit a targeted
   ;; rebuild touches (a note edit rebuilds only that species' file). DERIVED.
   ;; keyed-by (st-243): an IDENTITY gate against the store keyset. The harvest
   ;; does not filter beyond what notes-store-keys already scopes to (approved
   ;; notes ⋈ users), so the merged dir a partial rebuild leaves behind must be
   ;; EXACTLY one <canonical_name>.json per store key — a stale un-pruned file
   ;; and a missed key both fail the gate, by name.
   (make-artifact 'notes                        'dir
                  #:keyed-by (store-keyed 'notes-store.db "{}.json"))
   ;; the authoritative notes STORE — beeatlas's one piece of forward-only state on
   ;; this graph (user-authored notes; regenerable only by migration, never by the
   ;; build). It has NO producer here, so the graph structurally cannot rebuild it —
   ;; which IS the forward-only guarantee. 'authoritative documents that; the flag
   ;; is inert on an input (never output-snapshotted), so this is pure intent.
   (make-artifact 'notes-store.db               'file #:provenance 'authoritative)
   ;; per-place SVG set (st-cly), verified as a data-dependent SET (st-tul): one
   ;; place-maps/<slug>.svg per places.json[].slug. SOUNDNESS is gated — every map
   ;; is a real place; the places with zero occurrences get no map (filtered), so
   ;; those keys are reported incomplete, not failed.
   (make-artifact 'place-maps                   'dir
                  #:keyed-by (list (fan-out 'places.json '("slug") "{}.svg")))
   ;; per-variant Atom XML set (st-cly), verified via the manifest feeds emits
   ;; (st-q6i). feeds' filenames are collector-<slugify(recorded_by)>.xml /
   ;; genus-<slugify(genus)>.xml with slug collision-dedup — a TRANSFORM of the
   ;; column, so we don't re-derive it; feeds/index.json already maps each file to
   ;; its verbatim filter_value, which we check against the ecdysis_data columns.
   ;; determinations.xml + index.json are the un-keyed singletons.
   (make-artifact 'feeds                        'dir
                  #:keyed-by
                  (manifest-key "index.json" "filename" "filter_value" "filter_type"
                                (list (list "collector" "ecdysis_data.occurrences" "recorded_by")
                                      (list "genus"     "ecdysis_data.occurrences" "genus"))
                                (list "index.json" "determinations.xml")))
   ;; --- the compressed representations (st-ljy) ---
   ;; `compressed/`: one `<artifact><.br|.gz>` per runtime artifact worth compressing.
   ;; NOT a second copy of the data — the same bytes in the representation a client
   ;; actually downloads, which beeatlas ADR 0024 established and put in the publish
   ;; step. This node is the half that moves it off that path: `postbuild-data.mjs`
   ;; runs on `build:content`, the NOTE-PUBLISH path, and rebuilds `_site/data`
   ;; wholesale with no cache, so a note write spent ~2.9 s recompressing a 34 MB
   ;; database that changes once a night. Compression is a pure function of a
   ;; content-addressed input, which is the definition of an edge here, so early
   ;; cutoff produces these when the DATA moves and not when a note does.
   ;;
   ;; A plain 'dir with no #:keyed-by: its members ARE the declared inputs' names
   ;; (plus a suffix), so a fan-out key would restate the input list rather than check
   ;; anything the graph doesn't already say. The producer prunes what it didn't write,
   ;; which is what makes the tree digest settle — the same argument as app-bundle's.
   (make-artifact 'compressed                   'dir)
   ;; --- the site's app bundle (st-hdm step 2) ---
   ;; `_site/assets`: the hashed JS/CSS/wasm chunks Vite emits. The FIRST half of
   ;; reclaiming the render into the graph (ADR 0007's per-page-provenance
   ;; amendment), and deliberately the half that carries no provenance value — it
   ;; is here to prove the extent model before `site-content`, which is where the
   ;; note-to-page chain lands.
   ;;
   ;; A plain 'dir with NO #:keyed-by. Its members are content-hashed filenames
   ;; with no key structure to check a set against — there is no relation whose
   ;; keys they are, which is what a fan-out key means. The set is instead made
   ;; exact by the producer: `npm run build:bundle` ends in finish-bundle.mjs,
   ;; which deletes anything the Vite manifest does not name (beeatlas-8df). So
   ;; the tree digest settles because the directory is exactly the manifest, not
   ;; because Stelis polices it.
   (make-artifact 'app-bundle                   'dir)
   ;; --- taxon reasoning (st-ozp) ---
   ;; The curated high-rank trait assertions. Hand-authored, no producer — the
   ;; graph structurally cannot rebuild it, which IS the forward-only guarantee
   ;; (same argument as notes-store.db; here the forward-only store is git).
   ;; Modelled as an ARTIFACT rather than folded into the node's `code' so that
   ;; a curator's edit reads as the data change it is: 'input-changed naming the
   ;; file, visible in --why, and part of the graph snapshot.
   (make-artifact 'taxon-traits.rktd            'file #:provenance 'authoritative)
   ;; …and what the reasoning publishes: per-species derived traits, each with
   ;; the proof of which ancestor carries it and a learner-facing sentence.
   (make-artifact 'species_reasoning.json       'file)
   ;; EXPORT_DIR-placed copies of the dbt marts (place-marts output) + the
   ;; enriched species.parquet species-export writes there. Distinct artifacts
   ;; from the sandbox originals so each has exactly one producer.
   (make-artifact 'species.parquet@export       'file))))
(define mart-export-artifacts
  (for/list ([m (in-list placed-marts)]) (make-artifact (export-name m) 'file)))

;; --- Tasks (the 32 run.py STEPS, in list order) -----------------------------
;; `invoke' recipes transcribed from run.py's imports (module + function).
(define tasks
  (list
   ;; --- ingestion boundary ---
   (make-task 'taxa-download 'boundary #:outputs '(taxa.csv.gz)
              #:invoke (py "taxa_pipeline" "download_taxa_csv"))
   (make-task 'ecdysis 'boundary #:outputs '(ecdysis_data)
              #:invoke (py "ecdysis_pipeline" "load_ecdysis"))
   ;; ecdysis-links augments the ecdysis_data schema in place with the
   ;; occurrence_links table (load_ecdysis and load_links write the same dlt
   ;; dataset). Modelled as a distinct db-relation because dbt reads it through a
   ;; dedicated staging model (stg_ecdysis__occurrence_links); kept separate per
   ;; the 2026-07-11 review rather than collapsed into ecdysis_data.
   (make-task 'ecdysis-links 'boundary #:inputs '(ecdysis_data) #:outputs '(ecdysis_links)
              #:invoke (py "ecdysis_pipeline" "load_links"))
   (make-task 'inaturalist 'boundary #:outputs '(inat_observations)
              #:invoke (py "inaturalist_pipeline" "load_observations"))
   (make-task 'waba 'boundary #:outputs '(waba_data)
              #:invoke (py "waba_pipeline" "load_observations"))
   (make-task 'projects 'boundary #:inputs '(inat_observations) #:outputs '(inat_projects)
              #:invoke (py "projects_pipeline" "load_projects"))
   (make-task 'anti-entropy 'transform
              #:inputs '(ecdysis_data inat_observations waba_data)
              #:outputs '(anti-entropy-applied)
              #:invoke (py "anti_entropy_pipeline" "run_anti_entropy"))
   ;; load_checklist also materializes canonical_name onto ecdysis_data.occurrences
   ;; (checklist_pipeline._update_occurrences_canonical_name). The ecdysis loader uses
   ;; write_disposition='replace', which drops that column every run, so checklist MUST
   ;; run after `ecdysis` — matching run.py's linear order (…ecdysis…→checklist). The
   ;; ecdysis_data input declares that edge; without it the planner scheduled checklist
   ;; first and the subsequent replace wiped canonical_name, emptying
   ;; int_species_host_plants and failing species-export (st-84u).
   (make-task 'checklist 'boundary #:inputs '(ecdysis_data) #:outputs '(checklist_raw)
              #:invoke (py "checklist_pipeline" "load_checklist"))
   (make-task 'resolve-checklist-names 'transform
              #:inputs '(checklist_raw) #:outputs '(checklist_resolved)
              #:invoke (py "resolve_checklist_names" "resolve_checklist_names"))
   (make-task 'checklist-resolution-gate 'gate
              #:inputs '(checklist_resolved) #:outputs '(checklist-resolution-verified)
              #:invoke (py "resolve_checklist_names" "check_checklist_resolution_gate"))
   (make-task 'inat-obs 'boundary #:outputs '(inat_obs_data)
              #:invoke (py "inat_obs_pipeline" "load_inat_obs"))
   ;; integrity gate (st-0vz): block publish if inat_obs_data's record count
   ;; swings sharply vs. the previous build. An in-process rule node, not a
   ;; subprocess — the first instance of data-quality rules running as nodes.
   (make-task 'inat-obs-integrity 'gate
              #:inputs '(inat_obs_data) #:outputs '(inat-obs-count-verified)
              #:invoke (integrity-gate 'inat_obs_data))
   (make-task 'resolve-taxon-ids 'transform
              #:inputs '(inat_observations taxa.csv.gz) #:outputs '(canonical_to_taxon_id)
              #:invoke (py "resolve_taxon_ids" "resolve_taxon_ids"))
   (make-task 'resolution-gate 'gate
              #:inputs '(canonical_to_taxon_id) #:outputs '(resolution-verified)
              #:invoke (py "resolve_taxon_ids" "check_resolution_gate"))
   (make-task 'inactive-remap 'transform
              #:inputs '(canonical_to_taxon_id) #:outputs '(inactive_remaps)
              #:invoke (py "resolve_taxon_ids" "generate_inactive_remaps"))
   (make-task 'inactive-gate 'gate
              #:inputs '(inactive_remaps) #:outputs '(inactive-verified)
              #:invoke (py "resolve_taxon_ids" "check_inactive_gate"))
   (make-task 'taxon-lineage-extended 'transform
              #:inputs '(taxa.csv.gz) #:outputs '(taxon_lineage_extended)
              #:invoke (py "taxa_pipeline" "load_taxon_lineage_extended"))
   (make-task 'host-plant-lineage 'transform
              #:inputs '(taxa.csv.gz) #:outputs '(host_plant_lineage)
              #:invoke (py "host_plant_lineage" "load_host_plant_lineage"))
   (make-task 'places-validation 'gate
              #:inputs '(geographies) #:outputs '(places-validated)
              #:invoke (py "places_validation" "validate_places_step"))

   ;; DEM elevation backfill (beeatlas-sn8): samples USGS 3DEP for every
   ;; coordinate in the four source relations that feed int_combined's
   ;; NON-checklist arms, and caches the result in dem_data.elevations. dbt reads
   ;; it through stg_dem__elevations, so this MUST precede dbt-build — declared
   ;; the Stelis way, as an artifact dbt-build lists in its #:inputs, never as an
   ;; assumption about list order. (Same class of hazard as the ecdysis→checklist
   ;; edge below: run.py's linear STEPS enforced order implicitly; here it is an
   ;; explicit edge or it is nothing.)
   ;;
   ;; The four inputs are exactly the seed relations dem_elevation._SEED_SOURCES
   ;; reads — so a re-ingest that introduces new coordinates re-runs this step.
   ;; Note inat_observations (inaturalist_data) AND waba_data (inaturalist_waba_
   ;; data) are BOTH here: they are different relations feeding different arms.
   ;;
   ;; 'boundary, not 'transform, on two grounds. It reaches outside the build for
   ;; data (the ingestion-boundary rule), and a boundary always runs — which is
   ;; what makes a deferred tile self-heal. A tile that 5xx'd is recorded nowhere,
   ;; so its coordinates stay unsampled; under 'transform an unchanged-input build
   ;; would skip the step and strand them until the sources happened to move.
   ;; Running unconditionally costs one query when there is nothing new to sample.
   (make-task 'dem-elevation 'boundary
              #:inputs '(ecdysis_data inat_observations waba_data inat_obs_data)
              #:outputs '(dem_elevations)
              #:invoke (py "dem_elevation" "load_dem_elevations"))
   (make-task 'places-load 'transform
              #:inputs '(places-validated geographies) #:outputs '(geographies_places)
              #:invoke (py "places_load" "load_places_step"))

   ;; A correction overrides a CITED source, so it must not be able to outlive the
   ;; error it fixes (st-t4t). This gate fails the build when an upstream value no
   ;; longer matches the `expected_upstream` its correction was written against —
   ;; upstream fixed the record, or changed it to something else. Blocking rather
   ;; than advisory: if upstream has been fixed, continuing to override it would
   ;; REINTRODUCE an error in the name of correctness. An in-process rule node, as
   ;; the integrity gate is.
   (make-task 'corrections-drift-gate 'gate
              #:inputs '(bee_traits_corrections.csv bee_traits_beegap.csv
                         bee_parasite_hosts.csv)
              #:outputs '(corrections-verified)
              #:invoke (rule-check "corrections-drift"
                                   (make-corrections-drift-check
                                    (seed-file "bee_traits_corrections.csv")
                                    (seed-file "bee_traits_beegap.csv")
                                    (seed-file "bee_parasite_hosts.csv"))))

   ;; --- the transform hinge: one opaque task, many outputs ---
   (make-task 'dbt-build 'transform
              ;; ONE input per source() table dbt's models read — 22 tables across
              ;; these 19 artifacts. st-7hw closed a gap in exactly this list: it
              ;; named 14 of the 22, and the eight it missed included the geography
              ;; that three of the nine sandbox marts below are made OF. The failure
              ;; is silent and it bit: maderas's counties.geojson mart carries 1,305
              ;; vertices against 20,657 for the same 39 counties locally, because its
              ;; geographies.us_counties.geom is ~15x coarser — and a reload to fix
              ;; that would have changed nothing this task hashed, so dbt-build would
              ;; have cache-skipped and left the degraded marts in place.
              ;; checklist_raw is here for the same reason and is NOT redundant with
              ;; checklist_resolved: `resolved' digests inaturalist_data.canonical_to_
              ;; taxon_id, a DIFFERENT table, so it is an ancestor (the order was
              ;; already right) but never a witness to the four checklist_data tables
              ;; stg_checklist__* reads. Being transitively upstream orders a task;
              ;; only being NAMED here puts a table in its input address.
              #:inputs '(ecdysis_data ecdysis_links inat_observations inat_projects
                         waba_data anti-entropy-applied
                         checklist_raw
                         checklist_resolved checklist-resolution-verified
                         inat_obs_data inat-obs-count-verified
                         corrections-verified
                         canonical_to_taxon_id resolution-verified
                         inactive_remaps inactive-verified
                         taxon_lineage_extended host_plant_lineage
                         geographies_places geographies_us_counties
                         geographies_ecoregions geographies_us_states
                         geographies_padus_wilderness
                         dem_elevations)
              #:outputs sandbox-marts   ; exactly the nine sandbox marts (st-bft)
              ;; Recipe is `run.sh build' only — it writes the marts to the dbt
              ;; sandbox. run.py's _run_dbt_build ALSO copies six of them to
              ;; EXPORT_DIR; that placement is now its own `place-marts' node
              ;; (st-4cm), so it is a modeled, cache-skippable edge rather than a
              ;; side effect of the dbt step. occurrences.db is unaffected —
              ;; generate-sqlite reads occurrences.parquet from the sandbox directly.
              ;; dbt's CODE (st-0ql): the wrapper (whose uvx line pins the dbt
              ;; version), project+profiles config, and the source trees dbt
              ;; build reads — models/, macros/, seeds/, tests/, expanded
              ;; per-file so 'code-changed names the exact model. target/,
              ;; logs/, and .user.yml are deliberately ABSENT: they are dbt's
              ;; own outputs/mutable state, and hashing them into the input
              ;; address would self-invalidate every build.
              #:invoke (recipe 'dbt (list "build")
                               (map data-file
                                    '("dbt/run.sh" "dbt/dbt_project.yml"
                                      "dbt/profiles.yml" "dbt/models"
                                      "dbt/macros" "dbt/seeds" "dbt/tests"))))

   ;; --- the target producer (has a __main__; run as a script) ---
   (make-task 'generate-sqlite 'transform
              #:inputs '(occurrences.parquet taxa.csv.gz) #:outputs '(occurrences.db)
              #:invoke (recipe 'uv (list "sqlite_export.py")
                               (cons (data-file "sqlite_export.py")
                                     uv-runtime-code)))

   ;; --- mart placement: dbt outputs -> EXPORT_DIR, where post-dbt exports read
   ;; them (st-4cm). run.py folds this copy into dbt-build; here it is an explicit
   ;; node so the placement is a modeled, cache-skippable edge. Not on the
   ;; occurrences.db path (generate-sqlite reads the sandbox directly).
   (make-task 'place-marts 'transform
              #:inputs placed-marts
              #:outputs (map export-name placed-marts)
              #:invoke (recipe 'sh (list place-marts-script)))

   ;; --- post-dbt siblings (NOT upstream of occurrences.db) ---
   (make-task 'dedup-candidates 'transform
              #:inputs '(checklist.parquet) #:outputs '(dedup_candidates.csv)
              #:invoke (py "checklist_dedup" "write_dedup_candidates"))
   (make-task 'dedup-gate 'gate
              #:inputs '(dedup_candidates.csv) #:outputs '(dedup-verified)
              #:invoke (py "checklist_dedup" "check_dedup_gate"))
   ;; topology_postprocess reads the raw region marts from EXPORT_DIR (the @export
   ;; copies place-marts drops there — Pitfall 5, same as the other post-dbt
   ;; exporters), NOT the sandbox originals; the modeled edge read the sandbox marts
   ;; until this was exercised (st-4cm slice 4). One mapshaper pass per layer writes
   ;; a distinct <name>.clean.geojson sibling (beeatlas-hyq: no longer in place).
   ;; EDGE VERIFIED and determinism-clean: all 3 outputs are byte-identical across
   ;; runs. _meta.built_at now reads the ADR-0004 SOURCE_DATE_EPOCH clock stelis
   ;; injects (beeatlas-8td SITE 1, beeatlas d9ff9e26), and the geometry was already
   ;; stable — so two stelis runs of this task reproduce identical bytes.
   ;; `#:code' carries data/package-lock.json (st-vue): mapshaper is a SUBPROCESS
   ;; binary, so the py-imports scan cannot see it, yet its `-simplify' output is
   ;; algorithm-dependent — a version bump moves the geometry while the recorded
   ;; code-hashes sit still and the task cache-skips on stale output. That is the
   ;; st-egh/duckdb.rkt shape exactly. Declaring the ROOT lockfile was never
   ;; affordable (it moved for every site dependency bump, rebuilding geometry for
   ;; unrelated reasons); beeatlas-dqh split mapshaper into data/package.json, so
   ;; this lockfile now pins one tool used by one task — and dependabot watches
   ;; /data weekly, so it WILL move. Rebuild cost is ~2s of mapshaper on maderas
   ;; against real inputs, and these three artifacts are terminal here.
   (make-task 'topology-postprocess 'transform
              #:inputs '(counties.geojson@export ecoregions.geojson@export
                         wilderness.geojson@export)
              #:outputs '(counties.clean.geojson ecoregions.clean.geojson
                          wilderness.clean.geojson)
              #:invoke (py "topology_postprocess" "main"
                           #:code '("package-lock.json")))
   ;; species_export.main reads FOUR dbt-mart parquets from the sandbox and
   ;; writes species.json (among others) to EXPORT_DIR. occurrences.parquet is a
   ;; hard requirement (per-occurrence seasonality accumulation), not optional —
   ;; it was missing from this edge until the species.json target exercised it
   ;; (st-4cm). species_traits.parquet is read too but degrades gracefully
   ;; (warn + null-fill) so it stays an honest input without being load-bearing.
   (make-task 'species-export 'transform
              #:inputs '(species.parquet occurrences.parquet
                         species_traits.parquet higher_taxa.parquet)
              ;; One invocation writes SIX files to EXPORT_DIR: species.json, the
              ;; enriched species.parquet (23-col with slug; collectors/places read
              ;; THAT, not the dbt mart — hence @export), and four sibling feeds.
              ;; The slice-1 edge declared only the first two; edge-verify (st-qp7)
              ;; caught the other four as undeclared writes.
              #:outputs '(species.json species.parquet@export
                          seasonality.json photos.json species_hosts.json higher_taxa.json)
              #:invoke (py "species_export" "main"))
   ;; taxon-presence-export (beeatlas-0of.2): county/ecoregion -> taxon presence
   ;; with evidence bits, for the static /species/ pickers.
   ;;
   ;; Reads occurrences.parquet@export — the PLACED copy in EXPORT_DIR, not the
   ;; sandbox mart. The bead sketched this node on generate-sqlite (which reads the
   ;; sandbox), but this export sets ASSETS_DIR := EXPORT_DIR like collectors-export
   ;; does, so @export is the edge that matches what it actually opens (Pitfall 5).
   ;; It needs no taxa.csv.gz: presence is keyed on taxon_id straight from the mart,
   ;; with no name or lineage lookup.
   ;;
   ;; ONE output, and that is the whole list — the species-export scar above (a
   ;; slice-1 edge declaring 2 of the 6 files it wrote, with edge-verify catching
   ;; the rest as undeclared writes) is why this is stated rather than assumed.
   (make-task 'taxon-presence-export 'transform
              #:inputs '(occurrences.parquet@export)
              #:outputs '(taxon_presence.json)
              #:invoke (py "taxon_presence_export" "main"))
   ;; species_maps reads THREE EXPORT_DIR @export parquets — it never opens
   ;; species.json, so the slice-1 edge (declaring species.json) was wrong (st-4cm):
   ;;   species.parquet@export     enriched slug + genus/subgenus/tribe/subfamily membership
   ;;   occurrences.parquet@export occurrence points
   ;;   checklist.parquet@export   per-species checklist counties (degrades if absent)
   ;; County GEOMETRY comes from the geographies.us_counties db-relation, read
   ;; straight from the duckdb. Writes the species-maps/ directory SET (st-cly);
   ;; still an opaque 'dir — its fan-out is multi-key incl. a composite subgenus
   ;; (genus,subgenus), beyond the single-column st-tul model (follow-on st-5jt).
   ;; Edge corrected + determinism-verified (identical tree digest twice) here.
   (make-task 'species-maps 'transform
              #:inputs '(species.parquet@export occurrences.parquet@export
                         checklist.parquet@export geographies_us_counties)
              #:outputs '(species-maps)
              #:invoke (py "species_maps" "main"))
   ;; places_export reads its parquets from EXPORT_DIR (ASSETS_DIR), not the dbt
   ;; sandbox — the occurrence_places bridge, the occurrences mart (specimen/sample
   ;; counts), and species-export's enriched species.parquet are all @export copies,
   ;; the same Pitfall-5 fix collectors-export needed (st-4cm slice 2). geographies_
   ;; places is the DuckDB relation read for places.geojson. The modeled edge had
   ;; only the sandbox occurrence_places.parquet + geographies_places; the other
   ;; two @export inputs surfaced when places.json was built+verified (slice 3).
   ;; One invocation writes all three outputs; place_details.json is the heavy
   ;; per-place feed sibling.
   (make-task 'places-export 'transform
              #:inputs '(occurrence_places.parquet@export occurrences.parquet@export
                         species.parquet@export geographies_places)
              #:outputs '(places.geojson places.json place_details.json)
              #:invoke (py "places_export" "export_places_step"))
   ;; collectors_export reads EXPORT_DIR/occurrences.parquet (place-marts copy)
   ;; and EXPORT_DIR/species.parquet (species-export's enriched copy) — both
   ;; @export, not the sandbox originals; the sandbox occurrences.parquet edge
   ;; here was wrong until collectors.json exercised it (st-4cm slice 2).
   (make-task 'collectors-export 'transform
              #:inputs '(occurrences.parquet@export species.parquet@export)
              #:outputs '(collectors.json)
              #:invoke (py "collectors_export" "export_collectors_step"))
   ;; collectors_events_export reads base collectors.json (read-only) for the
   ;; records to enrich, occurrences.parquet@export for the event query, and
   ;; species.json + higher_taxa.json for slug resolution (all from EXPORT_DIR).
   ;; The declared edge had only collectors.json + collector_event_pages.json until
   ;; slice 4 exercised it; the enriched output is now the distinct collectors.
   ;; events.json (beeatlas-hyq), with collector_event_pages.json its sidecar.
   ;; (occurrence_synonyms.csv is a fixed dbt seed, not a graph artifact.)
   ;; EDGE VERIFIED and determinism-clean: both outputs are byte-identical across
   ;; runs after beeatlas-8td SITE 2 (0a025ff4) gave the event query a total-order
   ;; tiebreak (was reordering tied first_page_events rows under DuckDB parallelism).
   (make-task 'collectors-events-export 'transform
              #:inputs '(collectors.json occurrences.parquet@export
                         species.json higher_taxa.json)
              #:outputs '(collectors.events.json collector_event_pages.json)
              #:invoke (py "collectors_events_export" "export_collectors_events_step"))
   ;; notes-harvest reads the authoritative notes store (make_engine, NOTES_DB_PATH)
   ;; for approved notes AND collectors.json (byline resolution, D-11/D-12). Emits
   ;; the per-species notes/ SET. PARTIAL-CAPABLE (st-pd1): honors STELIS_REBUILD_KEYS
   ;; to re-harvest only the canonical_names a CRUD touched (beeatlas-partial-tasks).
   (make-task 'notes-harvest 'transform
              #:inputs '(collectors.json notes-store.db) #:outputs '(notes)
              #:invoke (py "notes_harvest" "main"))
   ;; places_maps reads occurrences.parquet@export + the occurrence_places.parquet@
   ;; export bridge (grouping points per place_slug) and county GEOMETRY from the
   ;; geographies.us_counties db-relation — it never opens places.geojson, so the
   ;; slice edge declaring it was wrong (st-4cm). The place SET it writes is a
   ;; FILTERED subset of the bridge's slugs (places with occurrences). Its fan-out
   ;; key (places.json[].slug, on the artifact) is verification metadata, not a data
   ;; read, so it stays off this input list. Determinism-gated.
   (make-task 'places-maps 'transform
              #:inputs '(occurrences.parquet@export occurrence_places.parquet@export
                         geographies_us_counties)
              #:outputs '(place-maps)
              #:invoke (py "places_maps" "main"))
   ;; feeds queries the ecdysis_data db-relation (identifications JOIN occurrences)
   ;; STRAIGHT from the duckdb and reads no @export file — so the slice-1 edge
   ;; (occurrences.parquet + species.json) was wrong on both inputs, and feeds does
   ;; NOT depend on dbt-build (st-4cm). Writes the feeds/ directory SET (st-cly):
   ;; per-collector + per-genus Atom XML plus determinations.xml/index.json
   ;; singletons — an opaque 'dir until the richer fan-out key lands (st-5jt).
   ;; Determinism-gated: feeds.py now honors SOURCE_DATE_EPOCH for empty feeds'
   ;; <updated> (was wall-clock), so two builds of a snapshot are byte-identical.
   (make-task 'feeds 'transform
              #:inputs '(ecdysis_data) #:outputs '(feeds)
              #:invoke (py "feeds" "main"))
   ;; --- pre-compression (st-ljy) -------------------------------------------
   ;; The runtime artifacts' `.br`/`.gz` representations, produced once per data
   ;; change instead of once per publish. See the artifact for why it is a node at
   ;; all; what is worth saying here is the two things holding it together.
   ;;
   ;; WHICH ARTIFACTS travels on argv rather than being read from
   ;; lib/runtime-artifacts.js by the script. Both would work until they disagreed,
   ;; and disagreement has a direction that matters: a script compressing MORE than
   ;; the graph declared would change this dir's digest with no declared input
   ;; change — a wrong skip. Passing the set makes the edge authoritative, and the
   ;; args are part of the recipe hash, so editing the list reads as
   ;; `recipe-changed`.
   ;;
   ;; ITS CODE is hand-listed, unlike the `py` tasks (st-6ga scans their imports) —
   ;; there is no JS import scan here, so the two local modules the script pulls in
   ;; are named explicitly. The st-egh failure mode applies: a NEW import inside
   ;; lib/precompress.js would change what this node does while its recorded
   ;; code-hashes sit still. Compression policy lives in that one file, which is why
   ;; the list is short enough to keep honest by eye.
   (make-task 'precompress 'transform
              #:inputs precompressed-artifacts
              #:outputs '(compressed)
              #:invoke (recipe 'node
                               (append (list "node" "scripts/precompress-artifacts.mjs")
                                       (map ~a precompressed-artifacts))
                               (append
                                (list (build-path BEEATLAS "scripts" "precompress-artifacts.mjs")
                                      (build-path BEEATLAS "lib" "precompress.js")
                                      (build-path BEEATLAS "lib" "build-data-dir.js"))
                                node-runtime-code)))
   ;; --- the app bundle (st-hdm step 2) ------------------------------------
   ;; The first task with NO data inputs. The bundle is a function of source
   ;; code and nothing else — no artifact upstream of it, so its plan is one
   ;; task and its only reason to run is `code-changed`.
   ;;
   ;; Which is why the inputs are declared as recipe CODE rather than as
   ;; artifacts. `code` already takes directories (st-0ql, dbt's models/) and
   ;; expands them per-file, so `src` gives the same per-file grain a 'dir
   ;; artifact would, and an edit reports 'code-changed naming the exact file.
   ;; Authoring six producerless leaf artifacts to say the same thing would put
   ;; six nodes in the graph snapshot whose only purpose is to be hashed.
   ;;
   ;; The list is beeatlas's own (scripts/build-app.mjs BUNDLE_INPUTS), which is
   ;; the gate this replaces — package-lock.json because a dependency bump
   ;; changes the emitted chunks, and the env files because Vite bakes VITE_*
   ;; values INTO them — VITE_DATA_BASE_URL and VITE_NOTES_API_BASE_URL, which
   ;; are the whole of it since beeatlas-q73 self-hosted the basemap and retired
   ;; VITE_MAPBOX_TOKEN (beeatlas src/env.d.ts says so; a stale line survives in
   ;; the local .env, which is what made it look current). Only a file's HASH is
   ;; recorded, never its content, so a secret never reaches the history or a log.
   ;;
   ;; All FOUR env files Vite loads in production mode are declared, though only
   ;; `.env` exists (st-e4y): as `optional-code', an absent one addresses to a
   ;; stable sentinel instead of #f, so the task still skips while they stay
   ;; absent AND one appearing is a `code-changed` naming it. Listing only what
   ;; exists would make a `.env.production` appearing later invisible to the
   ;; cache — beeatlas ADR 0019's expensive case (rotate the token, the gate
   ;; skips nightly, the live site keeps serving the revoked one).
   ;;
   ;; INCLUDING `.env`, which does exist here — raised in review (2026-08-02) on
   ;; the grounds that it is gitignored and host-local, so making it optional lets
   ;; a host WITHOUT one skip forever on a bundle built with no VITE_* values,
   ;; where before it would have reran forever. Peter's call, and it is the right
   ;; one: absence is a legitimate state for all four, and beeatlas's own gate
   ;; agrees (build-app.mjs's walk() returns [] for a path that isn't there, so a
   ;; missing .env contributes nothing to its digest either). Declaring `.env`
   ;; required would make Stelis stricter than the gate it replaces about a file
   ;; whose absence Vite itself treats as ordinary.
   (make-task 'app-bundle 'transform
              #:inputs '() #:outputs '(app-bundle)
              #:invoke (recipe 'node (list "npm" "run" "build:bundle")
                               (append
                                (list (build-path BEEATLAS "src")
                                      (build-path BEEATLAS "vite.config.ts")
                                      (build-path BEEATLAS "vite.sw.config.ts")
                                      (build-path BEEATLAS "package.json")
                                      (build-path BEEATLAS "package-lock.json"))
                                node-runtime-code
                                (for/list ([f (in-list VITE-ENV-FILES)])
                                  (optional-code (build-path BEEATLAS f))))))
   ;; --- taxon reasoning: the first transform INSIDE the engine (st-ozp) ---
   ;; Reads the rank tree off the species mart and the curated assertions off the
   ;; fact artifact; writes species_reasoning.json. species_traits.parquet is read
   ;; only to CROSS-CHECK the result against Bee-Gap's independent per-species
   ;; values (reported in the node's note, never published) — an honest input, and
   ;; a degrading one: losing it costs the report, not the reasoning.
   ;; Deliberately crosses "transformations stay external" (ADR 0008 decision 5):
   ;; what earns Stelis-side is unbounded-depth closure with a native why. A
   ;; bounded join or a bulk aggregation would still belong in dbt.
   (make-task 'taxon-reasoning 'transform
              #:inputs '(species.parquet species_traits.parquet taxon-traits.rktd)
              #:outputs '(species_reasoning.json)
              #:invoke (derivation
                        "taxon-traits"
                        (make-taxon-reasoning 'species.parquet 'species_traits.parquet
                                              'taxon-traits.rktd 'species_reasoning.json)
                        (rkt-import-closure taxon-seam-source taxon-rules-source)))))

;; --- Code artifacts + import edges (st-whi) ----------------------------------
;; Every module a py entry transitively imports becomes a producerless 'code
;; artifact carrying its DIRECT imports as helper→helper edges — the st-6ga
;; flattened code lists, promoted to graph structure. Authored from the same
;; one-directory scan `py' uses, and placed AFTER the task list so
;; py-entry-modules is complete. With no beeatlas checkout (CI) the scan is
;; empty: no artifacts, no edges — the same conservative degradation as the
;; st-6ga code lists (tasks whose code can't be hashed rerun).
(define py-helper-files
  (sort (remove-duplicates
         (append-map py-import-closure (hash-values py-entry-modules)))
        string<?))
(define (module-of f) (regexp-replace #rx"\\.py$" f ""))
(define py-code-artifacts
  (for/list ([f (in-list py-helper-files)])
    (make-artifact (string->symbol f) 'code
                   #:imports (map string->symbol (py-direct-imports (module-of f))))))
(define py-code-artifact-names (map artifact-name py-code-artifacts))

;; add-import-inputs : (listof task) -> (listof task)
;; The task→helper edges: a py task consumes its entry module's DIRECT local
;; imports as 'code inputs. Direct only — the transitive closure is the graph's
;; (imports edges), never a flattened list here.
(define (add-import-inputs ts)
  (for/list ([t (in-list ts)])
    (define entry (hash-ref py-entry-modules (task-invoke t) #f))
    (define direct (if entry (py-direct-imports entry) '()))
    (if (null? direct)
        t
        (struct-copy task t
                     [inputs (append (task-inputs t)
                                     (map string->symbol direct))]))))

(define beeatlas-graph
  (build-graph (add-import-inputs tasks)
               (append artifacts mart-export-artifacts py-code-artifacts)))
;; (st-0kf: the leaf check used to be called here explicitly. build-graph runs it
;; now, so no graph can skip it by forgetting — which is the point, since a graph
;; that forgot would fail silently.)
