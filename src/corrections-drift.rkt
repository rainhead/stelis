#lang racket/base

;; Correction drift detection (st-t4t) — the machine half of the correction
;; overlay, and the reason the overlay is allowed to override a cited source.
;;
;; WHAT A CORRECTION IS (user, 2026-07-25, and it decides the modality below). Not
;; a patch applied to a source: an ASSERTION THAT OUTRANKS one. If a taxonomist
;; says Bombus vosnesenskii is social, that is the claim; Bee-Gap disagreeing is a
;; fact about Bee-Gap. species_traits already encodes exactly that as precedence —
;; correction > beegap-species > genus-backbone.
;;
;; So `expected_upstream` is a CITATION, not a tripwire: it records the claim being
;; overruled, so a reader of the seed can see what was on the other side. This gate
;; reports when that citation stops describing the source — useful, but it is not
;; the thing that makes the correction legitimate. The taxonomist is.
;;
;; WHY THAT DEMOTES MOST OF THE BLOCKING. The generic argument for a blocking gate
;; here is that override tables rot silently — a live feed changes underneath and
;; the override keeps firing unexamined. That argument assumes a LIVE upstream.
;; Both correctable sources are checked-in seeds cut from USGS Bee-Gap 2017
;; (ScienceBase 5bd868b2e4b0b3fc5ce9dadd), a ONE-TIME publication. Their values
;; cannot move except by someone deliberately re-vintaging a seed and committing
;; it — at which point the report lands in a diff, in front of a reviewer, which is
;; a better place to read it than a halted 3am build. Blocking a nightly publish on
;; a door that only opens from the inside guards the wrong side.
;;
;; Hence `current-live-traits` below: the block is keyed to source cadence, and
;; nothing correctable is live today. The machinery stays because the day a live
;; source becomes correctable, the argument comes back exactly as written.
;;
;; DRIFT IS NOT ONE SITUATION (st-kfu). "Upstream stopped matching" covers cases
;; that deserve opposite responses, and a gate that blocks on all of them blocks on
;; its own success — upstream FIXING the record we corrected would take the nightly
;; build down. Worse, an alarm with no proportionate response teaches an operator to
;; re-pin `expected_upstream` until it goes quiet, which is exactly the rot the pin
;; exists to prevent. So the drift is classified, and the class picks the modality:
;;
;;   resolved  — the specific error we corrected is gone: upstream now says what we
;;               corrected it to, or has withdrawn the claim we called wrong. WARN:
;;               the row is dead weight and should be deleted.
;;   orphaned  — upstream has no row for this key AT ALL, so the correction matches
;;               nothing and already drops out of the mart. WARN.
;;   contested — upstream moved to some THIRD value, which nobody has judged. WARN
;;               for a frozen source (the move was a reviewed commit); BLOCK for a
;;               live one, where it arrived unattended.
;;   unchecked — the correction names a trait this gate has no upstream arm for, so
;;               it is not being verified at all. BLOCK ALWAYS: this is not a claim
;;               about upstream, it is our own coverage silently lapsing, and the
;;               seed then LOOKS guarded while one row is not.
;;
;; The asymmetry that makes this more than cosmetic: an empty upstream value is not
;; one fact. Under a `retract` it may be upstream withdrawing the very assertion we
;; objected to — the outcome we wanted — but it is ALSO what a mistyped key looks
;; like, and there the advice "upstream agrees, delete the row" is actively wrong:
;; the real species would go on publishing the error. So the two are separated by
;; whether upstream knows the KEY at all, not by whether it supplies the value.
;;
;; The split follows what was agreed for st-t4t: beeatlas owns the FIX (a dbt seed
;; and a precedence arm — a per-record override is a bounded join and by ADR
;; 0008's standing gate earns no substrate), Stelis owns the REPORT.
;;
;; It stays a Stelis node rather than a dbt seed test (user, 2026-07-25) even though
;; a frozen seed only changes at commit time: the coverage check is about THIS
;; module's arms, and the live-source case it is built for is a build-time concern.
;;
;; Reads both CSVs through the shared DuckDB CLI rather than hand-parsing: the
;; seeds are quoted CSV with commas and em-dashes inside the reason prose, and a
;; naive split would mis-parse exactly the rows that matter.

(require racket/list
         racket/string
         racket/format
         "duckdb.rkt"
         "exec.rkt")   ; check-context accessors — the rule-node interface

(provide (struct-out drift)
         known-trait?
         current-live-traits
         trait-cadence
         read-drift-rows
         drift-class
         drift-blocking?
         drift-verdict
         make-corrections-drift-check)

;; One correction whose upstream value no longer matches what it was written for.
;;   key       : string  — the corrected record (a canonical_name here)
;;   trait     : string  — which column it corrects
;;   action    : string  — "replace" | "retract"; the class depends on which
;;   expected  : string  — what upstream said when the correction was written
;;   corrected : string  — what we publish instead ("" for a retraction)
;;   actual    : string  — what upstream says now ("" when it supplies no value)
;;   key-known : boolean — does upstream have ANY row for this key? Separates
;;               "upstream dropped the claim" from "this correction names nothing",
;;               which `actual` alone cannot: both read as empty, and they call for
;;               opposite maintenance.
(struct drift (key trait action expected corrected actual key-known) #:transparent)

;; The traits this gate knows how to read out of the upstream seeds. Every
;; species-level trait is one column of the Bee-Gap seed; `host_bees` is an
;; AGGREGATE over a second seed and so gets its own arm below.
;;
;; This list is the gate's coverage, and `unchecked` is what happens outside it —
;; so adding a correctable trait is one entry here plus (for a non-Bee-Gap source)
;; one arm, rather than a silent hole. ADR 0009 records the matching beeatlas-side
;; cost; the failure this guards against is the seed *looking* guarded.
(define beegap-traits '("nesting" "sociality" "native" "foraging"))
(define aggregate-traits '("host_bees"))

;; known-trait? : string -> boolean
(define (known-trait? t)
  (and (or (member t beegap-traits) (member t aggregate-traits)) #t))

;; Which correctable traits come from a source that can change WITHOUT anyone here
;; deciding it should. Empty today, and that is a fact about the sources rather
;; than an omission: every correctable trait is read from a checked-in seed cut
;; from the one-time Bee-Gap 2017 publication, so a value can only move by a
;; reviewed commit.
;;
;; A parameter rather than a constant so the live-source behaviour is exercisable
;; in tests before a live source exists — the branch that blocks should not be the
;; branch nothing has ever run.
(define current-live-traits (make-parameter '()))

;; trait-cadence : string -> (or/c 'live 'frozen)
(define (trait-cadence t)
  (if (member t (current-live-traits)) 'live 'frozen))

;; read-drift-rows : path-string path-string path-string -> (or/c (listof drift) #f)
;; Every correction that no longer agrees with the upstream seed, or that this gate
;; cannot check at all. #f — not an empty list — when either file cannot be read, so
;; the caller can tell "nothing has drifted" from "the check could not run".
;;
;; The LEFT JOIN is what catches the case the SQL side cannot: a correction naming
;; a species with no upstream row at all yields actual = "", which disagrees with
;; any non-empty expectation. Such a correction silently drops out of
;; species_traits (nothing to override), so without this it would be invisible.
;;
;; An unknown trait is reported even when its expectation happens to compare equal:
;; there, "equal" only means both sides are empty, which is the gate agreeing with
;; itself about a column it never read.
(define (read-drift-rows corrections-path beegap-path parasites-path)
  ;; One `upstream' relation of (key, trait, value), unioned from every source a
  ;; correction may target — so the comparison is uniform and adding a source is
  ;; one more arm rather than another special case. A trait no arm supplies reads
  ;; as "" and is classified `unchecked': the gate must never vouch for a
  ;; correction it cannot actually compare.
  ;;
  ;; The host_bees arm aggregates exactly as species_traits.sql's `parasite' CTE
  ;; does (STRING_AGG DISTINCT, comma-space, ordered), so `expected_upstream' can
  ;; be written as the value a curator actually sees in the mart. It does NOT
  ;; route the key through int_synonyms as the mart does; a correction is authored
  ;; against the atlas name, and a synonym-only match would surface here as drift
  ;; rather than pass silently.
  ;; The Bee-Gap arms differ only in which column they project, so they are
  ;; generated from `beegap-traits' — one list drives both the SQL and the coverage
  ;; test, and the two cannot fall out of step.
  (define beegap-arms
    (for/list ([t (in-list beegap-traits)])
      (string-append " SELECT canonical_name AS k, '" t "' AS t, " t " AS v"
                     " FROM read_csv_auto('" (~a beegap-path) "')")))
  (define sql
    (string-append
     "WITH upstream AS ("
     (string-join beegap-arms " UNION ALL ")
     "  UNION ALL SELECT parasite, 'host_bees',"
     "      STRING_AGG(DISTINCT host_taxon, ', ' ORDER BY host_taxon)"
     "    FROM read_csv_auto('" (~a parasites-path) "') GROUP BY parasite"
     ")"
     ;; The second join answers "does upstream know this species at all", across
     ;; every source — deliberately not per-source, since a correction naming a
     ;; species no source has ever heard of is the case worth calling out, and a
     ;; species present in one seed but absent from another is ordinary.
     " SELECT c.canonical_name, c.trait, coalesce(c.action,''),"
     "        coalesce(c.expected_upstream,''), coalesce(c.corrected_value,''),"
     "        coalesce(u.v,''),"
     "        CASE WHEN uk.k IS NULL THEN '0' ELSE '1' END"
     " FROM read_csv_auto('" (~a corrections-path) "') c"
     " LEFT JOIN upstream u ON u.k = c.canonical_name AND u.t = c.trait"
     " LEFT JOIN (SELECT DISTINCT k FROM upstream) uk ON uk.k = c.canonical_name"
     " ORDER BY c.canonical_name, c.trait"))
  (define out (duckdb-query #f sql))
  (and out
       (for*/list ([line (in-list (string-split out "\n"))]
                   [tup (in-value (string-split line "|" #:trim? #f))]
                   #:when (and (= 7 (length tup)) (not (string=? (first tup) "")))
                   [d (in-value (drift (first tup) (second tup) (third tup)
                                       (fourth tup) (fifth tup) (sixth tup)
                                       (string=? (seventh tup) "1")))]
                   #:unless (and (string=? (drift-expected d) (drift-actual d))
                                 (known-trait? (drift-trait d))))
         d)))

;; drift-class : drift -> (or/c 'resolved 'orphaned 'contested 'unchecked)
;; Which of the four situations this row is in. Pure, and the only place the
;; replace/retract asymmetry is interpreted.
;;
;; `unchecked' is tested FIRST: if the gate has no arm for the trait, `actual' is
;; the absence of a reading rather than a reading of an absence, and every other
;; branch would be drawing a conclusion from it.
;;
;; An unrecognized ACTION also lands as contested. The dbt seed contract already
;; restricts it, so this is the belt to that suspenders — and guessing on behalf of
;; a correction whose intent we cannot read is the wrong direction to be wrong in.
(define (drift-class d)
  (define actual-empty? (string=? (drift-actual d) ""))
  (cond
    [(not (known-trait? (drift-trait d))) 'unchecked]
    ;; Before reading the value: a key upstream has never heard of makes every
    ;; reading of that value vacuous, and points at the correction's key rather
    ;; than at upstream.
    [(not (drift-key-known d)) 'orphaned]
    ;; A retraction says "this assertion is wrong" and supplies no replacement. So
    ;; upstream withdrawing the assertion IS upstream agreeing with us; upstream
    ;; asserting something ELSE is a new claim nobody has judged.
    [(string=? (drift-action d) "retract")
     (if actual-empty? 'resolved 'contested)]
    [(string=? (drift-action d) "replace")
     (cond
       [(and (not (string=? (drift-corrected d) ""))
             (string=? (drift-actual d) (drift-corrected d)))
        'resolved]
       ;; Upstream still knows the species but no longer makes the claim we called
       ;; wrong. The error is gone, so this is resolved rather than contested —
       ;; though what remains is an addition, not a correction, which is why the
       ;; advisory text offers keeping it as a distinct option.
       [actual-empty? 'resolved]
       [else 'contested])]
    [else 'contested]))

;; drift-blocking? : drift -> boolean
;; Blocking is reserved for what a build can still prevent.
;;
;; `unchecked` always blocks: the correction is unverified, and unlike every other
;; class that is a defect in THIS module, not news about a source.
;;
;; `contested` blocks only against a LIVE source. Against a frozen one the value
;; moved because someone re-vintaged a seed and committed it — the report belongs
;; in that diff, and halting the nightly adds nothing except pressure to re-pin
;; `expected_upstream` until it goes quiet, which would turn the citation into a
;; rubber stamp.
;;
;; `resolved` and `orphaned` never block: dead weight is untidy, not dangerous, and
;; blocking on `resolved` would stop the build over the correction having worked.
(define (drift-blocking? d)
  (case (drift-class d)
    [(unchecked) #t]
    [(contested) (eq? 'live (trait-cadence (drift-trait d)))]
    [else #f]))

;; describe : drift -> string
;; One row, phrased as the maintenance it implies rather than as a diff. Whoever
;; reads this is deciding what to do about a correction, not admiring the delta.
(define (describe d)
  (define where (format "~a.~a" (drift-key d) (drift-trait d)))
  (case (drift-class d)
    [(resolved)
     (cond
       [(string=? (drift-action d) "retract")
        (format "~a: upstream has withdrawn the assertion this correction retracted — delete the row" where)]
       [(string=? (drift-actual d) "")
        (format "~a: upstream no longer claims anything here (was ~s) — delete the row, or keep ~s as an addition rather than a correction"
                where (drift-expected d) (drift-corrected d))]
       [else
        (format "~a: upstream now says ~s itself — delete the row" where (drift-corrected d))])]
    [(orphaned)
     (format "~a: upstream has no record of this species (the correction expected ~s) — check the name for a typo before deleting; if it is wrong, the species you meant is still publishing the error"
             where (drift-expected d))]
    [(contested)
     ;; Deliberately does NOT lead with "update expected_upstream". The citation is
     ;; the cheapest thing to change and the least likely to be the right change;
     ;; whether the assertion still holds is the actual question.
     (format "~a: cited ~s, the seed now says ~s — does the assertion still hold? Then keep it (re-citing), or drop it"
             where (drift-expected d)
             (if (string=? (drift-actual d) "") "<no row>" (drift-actual d)))]
    [(unchecked)
     (format "~a: this gate has no upstream arm for trait ~s, so the correction is NOT being verified — add one in corrections-drift.rkt"
             where (drift-trait d))]))

;; summarize : (listof drift) -> string
;; Caps the enumeration but never hides the count: a silently truncated list reads
;; as "that's all of them".
(define (summarize ds)
  (define shown (take ds (min 5 (length ds))))
  (string-join
   (append (map describe shown)
           (if (> (length ds) (length shown))
               (list (format "…and ~a more" (- (length ds) (length shown))))
               '()))
   "; "))

;; drift-verdict : (or/c (listof drift) #f) -> (values boolean string)
;; The pure rule. PASS when nothing drifted, and pass WITH A WARNING when the
;; check could not run at all (#f) — the codebase's standing choice for an
;; unreadable between-tasks read (duckdb.rkt's #f-on-absence, the integrity
;; gate's unreadable-count arm): degrade rather than halt a pipeline on what is
;; almost always missing infrastructure.
;;
;; Otherwise `drift-blocking?` decides (st-kfu), and today almost nothing does —
;; the sources are frozen, so what this mostly produces is a report a maintainer
;; reads rather than a wall a build hits. A blocking verdict still enumerates the
;; advisory rows: the person handling the blocker is the one best placed to clear
;; the rest, and the alternative is discovering them one build at a time.
;;
;; "want attention" rather than "no longer needed": the advisory set mixes rows
;; that are dead weight with rows that need a judgement call, and flattening that
;; into "delete these" would be advice the reader should not take.
(define (drift-verdict rows)
  (cond
    [(not rows)
     (values #t "corrections: seeds unreadable — drift NOT checked")]
    [(null? rows)
     (values #t "corrections: every correction still matches its upstream value")]
    [else
     (define-values (blocking advisory) (partition drift-blocking? rows))
     (define advisory-note
       (if (null? advisory)
           ""
           (format " ~a want~a attention (not blocking): ~a."
                   (length advisory) (if (= 1 (length advisory)) "s" "")
                   (summarize advisory))))
     (cond
       [(null? blocking)
        (values #t (format "corrections:~a" advisory-note))]
       [else
        (values #f
                (format "UNVERIFIED CORRECTION~a: ~a.~a"
                        (if (= 1 (length blocking)) "" "S")
                        (summarize blocking)
                        advisory-note))])]))

;; make-corrections-drift-check : path-string path-string path-string
;;                                -> (check-context -> (values boolean string))
;; The `rule-check` body, given the seed paths. Reads at gate time, not at
;; graph-authoring time, so a seed edited between builds is seen.
(define (make-corrections-drift-check corrections-path beegap-path parasites-path)
  (lambda (_ctx)
    (drift-verdict (read-drift-rows corrections-path beegap-path parasites-path))))
