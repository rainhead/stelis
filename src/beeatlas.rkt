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
         racket/string
         racket/system
         racket/port
         "model.rkt"
         "exec.rkt"
         "relation-digest.rkt"
         "notes-digest.rkt"
         "data-quality.rkt"
         "fan-out-key.rkt")

(provide beeatlas-graph
         beeatlas-runtimes
         beeatlas-path
         beeatlas-db
         beeatlas-relation-tables
         beeatlas-resolve-relation
         beeatlas-resolve-relation-columns
         beeatlas-resolve-store-keys
         beeatlas-partial-tasks
         beeatlas-source-date-epoch)

;; --- Hermetic runtimes ------------------------------------------------------
;; beeatlas's data/ is a uv project pinned to Python 3.14; dbt is shelled through
;; data/dbt/run.sh, which uvx-pins Python 3.13. Stelis delegates hermeticity to
;; those existing pins — it just launches the right command per task.
;; Where the beeatlas case-study repo lives. Defaults to the author's checkout;
;; override with BEEATLAS_DIR to run this graph on another host (maderas, CI).
(define BEEATLAS (or (getenv "BEEATLAS_DIR") "/Users/rainhead/dev/beeatlas"))
(define DATA (string-append BEEATLAS "/data"))

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
  (hash 'uv  (runtime 'uv  (list "uv" "run" "--directory" DATA "python") "uv/3.14")
        'dbt (runtime 'dbt (list "bash" (string-append DATA "/dbt/run.sh")) "uvx/3.13")
        ;; `sh': a bare shell for file PLACEMENT (not transformation) — used by
        ;; place-marts to copy derived dbt outputs to their export destination.
        ;; No interpreter pin needed; cp is content-preserving.
        'sh  (runtime 'sh  (list "bash" "-c") "sh")))

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
    notes.json)) ; assembled from the per-species notes/ dir by notes-assemble (st-pd1)

;; Directory ('dir) terminal exports (st-cly): data-dependent output SETS that each
;; land as a directory of per-entity files under EXPORT_DIR — species_maps writes
;; EXPORT_DIR/species-maps/, places_maps EXPORT_DIR/place-maps/, feeds EXPORT_DIR/
;; feeds/. The directory name is the artifact name. Content-addressed as a whole by
;; an order-independent tree digest (tree-digest.rkt); SET completeness is st-tul.
;; `notes' is the per-canonical_name notes SET (st-pd1): notes-harvest writes
;; EXPORT_DIR/notes/<canonical_name>.json, one per approved species — the keyed unit
;; a targeted rebuild touches (notes-assemble then rolls it into notes.json).
(define export-dir-dirs '(species-maps place-maps feeds notes))

;; The authoritative notes STORE (st-msn): the SQLite file notes-harvest reads
;; read-only. A fixed absolute path OUTSIDE the beeatlas repo (D-15), from
;; NOTES_DB_PATH — resolved the same way beeatlas does, and the subprocess inherits
;; stelis's NOTES_DB_PATH unchanged, so both see the same file. Content-hashed like
;; any file input when present; absent (not mounted locally) it reads unresolvable,
;; which only forces a conservative rerun.
(define notes-store-path
  (string->path (or (getenv "NOTES_DB_PATH") "/opt/beeatlas-store/notes.db")))

;; raw/fetched/authoritative inputs at fixed paths (taxa under DATA; the notes
;; store at its absolute NOTES_DB_PATH).
(define raw-file-paths (hash 'taxa.csv.gz    (build-path DATA "raw" "taxa.csv.gz")
                             'notes-store.db notes-store-path))

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
    [(memq artifact sandbox-marts) (build-path SANDBOX s)]
    ;; @export copies (place-marts' verbatim copies + species-export's enriched
    ;; parquet): the placed sibling lives under export-dir at the un-suffixed name.
    [(regexp-match #rx"^(.+)@export$" s)
     => (lambda (m) (build-path export-dir (cadr m)))]
    [(memq artifact export-dir-files) (build-path export-dir s)]
    ;; 'dir outputs: a directory named for the artifact, directly under export-dir.
    [(memq artifact export-dir-dirs) (build-path export-dir s)]
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
    [(geographies_places)     '("geographies.places")]
    ;; county GEOMETRY species_maps reads straight from the duckdb (st-4cm edge fix)
    [(geographies_us_counties) '("geographies.us_counties")]
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
(define (py module fn)
  (recipe 'uv (list "-c" (~a "from " module " import " fn "; " fn "()"))))

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
   (make-artifact 'geographies_places       'db-relation)
   (make-artifact 'geographies_us_counties  'db-relation) ; county geometry (st-4cm)
   (make-artifact 'geographies              'external)
   (make-artifact 'anti-entropy-applied     'token)
   (make-artifact 'checklist-resolution-verified 'token)
   (make-artifact 'resolution-verified      'token)
   (make-artifact 'inactive-verified        'token)
   (make-artifact 'places-validated         'token)
   (make-artifact 'dedup-verified           'token)
   (make-artifact 'inat-obs-count-verified  'token) ; integrity gate (st-0vz)
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
   (make-artifact 'notes                        'dir)
   ;; notes.json is DERIVED: notes-assemble rolls the notes/ dir up into the
   ;; monolithic Record _data/notes.js reads (st-pd1; was notes-harvest's direct
   ;; output, st-msn). The authoritative thing is the INPUT store below, not this.
   (make-artifact 'notes.json                   'file)
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
   (make-task 'checklist 'boundary #:outputs '(checklist_raw)
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
   (make-task 'places-load 'transform
              #:inputs '(places-validated geographies) #:outputs '(geographies_places)
              #:invoke (py "places_load" "load_places_step"))

   ;; --- the transform hinge: one opaque task, many outputs ---
   (make-task 'dbt-build 'transform
              #:inputs '(ecdysis_data ecdysis_links inat_observations inat_projects
                         waba_data anti-entropy-applied
                         checklist_resolved checklist-resolution-verified
                         inat_obs_data inat-obs-count-verified
                         canonical_to_taxon_id resolution-verified
                         inactive_remaps inactive-verified
                         taxon_lineage_extended host_plant_lineage geographies_places)
              #:outputs sandbox-marts   ; exactly the nine sandbox marts (st-bft)
              ;; Recipe is `run.sh build' only — it writes the marts to the dbt
              ;; sandbox. run.py's _run_dbt_build ALSO copies six of them to
              ;; EXPORT_DIR; that placement is now its own `place-marts' node
              ;; (st-4cm), so it is a modeled, cache-skippable edge rather than a
              ;; side effect of the dbt step. occurrences.db is unaffected —
              ;; generate-sqlite reads occurrences.parquet from the sandbox directly.
              #:invoke (recipe 'dbt (list "build")))

   ;; --- the target producer (has a __main__; run as a script) ---
   (make-task 'generate-sqlite 'transform
              #:inputs '(occurrences.parquet taxa.csv.gz) #:outputs '(occurrences.db)
              #:invoke (recipe 'uv (list "sqlite_export.py")))

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
   (make-task 'topology-postprocess 'transform
              #:inputs '(counties.geojson@export ecoregions.geojson@export
                         wilderness.geojson@export)
              #:outputs '(counties.clean.geojson ecoregions.clean.geojson
                          wilderness.clean.geojson)
              #:invoke (py "topology_postprocess" "main"))
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
   ;; notes-assemble rolls the per-species notes/ dir up into the monolithic
   ;; notes.json _data/notes.js reads — full + cheap, and it runs AFTER any prune of
   ;; retracted species, so notes.json reflects exactly the dir (st-pd1).
   (make-task 'notes-assemble 'transform
              #:inputs '(notes) #:outputs '(notes.json)
              #:invoke (py "assemble_notes" "main"))
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
              #:invoke (py "feeds" "main"))))

(define beeatlas-graph (build-graph tasks (append artifacts mart-export-artifacts)))
