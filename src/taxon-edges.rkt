#lang racket/base

;; Edge TYPING (st-an7, ADR 0008 step 2) — the pure core.
;;
;; Characterizations say what a bee IS (taxon-inherit.rkt, inheritable with
;; proofs); edges say what a bee DEPENDS ON (the bee_parasite_hosts and
;; bee_specialist_hosts seeds). Typing an edge attaches its OBLIGATE-ness, with
;; provenance, and its GROUNDING — whether the depended-on thing is in this
;; atlas at all. The at-risk closure (st-6x9) may propagate necessity only
;; through obligate edges (ADR 0008 D4); this module is what makes that rule
;; expressible.
;;
;; The ratified shape (st-an7's design field holds the full argument):
;;
;;   PARASITE edges — the rows don't say "obligate"; CLEPTOPARASITISM does. An
;;   edge types obligate via the bee's inherited nesting characterization, and
;;   its proof is the inheritance chain ("because Nomadinae is cleptoparasitic").
;;   Dependence is grouped per parasite as ONE obligate dependence on the host
;;   SET, any-of — ungrouped, the closure would claim "imperilled because one of
;;   five hosts declined". A parasite no assertion reaches keeps a distinct
;;   SOURCE-level proof ('recorded — "Bee-Gap lists it as a parasite"), today an
;;   empty set (the integration test's 0 uncovered), kept distinct so a future
;;   uncovered lineage degrades honestly instead of borrowing an inheritance it
;;   doesn't have.
;;
;;   FORAGE edges — Fowler & Droege is a SPECIALISTS-ONLY list, so a row's
;;   existence already is the obligate claim; the type makes it explicit with
;;   the source as proof. No generalist forage edges exist, so D4's over-claim
;;   scenario (cuckoo -> generalist host -> every flower it visits) is
;;   structurally impossible: the closure stops at a generalist for lack of an
;;   edge, not by policy. Where the mart's diet_breadth (Bee-Gap-derived)
;;   DISAGREES — 41 species nationally at last count — the edge carries a
;;   'disputed flag rather than failing anything: two respectable sources
;;   disagreeing is editorial content (ADR 0006's flag side), not an operator
;;   alarm, and neither source outranks the other the way expected_upstream
;;   does. A diet_breadth of no value is the same coverage win the nesting
;;   cross-check counts as "gaps filled".
;;
;;   GROUNDING — out-of-atlas hosts are KEPT, marked (D4 of the ratified set):
;;   only 57 of the 456 recorded parasites are on the checklist, and a local
;;   cuckoo can have European recorded hosts. The dependence is real biology
;;   the atlas just can't see; dropping it would make silence look like safety.
;;   Resolution is exact canonical-name matching — Bee-Gap spellings that are
;;   synonyms of checklist names stay unresolved, a recorded limitation.
;;
;; Pure over plain data: edge rows in, typed dependence structs out. IO — the
;; seed CSVs, the marts, the artifact write — lives in taxon-derive.rkt, the
;; same seam split st-ozp used.

(require racket/list
         racket/set
         racket/string
         "taxon-inherit.rkt")

(provide (struct-out host-dependence)
         (struct-out forage-dependence)
         host-dependencies
         forage-dependencies)

;; One parasite's obligate dependence on its recorded host SET.
;;   species     : string — the depending species' canonical_name (in-atlas)
;;   proof       : 'characterized | 'recorded — inheritance chain vs source-only
;;   source-rank : (or/c symbol #f) — the asserting ancestor's rank ('characterized)
;;   source-name : (or/c string #f) — its name ("Nomadinae")
;;   targets     : (listof (cons string boolean)) — (host display name . in-atlas?),
;;                 sorted, deduplicated; the SET the dependence is on
(struct host-dependence (species proof source-rank source-name targets) #:transparent)

;; One specialist's obligate dependence on its recorded plant taxa.
;;   species : string — canonical_name (in-atlas)
;;   beegap  : 'agrees | 'no-value | 'disputed — the mart's diet_breadth beside
;;             Fowler's membership claim (see the module essay; a flag, never a gate)
;;   plants  : (listof (cons (or/c string #f) string)) — (family . detail), the
;;             family #f where Fowler gives only a genus ("Larrea Cav."), sorted
;;             by detail
(struct forage-dependence (species beegap plants) #:transparent)

;; host-dependencies : (listof (cons string string)) hash set-of-string
;;   -> (listof host-dependence)
;; `edges`   — (parasite canonical_name . host display name), one row per record
;; `nesting` — canonical_name -> the species' inherited NESTING fact (built by
;;             the seam from the closure's own output; this is why typing lives
;;             beside the inheritance rather than in dbt)
;; `atlas`   — the set of lowercase checklist canonical_names
;; Only in-atlas parasites produce a dependence: this artifact's key space is
;; the atlas's species pages, and a national-only parasite has no page to
;; ground a claim on. Targets keep their display spelling; grounding compares
;; lowercase.
(define (host-dependencies edges nesting atlas)
  (define by-parasite (make-hash))
  (for ([e (in-list edges)])
    (hash-update! by-parasite (car e) (lambda (v) (cons (cdr e) v)) '()))
  (sort
   (for/list ([(parasite hosts) (in-hash by-parasite)]
              #:when (set-member? atlas parasite))
     (define fact (hash-ref nesting parasite #f))
     (define characterized?
       (and fact (eq? 'cleptoparasitic (inherited-value fact))))
     (host-dependence
      parasite
      (if characterized? 'characterized 'recorded)
      (and characterized? (inherited-source-rank fact))
      (and characterized? (inherited-source-name fact))
      (for/list ([h (in-list (sort (remove-duplicates hosts) string<?))])
        (cons h (set-member? atlas (string-downcase h))))))
   string<? #:key host-dependence-species))

;; forage-dependencies : (listof (list string (or/c string #f) string)) hash
;;                       set-of-string -> (listof forage-dependence)
;; `rows` — (canonical_name family-or-#f detail), one per Fowler record
;; `diet` — canonical_name -> the mart's diet_breadth, lowercase ("" = no value)
;; Membership is the obligate claim; `diet` only names how Bee-Gap's independent
;; column sits beside it.
(define (forage-dependencies rows diet atlas)
  (define by-species (make-hash))
  (for ([r (in-list rows)])
    (hash-update! by-species (first r)
                  (lambda (v) (cons (cons (second r) (third r)) v)) '()))
  (sort
   (for/list ([(sp plants) (in-hash by-species)]
              #:when (set-member? atlas sp))
     (define d (hash-ref diet sp ""))
     (forage-dependence
      sp
      (cond [(string=? d "") 'no-value]
            [(string-ci=? d "specialist") 'agrees]
            [else 'disputed])
      (sort (remove-duplicates plants) string<? #:key cdr)))
   string<? #:key forage-dependence-species))
