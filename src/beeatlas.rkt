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

(require "model.rkt")

(provide beeatlas-graph)

;; --- Artifacts --------------------------------------------------------------
;; kinds: 'file  'db-relation (a schema/table in the shared beeatlas.duckdb)
;;        'external (loaded outside the nightly graph)  'token (a gate result)
(define artifacts
  (list
   ;; raw / ingestion
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
   ;; geographies boundaries are loaded MANUALLY (excluded from the nightly run,
   ;; per run.py) — modelled as an external leaf dbt/places read but no graph
   ;; task produces.
   (make-artifact 'geographies              'external)
   ;; reconciliation + gate tokens
   (make-artifact 'anti-entropy-applied     'token)
   (make-artifact 'checklist-resolution-verified 'token)
   (make-artifact 'resolution-verified      'token)
   (make-artifact 'inactive-verified        'token)
   (make-artifact 'places-validated         'token)
   (make-artifact 'dedup-verified           'token)
   ;; dbt outputs (parquet + geojson materializations)
   (make-artifact 'occurrences.parquet          'file)
   (make-artifact 'occurrence_places.parquet    'file)
   (make-artifact 'checklist.parquet            'file)
   (make-artifact 'species.parquet              'file)
   (make-artifact 'species_traits.parquet       'file)
   (make-artifact 'higher_taxa.parquet          'file)
   (make-artifact 'counties.geojson             'file)
   (make-artifact 'ecoregions.geojson           'file)
   (make-artifact 'wilderness.geojson           'file)
   ;; the target
   (make-artifact 'occurrences.db               'file)
   ;; post-dbt outputs (siblings)
   (make-artifact 'dedup_candidates.csv         'file)
   (make-artifact 'region-topology-clean        'file)
   (make-artifact 'species.json                 'file)
   (make-artifact 'species-maps                 'file)
   (make-artifact 'places.geojson               'file)
   (make-artifact 'places.json                  'file)
   (make-artifact 'collectors.json              'file)
   (make-artifact 'collector_event_pages.json   'file)
   (make-artifact 'notes.json                   'file)
   (make-artifact 'place-maps                   'file)
   (make-artifact 'feeds                        'file)))

;; --- Tasks (the 32 run.py STEPS, in list order) -----------------------------
(define tasks
  (list
   ;; --- ingestion boundary ---
   (make-task 'taxa-download 'boundary #:outputs '(taxa.csv.gz))
   (make-task 'ecdysis 'boundary #:outputs '(ecdysis_data))
   ;; ecdysis-links loads occurrence_links, keyed off already-loaded ecdysis.
   (make-task 'ecdysis-links 'boundary #:inputs '(ecdysis_data) #:outputs '(ecdysis_links))
   (make-task 'inaturalist 'boundary #:outputs '(inat_observations))
   (make-task 'waba 'boundary #:outputs '(waba_data))
   ;; projects: iNat project membership; loaded against the observation set. COARSE input.
   (make-task 'projects 'boundary #:inputs '(inat_observations) #:outputs '(inat_projects))
   ;; anti-entropy: reconciles the loaded occurrence sets before dbt reads them.
   ;; COARSE: modelled as a token dbt-build waits on.
   (make-task 'anti-entropy 'transform
              #:inputs '(ecdysis_data inat_observations waba_data)
              #:outputs '(anti-entropy-applied))
   (make-task 'checklist 'boundary #:outputs '(checklist_raw))
   (make-task 'resolve-checklist-names 'transform
              #:inputs '(checklist_raw) #:outputs '(checklist_resolved))
   (make-task 'checklist-resolution-gate 'gate
              #:inputs '(checklist_resolved) #:outputs '(checklist-resolution-verified))
   (make-task 'inat-obs 'boundary #:outputs '(inat_obs_data))
   (make-task 'resolve-taxon-ids 'transform
              #:inputs '(inat_observations taxa.csv.gz) #:outputs '(canonical_to_taxon_id))
   (make-task 'resolution-gate 'gate
              #:inputs '(canonical_to_taxon_id) #:outputs '(resolution-verified))
   (make-task 'inactive-remap 'transform
              #:inputs '(canonical_to_taxon_id) #:outputs '(inactive_remaps))
   (make-task 'inactive-gate 'gate
              #:inputs '(inactive_remaps) #:outputs '(inactive-verified))
   (make-task 'taxon-lineage-extended 'transform
              #:inputs '(taxa.csv.gz) #:outputs '(taxon_lineage_extended))
   ;; host-plant-lineage: plant taxonomy. COARSE input.
   (make-task 'host-plant-lineage 'transform
              #:inputs '(taxa.csv.gz) #:outputs '(host_plant_lineage))
   (make-task 'places-validation 'gate
              #:inputs '(geographies) #:outputs '(places-validated))
   (make-task 'places-load 'transform
              #:inputs '(places-validated geographies) #:outputs '(geographies_places))

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
                          wilderness.geojson))

   ;; --- the target producer ---
   (make-task 'generate-sqlite 'transform
              #:inputs '(occurrences.parquet taxa.csv.gz) #:outputs '(occurrences.db))

   ;; --- post-dbt siblings (NOT upstream of occurrences.db) ---
   (make-task 'dedup-candidates 'transform
              #:inputs '(checklist.parquet) #:outputs '(dedup_candidates.csv))
   (make-task 'dedup-gate 'gate
              #:inputs '(dedup_candidates.csv) #:outputs '(dedup-verified))
   (make-task 'topology-postprocess 'transform
              #:inputs '(counties.geojson ecoregions.geojson wilderness.geojson)
              #:outputs '(region-topology-clean))
   (make-task 'species-export 'transform
              #:inputs '(species.parquet species_traits.parquet higher_taxa.parquet)
              #:outputs '(species.json))
   (make-task 'species-maps 'transform
              #:inputs '(species.json) #:outputs '(species-maps))
   (make-task 'places-export 'transform
              #:inputs '(occurrence_places.parquet geographies_places)
              #:outputs '(places.geojson places.json))
   (make-task 'collectors-export 'transform
              #:inputs '(occurrences.parquet) #:outputs '(collectors.json))
   (make-task 'collectors-events-export 'transform
              #:inputs '(collectors.json) #:outputs '(collector_event_pages.json))
   ;; notes-harvest: read-only harvest keyed off collectors.json's login set.
   (make-task 'notes-harvest 'transform
              #:inputs '(collectors.json) #:outputs '(notes.json))
   (make-task 'places-maps 'transform
              #:inputs '(places.geojson) #:outputs '(place-maps))
   (make-task 'feeds 'transform
              #:inputs '(occurrences.parquet species.json) #:outputs '(feeds))))

(define beeatlas-graph (build-graph tasks artifacts))
