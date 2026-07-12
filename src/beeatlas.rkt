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
        'dbt (runtime 'dbt (list "bash" (string-append DATA "/dbt/run.sh")) "uvx/3.13")))

;; Where beeatlas's file artifacts physically live — the resolver caching uses to
;; content-hash inputs and to place/verify outputs. #f for artifacts with no known
;; single file (duckdb relations, tokens, externals): those aren't content-hashed
;; in Horizon 0. Outputs land under the build's export-dir (explicit destination).
(define SANDBOX (string-append DATA "/dbt/target/sandbox"))
(define (beeatlas-path artifact export-dir)
  (case artifact
    [(occurrences.parquet occurrence_places.parquet checklist.parquet
      species.parquet species_traits.parquet higher_taxa.parquet)
     (build-path SANDBOX (~a artifact))]
    [(taxa.csv.gz)   (build-path DATA "raw" "taxa.csv.gz")]
    [(occurrences.db) (build-path export-dir "occurrences.db")]
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
   (make-artifact 'species-maps                 'file)
   (make-artifact 'places.geojson               'file)
   (make-artifact 'places.json                  'file)
   (make-artifact 'collectors.json              'file)
   (make-artifact 'collector_event_pages.json   'file)
   ;; notes is beeatlas's one authoritative artifact (data/artifacts.toml) —
   ;; forward-only, never rebuilt from scratch. It's a pruned sibling here, so the
   ;; escape hatch isn't exercised on the occurrences.db path, but the model now
   ;; expresses it (addresses the derived-vs-authoritative commitment).
   (make-artifact 'notes.json                   'file #:provenance 'authoritative)
   (make-artifact 'place-maps                   'file)
   (make-artifact 'feeds                        'file)))

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
              ;; Recipe is `run.sh build' only. run.py's _run_dbt_build ALSO copies
              ;; six parquets to EXPORT_DIR; omitted deliberately — a downstream
              ;; artifact-placement concern not needed for occurrences.db, since
              ;; generate-sqlite reads occurrences.parquet from the dbt sandbox
              ;; directly. Revisit under st-d44.4 (explicit output destinations).
              #:invoke (recipe 'dbt (list "build")))

   ;; --- the target producer (has a __main__; run as a script) ---
   (make-task 'generate-sqlite 'transform
              #:inputs '(occurrences.parquet taxa.csv.gz) #:outputs '(occurrences.db)
              #:invoke (recipe 'uv (list "sqlite_export.py")))

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
   (make-task 'species-export 'transform
              #:inputs '(species.parquet species_traits.parquet higher_taxa.parquet)
              #:outputs '(species.json)
              #:invoke (py "species_export" "main"))
   (make-task 'species-maps 'transform
              #:inputs '(species.json) #:outputs '(species-maps)
              #:invoke (py "species_maps" "main"))
   (make-task 'places-export 'transform
              #:inputs '(occurrence_places.parquet geographies_places)
              #:outputs '(places.geojson places.json)
              #:invoke (py "places_export" "export_places_step"))
   (make-task 'collectors-export 'transform
              #:inputs '(occurrences.parquet) #:outputs '(collectors.json)
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

(define beeatlas-graph (build-graph tasks artifacts))
