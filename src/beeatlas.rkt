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
         "model.rkt"
         "exec.rkt"
         "relation-digest.rkt")

(provide beeatlas-graph
         beeatlas-runtimes
         beeatlas-path
         beeatlas-db
         beeatlas-relation-tables
         beeatlas-resolve-relation)

;; --- Hermetic runtimes ------------------------------------------------------
;; beeatlas's data/ is a uv project pinned to Python 3.14; dbt is shelled through
;; data/dbt/run.sh, which uvx-pins Python 3.13. Stelis delegates hermeticity to
;; those existing pins — it just launches the right command per task.
(define BEEATLAS "/Users/rainhead/dev/beeatlas")
(define DATA (string-append BEEATLAS "/data"))

(define beeatlas-runtimes
  (hash 'uv  (runtime 'uv  (list "uv" "run" "--directory" DATA "python") "uv/3.14")
        'dbt (runtime 'dbt (list "bash" (string-append DATA "/dbt/run.sh")) "uvx/3.13")
        ;; `sh': a bare shell for file PLACEMENT (not transformation) — used by
        ;; place-marts to copy derived dbt outputs to their export destination.
        ;; No interpreter pin needed; cp is content-preserving.
        'sh  (runtime 'sh  (list "bash" "-c") "sh")))

;; The dbt mart artifacts run.py's _run_dbt_build copies from the sandbox into
;; EXPORT_DIR so the post-dbt exports find them at the expected paths. (species.
;; parquet is deliberately NOT here — species_export writes its own enriched copy.)
(define mart-files
  '("occurrences.parquet" "occurrence_places.parquet" "counties.geojson"
    "ecoregions.geojson" "wilderness.geojson" "checklist.parquet"))

;; name of the EXPORT_DIR-placed copy of a mart file (distinct from the sandbox
;; artifact so the graph has one producer per artifact: dbt-build makes the
;; sandbox copy, place-marts makes the @export copy).
(define (export-name file) (string->symbol (string-append file "@export")))

;; Where beeatlas's file artifacts physically live — the resolver caching uses to
;; content-hash inputs and to place/verify outputs. #f for artifacts with no known
;; single file (duckdb relations, tokens, externals): those aren't content-hashed
;; in Horizon 0. Outputs land under the build's export-dir (explicit destination).
(define SANDBOX (string-append DATA "/dbt/target/sandbox"))
(define (beeatlas-path artifact export-dir)
  (define s (~a artifact))
  (cond
    ;; @export artifacts are the EXPORT_DIR-placed copies (place-marts, st-4cm):
    ;; strip the suffix to get the on-disk filename under export-dir.
    [(regexp-match #rx"^(.+)@export$" s)
     => (lambda (m) (build-path export-dir (cadr m)))]
    [else (beeatlas-path/case artifact export-dir)]))
(define (beeatlas-path/case artifact export-dir)
  (case artifact
    [(occurrences.parquet occurrence_places.parquet checklist.parquet
      species.parquet species_traits.parquet higher_taxa.parquet
      counties.geojson ecoregions.geojson wilderness.geojson)
     (build-path SANDBOX (~a artifact))]
    [(taxa.csv.gz)   (build-path DATA "raw" "taxa.csv.gz")]
    ;; terminal export targets land in EXPORT_DIR (species_export writes
    ;; ASSETS_DIR := EXPORT_DIR). species.json was the first post-dbt target built
    ;; and verified through Stelis beyond occurrences.db (st-h4m); collectors.json
    ;; is the second, via place-marts (st-4cm slice 2); places.json (with its
    ;; siblings places.geojson + place_details.json, all written by one
    ;; places_export invocation) is the third (st-4cm slice 3).
    [(occurrences.db species.json collectors.json
      places.json places.geojson place_details.json
      ;; species-export's four sibling feeds (st-qp7 — see its outputs)
      seasonality.json photos.json species_hosts.json higher_taxa.json)
     (build-path export-dir (~a artifact))]
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
(define beeatlas-db (build-path DATA "beeatlas.duckdb"))

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
    [else #f]))

;; beeatlas-resolve-relation : symbol -> (or/c string #f)
;; A db-relation's content hash (via DuckDB), or #f when it has no mapping or
;; can't be read — the build-env resolve-relation slot for beeatlas.
(define (beeatlas-resolve-relation artifact)
  (define tables (beeatlas-relation-tables artifact))
  (and tables (relation-digest beeatlas-db tables)))

;; py: a uv/3.14 recipe that calls `module.fn()' the way run.py imports it.
(define (py module fn)
  (recipe 'uv (list "-c" (~a "from " module " import " fn "; " fn "()"))))

;; place-marts copies each dbt mart from the sandbox to $EXPORT_DIR (injected by
;; the executor). `set -e' so a missing mart fails the task rather than a partial
;; placement. This is exactly run.py's _run_dbt_build copy loop, split out as its
;; own node (the copy is placement, not the dbt transform).
(define place-marts-script
  (string-append "set -e; for f in " (string-join mart-files " ")
                 "; do cp \"" SANDBOX "/$f\" \"$EXPORT_DIR/$f\"; done"))

;; --- Artifacts --------------------------------------------------------------
;; kinds: 'file  'db-relation (a schema/table in the shared beeatlas.duckdb)
;;        'external (loaded outside the nightly graph)  'token (a gate result)
(define artifacts
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
   (make-artifact 'geographies              'external)
   (make-artifact 'anti-entropy-applied     'token)
   (make-artifact 'checklist-resolution-verified 'token)
   (make-artifact 'resolution-verified      'token)
   (make-artifact 'inactive-verified        'token)
   (make-artifact 'places-validated         'token)
   (make-artifact 'dedup-verified           'token)
   (make-artifact 'occurrences.parquet          'file)
   (make-artifact 'occurrence_places.parquet    'file)
   (make-artifact 'checklist.parquet            'file)
   (make-artifact 'species.parquet              'file)
   (make-artifact 'species_traits.parquet       'file)
   (make-artifact 'higher_taxa.parquet          'file)
   (make-artifact 'counties.geojson             'file)
   (make-artifact 'ecoregions.geojson           'file)
   (make-artifact 'wilderness.geojson           'file)
   (make-artifact 'occurrences.db               'file)
   (make-artifact 'dedup_candidates.csv         'file)
   (make-artifact 'region-topology-clean        'file)
   (make-artifact 'species.json                 'file)
   ;; species_export writes SIX files in one invocation; species.json is the
   ;; headline target but these four are equally real outputs (the edge-verify
   ;; harness, st-qp7, surfaced them as undeclared writes on the slice-1 edge).
   (make-artifact 'seasonality.json             'file)
   (make-artifact 'photos.json                  'file)
   (make-artifact 'species_hosts.json           'file)
   (make-artifact 'higher_taxa.json             'file)
   (make-artifact 'species-maps                 'file)
   (make-artifact 'places.geojson               'file)
   (make-artifact 'places.json                  'file)
   ;; heavy per-place feed (species + collection timing) written by the same
   ;; places_export invocation as places.json; a build_time_fetch sibling (like
   ;; collectors.json), modelled so the node's third output has a producer (st-4cm).
   (make-artifact 'place_details.json           'file)
   (make-artifact 'collectors.json              'file)
   (make-artifact 'collector_event_pages.json   'file)
   ;; notes is beeatlas's one authoritative artifact (data/artifacts.toml) —
   ;; forward-only, never rebuilt from scratch. It's a pruned sibling here, so the
   ;; escape hatch isn't exercised on the occurrences.db path, but the model now
   ;; expresses it (addresses the derived-vs-authoritative commitment).
   (make-artifact 'notes.json                   'file #:provenance 'authoritative)
   (make-artifact 'place-maps                   'file)
   (make-artifact 'feeds                        'file)
   ;; EXPORT_DIR-placed copies of the dbt marts (place-marts output) + the
   ;; enriched species.parquet species-export writes there. Distinct artifacts
   ;; from the sandbox originals so each has exactly one producer.
   (make-artifact 'species.parquet@export       'file)))
(define mart-export-artifacts
  (for/list ([f (in-list mart-files)]) (make-artifact (export-name f) 'file)))

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
                         inat_obs_data canonical_to_taxon_id resolution-verified
                         inactive_remaps inactive-verified
                         taxon_lineage_extended host_plant_lineage geographies_places)
              #:outputs '(occurrences.parquet occurrence_places.parquet
                          checklist.parquet species.parquet species_traits.parquet
                          higher_taxa.parquet counties.geojson ecoregions.geojson
                          wilderness.geojson)
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
              #:inputs (map string->symbol mart-files)
              #:outputs (map export-name mart-files)
              #:invoke (recipe 'sh (list place-marts-script)))

   ;; --- post-dbt siblings (NOT upstream of occurrences.db) ---
   (make-task 'dedup-candidates 'transform
              #:inputs '(checklist.parquet) #:outputs '(dedup_candidates.csv)
              #:invoke (py "checklist_dedup" "write_dedup_candidates"))
   (make-task 'dedup-gate 'gate
              #:inputs '(dedup_candidates.csv) #:outputs '(dedup-verified)
              #:invoke (py "checklist_dedup" "check_dedup_gate"))
   (make-task 'topology-postprocess 'transform
              #:inputs '(counties.geojson ecoregions.geojson wilderness.geojson)
              #:outputs '(region-topology-clean)
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
   (make-task 'species-maps 'transform
              #:inputs '(species.json) #:outputs '(species-maps)
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
   (make-task 'collectors-events-export 'transform
              #:inputs '(collectors.json) #:outputs '(collector_event_pages.json)
              #:invoke (py "collectors_events_export" "export_collectors_events_step"))
   (make-task 'notes-harvest 'transform
              #:inputs '(collectors.json) #:outputs '(notes.json)
              #:invoke (py "notes_harvest" "main"))
   (make-task 'places-maps 'transform
              #:inputs '(places.geojson) #:outputs '(place-maps)
              #:invoke (py "places_maps" "main"))
   (make-task 'feeds 'transform
              #:inputs '(occurrences.parquet species.json) #:outputs '(feeds)
              #:invoke (py "feeds" "main"))))

(define beeatlas-graph (build-graph tasks (append artifacts mart-export-artifacts)))
