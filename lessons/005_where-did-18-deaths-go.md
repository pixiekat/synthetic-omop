# Lesson 005: Where Did 18 Deaths Go? Reconciling Counts Through an ETL

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | 90 minutes (case study + lab) |
| **Prerequisites** | Lessons 001–004; SQL with `JOIN`, `GROUP BY`, `LEFT JOIN` |
| **Project files** | `services/etl/sql/patch_missing_deaths.sql`, `services/etl/sql/patch_missing_immunizations.sql`, `docs/run-log.md`, `docs/assumptions.md` |
| **Previous lesson** | 004: Deep Dive into NSDUH, Synthea, Athena and the ETL |

> This lesson is a **true story**. Every number, query and result below comes from the
> project's pilot load (`pilot-0001`), in the order things actually happened, including the
> prediction that turned out to be wrong.

## Learning objectives

By the end of this lesson you should be able to:

1. Explain why **"zero unmapped"** doesn't prove an ETL lost nothing.
2. **Reconcile** record counts across the stages of a pipeline: source → staging → CDM.
3. Narrow a gap down by **splitting it into groups** until each group has a single cause.
4. Use the **predict → test → read the source** loop, and treat a failed prediction as information.
5. Recognise six common **failure modes** of vocabulary-based ETLs, and the query that reveals each one.
6. Write a **responsible patch**: no guessed mappings, original values kept, safe to rerun, tested, documented.
7. Write the result up so others can **reproduce** it: run log, assumption IDs, an upstream issue.

---

## 0. The trap

After the first successful ETL run, two checks looked perfect:

```sql
SELECT COUNT(*) FILTER (WHERE drug_concept_id = 0) AS unmapped,
       COUNT(*)                                     AS total
  FROM cdm.drug_exposure;
-- unmapped = 0, total = 28,265
```

**Zero unmapped drugs.** But Synthea had produced **2,711 immunizations**, and 28,265 was
*exactly* the number of medications. None of the immunizations were there.

That's the trap this lesson is about:

> An ETL that maps an unknown code to `0` leaves a **visible** gap.
> An ETL that **drops** the row leaves **no trace**: the unmapped count stays at zero.
> **Only comparing counts between stages reveals a drop.**

---

## 1. The method: a reconciliation ladder

Work down the ladder, one rung at a time. Stop going down once a rung explains everything.

| Rung | Question | Typical query |
|---|---|---|
| **1. Totals** | Does the count survive each stage (CSV → staging → CDM)? | `COUNT(*)` on each side |
| **2. Groups** | The gap: does it split into groups with different causes? | `GROUP BY` a property (has an encounter? which code?) |
| **3. Codes** | Within a group: which codes are affected? | Per-code staged vs loaded, `LEFT JOIN`, `WHERE` counts differ |
| **4. Vocabulary** | For each code: does it exist, is it standard, does it map, where to? | `concept`, `concept_relationship`, Athena |
| **5. Source** | What does the ETL code actually do with it? | Read the SQL |

Around the ladder runs a loop:

```
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │  Observe a  │ ──▶ │ Hypothesise │ ──▶ │   Predict   │
   │     gap     │     │   a cause   │     │ a number    │
   └─────────────┘     └─────────────┘     └──────┬──────┘
          ▲                                       │
          │          ┌─────────────┐              ▼
          └───────── │  Compare:   │ ◀──── run the test
   (wrong? new info) │ right/wrong │
                     └─────────────┘
```

**Predicting a specific number before you run the test is what makes the loop work.** "It'll
be about right" can't be wrong, so it can't teach you anything. "It'll be 160" can.

---

## 2. Case 1: the 18 missing deaths

### Act 1: the gap (rung 1)

```sql
SELECT (SELECT COUNT(*) FROM synthea.patients WHERE deathdate IS NOT NULL) AS deceased_in_synthea,
       (SELECT COUNT(*) FROM cdm.death)                                    AS rows_in_cdm_death;
-- 175 vs 157
```

Synthea recorded **175** deaths. The CDM held **157**. **18** were missing.

### Act 2: split the gap (rung 2)

First question: did those 18 patients even have the encounter the ETL builds deaths from
(the **death-certification encounter**, SNOMED `308646001`)?

| Missing patients | Death-cert encounter? |
|---|---|
| **8** | No |
| **10** | Yes, one each |

**Two groups, so at least two causes.** The 8 had nothing to build a row from. The 10 needed
a closer look.

### Act 3: the 10 (rung 3)

Every death-cert encounter carries the cause of death. For the 10:

| Cause code | Description | Count | Source concept | Standard? | Maps to |
|---|---|---|---|---|---|
| `55680006` | Drug overdose | 7 | 4208104 | No | *(none)* |
| `94260004` | Secondary malignant neoplasm of colon | 3 | 4311765 | No | *(none)* |

Both causes **exist** in the vocabulary, but neither is standard, and neither maps to one.

> In an SUD project, the death type dropped most was **drug overdose**. A study of mortality
> in this cohort would have undercounted exactly the outcome that matters most.

### Act 4: two different reasons (rung 4)

Looking at each concept's status and relationships:

| Code | `invalid_reason` | What we found | Diagnosis |
|---|---|---|---|
| `55680006` | **D** (retired 2021-07-31) | Only weak hints: `Concept poss_eq to` "Overdose", `Subsumes` "Overdose of opiate" | **Retired code.** SNOMED moved on; Synthea's module didn't |
| `94260004` | *(valid)* | A `Maps to value → Positive`, but **no `Maps to`** | Something's **missing** |

A `Maps to value` with no `Maps to` is incomplete. The value is meant to *qualify* a mapping.
The concept's page on Athena showed the missing half:

```
Non-standard to Standard map (OMOP)  →  35226112 "Metastasis to colon"   Cancer Modifier
```

The target was in **Cancer Modifier**, a vocabulary not in the first download. Athena leaves
out any relationship that points into a vocabulary you didn't select. **Diagnosis: a download gap.**

### Act 5: the fix that didn't fix it (the loop)

Hypothesis: adding Cancer Modifier fixes the 3 metastasis deaths.

**Prediction: `cdm.death` = 157 + 3 = 160.**

The vocabulary was re-downloaded with Cancer Modifier (and CVX, see Case 2), and the ETL rerun.

**Observed: 157.** The prediction was wrong.

That wrong number was the most useful result of the investigation, because it ruled the
hypothesis out cleanly. Something *else* was dropping them. Checking ETL-Synthea's own lookup table:

```
source_code 94260004 → target_concept_id 35226112   target_vocabulary Cancer Modifier   target_domain Measurement
```

The mapping now existed. So the drop had to be in the script that **uses** the lookup.

### Act 6: read the source (rung 5)

```bash
docker compose --profile etl run --rm --entrypoint sh etl -c \
  'f=$(Rscript -e "cat(system.file(\"sql\", package=\"ETLSyntheaBuilder\"))"); \
   find "$f" -name "insert_death.sql" | xargs grep -n -i -E "domain|join"'
```

```
30:  join @cdm_schema.source_to_standard_vocab_map srctostdvm
32:   and srctostdvm.target_domain_id        = 'Condition'
33:   and srctostdvm.source_domain_id        = 'Condition'
```

An **inner join**, plus a filter that keeps only causes whose standard concept is in the
**Condition** domain. "Metastasis to colon" is a **Measurement**, so it fails the filter.
Everything that fails is dropped, not kept with `0`.

### The complete account

| Group | Count | Root cause | Confirmed by |
|---|---|---|---|
| No death-cert encounter | 8 | Nothing for the inner join to match | Rung 2 query |
| Drug overdose `55680006` | 7 | Retired code: no standard mapping exists | Concept status (rung 4) |
| Colon metastasis `94260004` | 3 | Maps to a Measurement; script requires Condition | Lookup table + source (rung 5) |

**Fix:** `patch_missing_deaths.sql` (section 5 covers the rules it follows). Result: `INSERT 0 18`, totals **175 / 175**;
the 3 metastasis deaths carry `cause_concept_id = 35226112`, and the 7 overdoses carry `0`.

---

## 3. Case 2: the immunizations

### Act 1: the gap, hidden by "0 unmapped"

From section 0: `drug_exposure` held 28,265 rows with 0 unmapped. Rung 1 told the real story:

| Staged medications | Staged immunizations | `drug_exposure` rows |
|---|---|---|
| 28,265 | 2,711 | **28,265** |

Every immunization was missing. The vocabulary list confirmed why: **CVX**, the vocabulary
Synthea uses for vaccines, wasn't in the bundle. With no CVX concepts, nothing could match, and
the inner join dropped them all.

### Act 2: reload, mostly fixed

With CVX added: **2,685 of 2,711.** Ninety-nine percent fixed. Rather than stopping, we went
down to rung 3: which codes are still short?

```sql
WITH staged AS (
  SELECT code, MAX(description) AS description, COUNT(*) AS n
    FROM synthea.immunizations GROUP BY code
), loaded AS (
  SELECT drug_source_value AS code, COUNT(*) AS n
    FROM cdm.drug_exposure GROUP BY drug_source_value
)
SELECT s.code, s.description, s.n AS staged, COALESCE(l.n, 0) AS in_cdm
  FROM staged s
  LEFT JOIN loaded l USING (code)
 WHERE COALESCE(l.n, 0) <> s.n;
```

| Code | Vaccine | Staged | In CDM |
|---|---|---|---|
| `3` | MMR | 6 | 0 |
| `8` | Hep B, pediatric | 2 | 0 |
| `207` | COVID-19 mRNA | 8 | 0 |
| `208` | COVID-19 mRNA | 10 | 0 |

6 + 2 + 8 + 10 = **26**: the whole remaining gap, and again in two groups.

### Act 3: two more causes

**Codes `3` and `8`: a format mismatch.** The CVX vocabulary writes these codes as **`03`** and
**`08`**. Synthea writes `3` and `8`. Codes are **text**, so `'3' = '03'` is false. The concepts
were there all along; the lookup just couldn't find them.

> ETL-Synthea's lookup table also has `source_code = '3'` rows for **Race** ("Black or African
> American"), SOPT, UB04 and others. The ETL restricts the lookup to CVX, so `3` never matched
> the wrong thing. That's Lesson 003's point in practice: codes are only unique *within* a vocabulary.

**Codes `207` and `208`: a vocabulary filter.** These *do* map, to Drug-domain concepts in
**RxNorm**. Reading the source:

```
127: and srctostdvm.target_vocabulary_id    = 'CVX'
```

The immunization section only accepts targets that are **themselves CVX**. In current
vocabulary releases, the COVID vaccine codes map to RxNorm instead, so the filter rejects them.

**Fix:** `patch_missing_immunizations.sql`. Result: `INSERT 0 26`, all 2,711 accounted for,
23 of the 26 linked to a visit.

---

## 4. Patterns: six ways an ETL loses records

Both cases came down to these, and you'll meet them again in real hospital data:

| Failure mode | Symptom | How to detect it | Pilot example |
|---|---|---|---|
| **Missing source record** | Whole rows absent | Rung 2: does the record the ETL builds from exist? | 8 deaths, no death-cert encounter |
| **Missing vocabulary** | A whole code family absent | `VOCABULARY.csv`; `Maps to value` without `Maps to` | CVX; Cancer Modifier |
| **Retired code** | Code exists but has no `Maps to` | `invalid_reason = 'D'` | `55680006` Drug overdose |
| **Domain filter** | Maps correctly, still dropped | Lookup table's `target_domain_id` vs the script's filter | Metastasis → Measurement |
| **Vocabulary filter** | Maps correctly, still dropped | Lookup table's `target_vocabulary_id` vs the script's filter | COVID → RxNorm |
| **Format mismatch** | Concept exists, never matched | Compare code formats: lengths, leading zeros, case, whitespace | `3` vs `03` |

Notice that **three of the six are in the ETL code**, not the data or the vocabulary. And
all six share one root: **an inner join where a left join was needed.**

---

## 5. Fixing it responsibly

A patch changes data, so it needs rules. Both of the project's patches follow them:

| Rule | Why | In the patches |
|---|---|---|
| **Never guess a mapping** | A wrong concept is worse than a visible `0` | Unmappable → `concept_id = 0`; candidates go to terminology review (A-006) |
| **Keep the original value** | Traceability: anyone can see what was recorded | `cause_source_value`, `drug_source_value` keep Synthea's codes (`3`, not `03`) |
| **Don't modify staging** | Staging is the record of what arrived (Lesson 001) | Codes are padded only *during the lookup* |
| **Safe to rerun** | Patches get run twice by accident | `WHERE NOT EXISTS (…)`: a second run inserts nothing |
| **Test before running for real** | Patches are code, and code has bugs | Tested on a mock CDM; it caught `LPAD('207', 2, '0')` returning `'20'` |
| **Document it** | A patch is a deviation from the standard ETL | Assumption IDs (A-005, A-008), run log entries, README sections |
| **Report upstream** | Fixing it at the source helps everyone | The confirmed lines and queries make a complete issue report |

### When *not* to patch

Not every gap needs a patch. Ask:
- **Is it legitimate?** Some counts *should* differ: a source "condition" that maps to an
  Observation lands in `observation`, not `condition_occurrence` (Lesson 003, section 4).
- **Is a mapping decision needed?** If fixing it means choosing a concept, it's a terminology
  question first, not a code change.
- **Is it worth it?** Sometimes documenting a known residual (e.g. "26 immunizations,
  causes known") is the right call for a pilot. Write it down either way.

---

## 6. Writing it up

### In the run log

Record the *measurements*, not the story: counts before and after, what each patch inserted, the
remaining residuals, and the ETL version (line numbers belong to a specific commit). See the
`pilot-0001 / Load 2` entry in `docs/run-log.md`.

### As an upstream issue

A good issue lets a maintainer **reproduce the problem in minutes**. A shape that works:

```markdown
**Summary:** insert_death.sql drops deaths whose cause doesn't map to a Condition-domain concept

**Versions:** ETL-Synthea <commit SHA>, CDM 5.4, Synthea v3.3.0, vocabulary v5.0 29-AUG-26
(defaults + CVX + Cancer Modifier)

**Expected:** every deceased patient in synthea.patients has a row in cdm.death; unmapped causes
use cause_concept_id = 0 (OMOP convention).

**Actual:** 175 deceased → 157 rows. 18 dropped: 8 with no death-certification encounter,
7 with a retired cause (SNOMED 55680006), 3 with a cause mapping to Cancer Modifier (Measurement).

**Cause:** inner join + domain filter, cdm_version/v540/insert_death.sql lines 30–33:
    and srctostdvm.target_domain_id = 'Condition'
    and srctostdvm.source_domain_id = 'Condition'

**Reproduction:** <the rung 1–3 queries from this lesson>

**Suggested fix:** LEFT JOIN with COALESCE(target_concept_id, 0); keep cause_source_value.
```

---

## Lab: reconcile something new

You've seen deaths and immunizations. Now apply the ladder to tables we **didn't** check.

### Part 1: predict first (5 minutes)

Before running anything, write down:
- Will `cdm.condition_occurrence` hold **more**, **fewer** or **the same** number of rows as `synthea.conditions`? Why?
- Will `cdm.procedure_occurrence` hold all of `synthea.procedures`? (Hint: CPT4 wasn't merged.)

### Part 2: rung 1, totals (10 minutes)

```sql
SELECT 'conditions' AS source, (SELECT COUNT(*) FROM synthea.conditions) AS staged,
       (SELECT COUNT(*) FROM cdm.condition_occurrence)                    AS condition_occurrence,
       (SELECT COUNT(*) FROM cdm.observation)                             AS observation,
       (SELECT COUNT(*) FROM cdm.measurement)                             AS measurement
UNION ALL
SELECT 'procedures', (SELECT COUNT(*) FROM synthea.procedures),
       (SELECT COUNT(*) FROM cdm.procedure_occurrence), NULL, NULL;
```

Compare with your predictions. Remember that a source condition can **legitimately** land in
another table, depending on its standard concept's domain.

### Part 3: rung 3, codes that didn't land anywhere (20 minutes)

```sql
-- Condition codes whose staged count isn't matched across the three tables they could land in.
-- Heuristic: observation and measurement also hold Synthea observations (mostly LOINC),
-- so a matching count doesn't *prove* nothing was lost. A shortfall is still worth a look.
WITH staged AS (
  SELECT code, MAX(description) AS description, COUNT(*) AS n
    FROM synthea.conditions GROUP BY code
), landed AS (
  SELECT condition_source_value AS code, COUNT(*) AS n FROM cdm.condition_occurrence GROUP BY 1
  UNION ALL
  SELECT observation_source_value, COUNT(*) FROM cdm.observation GROUP BY 1
  UNION ALL
  SELECT measurement_source_value, COUNT(*) FROM cdm.measurement GROUP BY 1
)
SELECT s.code, s.description, s.n AS staged, COALESCE(SUM(l.n), 0) AS landed
  FROM staged s
  LEFT JOIN landed l USING (code)
 GROUP BY s.code, s.description, s.n
HAVING COALESCE(SUM(l.n), 0) < s.n
 ORDER BY s.n - COALESCE(SUM(l.n), 0) DESC
 LIMIT 20;
```

### Part 4: rungs 4–5 (20 minutes)

Pick the biggest shortfall from Part 3 (or from procedures).
1. Look the code up: exists? standard? retired? `Maps to` where, which domain? (Lesson 003 Query 4)
2. Check its row in `cdm.source_to_standard_vocab_map`.
3. Read the relevant `insert_*.sql` for its join and filters (Lesson 004, Part D).
4. Name the failure mode from section 4.

### Part 5: write it up (10 minutes)

In five lines or fewer: the gap, the cause, the evidence, and whether it needs a patch, a
terminology decision, or just a note in the run log.

---

## Check your understanding

1. `drug_exposure` shows 0 unmapped rows. Why isn't that enough to say no drugs were lost?
2. Why split a gap into groups *before* looking at individual codes?
3. You predicted 160 deaths and observed 157. What did that tell you that "about right" wouldn't have?
4. A concept has `Maps to value` but no `Maps to`. What's the first thing to check?
5. Why did `3` fail to match CVX, and why didn't it accidentally match the Race concept with code `3`?
6. The patch stores `drug_source_value = '3'`, not `'03'`. Why?
7. Why should a patch use `WHERE NOT EXISTS`?
8. Give one case where counts differ between staging and a CDM table, and nothing is wrong.

<details>
<summary><strong>Answers</strong></summary>

1. An ETL can **drop** rows instead of mapping them to `0`. Dropped rows never appear as
   unmapped. Only comparing staged and loaded counts reveals them.
2. A single gap can have **several causes**. Grouping (e.g. by "has a death-cert encounter")
   separates them, so each group can be explained on its own.
3. It **ruled the hypothesis out**: the missing vocabulary wasn't the only cause. That pointed
   to the script that uses the mapping, which is where the domain filter was found.
4. Whether the `Maps to` target is in a **vocabulary you didn't download**: look the concept up
   on Athena and check which vocabulary its `Maps to` points into.
5. Codes are text, and CVX writes `03`. The lookup is restricted to `source_vocabulary_id = 'CVX'`,
   so the Race vocabulary's `3` was never considered.
6. **Traceability**: `_source_value` records what the source actually said. The padding is a
   lookup detail, not a fact about the data.
7. So running it twice doesn't insert duplicates: it only inserts records that aren't already there.
8. A source condition whose standard concept is in the **Observation** or **Measurement**
   domain lands in that table, not `condition_occurrence`. It's moved, not lost.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Reconciliation** | Comparing record counts across pipeline stages to find what was lost or moved |
| **Silent drop** | A record removed by an ETL without leaving an unmapped (`0`) row behind |
| **Reconciliation ladder** | Totals → groups → codes → vocabulary → source, stopping when explained |
| **Hypothesis-driven debugging** | Predict a specific result, test it, learn from mismatches |
| **Inner join** | Keeps only matching rows: the root of every silent drop in this lesson |
| **Domain / vocabulary filter** | A hard-coded condition in ETL code about what a valid target looks like |
| **Format mismatch** | The same code written differently (`3` vs `03`), so text comparison fails |
| **Patch** | A documented, tested, rerunnable fix applied after the standard ETL |
| **Residual** | A known, explained gap left in place and recorded |
| **Upstream** | The original project (here, OHDSI/ETL-Synthea) where a fix helps everyone |

---

## Further reading

- **The Book of OHDSI**, chapter 15 (Data Quality): <https://ohdsi.github.io/TheBookOfOhdsi/>
- **Data Quality Dashboard**, automated conformance, completeness and plausibility checks:
  <https://ohdsi.github.io/DataQualityDashboard/>
- **Achilles**, database characterization: record counts per concept, per table:
  <https://ohdsi.github.io/Achilles/>
- **ETL-Synthea** source and issues: <https://github.com/OHDSI/ETL-Synthea>
- The project's own **`docs/run-log.md`** (pilot-0001) and **README Step 7** sections 7a–7c,
  which this lesson narrates.
