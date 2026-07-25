;; Taxon trait assertions (st-ozp) — curated domain facts, checked in.
;;
;; Each clause asserts that a trait holds for a taxon AND EVERYTHING BELOW IT.
;; One line here characterizes a whole subtree: "Nomadinae" reaches 52 species on
;; the beeatlas checklist across 4 tribes and 5 genera. That leverage is the point
;; — ADR 0008 accepted taxon reasoning as the value prop precisely because sparse
;; high-rank knowledge fills per-species gaps that no per-species source has.
;;
;; TWO SECTIONS, and the split matters:
;;
;;   (glossary (value "definition"))
;;     What a trait value MEANS, said ONCE. Every species carrying the value
;;     shares this text, so the site renders it once per page rather than
;;     repeating it per species.
;;
;;   (traits (rank "Name" (trait value (hosts "…") (note "…"))))
;;     What is SPECIFIC to this lineage. `hosts` is the substance for a parasite:
;;     what it attacks is exactly what differs between Nomadinae and Psithyrus and
;;     Stelis. `note` is optional and should usually be absent — reserve it for
;;     something genuinely particular to this lineage, not for re-teaching the
;;     term. (The first draft of this file put a full definition of cuckoo-ness in
;;     every clause; a reader visiting two cuckoo pages met the same paragraph
;;     twice, while the hosts — the interesting part — were buried inside it.)
;;
;;   rank — one of: family subfamily tribe genus subgenus species
;;
;; Every asserted value MUST have a glossary entry; the parser refuses the file
;; otherwise, since a value with no definition publishes a bare word.
;;
;; Each assertion sits at the HIGHEST rank verified wholly cleptoparasitic against
;; the data, not assumed: Melectini and Dioxyini are parasitic as entire tribes,
;; while Sphecodes and Coelioxys stop at genus because their tribes also hold
;; ordinary pollen-collecting bees (Lasioglossum beside Sphecodes, Megachile
;; beside Coelioxys).
;;
;; Vocabulary is Stelis's own (lowercase, unabbreviated), deliberately NOT the
;; Bee-Gap spelling in species_traits.nesting ("Host Nest"). The two stay separate
;; published fields; the derivation reports how well they agree, and the site
;; decides how to merge them.
;;
;; Editing this file re-runs the reasoning node: it is an input ARTIFACT of the
;; graph, content-addressed like any other data. Its forward-only store is git.

(taxon-traits

 (glossary
   (cleptoparasitic
     "A cleptoparasite — a \"cuckoo bee\" — builds no nest and gathers no pollen of its own. The female enters another bee's nest and lays her egg in a cell already stocked with provisions; her larva destroys the host's egg or grub and eats the store left for it. Cuckoos are usually sparsely haired and wasp-like, having no need of a pollen-carrying brush."))

 (traits

  (subfamily "Nomadinae"
    (nesting cleptoparasitic
      (hosts "ground-nesting bees, chiefly Andrena, with Agapostemon, Lasioglossum, Melitta and Colletes among the recorded hosts")))

  (subgenus "Psithyrus"
    (nesting cleptoparasitic
      (hosts "other bumble bees")
      ;; Genuinely particular: this is social parasitism, not simply cell
      ;; robbery — the only lineage here that subverts a colony rather than a cell.
      (note "Alone among these lineages the cuckoo bumble bees parasitize a whole colony rather than a single cell: the female has no worker caste of her own, so she kills or subdues the host queen and leaves the host's workers to raise her offspring.")))

  ;; The genus this build system is named for — and, like the others, a cuckoo.
  (genus "Stelis"
    (nesting cleptoparasitic
      (hosts "mason and leafcutter bees, especially Osmia, Anthidium, Heriades and Megachile")))

  (tribe "Melectini"
    (nesting cleptoparasitic
      (hosts "digger bees — Anthophora and Habropoda")
      (note "The newly hatched larva is equipped with long sickle-shaped jaws it uses to kill the host's egg, and which it later moults away.")))

  (tribe "Dioxyini"
    (nesting cleptoparasitic
      (hosts "mason, leafcutter and carder bees — Osmia, Megachile and Anthidium")))

  (genus "Sphecodes"
    (nesting cleptoparasitic
      (hosts "sweat bees, chiefly Lasioglossum and Halictus, and some Andrena")
      (note "Known as blood bees for the red abdomen most species carry. Unusually, the female often destroys the host's egg herself rather than leaving the work to her larva.")))

  (genus "Coelioxys"
    (nesting cleptoparasitic
      (hosts "leafcutter bees, chiefly Megachile")
      (note "The female's sharply pointed abdomen — the source of the name sharp-tailed bee — lets her pierce the wall of a host's closed leafy cell to lay inside it.")))))
