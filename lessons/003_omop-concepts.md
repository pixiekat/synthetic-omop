# Lesson 003: OMOP Concepts, the Vocabulary Behind Every Row

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | 75–90 minutes (lecture + lab) |
| **Prerequisites** | Lesson 001 (sections 4–6); basic SQL including `JOIN` |
| **Project tables** | `cdm.concept`, `cdm.concept_relationship`, `cdm.concept_ancestor`, `cdm.vocabulary`, and any clinical table (`cdm.condition_occurrence`, `cdm.death`…) |
| **Previous lesson** | 002: Calibration |
| **Next lesson** | 004: Deep Dive into NSDUH, Synthea, Athena and the ETL |

> **About the examples:** every concept ID in this lesson comes from the project's own
> database, from the investigation we ran on the pilot load. You can look each one up
> yourself in the lab.

## Learning objectives

By the end of this lesson you should be able to:

1. Describe what an OMOP **concept** is, and read every column of a `concept` row.
2. Explain the difference between a **concept_id** and a **concept_code**.
3. Tell **standard**, **classification** and **non-standard** concepts apart, and say which ones analyses use.
4. Explain how a concept's **domain** decides which clinical table a record lands in.
5. Follow **`Maps to`** and **`Maps to value`** relationships from a source code to a standard concept.
6. Use **`concept_ancestor`** to find every concept beneath a broader one.
7. Explain what **deprecated** concepts are, and why they cause `concept_id = 0`.
8. Read the **`_concept_id` / `_source_value` / `_source_concept_id`** pattern found in every clinical table.

---

## 1. One idea, many codes

Lesson 001 introduced the problem: the same clinical idea has different codes in different
coding systems. "Diabetes" is one code in ICD-10, another in SNOMED, another in Read codes.
Hospitals pick different systems, so their data can't be queried together.

OMOP's solution is to put **every code from every vocabulary into one table**, give each one
an OMOP-wide ID, and record how they relate to each other. That table is `cdm.concept`, and
each row in it is a **concept**.

In the project database, `concept` holds **millions** of rows. Every coded value in every
clinical table (a diagnosis, a drug, a lab test, a visit type, a gender, even the *kind* of
record) points into it.

---

## 2. Anatomy of a concept

Here's a real row from the project database, the concept Synthea used for some causes of
death:

| Column | Value | What it means |
|---|---|---|
| `concept_id` | **4311765** | OMOP's own ID: unique across *all* vocabularies |
| `concept_name` | Metastatic malignant neoplasm to colon | Human-readable label |
| `domain_id` | Condition | What *kind* of thing it is (section 4) |
| `vocabulary_id` | SNOMED | Which coding system it came from |
| `concept_class_id` | Disorder | A finer category *within* the vocabulary |
| `standard_concept` | *(null)* | **Non-standard** (section 3) |
| `concept_code` | **94260004** | The code *as SNOMED writes it* |
| `valid_start_date` | 2002-01-31 | When it became valid |
| `valid_end_date` | 2099-12-31 | Still valid ("2099" means no end date) |
| `invalid_reason` | *(null)* | Not retired (section 7) |

### concept_id vs concept_code

This distinction trips everyone up at first:

- **`concept_code`** is the code the *source vocabulary* uses: `94260004` is SNOMED's code.
  Codes are only unique **within** a vocabulary. The same string can mean entirely different
  things in two vocabularies.
- **`concept_id`** is OMOP's own number, `4311765`, unique across **everything**. Clinical
  tables store concept_ids, never bare codes, so there's never any ambiguity about which
  vocabulary a value came from.

> **Analogy:** `concept_code` is like a room number ("Room 101"). Every building has one.
> `concept_id` is like a full postal address. It points to exactly one room in the world.

---

## 3. Standard, classification, non-standard

The `standard_concept` column is the most important one for analysis:

| Value | Meaning | Used for |
|---|---|---|
| `S` | **Standard**: OMOP's chosen representative for this idea | Storing data and writing analyses |
| `C` | **Classification**: a grouping concept (e.g. a drug class) | Navigating hierarchies, not storing records |
| *null* | **Non-standard**: a valid code, but not OMOP's chosen one | Only via mapping to a standard concept |

For any given idea, OMOP picks **one** standard concept, usually from a preferred vocabulary
for that domain (SNOMED for conditions, RxNorm for drugs, LOINC for lab tests). Every other
code for the same idea is non-standard, and is **mapped** to the standard one.

Our example, `4311765`, is **non-standard**, even though it's a perfectly valid SNOMED code.
OMOP decided metastases are better represented a different way (section 5).

---

## 4. Domains decide where data goes

Every concept has a **`domain_id`**, and a standard concept's domain decides which clinical
table a record is stored in:

| Domain | Table | Example |
|---|---|---|
| Condition | `condition_occurrence` | Major depressive disorder |
| Drug | `drug_exposure` | A medication, **or a vaccine** |
| Procedure | `procedure_occurrence` | Appendectomy |
| Measurement | `measurement` | A lab result, **or a cancer modifier** |
| Observation | `observation` | Social history, survey answers |
| Visit | `visit_occurrence` | Outpatient visit |

This is why OMOP ETLs are sometimes surprising. A record doesn't go where its *source* says
it should. It goes where its **standard concept's domain** says. You'll see a real example in
the next section, where a "condition" ends up as a **measurement**.

---

## 5. Relationships: how concepts connect

`cdm.concept_relationship` links concepts in pairs. Each row says
"`concept_id_1` *relationship* `concept_id_2`". There are hundreds of relationship types; these
are the ones you'll use most:

| Relationship | Meaning | Shown on the Athena website as |
|---|---|---|
| **`Maps to`** | "Use this standard concept instead of me." The key relationship for ETL. | Non-standard to Standard map (OMOP) |
| **`Maps to value`** | Supplies the *value* that goes with a `Maps to` | Non-standard to value_as_concept map (OMOP) |
| `Is a` / `Subsumes` | Parent/child in a hierarchy | Is a / Subsumes |
| `Concept replaced by` | The successor of a retired concept | Concept replaced by |
| `Concept poss_eq to` | "*Possibly* equivalent": a hint, not a mapping | Concept poss_eq to |

### A real mapping: `Maps to` + `Maps to value`

When we looked up `4311765` on Athena, its mappings were:

```
4311765  "Metastatic malignant neoplasm to colon"   (SNOMED, non-standard, Condition)
   │
   ├── Maps to        → 35226112  "Metastasis to colon"   (Cancer Modifier, Measurement)
   └── Maps to value  →     9191  "Positive"              (SNOMED)
```

Read it as one sentence: *"Record this as a **measurement** of 'metastasis to colon', with the
value **positive**."* OMOP models a metastasis as a **modifier** of the primary cancer, not as
a separate disease. So a source "condition" becomes a **Measurement-domain** record. That's
section 4 in action.

> **Case study, in two acts.** *Act 1:* the project's first vocabulary download didn't include
> **Cancer Modifier**. Athena leaves out relationships that point into vocabularies you didn't
> select, so the `Maps to` row was missing and only the `Maps to value → Positive` half arrived.
> **A `Maps to value` with no `Maps to` is a red flag for a missing vocabulary.**
> *Act 2:* after adding Cancer Modifier, the mapping appeared, but the three deaths were *still*
> dropped. The ETL's death script only accepts causes whose standard concept is in the
> **Condition** domain, and this one is a **Measurement**. Domains matter at every step, not just
> when choosing a table. Lesson 005 tells the whole story.

---

## 6. Hierarchies: `concept_ancestor`

Standard concepts form hierarchies. For example, "Malignant neoplasm of colon" (`4180790`,
standard) sits *below* broader cancer concepts and *above* more specific ones.

Walking that tree with `concept_relationship` one step at a time would be slow. So OMOP
**precomputes every ancestor/descendant pair** into `cdm.concept_ancestor`:

| Column | Meaning |
|---|---|
| `ancestor_concept_id` | The broader concept |
| `descendant_concept_id` | Any concept beneath it, at any depth (including itself, at depth 0) |
| `min_levels_of_separation` | Shortest path between them |
| `max_levels_of_separation` | Longest path between them |

That's why `concept_ancestor` was the biggest table in the vocabulary load, at **over 63 million
rows**: it stores *every* pair, not just parent and child.

**Why it matters:** an analyst asking "who has colon cancer?" doesn't want to list every specific
subtype by hand. Instead:

```sql
-- Everyone with colon cancer OR any more specific kind of it
SELECT DISTINCT co.person_id
  FROM cdm.condition_occurrence co
  JOIN cdm.concept_ancestor ca
    ON ca.descendant_concept_id = co.condition_concept_id
 WHERE ca.ancestor_concept_id = 4180790;   -- Malignant neoplasm of colon
```

One join replaces a long, error-prone list of codes, and automatically includes any new
subtypes added in future vocabulary releases.

---

## 7. Concepts age: deprecation

Vocabularies change. Codes get split, merged, renamed or retired. OMOP keeps old concepts
rather than deleting them, but marks them:

| `invalid_reason` | Meaning |
|---|---|
| *(null)* | Valid |
| `D` | **Deleted** (deprecated): retired, no longer to be used |
| `U` | **Upgraded**: replaced by a successor concept |

### A real retired concept

Synthea records some deaths with SNOMED `55680006` "Drug overdose." In the project database:

| `concept_id` | `concept_code` | `invalid_reason` | `valid_end_date` |
|---|---|---|---|
| 4208104 | 55680006 | **D** | **2021-07-31** |

SNOMED retired it in 2021. It has **no `Maps to`** and **no `Concept replaced by`**, only
weaker hints like `Concept poss_eq to` → `607147` "Overdose", and `Subsumes` links to specific
concepts such as `4053782` "Overdose of opiate".

So the ETL can't map it, and the record ends up with `concept_id = 0`, or gets dropped. Choosing
one of those hints as a replacement is a **terminology decision** for a reviewer, never something
to guess in code.

> **Why this happens with Synthea:** Synthea's disease modules were written years ago, using
> SNOMED codes that were valid then. Vocabularies moved on; the modules didn't. Old source data
> from real hospitals has exactly the same problem.

---

## 8. The three-column pattern in every clinical table

Clinical tables store each coded value in **three** columns. Using `cdm.death` as an example:

| Column | Holds | Example (a metastasis death, restored by the project's patch) |
|---|---|---|
| `cause_concept_id` | The **standard** concept: what analyses use | `35226112` (Metastasis to colon) |
| `cause_source_value` | The **original** code, verbatim, as text | `94260004` |
| `cause_source_concept_id` | The original code's **concept** (often non-standard) | `4311765` |

Every domain table follows the same pattern: `condition_concept_id` /
`condition_source_value` / `condition_source_concept_id`, and so on.

**Why keep all three?**
- `_concept_id` makes data **comparable** across sites (OMOP's whole purpose).
- `_source_value` keeps **traceability**: you can always see what was actually recorded.
- `_source_concept_id` lets you **re-map** later if the vocabulary improves, without going back
  to the raw data.

### The meaning of `concept_id = 0`

`0` means **"No matching concept"**. By OMOP convention, an unmappable value keeps its row, with
`_concept_id = 0` and the original in `_source_value`. That way:

- the record still **counts** (a death is still a death, even with an unmapped cause), and
- the unmapped values form a **worklist** someone can review.

> **The trap:** an ETL that **drops** unmappable rows instead of using `0` breaks this
> convention. Then the unmapped count looks clean while records quietly vanish. In the pilot,
> 18 deaths with unmappable causes and all 2,711 immunizations (loaded without the CVX
> vocabulary) disappeared this way, while the unmapped drug count read **0**.
> **"Zero unmapped" is not the same as "nothing lost."**

---

## Lab: explore the concept tables

Connect to the project database (`localhost:5432`, credentials from `.env`), or:

```bash
docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

**Query 1: read a full concept row (section 2).**

```sql
SELECT *
  FROM cdm.concept
 WHERE concept_id = 4311765;
```

**Query 2: codes aren't unique across vocabularies (section 2).**

```sql
-- Concept codes that appear in the most different vocabularies
SELECT concept_code,
       COUNT(DISTINCT vocabulary_id) AS vocabularies,
       STRING_AGG(DISTINCT vocabulary_id, ', ') AS which
  FROM cdm.concept
 GROUP BY concept_code
HAVING COUNT(DISTINCT vocabulary_id) > 3
 ORDER BY vocabularies DESC
 LIMIT 10;
```

> Pick one result and look at what the same code means in two vocabularies.

**Query 3: what's standard, by domain (sections 3–4)?**

```sql
SELECT domain_id, COUNT(*) AS standard_concepts
  FROM cdm.concept
 WHERE standard_concept = 'S'
 GROUP BY domain_id
 ORDER BY standard_concepts DESC
 LIMIT 12;
```

**Query 4: follow a mapping (section 5).**

```sql
SELECT c1.concept_code   AS source_code,
       c1.vocabulary_id  AS source_vocab,
       cr.relationship_id,
       c2.concept_id     AS target_id,
       c2.concept_name   AS target_name,
       c2.vocabulary_id  AS target_vocab,
       c2.domain_id      AS target_domain
  FROM cdm.concept c1
  JOIN cdm.concept_relationship cr
    ON cr.concept_id_1 = c1.concept_id
   AND cr.relationship_id IN ('Maps to', 'Maps to value')
   AND cr.invalid_reason IS NULL
  JOIN cdm.concept c2
    ON c2.concept_id = cr.concept_id_2
 WHERE c1.concept_id = 4311765;
```

> With the Cancer Modifier vocabulary loaded, you should see **both** rows from section 5.
> Note the target's **domain**.

**Query 5: one of the project's own codes.** Is SNOMED `7200002` (our module's SUD code)
standard? If not, what does it map to?

```sql
SELECT concept_id, concept_name, domain_id, standard_concept, invalid_reason
  FROM cdm.concept
 WHERE vocabulary_id = 'SNOMED' AND concept_code = '7200002';
```

> Reuse Query 4 with the `concept_id` you find to check its mappings.

**Query 6: walk a hierarchy (section 6).**

```sql
-- Concepts beneath "Malignant neoplasm of colon", nearest first
SELECT c.concept_id, c.concept_name, ca.min_levels_of_separation AS depth
  FROM cdm.concept_ancestor ca
  JOIN cdm.concept c ON c.concept_id = ca.descendant_concept_id
 WHERE ca.ancestor_concept_id = 4180790
 ORDER BY ca.min_levels_of_separation, c.concept_name
 LIMIT 20;
```

**Query 7: a retired concept (section 7).**

```sql
SELECT concept_id, concept_name, standard_concept, invalid_reason, valid_end_date
  FROM cdm.concept
 WHERE vocabulary_id = 'SNOMED' AND concept_code = '55680006';
```

**Query 8: the three-column pattern (section 8).**

```sql
SELECT cause_concept_id, cause_source_value, cause_source_concept_id, COUNT(*) AS deaths
  FROM cdm.death
 GROUP BY 1, 2, 3
 ORDER BY deaths DESC
 LIMIT 15;
```

> Find a row where `cause_concept_id = 0`. What's its source value? Use Query 7's pattern to
> find out why it doesn't map.

**Stretch: use the hierarchy for real.** Count how many people in the database have any kind of
colon cancer, using Query 6's ancestor. Then count how many you'd find matching
`condition_concept_id = 4180790` *exactly*. What does the difference tell you?

---

## Check your understanding

1. What's the difference between `concept_id` and `concept_code`? Why do clinical tables store the ID?
2. A concept has `standard_concept` = null. Can you store it in `condition_concept_id`? What should happen instead?
3. A SNOMED code for a **condition** ends up as a row in `measurement`. Is that a bug?
4. You see a concept with `Maps to value` but no `Maps to`. What's the most likely explanation, and how do you check?
5. Why does `concept_ancestor` have so many more rows than `concept_relationship`'s `Is a` links?
6. A death has `cause_concept_id = 0` and `cause_source_value = 55680006`. Is the data wrong?
7. Why is "0 unmapped" not proof that an ETL lost nothing?

<details>
<summary><strong>Answers</strong></summary>

1. `concept_code` is the source vocabulary's own code and is only unique **within** that
   vocabulary. `concept_id` is unique across **all** vocabularies, so storing it removes any
   ambiguity about where a value came from.
2. **No.** `_concept_id` columns hold **standard** concepts. Follow its `Maps to` to the standard
   concept and store that. Keep the original in `_source_value` and `_source_concept_id`.
3. **Not necessarily.** The standard concept's **domain** decides the table. Metastases, for
   example, map to Cancer Modifier concepts in the **Measurement** domain. (The flip side: code
   that *assumes* a domain, like the ETL's Condition-only death script, can silently drop such
   records.)
4. The `Maps to` target is in a **vocabulary that wasn't downloaded**, so Athena left the row out.
   Look the concept up on athena.ohdsi.org and check which vocabulary its `Maps to` points into.
5. `concept_ancestor` stores **every** ancestor–descendant pair at **every** depth (plus each
   concept with itself), not only direct parent–child links.
6. **No, it's working as designed.** The cause is a retired SNOMED code with no standard mapping,
   so `0` is correct. The original code is kept for review, and the death still counts.
7. An ETL can **drop** unmappable rows instead of setting them to `0`. Dropped rows never show up
   as "unmapped." Only comparing counts from staging to CDM reveals them.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Concept** | One coded idea in the OMOP vocabulary: a row in `cdm.concept` |
| **concept_id** | OMOP's ID for a concept, unique across all vocabularies |
| **concept_code** | The code as the source vocabulary writes it; unique only within that vocabulary |
| **Vocabulary** | A coding system (SNOMED, RxNorm, LOINC, CVX, Cancer Modifier…) |
| **Domain** | The kind of thing a concept is; decides which clinical table data goes into |
| **Standard concept** | OMOP's chosen representative for an idea (`S`); the only kind stored in `_concept_id` |
| **Classification concept** | A grouping concept (`C`) for navigating hierarchies |
| **Maps to** | Links a non-standard concept to its standard equivalent |
| **Maps to value** | Supplies a value to go with a `Maps to` (e.g. "Positive") |
| **concept_ancestor** | Precomputed table of every ancestor–descendant pair |
| **Deprecated concept** | A retired concept (`invalid_reason = 'D'`), kept for history |
| **concept_id = 0** | "No matching concept": the record is kept, but unmapped |
| **Source value** | The original recorded code, kept verbatim for traceability |

---

## Further reading

- **The Book of OHDSI**, chapter 5 (Standardized Vocabularies): the definitive introduction to
  everything in this lesson: <https://ohdsi.github.io/TheBookOfOhdsi/>
- **Athena** (<https://athena.ohdsi.org/>): look up any concept from the lab and explore its
  relationships in the browser. Try `4311765`, `4208104` and `4180790`.
- **OMOP CDM 5.4 documentation**, the vocabulary tables and the conventions for `_concept_id`,
  `_source_value` and `_source_concept_id`: <https://ohdsi.github.io/CommonDataModel/cdm54.html>
- **EHDEN Academy**: free courses on the OMOP vocabularies: <https://academy.ehden.eu/>
