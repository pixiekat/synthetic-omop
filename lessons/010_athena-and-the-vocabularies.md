# Lesson 010: Athena and the OMOP Standardized Vocabularies, a Deep Dive

| | |
|---|---|
| **Course level** | Second to third year undergraduate (health informatics / data engineering) |
| **Estimated time** | 2 × 90-minute lectures + 3-hour lab |
| **Prerequisites** | Lesson 003 (concepts, standard vs non-standard, `Maps to`, `concept_ancestor`, deprecation); Lesson 004 section 3 (Athena bundles); Lesson 009 (window functions); recursive SQL helps |
| **Project files** | The `cdm` vocabulary tables; `data/vocab/athena/`; `athena-extras/`; `docs/run-log.md`; `docs/assumptions.md` |
| **Previous lesson** | 009: From Synthea to the CDM, the ETL Internals |

> **How this lesson relates to 003 and 004.** Lesson 003 taught you to *use* the vocabulary:
> look up a concept, follow `Maps to`, walk a hierarchy. Lesson 004 showed that the bundle you
> download changes what you get. This lesson treats the vocabularies as an **engineered product**:
> how it's built and released, how its tables fit together, what its design decisions are, where
> it breaks, and how you extend it with your own codes.

## Learning objectives

By the end of this lesson you should be able to:

1. Explain what Athena is, and how the Standardized Vocabularies are **built, versioned and released**.
2. Draw the vocabulary **data model**, including the tables that describe the vocabulary itself.
3. Explain how **standard concepts** are chosen per domain, and why there is one per meaning.
4. Classify mappings (one-to-one, one-to-many, `Maps to value`) and explain how each shows up in CDM rows.
5. Explain `concept_ancestor` as a **transitive closure**, and rebuild part of it with a recursive query.
6. Assess the impact of a **vocabulary upgrade** on an existing database, and plan for it.
7. Describe the **licensing** model and its practical consequences.
8. Choose between `source_to_concept_map` and **2-billion custom concepts** for local codes.

---

## Lecture 1: The product and its data model

### 1. Athena is a front door; the vocabularies are the product

Three different things share the name "Athena" in conversation:

| Thing | What it is |
|---|---|
| **The Standardized Vocabularies** | The data: concepts, relationships and hierarchies from many source vocabularies (SNOMED, RxNorm, LOINC, ICD-10-CM, CVX …), merged into one model |
| **The build process** | OHDSI's vocabulary team runs a build (the `OHDSI/Vocabulary-v5.0` repository, written mostly in PL/pgSQL) that ingests each source and produces the merged tables |
| **Athena** (<https://athena.ohdsi.org>) | The website where you **search** concepts and **download** bundles |

So when a mapping is wrong, the fix isn't "in Athena". It's in the build, and it reaches you
in a later **release**.

### 2. Releases: how the product changes

| Fact | Detail |
|---|---|
| **Cadence** | Planned releases twice a year, **February** and **August**, aligned with the release schedules of the source vocabularies |
| **Naming** | By date, not major.minor. Your database reports `v5.0 29-AUG-26` (the `vocabulary_version` of the `None` row in `VOCABULARY.csv`); GitHub tags look like `v20260227` |
| **Release notes** | Each release lists domain changes, new concepts by vocabulary and domain, and standard-concept changes |
| **Our release** | August 2026. It added two new rare-disease vocabularies, ORPHAcode and Mondo |
| **History** | Prior versions are **not publicly available** to download |

The last row is the important one for this project:

> **Your downloaded zip is the only copy of your exact vocabulary.** Athena won't give you the
> August 2026 release again once newer ones exist. That's why the project keeps the bundle
> outside the repository (it's large and licensed) but **does** keep it, with its checksum in
> the run log. Reproducing pilot-0001 next year depends on that file.

### 3. The data model

An Athena bundle is ten tables. (The CDM has one more vocabulary table, `source_to_concept_map`,
which Athena doesn't ship because it holds *your* local mappings; see section 10.) Arrows point
from a foreign key to the table it references:

```
                        ┌───────────────┐
                        │  VOCABULARY   │──┐
                        └───────────────┘  │
 ┌───────────────┐      ┌───────────────┐  │      ┌────────────────────┐
 │    DOMAIN     │◀─────│    CONCEPT    │◀─┼──────│  CONCEPT_SYNONYM   │
 └───────────────┘      │ concept_id PK │  │      └────────────────────┘
 ┌───────────────┐      │ vocabulary_id │──┘
 │ CONCEPT_CLASS │◀─────│ domain_id     │
 └───────────────┘      │ class_id      │◀──────┬──────────────┬─────────────┐
                        └───────────────┘       │              │             │
                         ▲            ▲         │              │             │
     ┌───────────────────┴──┐   ┌─────┴─────────┴─────┐  ┌─────┴──────┐ ┌────┴─────────┐
     │ CONCEPT_RELATIONSHIP │   │  CONCEPT_ANCESTOR   │  │DRUG_STRENGTH│ │ PACK_CONTENT │
     │ id_1, id_2, rel_id   │   │ ancestor, descendant│  └────────────┘ └──────────────┘
     └──────────┬───────────┘   │ min/max levels      │
                ▼               └─────────────────────┘
        ┌──────────────┐
        │ RELATIONSHIP │  is_hierarchical, defines_ancestry, reverse_relationship_id
        └──────────────┘
```

Things worth knowing at this level:

| Table | Key design point |
|---|---|
| `concept` | One row per code per vocabulary. `concept_id` is a **surrogate key** (meaningless integer, unique across everything); `concept_code` is the **natural key**, unique only within its vocabulary. `valid_start_date`/`valid_end_date`/`invalid_reason` give each concept a **lifecycle** |
| `concept_relationship` | Stored in **both directions**: if A `Maps to` B, there's also B `Mapped from` A. Relationships have their own validity dates |
| `relationship` | Metadata about each relationship type: is it hierarchical, does it **define ancestry** (i.e. feed `concept_ancestor`), and what's its reverse |
| `concept_ancestor` | **Derived** (section 7), not curated by hand |
| `drug_strength` | How much of each ingredient a drug contains: an amount, or a numerator/denominator with units. Needed for dose calculations |
| `vocabulary`, `domain`, `concept_class` | Each row also points to a **concept** that represents it (`vocabulary_concept_id`, …) |

That last point is elegant: **the vocabulary describes itself**. "SNOMED", "Condition" and
"Clinical Finding" are all concepts too. One mechanism (concepts and relationships) is used
for clinical meaning *and* for the model's own metadata.

### 4. Standard concepts: one meaning, one representative

The central design decision: for each clinical meaning, exactly one concept is **standard**
(`standard_concept = 'S'`), and only standard concepts go in `*_concept_id` fields. Each domain
has preferred source vocabularies for its standard concepts:

| Domain | Standard concepts mostly from |
|---|---|
| Condition | SNOMED |
| Drug | RxNorm, RxNorm Extension |
| Measurement | LOINC (plus SNOMED) |
| Procedure | SNOMED, CPT4, HCPCS, ICD-10-PCS |
| Unit | UCUM |
| Race, Ethnicity, Gender | OMB-based Race/Ethnicity vocabularies, Gender |
| Visit, Type concepts | OMOP's own `Visit` and `Type Concept` vocabularies |

| `standard_concept` | Meaning | In clinical data? | In hierarchies? |
|---|---|---|---|
| `S` | Standard | Yes, in `*_concept_id` | Yes |
| `C` | Classification (e.g. ATC drug classes) | **Never** | Yes, as **ancestors** |
| null | Non-standard (e.g. ICD-10-CM, CVX codes that map elsewhere) | Only in `*_source_concept_id` | No |

**Why one per meaning?** Because the alternative is every analysis listing every coding
system's codes for the same idea. With one standard concept, an ICD-10-CM diagnosis from one
hospital and a SNOMED diagnosis from another land on the **same** `condition_concept_id`, so
one query works for both.

**The cost:** someone has to decide which concept is the standard one, and map everything else
to it. That curation is most of the vocabulary team's work, and it's where errors come from.

### 5. Mapping patterns

`Maps to` isn't always one arrow to one concept:

| Pattern | Example | Result in the CDM |
|---|---|---|
| **One-to-one** | A non-standard code maps to one standard concept | One row |
| **One-to-many** | One ICD-10-CM code meaning "X *with* Y" maps to two SNOMED concepts | **Two rows** from one source record |
| **Many-to-one** | Several codes, in several vocabularies, map to one standard concept | Different sources, same `*_concept_id` |
| **`Maps to` + `Maps to value`** | A code that combines a question and an answer (e.g. a test with its result) | One row whose concept is the question, with `value_as_concept_id` set to the answer |
| **No mapping** | Retired code, or nothing suitable exists | `*_concept_id = 0`, source value kept |

Two consequences for anyone counting rows (Lessons 005 and 009):

- **One-to-many mappings make CDM counts higher than source counts.** That's correct, not a bug.
- **`Maps to value` without `Maps to` is a broken pair.** In this project it meant a vocabulary
  was missing from the bundle (Cancer Modifier, Lesson 003).

---

## Lecture 2: Hierarchies, change, licensing and local codes

### 6. Pre-coordination and post-coordination

Vocabularies differ in how much meaning they pack into one code:

- **Pre-coordinated:** one code says everything ("Type 2 diabetes with diabetic nephropathy").
- **Post-coordinated:** meaning is built from parts ("Type 2 diabetes" + "nephropathy" +
  "caused by").

OMOP is mostly pre-coordinated: each row has **one** concept, plus at most a value. When a
source code is richer than any single standard concept, the mapping splits it (one-to-many) or
moves part of it into `value_as_concept_id`. Keep that in mind when a mapping looks "lossy":
sometimes it's the model, not a mistake.

### 7. `concept_ancestor` is a transitive closure

`concept_relationship` stores **direct** links (A `Is a` B). `concept_ancestor` stores **every**
pair connected by any path of hierarchical links. In graph terms, it's the
**transitive closure** of the hierarchy graph, restricted to relationship types with
`defines_ancestry = 1`, and to standard and classification concepts. Every concept is also its
own ancestor at level 0.

| Column | Meaning |
|---|---|
| `min_levels_of_separation` | Length of the **shortest** path |
| `max_levels_of_separation` | Length of the **longest** path (hierarchies aren't trees: a concept can have several parents) |

Why precompute it? Because "all descendants of X" with only direct links needs a **recursive**
query that walks the graph every time. With the closure table it's one join. That's a classic
trade: **storage for speed** (63 million rows in our bundle, in exchange for instant
"include descendants" in every cohort).

The hierarchy also crosses vocabularies. RxNorm drug products sit below RxNorm **ingredients**,
which sit below **ATC classes** (classification concepts). So "all drugs in ATC class N06A
(antidepressants)" is one `concept_ancestor` join, even though the drug records are RxNorm.

**Where it goes wrong.** The closure is only as good as the links it's built from. A real
example from the OHDSI forums (August 2026): an ICD-10-CM code mapped to a *sibling* SNOMED
concept, so it couldn't be reached from the expected ancestor through `concept_ancestor`, and
cohorts using "include descendants" silently missed it. A practical rule follows: **when a
cohort depends on a hierarchy, check which source codes actually land inside it**. That's
exactly what CohortDiagnostics' "orphan concepts" check (Lesson 007) is for.

### 8. Change over time

Every release changes some concepts:

| Change | How it appears | Effect on an existing database |
|---|---|---|
| **Deprecated** | `invalid_reason = 'D'`, `valid_end_date` set | Data already loaded keeps the old ID; a **re-ETL** maps it differently, or to `0` |
| **Upgraded** | `invalid_reason = 'U'`, with a `Concept replaced by` relationship | Old ID still in old data; new loads use the successor |
| **Remapped** | The `Maps to` target changes | Same source data, different `*_concept_id` after re-ETL |
| **Domain change** | A concept moves domain (e.g. Condition → Observation) | Re-ETL moves rows to a **different table** |
| **New vocabulary** | e.g. ORPHAcode, Mondo in August 2026 | New mapping targets may appear |

Three practical rules:

1. **The vocabulary version is part of the dataset's identity.** Same Synthea run + different
   vocabulary = different database (Lesson 004). Record it in the run log.
2. **Upgrading is a migration, not an update.** Before switching releases, diff them: which
   concepts your data uses changed status, mapping or domain? (Lab 5 shows how.)
3. **Saved cohort definitions can drift.** A concept set defined against one release may resolve
   to different concepts in the next. Re-check "Included Concepts" after an upgrade.

### 9. Licensing

Most vocabularies in Athena are free to download after registering. Some carry their owners'
licence terms:

| Case | What happens |
|---|---|
| **CPT4** (owned by the AMA) | The concepts aren't shipped directly. Athena gives you a tool (`cpt4.jar`) that rebuilds them using **your own** UMLS API key (README 3c) |
| **Other licensed vocabularies** (e.g. MedDRA) | Shown with a licence requirement in Athena; you must hold the licence before they're included in your bundle |
| **Everything else** | Free, but read Athena's terms: redistribution of a full bundle isn't the same as using it |

The consequence for this project: **bundles never go in Git** (the README's `.gitignore`), and
"CPT4: yes/no" is recorded per load, because two people with different licences can't build
identical databases.

### 10. Local codes: when your source isn't in Athena

Real hospitals have codes Athena has never heard of: local lab codes, in-house order sets,
custom flowsheet rows. Three options, in increasing order of effort:

| Option | How | When |
|---|---|---|
| **`0` + source value** | Keep `*_source_value`, set `*_concept_id = 0` | The code is rare, or a decision is pending (our A-006, A-009) |
| **`source_to_concept_map`** (STCM) | A simple table: source code → standard concept. Supported by the OHDSI mapping tool **Usagi** | Quick start; mappings maintained by people unfamiliar with OMOP |
| **"2-billion" custom concepts** | Add rows to `concept` with `concept_id ≥ 2,000,000,000`, plus `Maps to` rows in `concept_relationship` | Codes you want to search, track and use in ATLAS |

Why 2 billion? OMOP reserves IDs from **2,000,000,000** up for local concepts, so they can never
collide with official IDs, and anyone can tell a local concept from an official one by its ID
alone.

Community practice worth adopting:

- **Local concepts are source concepts, never standard.** Mark them non-standard, use them in
  `*_source_concept_id`, and map them (`Maps to`) to real standard concepts where possible.
  Otherwise your data can't take part in network studies.
- **Document every custom concept** alongside the source codes that motivated it: each one is a
  local divergence, and a candidate for contributing back to the official vocabulary.
- **Protect them across upgrades.** A vocabulary reload replaces the official tables; your
  2-billion rows must be reloaded afterwards from your own script, so keep them in version control.

---

## Lab (3 hours)

All queries run against `omop-db`. Lab 6 uses a scratch schema so it can't affect the CDM.

### Lab 1: the vocabulary describes itself (20 minutes)

```sql
-- 1a. Release and per-vocabulary versions
SELECT vocabulary_id, vocabulary_version
  FROM cdm.vocabulary
 ORDER BY vocabulary_id = 'None' DESC, vocabulary_id;

-- 1b. What's in the bundle: concepts per vocabulary, split by standard status
SELECT vocabulary_id,
       COUNT(*) FILTER (WHERE standard_concept = 'S') AS standard,
       COUNT(*) FILTER (WHERE standard_concept = 'C') AS classification,
       COUNT(*) FILTER (WHERE standard_concept IS NULL) AS non_standard,
       COUNT(*) FILTER (WHERE invalid_reason IS NOT NULL) AS invalid
  FROM cdm.concept
 GROUP BY vocabulary_id
 ORDER BY COUNT(*) DESC
 LIMIT 25;

-- 1c. Metadata as concepts: the concept that represents each vocabulary
SELECT v.vocabulary_id, c.concept_id, c.concept_name, c.domain_id
  FROM cdm.vocabulary v
  JOIN cdm.concept c ON c.concept_id = v.vocabulary_concept_id
 WHERE v.vocabulary_id IN ('SNOMED', 'RxNorm', 'LOINC', 'CVX');
```

1. Is ORPHAcode or Mondo in your bundle? If not, why not (think about what you selected in Step 3b)?
2. Which vocabulary has the most **classification** concepts, and why does that make sense?

### Lab 2: relationships come in pairs (25 minutes)

```sql
-- 2a. Relationship metadata
SELECT relationship_id, is_hierarchical, defines_ancestry, reverse_relationship_id
  FROM cdm.relationship
 WHERE relationship_id IN ('Maps to', 'Mapped from', 'Is a', 'Subsumes',
                           'Maps to value', 'Concept replaced by');

-- 2b. Integrity: every relationship row should have its reverse. Expect 0.
SELECT COUNT(*) AS missing_reverse
  FROM cdm.concept_relationship cr
  JOIN cdm.relationship r ON r.relationship_id = cr.relationship_id
 WHERE NOT EXISTS (SELECT 1 FROM cdm.concept_relationship rev
                    WHERE rev.concept_id_1    = cr.concept_id_2
                      AND rev.concept_id_2    = cr.concept_id_1
                      AND rev.relationship_id = r.reverse_relationship_id);
```

1. 2b scans a very large table. Before running it, estimate how long it will take, and check
   with `EXPLAIN` first. Then run it.
2. If the answer isn't 0, what's the most likely reason? (Hint: Lesson 004 section 3.3, bundles
   leave out relationships into vocabularies you didn't select.)

### Lab 3: rebuild a piece of `concept_ancestor` (40 minutes)

Compute the descendants of "Malignant neoplasm of colon" (`4180790`) yourself, by walking
hierarchical links with a recursive query, and compare with the closure table:

```sql
WITH RECURSIVE hier AS (            -- relationship types that build the hierarchy
  SELECT relationship_id FROM cdm.relationship WHERE defines_ancestry = '1'
), walk (concept_id, depth) AS (
  SELECT 4180790, 0
  UNION ALL
  SELECT cr.concept_id_2, w.depth + 1
    FROM walk w
    JOIN cdm.concept_relationship cr
      ON cr.concept_id_1 = w.concept_id
     AND cr.invalid_reason IS NULL
     AND cr.relationship_id = 'Subsumes'          -- parent → child direction
     AND cr.relationship_id IN (SELECT relationship_id FROM hier)
   WHERE w.depth < 20                              -- guard against cycles
), mine AS (
  SELECT w.concept_id, MIN(w.depth) AS min_depth, MAX(w.depth) AS max_depth
    FROM walk w
    JOIN cdm.concept c ON c.concept_id = w.concept_id
   WHERE c.standard_concept IN ('S', 'C')          -- the closure only holds these
   GROUP BY w.concept_id
)
SELECT
  (SELECT COUNT(*) FROM mine)                                           AS my_descendants,
  (SELECT COUNT(*) FROM cdm.concept_ancestor WHERE ancestor_concept_id = 4180790) AS closure_rows,
  (SELECT COUNT(*) FROM mine m
     JOIN cdm.concept_ancestor ca
       ON ca.ancestor_concept_id = 4180790 AND ca.descendant_concept_id = m.concept_id
    WHERE ca.min_levels_of_separation = m.min_depth
      AND ca.max_levels_of_separation = m.max_depth)                    AS levels_agree;
```

1. Explain why the query needs `UNION ALL` plus a depth guard, and why `MIN`/`MAX` depth differ
   for some concepts (draw a small "diamond" hierarchy).
2. Do the counts match? If not, list the concepts in one set but not the other, and explain
   each difference. (Candidates: relationship types other than `Subsumes`, invalid relationships,
   non-standard intermediate concepts.)
3. Time the recursive query, then time `SELECT … FROM cdm.concept_ancestor WHERE ancestor_concept_id = 4180790`.
   That ratio is why the closure table exists.

### Lab 4: mapping patterns in your bundle (30 minutes)

```sql
-- 4a. One-to-many: how many non-standard concepts per vocabulary have more than one valid
--     'Maps to'? Inner query: one row per such concept; outer query: count them per vocabulary.
SELECT vocabulary_id, COUNT(*) AS one_to_many_concepts, MAX(targets) AS max_targets
  FROM (
    SELECT c.vocabulary_id, c.concept_id, COUNT(*) AS targets
      FROM cdm.concept c
      JOIN cdm.concept_relationship cr
        ON cr.concept_id_1 = c.concept_id AND cr.relationship_id = 'Maps to' AND cr.invalid_reason IS NULL
     WHERE c.standard_concept IS NULL
     GROUP BY c.vocabulary_id, c.concept_id
    HAVING COUNT(*) > 1
  ) one_to_many
 GROUP BY vocabulary_id
 ORDER BY one_to_many_concepts DESC;

-- 4b. Broken pairs: 'Maps to value' with no 'Maps to'. In a full release this should be rare.
SELECT c.vocabulary_id, COUNT(DISTINCT c.concept_id) AS broken_pairs
  FROM cdm.concept c
  JOIN cdm.concept_relationship v
    ON v.concept_id_1 = c.concept_id AND v.relationship_id = 'Maps to value' AND v.invalid_reason IS NULL
 WHERE NOT EXISTS (SELECT 1 FROM cdm.concept_relationship m
                    WHERE m.concept_id_1 = c.concept_id AND m.relationship_id = 'Maps to'
                      AND m.invalid_reason IS NULL)
 GROUP BY c.vocabulary_id
 ORDER BY broken_pairs DESC;
```

1. Pick one one-to-many concept from 4a and look it up on athena.ohdsi.org. Why does it split?
2. For the vocabularies in 4b, which vocabulary are the missing `Maps to` targets probably in?
   Check one on Athena. Would adding that vocabulary to the bundle fix it (as Cancer Modifier did)?

### Lab 5: a vocabulary audit of our own data (35 minutes)

Which codes **Synthea actually used** are retired or unmappable in our release? This
generalizes the overdose discovery (A-006) to every code at once:

```sql
-- Condition codes used by Synthea, with their status in this release
WITH used AS (
  SELECT code, MAX(description) AS description, COUNT(*) AS records
    FROM synthea.conditions GROUP BY code
)
SELECT u.code, u.description, u.records,
       c.concept_id, c.standard_concept, c.invalid_reason, c.valid_end_date,
       EXISTS (SELECT 1 FROM cdm.concept_relationship cr
                WHERE cr.concept_id_1 = c.concept_id AND cr.relationship_id = 'Maps to'
                  AND cr.invalid_reason IS NULL) AS has_maps_to
  FROM used u
  LEFT JOIN cdm.concept c ON c.concept_code = u.code AND c.vocabulary_id = 'SNOMED'
 WHERE c.concept_id IS NULL                 -- code not in the vocabulary at all
    OR c.invalid_reason IS NOT NULL         -- retired or upgraded
    OR (c.standard_concept IS NULL AND NOT EXISTS (
          SELECT 1 FROM cdm.concept_relationship cr
           WHERE cr.concept_id_1 = c.concept_id AND cr.relationship_id = 'Maps to'
             AND cr.invalid_reason IS NULL))  -- non-standard with nowhere to go
 ORDER BY u.records DESC;
```

1. Does `55680006` (drug overdose) appear? It should: it's A-006.
2. Repeat for `synthea.procedures` (SNOMED) and `synthea.medications` (RxNorm). Which source has
   the most problems?
3. Write a **release-upgrade checklist** in five lines: what would you run against a *new*
   bundle, before loading it, to know what will change in our database?

### Lab 6: design local concepts (30 minutes)

A partner clinic sends three local codes Athena doesn't know: `PCLIN-001` "Peer support session",
`PCLIN-002` "Harm reduction kit given", `PCLIN-003` "Recovery coach check-in".

1. For each, decide: `0`, STCM, or a 2-billion concept? Justify in one sentence each.
2. Build them **in a scratch schema**, never in `cdm` (and never commit real partner codes to Git):

```sql
CREATE SCHEMA IF NOT EXISTS scratch_vocab;

CREATE TABLE scratch_vocab.concept (LIKE cdm.concept INCLUDING ALL);
CREATE TABLE scratch_vocab.concept_relationship (LIKE cdm.concept_relationship INCLUDING ALL);

-- Local SOURCE concepts: ≥ 2,000,000,000, non-standard (standard_concept NULL).
INSERT INTO scratch_vocab.concept
  (concept_id, concept_name, domain_id, vocabulary_id, concept_class_id,
   standard_concept, concept_code, valid_start_date, valid_end_date, invalid_reason)
VALUES
  (2000000001, 'Peer support session',     'Observation', 'PCLIN', 'Local code', NULL, 'PCLIN-001', DATE '2026-01-01', DATE '2099-12-31', NULL),
  (2000000002, 'Harm reduction kit given', 'Observation', 'PCLIN', 'Local code', NULL, 'PCLIN-002', DATE '2026-01-01', DATE '2099-12-31', NULL),
  (2000000003, 'Recovery coach check-in',  'Observation', 'PCLIN', 'Local code', NULL, 'PCLIN-003', DATE '2026-01-01', DATE '2099-12-31', NULL);
```

3. Search the vocabulary for a **standard** concept each could `Maps to` (try SNOMED procedures
   and observables). Write the `Maps to` **and** `Mapped from` rows for any you'd defend to a
   terminology reviewer. Leave the rest unmapped and say why.
4. A real `concept` load would also need a `vocabulary` row for `PCLIN`, and a `concept_class`
   row for `Local code`. What else breaks if they're missing? (Think foreign keys and ATLAS.)
5. Clean up: `DROP SCHEMA scratch_vocab CASCADE;`

---

## Check your understanding

1. A mapping is wrong. Where does the fix happen, and when will you see it?
2. Why does this project keep its downloaded bundle, even though it's not in Git?
3. What does it mean that "the vocabulary describes itself"? Give one example.
4. Why does OMOP insist on one standard concept per meaning? What does that cost?
5. A source table has 1,000 diagnoses; `condition_occurrence` gets 1,040 rows from them. Bug?
6. What is a transitive closure, and why store it instead of computing it on demand?
7. Why can `min_levels_of_separation` differ from `max_levels_of_separation`?
8. You upgrade the vocabulary and re-run the ETL on the same Synthea data. Name three ways the CDM could change.
9. Why should a 2-billion local concept be non-standard?
10. Why can't two people with different licences necessarily build identical databases from the same data?

<details>
<summary><strong>Answers</strong></summary>

1. In the vocabulary **build** (OHDSI's Vocabulary-v5.0 process), usually after it's reported on
   the OHDSI forums or GitHub. You see it in a later **release** (February or August), after you
   download that release and reload.
2. Prior releases aren't publicly downloadable from Athena, so the zip is the only way to
   reproduce a load with exactly that vocabulary. Git is the wrong place (size, licensing), but
   the file must still be kept, with its checksum in the run log.
3. Vocabularies, domains and concept classes are themselves represented as concepts
   (`vocabulary.vocabulary_concept_id` points to a row in `concept`). One mechanism serves both
   clinical meaning and the model's metadata.
4. So every analysis can use one ID per meaning across all sources and sites. The cost is
   curation: someone must choose the standard and maintain mappings, which is where errors and
   lag come from.
5. Not necessarily. One-to-many mappings legitimately produce several rows from one source
   record. Check whether the extra 40 come from source codes with more than one `Maps to`.
6. The set of all pairs connected by any path in a graph. Computing descendants on demand needs
   a recursive walk for every query; the precomputed table makes it one indexed join, at the
   cost of storage (63M rows).
7. Hierarchies aren't trees: a concept can reach an ancestor through several parents, along
   paths of different lengths.
8. Rows move between tables (domain changes), `*_concept_id` values change (remapping), and rows
   become `0` or get dropped (deprecation, depending on the ETL's joins). Also, new mappings can
   turn former `0`s into real concepts.
9. Standard concepts are the shared language across the OHDSI network. A local standard concept
   would make your data impossible to compare with anyone else's. As a source concept, it keeps
   the local detail and can still `Maps to` a real standard concept.
10. Licensed vocabularies (CPT4, MedDRA …) are only included if you hold the licence, so without
    them, codes from those vocabularies can't map, and the resulting databases differ.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Standardized Vocabularies** | OHDSI's merged, curated set of source vocabularies, concepts and relationships |
| **Athena** | The website for searching the vocabularies and downloading bundles |
| **Release** | A dated, published version of the vocabularies (February and August) |
| **Surrogate vs natural key** | `concept_id` (meaningless, global) vs `concept_code` (the source's own code) |
| **Classification concept** | A `C` concept used only as an ancestor (e.g. ATC classes) |
| **One-to-many mapping** | One source concept mapping to several standard concepts |
| **Pre-/post-coordination** | Meaning packed into one code vs built from several parts |
| **Transitive closure** | All ancestor–descendant pairs reachable by any path; what `concept_ancestor` stores |
| **`defines_ancestry`** | Relationship flag: does this relationship type feed `concept_ancestor`? |
| **Concept lifecycle** | `valid_start_date`, `valid_end_date`, `invalid_reason` (`D`/`U`) |
| **STCM** | `source_to_concept_map`: a simple local-code-to-standard mapping table |
| **2-billion concept** | A local concept with `concept_id ≥ 2,000,000,000` |
| **Usagi** | OHDSI's tool for mapping source codes to standard concepts |

---

## Further reading

- **The Book of OHDSI**, chapter 5 (Standardized Vocabularies): <https://ohdsi.github.io/TheBookOfOhdsi/StandardizedVocabularies.html>
- **Vocabulary releases and release notes**: <https://github.com/OHDSI/Vocabulary-v5.0/wiki/Releases> and <https://github.com/OHDSI/Vocabulary-v5.0/releases>
- **Release planning** (what's coming next): <https://github.com/OHDSI/Vocabulary-v5.0/wiki/Release-planning>
- **OHDSI Forums, Vocabulary Users** (where mapping problems get reported and discussed): <https://forums.ohdsi.org/c/vocabulary-users/14>
- **CDM 5.4 vocabulary table specifications**: <https://ohdsi.github.io/CommonDataModel/cdm54.html>
- **Usagi**: <https://github.com/OHDSI/Usagi>
- **"Who wants to be a 2-billionaire?"** (OHDSI 2024, local concepts methodology): <https://ohdsi.org/wp-content/uploads/2024/10/33-carlson-Who-Wants-To-Be-A-2Billionaire-brief.pdf>
- **HL7 FHIR-to-OMOP IG**, code mappings and custom concepts: <https://build.fhir.org/ig/HL7/fhir-omop-ig/en/codemappings.html>
