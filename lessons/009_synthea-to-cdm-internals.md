# Lesson 009: From Synthea to the CDM, the ETL Internals

| | |
|---|---|
| **Course level** | Second to third year undergraduate (data engineering / health informatics) |
| **Estimated time** | 2 × 90-minute lectures + 3-hour lab (or two 90-minute lab sessions) |
| **Prerequisites** | Lessons 001, 003, 004 and 005; SQL window functions (`ROW_NUMBER`, `LAG`, `SUM … OVER`); basic relational design (keys, foreign keys) |
| **Project files** | `services/etl/run_etl.R`, `services/etl/sql/*.sql`, the ETL-Synthea SQL inside the `etl` image, `synthea.*` and `cdm.*` |
| **Previous lesson** | 008: Our ATLAS Setup and the UI |

> **How this lesson relates to 001 and 004.** Lesson 001 introduced *extract, transform, load*.
> Lesson 004 named ETL-Synthea's stages and its lookup table. This lesson opens each stage and
> asks the engineering questions: what's the **contract** between systems, how are **keys**
> created, how are rows **grouped and derived**, what happens on **failure or rerun**, and how
> do you **prove** the output is right? The labs make you rebuild parts of the ETL yourself and
> compare your output with ETL-Synthea's.

## Learning objectives

By the end of this lesson you should be able to:

1. Describe Synthea's CSV export as a **data contract**, and explain why the ETL needs the exact Synthea version.
2. Explain the **staging** design (lossless, typed, untransformed) and what it buys you.
3. Trace how a Synthea UUID becomes an OMOP integer key, and say whether those keys are **stable across loads**.
4. Explain and implement **visit roll-up** (encounters → visits) as a *gaps-and-islands* problem.
5. Explain **domain routing**: why one source table can feed several CDM tables.
6. Explain and implement the **era** algorithm (30-day persistence window) and compare it with ETL-Synthea's output.
7. Reason about an ETL's **dependency graph**, idempotency, atomicity and performance.
8. Design an **ETL test strategy**: fixtures, reconciliation, integrity checks, data quality checks.

---

## Lecture 1: Contracts, keys and visits

### 1. The pipeline as a dependency graph

Lesson 004 listed the stages in order. A better mental model is a **directed acyclic graph
(DAG)**: each step can only run once the steps it depends on have finished.

```
 Synthea CSVs ──▶ synthea.* (staging)
                       │
 Athena CSVs ──▶ cdm.concept, concept_relationship, concept_ancestor … (vocabulary)
                       │
                       ▼
        ┌──────── mapping + roll-up tables ────────┐
        │ source_to_standard_vocab_map             │
        │ source_to_source_vocab_map               │
        │ all_visits → assign_all_visit_ids        │
        │            → final_visit_ids             │
        └───────────────────┬──────────────────────┘
                            ▼
    location → care_site → provider → person → observation_period
                                         │
                                         ▼
                       visit_occurrence → visit_detail
                                         │
           ┌────────────┬────────────────┼──────────────┬───────────────┐
           ▼            ▼                ▼              ▼               ▼
   condition_occ.  observation    measurement   procedure_occ.   drug_exposure …
           │                                                         │
           ▼                                                         ▼
     condition_era                                               drug_era
```

Why the graph matters:

- **Ordering.** `condition_occurrence` needs `person_id` and `visit_occurrence_id`, so `person`
  and `visit_occurrence` must already be loaded. `condition_era` is computed *from*
  `condition_occurrence`, so it comes last.
- **Partial reruns.** If one node fails, everything downstream of it is suspect, and nothing
  upstream is. (Our patches in Lesson 005 sit *after* `LoadEventTables` for this reason.)
- **Parallelism.** Nodes with no path between them (e.g. `measurement` and `drug_exposure`)
  could run at the same time. ETL-Synthea runs them one after another for simplicity.

### 2. The contract: Synthea's CSV export

A **data contract** is the agreed shape of the data that crosses a boundary: file names, column
names, types, keys and meanings. Synthea's CSV export (v3.3.0) is our contract.

| File | Grain (one row = …) | Key | Points to |
|---|---|---|---|
| `patients.csv` | One person | `Id` (UUID) | n/a |
| `encounters.csv` | One encounter | `Id` (UUID) | `PATIENT`, `PROVIDER`, `ORGANIZATION`, `PAYER` |
| `conditions.csv` | One diagnosis | (no own key) | `PATIENT`, `ENCOUNTER` |
| `medications.csv` | One prescription span | (no own key) | `PATIENT`, `ENCOUNTER` |
| `immunizations.csv` | One vaccine dose | (no own key) | `PATIENT`, `ENCOUNTER` |
| `observations.csv` | One measured/observed value | (no own key) | `PATIENT`, `ENCOUNTER` |
| `procedures.csv` | One procedure | (no own key) | `PATIENT`, `ENCOUNTER` |

Plus allergies, care plans, devices, imaging studies, supplies, payers, providers,
organizations and claims files.

Three properties of this contract shape the whole ETL:

1. **Keys are UUIDs.** Globally unique strings like `a1b2c3d4-…`. OMOP needs integer keys, so
   the ETL must *generate* them (section 4).
2. **Clinical rows have no key of their own.** A condition is identified by (patient, encounter,
   code, start date). OMOP gives every row a surrogate key (`condition_occurrence_id`).
3. **The contract is versioned.** Columns change between Synthea releases. ETL-Synthea takes a
   `syntheaVersion` argument and supports a fixed list of releases (2.7.0 and 3.0.0 to 3.3.0 at
   our pinned commit). Give it CSVs from a different version and you get errors at best, and
   silently misread columns at worst. This is why `run_etl.R` says `synthea_version` **must**
   match the release that made the CSVs.

> **Engineering principle:** pin both sides of every contract. We pin Synthea (`v3.3.0`), the
> ETL (commit SHA), the CDM (`5.4`) and the vocabulary (`v5.0 29-AUG-26`). Change one, and you
> re-verify the contract.

### 3. Extract: staging done properly

`CreateSyntheaTables` creates one staging table per CSV, with typed columns. `LoadSyntheaTables`
reads each CSV and inserts it **unchanged** (through the OHDSI `DatabaseConnector` package).

Good staging has three properties:

| Property | Meaning | Why |
|---|---|---|
| **Lossless** | Every CSV row becomes exactly one staging row | Reconciliation starts here: CSV lines − 1 header = staging rows |
| **Typed** | Dates are dates, numbers are numbers | Bad values fail *here*, at the boundary, not deep in a transform |
| **Untransformed** | No mapping, no filtering | Staging is the evidence. If the CDM looks wrong, staging tells you whether the input was wrong |

Staging is also replaced on every run (`CreateSyntheaTables` drops and recreates it). It holds
**this** run's input, not a history. History lives in `data/synthea-output/<run-id>/` and the
run log.

### 4. Identity: from UUIDs to integer keys

OMOP keys are integers. The ETL creates them. The general pattern (read `insert_person.sql` in
the lab to confirm the exact rule your commit uses):

```sql
-- The pattern: number the source rows, keep the source key alongside.
INSERT INTO cdm.person (person_id, person_source_value, …)
SELECT ROW_NUMBER() OVER (ORDER BY p.id), p.id, …
  FROM synthea.patients p;
```

Every later script then **looks up** the integer through the stored source value. ETL-Synthea's
own documentation describes `visit_occurrence.person_id` as found by mapping
`encounters.patient` to `person.person_source_value`.

```sql
JOIN cdm.person per ON per.person_source_value = e.patient
```

Two consequences you must remember:

1. **`person_source_value` is the bridge.** Without it, nothing downstream could find its person.
   That's why OMOP keeps `*_source_value` columns: traceability *and* key resolution.
2. **Integer keys are not stable across loads.** They depend on numbering order. Regenerate,
   reload, or change the ordering, and person 42 may be a different patient. **Never** write a
   `person_id` into documentation, a test or a cohort expecting it to survive a reload. Use the
   source value (the Synthea UUID) instead.

### 5. Visits: rolling encounters up

Synthea writes **encounters**, which look like billing lines: a three-day hospital stay can
appear as several encounters, and an emergency visit that leads to admission is a separate
encounter from the admission. OMOP wants **visits**: one row per real stay or appointment.

ETL-Synthea builds the visits in three steps, in three tables: `ALL_VISITS`,
`ASSIGN_ALL_VISIT_IDS` and `FINAL_VISIT_IDS`.

| Step | Table | What happens |
|---|---|---|
| 1 | `all_visits` | Groups encounters into visits by type, using the rules below |
| 2 | `assign_all_visit_ids` | Records which **encounter** belongs to which **visit** |
| 3 | `final_visit_ids` | One chosen visit ID per encounter, which clinical rows use to find their `visit_occurrence_id` |

The grouping rules, by encounter class:

| Class | Becomes | Rule |
|---|---|---|
| `inpatient` | Inpatient visit (`9201`) | For each person, sorted by start: merge encounters while the gap between one's end and the next's start is **≤ 1 day**. Visit = `MIN(START)` to `MAX(END)` |
| `emergency`, `urgentcare` | ER visit (`9203`) | Merge ER encounters that **start on the same day** |
| `ambulatory`, `wellness`, `outpatient` | Outpatient visit (`9202`) | One visit per start, ending at `MAX(END)` |
| Any of the above *during* an inpatient stay | (absorbed) | Outpatient and ER encounters inside an inpatient visit are folded into it, unless the ER visit started and ended on the stay's first day |

This is a classic **gaps-and-islands** problem: the encounters are points on a timeline, and
you want the "islands" separated by "gaps" larger than a threshold. You'll implement it in the
lab.

> **Why it mattered in our pilot.** The immunization patch (Lesson 005) linked 23 of 26 restored
> rows to a visit. The other 3 belonged to encounters the roll-up had **absorbed** into another
> visit, so a direct `visit_source_value = encounter` lookup found nothing. A design choice in
> one node (visits) showed up as a mystery in another (immunizations). That's the DAG again.

A small design detail worth noticing: ETL-Synthea sets `visit_detail_id` to the
`visit_occurrence_id` **plus 1,000,000**. It's a cheap way to make two ID spaces that can't
collide. It works, but it quietly assumes there will never be a million visits. Questioning that
kind of assumption is part of reading other people's ETLs.

---

## Lecture 2: Routing, derived tables and engineering properties

### 6. Domain routing: one source, many destinations

In Synthea, "condition" means "something recorded as a condition". In OMOP, a row goes to the
table matching its **standard concept's domain** (Lesson 003). So the insert scripts route rows
by `target_domain_id` from `source_to_standard_vocab_map`:

```
 synthea.conditions ──map──▶ target_domain_id = 'Condition'   ──▶ cdm.condition_occurrence
                     └─────▶ target_domain_id = 'Observation' ──▶ cdm.observation
 synthea.observations ─map─▶ 'Measurement' ──▶ cdm.measurement
                     └─────▶ 'Observation' ──▶ cdm.observation
```

The consequence for reconciliation: **"staged conditions = loaded conditions" is the wrong test.**
The right test is "staged conditions = condition_occurrence + the condition-sourced share of
observation (and anything else routed elsewhere)". That's Lesson 005's lab, Part 3.

Every routed row also gets a **type concept**: *where did this record come from?* (EHR,
claim, registry …). ETL-Synthea marks its rows as EHR-derived, and our death patch used `32817`
("EHR") to match.

### 7. Derived tables: observation periods and eras

Some CDM tables have **no source rows at all**. They're computed from what's already loaded.

#### 7.1 `observation_period`

The span in which the database can "see" a person. Cohort logic depends on it heavily (Lesson
007). Synthea has no such concept, so the ETL **derives** it from the person's events. Reading
`insert_observation_period.sql` to find the exact rule is lab task 1d: you should know where
this table comes from before you trust a "365 days of prior observation" criterion.

#### 7.2 `condition_era`

A **condition era** is a span of time in which a person is assumed to have a condition,
merged from individual occurrences. The OHDSI convention:

- Group by **person** and **exact `condition_concept_id`**. Unlike drug eras, condition eras
  aren't rolled up to parent concepts.
- If an occurrence has no end date, treat it as **one day** long.
- Merge occurrences when the next one starts within **30 days** of the previous one's end (the
  **persistence window**).
- Era start = first start; era end = last end.

The OHDSI reference SQL implements this as **pad, merge, unpad**: add 30 days to every end date,
merge the overlapping intervals, then subtract 30 days from each merged end.

#### 7.3 `drug_era`

The same idea, with two differences that make it harder:

1. **Roll-up to ingredient.** A drug era is about an **active ingredient**, not a product. Each
   `drug_concept_id` is mapped up the hierarchy (`concept_ancestor`) to its RxNorm
   `Ingredient`. "Sertraline 50 mg tablet" and "sertraline 100 mg tablet" join one sertraline
   era.
2. **Unmapped drugs are excluded.** Rows with `drug_concept_id = 0` are skipped, because
   otherwise every unmapped drug would merge into one meaningless era.

The 30-day window and the "no stockpiling" assumption are **conventions**, not facts. If a study
needs a different window, the OHDSI answer is to define it as a cohort (Lesson 007), not to
change the era tables.

### 8. Engineering properties of this ETL

| Property | Question | ETL-Synthea's answer | Our mitigation |
|---|---|---|---|
| **Idempotency** | Can you run it twice and get the same result? | `LoadEventTables` expects **empty** event tables; a second run duplicates rows | Reset (`down -v`) and reload per run; our patches use `NOT EXISTS`, so they *are* idempotent |
| **Atomicity** | If it fails halfway, what's left? | Each script commits on its own; a failure leaves a **partially loaded** CDM | Treat any failed load as invalid; reload from clean. Record failures in the run log |
| **Determinism** | Same input, same output? | Same rows, but generated IDs depend on ordering (section 4) | Compare by source values, not IDs |
| **Performance** | Where does time go? | Vocabulary load (~18 min in the pilot) dominates; event inserts ~3 min | `CreateExtraIndices` before inserts; later, load vocabulary once into its own schema |
| **Observability** | Can you see what happened? | Console progress per script | `run_etl.R`'s timed `step()` wrapper; the run log |
| **Inspectability** | Can you read what will run? | Yes: SQL ships in the package, and `sqlOnly = TRUE` writes the SQL without running it | Lab 5 |

> **Set-based, not row-by-row.** Every transform in ETL-Synthea is one `INSERT … SELECT` over
> the whole table, not a loop over rows. Databases are built for set operations, which is why
> ~1,200 patients' worth of events loads in minutes. A row-by-row loop in R would take far
> longer and be harder to reason about.

### 9. Testing an ETL

No single check proves an ETL correct. Use layers, cheapest first:

| Layer | Question | Tool in this project |
|---|---|---|
| **Contract** | Did the input arrive whole and well-typed? | CSV line counts vs staging counts |
| **Reconciliation** | Did every input record end up somewhere, or get dropped *on purpose*? | Lesson 005's ladder |
| **Integrity** | Does every foreign key point at a real row? Is every `*_concept_id` standard or 0? | Lab 4 queries |
| **Conformance and plausibility** | Does the data follow CDM rules and look sane? | Data Quality Dashboard (Step 8a) |
| **Population** | Does the data say what we designed it to say? | `validate_joint.sql` (Step 8b), Achilles in ATLAS |
| **Regression** | Did an ETL or vocabulary upgrade change anything? | Compare the same run's summary counts across versions |

The strongest technique of all is a **fixture**: a tiny hand-made input (say 3 patients, 10
encounters) where you know the right output *by hand*, run through the real ETL. Synthetic
data makes this unusually easy, because you can design the edge cases.

---

## Lab (3 hours)

All queries run on `omop-db`. In DBeaver, or through
`docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'`.

### Lab 1: follow one patient end to end (40 minutes)

**1a. Pick a patient** with an inpatient encounter (so the visit roll-up has something to do):

```sql
SELECT patient, COUNT(*) AS inpatient_encounters
  FROM synthea.encounters
 WHERE encounterclass = 'inpatient'
 GROUP BY patient
 ORDER BY inpatient_encounters DESC
 LIMIT 5;
```

Write the UUID down. **Use the UUID, not a `person_id`, from now on** (section 4).

**1b. Count the patient's source rows:**

```sql
-- Replace the UUID. One row per staging table.
WITH p AS (SELECT 'PUT-UUID-HERE'::text AS id)
SELECT 'encounters'    AS src, COUNT(*) FROM synthea.encounters    WHERE patient = (SELECT id FROM p)
UNION ALL SELECT 'conditions',    COUNT(*) FROM synthea.conditions    WHERE patient = (SELECT id FROM p)
UNION ALL SELECT 'medications',   COUNT(*) FROM synthea.medications   WHERE patient = (SELECT id FROM p)
UNION ALL SELECT 'immunizations', COUNT(*) FROM synthea.immunizations WHERE patient = (SELECT id FROM p)
UNION ALL SELECT 'observations',  COUNT(*) FROM synthea.observations  WHERE patient = (SELECT id FROM p)
UNION ALL SELECT 'procedures',    COUNT(*) FROM synthea.procedures    WHERE patient = (SELECT id FROM p);
```

**1c. Resolve the key, then count the CDM rows:**

```sql
SELECT person_id FROM cdm.person WHERE person_source_value = 'PUT-UUID-HERE';

-- Replace 0 with that person_id.
SELECT 'visit_occurrence' AS tbl, COUNT(*) FROM cdm.visit_occurrence     WHERE person_id = 0
UNION ALL SELECT 'condition_occurrence', COUNT(*) FROM cdm.condition_occurrence WHERE person_id = 0
UNION ALL SELECT 'drug_exposure',        COUNT(*) FROM cdm.drug_exposure        WHERE person_id = 0
UNION ALL SELECT 'measurement',          COUNT(*) FROM cdm.measurement          WHERE person_id = 0
UNION ALL SELECT 'observation',          COUNT(*) FROM cdm.observation          WHERE person_id = 0
UNION ALL SELECT 'procedure_occurrence', COUNT(*) FROM cdm.procedure_occurrence WHERE person_id = 0
UNION ALL SELECT 'condition_era',        COUNT(*) FROM cdm.condition_era        WHERE person_id = 0
UNION ALL SELECT 'drug_era',             COUNT(*) FROM cdm.drug_era             WHERE person_id = 0
UNION ALL SELECT 'observation_period',   COUNT(*) FROM cdm.observation_period   WHERE person_id = 0;
```

**1d. Explain every difference** between 1b and 1c in one sentence each, using these sections:
roll-up (5), routing (6), derivation (7). Then answer: how is this person's
`observation_period` start and end chosen? Find the rule in `insert_observation_period.sql`
(see Lab 5 for where the SQL lives) and check it against the patient's data.

### Lab 2: visit roll-up, rebuilt by hand (40 minutes)

Implement the **inpatient** rule from section 5 yourself, as gaps-and-islands:

```sql
-- Islands of inpatient encounters for one patient: a new island starts when the gap
-- since the latest end so far is more than 1 day.
WITH ip AS (
  SELECT id, start::timestamp AS s, stop::timestamp AS e
    FROM synthea.encounters
   WHERE patient = 'PUT-UUID-HERE' AND encounterclass = 'inpatient'
), ordered AS (
  SELECT *,
         MAX(e) OVER (ORDER BY s, e ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
    FROM ip
), flagged AS (
  SELECT *,
         CASE WHEN prev_max_end IS NULL OR s > prev_max_end + INTERVAL '1 day' THEN 1 ELSE 0 END AS new_island
    FROM ordered
), islands AS (
  SELECT *, SUM(new_island) OVER (ORDER BY s, e ROWS UNBOUNDED PRECEDING) AS island
    FROM flagged
)
SELECT island, MIN(s) AS visit_start, MAX(e) AS visit_end, COUNT(*) AS encounters
  FROM islands
 GROUP BY island
 ORDER BY island;
```

1. Read the query and explain each CTE in a comment. Why `MAX(e)` over all *previous* rows,
   rather than just the previous row's `e`? (Hint: a long stay can contain a shorter one.)
2. Compare your islands with the patient's inpatient rows in `cdm.visit_occurrence`
   (`visit_concept_id = 9201`). Same count? Same dates?
3. If they differ, find out why in `AllVisitTable.sql`. Don't guess.

### Lab 3: condition eras, rebuilt by hand (40 minutes)

Implement section 7.2 for **all** persons, then compare with the ETL's table:

```sql
WITH ev AS (
  SELECT person_id,
         condition_concept_id AS concept_id,
         condition_start_date AS s,
         COALESCE(condition_end_date, condition_start_date + 1) AS e   -- no end date = 1 day
    FROM cdm.condition_occurrence
   WHERE condition_concept_id <> 0
), ordered AS (
  SELECT *,
         MAX(e) OVER (PARTITION BY person_id, concept_id ORDER BY s, e
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_end
    FROM ev
), flagged AS (
  SELECT *,
         CASE WHEN prev_max_end IS NULL OR s > prev_max_end + 30 THEN 1 ELSE 0 END AS new_era
    FROM ordered
), eras AS (
  SELECT person_id, concept_id,
         SUM(new_era) OVER (PARTITION BY person_id, concept_id ORDER BY s, e ROWS UNBOUNDED PRECEDING) AS era_no,
         s, e
    FROM flagged
)
SELECT COUNT(*) AS my_eras,
       (SELECT COUNT(*) FROM cdm.condition_era) AS etl_eras
  FROM (SELECT person_id, concept_id, era_no FROM eras GROUP BY 1, 2, 3) x;
```

1. **Predict first**: will your count be higher, lower or equal? Write it down.
2. If the counts differ, find a person/concept where they differ and compare the dates. Is the
   difference about the boundary (exactly 30 days apart?), about end dates, or about which rows
   were included?
3. Which one is "right"? (Careful: both may be valid readings of the convention. Say which
   assumption each makes.)

### Lab 4: integrity audit (30 minutes)

Write one query per check. Each should return **0**. Run them and record the results.

```sql
-- 4a. Orphans: clinical rows whose person doesn't exist.
SELECT COUNT(*) FROM cdm.condition_occurrence co
 WHERE NOT EXISTS (SELECT 1 FROM cdm.person p WHERE p.person_id = co.person_id);

-- 4b. Dangling visits: a visit_occurrence_id that points nowhere.
SELECT COUNT(*) FROM cdm.drug_exposure de
 WHERE de.visit_occurrence_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM cdm.visit_occurrence v WHERE v.visit_occurrence_id = de.visit_occurrence_id);

-- 4c. Non-standard concepts in a *_concept_id field (should be standard, or 0).
SELECT COUNT(*) FROM cdm.condition_occurrence co
  JOIN cdm.concept c ON c.concept_id = co.condition_concept_id
 WHERE co.condition_concept_id <> 0 AND c.standard_concept IS DISTINCT FROM 'S';

-- 4d. Events outside every observation period.
SELECT COUNT(*) FROM cdm.condition_occurrence co
 WHERE NOT EXISTS (SELECT 1 FROM cdm.observation_period op
                    WHERE op.person_id = co.person_id
                      AND co.condition_start_date BETWEEN op.observation_period_start_date
                                                      AND op.observation_period_end_date);
```

Then:
1. Extend 4a–4d to two more tables of your choice (DRY: could you generate these queries
   from a list of table names?).
2. Check whether the database **enforces** any of this: `\d cdm.condition_occurrence`. Are there
   foreign key constraints? If not, why might an ETL load without them and check afterwards?
3. Do our **patches** pass these checks? (The death patch inserts `cause_concept_id = 0` rows;
   the immunization patch inserts rows with and without visits.)

### Lab 5: read the machine (30 minutes)

**5a. Find the SQL.** It ships inside the image:

```bash
docker compose --profile etl run --rm --entrypoint sh etl -c \
  'ls "$(Rscript -e "cat(system.file(\"sql/sql_server/cdm_version/v540\", package=\"ETLSyntheaBuilder\"))")"'
```

Open `insert_person.sql`, `insert_observation_period.sql` and `AllVisitTable.sql`
(use `cat` with the same path). For each, write three lines: input tables, output table, and
the one rule that matters most.

**5b. Generate without running.** `CreateMapAndRollupTables` and `LoadEventTables` accept
`sqlOnly = TRUE`, which writes the translated PostgreSQL to files instead of executing it.
Write a short R script (a copy of `run_etl.R` that only calls these two with `sqlOnly = TRUE`)
and look at what's produced. Why is this useful **before** upgrading the ETL to a new commit?

---

## Check your understanding

1. Why must `syntheaVersion` match the release that made the CSVs? What's the worst case if it doesn't?
2. Name three properties of good staging, and what each buys you.
3. You find `person_id = 42` in last month's notes. Can you look up the same patient today? What should the notes have recorded instead?
4. Why is visit roll-up a gaps-and-islands problem? What are the gap thresholds for inpatient and ER encounters?
5. Staged conditions: 10,000. `condition_occurrence`: 9,400. Is something wrong? What do you check first?
6. Why does `drug_era` roll up to ingredients, but `condition_era` doesn't roll up to parent concepts?
7. `LoadEventTables` fails on `insert_measurement.sql`. Which tables can you trust, and what do you do?
8. Why does an ETL often load without foreign key constraints and check integrity afterwards?
9. What does `sqlOnly = TRUE` give you, and when would you use it?

<details>
<summary><strong>Answers</strong></summary>

1. Synthea's columns change between releases; the ETL's staging DDL and SQL assume one release's
   layout. Worst case isn't an error: it's columns read into the wrong fields **without** an
   error, producing plausible-looking wrong data.
2. Lossless (exact row reconciliation from CSV), typed (bad input fails at the boundary),
   untransformed (staging is evidence of what arrived, so you can tell input errors from ETL errors).
3. No, not reliably: integer keys are generated per load and can change. The notes should have
   recorded `person_source_value` (the Synthea UUID), which is stable for that generated dataset.
4. Encounters are intervals on a timeline; a visit is a run of encounters with no gap above a
   threshold (an "island"). Inpatient: merge while the gap is ≤ 1 day. ER: merge encounters
   starting on the same day.
5. Not necessarily. Domain routing sends some source conditions to `observation` (or other
   tables). First check where the other 600 went (Lesson 005's ladder, rung 2), *then* decide
   whether anything was dropped.
6. The question a drug era answers is "exposed to this **active ingredient**", so products must
   be combined. Condition concepts at different levels of the hierarchy mean different clinical
   things, so condition eras keep the exact concept.
7. Everything upstream of measurement in the DAG (person, visits, conditions loaded before it) is
   intact; measurement and everything after it is missing or partial. Because the ETL isn't
   idempotent, the safe action is to reset and reload from clean, recording the failure.
8. Constraint checks slow bulk loads and force a strict load order. Loading first and auditing
   with queries (Lab 4) is faster, and still catches violations, as long as you actually run
   the audit.
9. The exact SQL the ETL would run on your database dialect, without changing any data. Use it
   to review the logic, to diff two ETL versions before upgrading, or to run steps by hand while
   debugging.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Data contract** | The agreed shape (files, columns, types, keys, meanings) of data crossing a boundary |
| **Staging** | A lossless, typed, untransformed copy of the input, kept as evidence |
| **Surrogate key** | A generated identifier (integer) with no meaning outside the database |
| **Natural / source key** | The identifier from the source system (Synthea's UUID), kept in `*_source_value` |
| **DAG** | Directed acyclic graph: the dependency order of ETL steps |
| **Visit roll-up** | Merging encounters into visits by class and time gaps |
| **Gaps and islands** | Grouping ordered intervals into runs separated by gaps above a threshold |
| **Domain routing** | Sending each row to the CDM table matching its standard concept's domain |
| **Type concept** | Records where a row came from (EHR, claim, registry …) |
| **Persistence window** | Max gap (30 days by convention) for merging events into one era |
| **Idempotent** | Running twice gives the same result as running once |
| **Atomic** | All-or-nothing; a failure leaves no partial result |
| **Fixture** | A small, hand-designed input with a known correct output, used for testing |

---

## Further reading

- **The Book of OHDSI**, chapter 6 (Extract Transform Load): <https://ohdsi.github.io/TheBookOfOhdsi/ExtractTransformLoad.html>
- **ETL-Synthea documentation**, per-table mapping specs: <https://ohdsi.github.io/ETL-Synthea/>
- **OHDSI ETL tutorial**, Synthea visit occurrence mapping: <https://ohdsi.github.io/Tutorial-ETL/cdm_synthea_v2/Visit_occurrence.html>
- **OMOP CDM 5.4** documentation and conventions (eras, observation periods): <https://ohdsi.github.io/CommonDataModel/>
- **Synthea CSV data dictionary**: <https://github.com/synthetichealth/synthea/wiki/CSV-File-Data-Dictionary>
- **OHDSI Forums: drug era persistence window**, for the reasoning behind the 30 days: <https://forums.ohdsi.org/t/where-does-gap-days-come-from-when-building-cdm-v5-drug-era/661>
- **Kleppmann, *Designing Data-Intensive Applications***, chapter 10 (batch processing). The general theory behind pipelines like this one.
- **Gaps and islands**: search for "gaps and islands SQL window functions"; it's a standard interview and analytics pattern worth knowing well.
