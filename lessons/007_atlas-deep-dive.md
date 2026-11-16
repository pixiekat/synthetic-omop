# Lesson 007: ATLAS Deep Dive: From Cohort Logic to SQL

| | |
|---|---|
| **Course level** | First to second year undergraduate (upper end) |
| **Estimated time** | 2 × 75 minutes (two sessions: definitions, then analyses) |
| **Prerequisites** | Lesson 006; Lesson 003 (hierarchies, `concept_ancestor`); comfortable reading SQL |
| **Project files** | README Step 9; `results` schema; your `MHD (course)` and `SUD (course)` concept sets from Lesson 006 |
| **Previous lesson** | 006: Introduction to ATLAS |
| **Next lesson** | 008: Our ATLAS Setup and the UI |

## Learning objectives

By the end of this lesson you should be able to:

1. Build a cohort definition that answers all four questions (entry, inclusion, exit, eras), and justify each choice.
2. Explain the difference between **qualifying criteria on the entry event** and **inclusion rules**, and why it changes the attrition report.
3. Choose an **exit strategy** and an **era collapse gap**, and predict how each changes the row count in `results.cohort`.
4. Read an **inclusion (attrition) report** and say which rule removed whom.
5. Export a definition as **JSON** and **SQL**, and find each part of your definition in the SQL.
6. Explain what Characterization, Incidence Rates and Cohort Pathways compute, and what each needs as input.
7. Say why a cohort definition is a **hypothesis**, and name tools for evaluating it.

---

## Session 1: Cohort definitions

### 1. The person timeline

Every rule in a cohort definition is a statement about *time*, relative to one person's
**observation period** (the span in which the database can see them):

```
 observation_period_start                                        observation_period_end
 │                                                                                    │
 ├──── prior observation ────┤ ENTRY (index date) ├──── cohort membership ────┤ EXIT │
 │   "≥365 days before"      │  e.g. 1st MHD dx   │                           │      │
 │                           │                    │  inclusion rules look      │      │
 │  inclusion rules look ◀───┘                    └──▶ forward from index too  │      │
 │  back from the index date                                                  │      │
```

The **index date** is the date of the entry event. Almost every other setting is written as
"N days before / after index".

### 2. Question 1: entry events

The **Cohort Entry Events** box says which events can start membership.

| Setting | Options | What it controls |
|---|---|---|
| **Event type** | Condition occurrence, drug exposure, measurement, visit, observation period … | Which CDM table is searched |
| **Concept set** | e.g. `MHD (course)` | Which concepts count |
| **Attributes** on the event | *First occurrence in history*, age at occurrence, gender, visit type, value ranges … | Filters on the event row itself |
| **Observation window** | Continuous observation N days before and M days after the event | Requires the person to be *visible* around the index |
| **Limit primary events to** | All events / earliest / latest, per person | How many index dates a person can have |

Two traps:

- **"First occurrence in history"** (an attribute) is not the same as **"earliest event"** (the
  limit). The first means "this is the first time *ever*, in the whole record"; the second means
  "of the events that passed the filters, keep the earliest". With prior-observation
  requirements they can disagree.
- An **observation window** silently drops people whose diagnosis falls near the start of their
  record. In Synthea data, histories are long, so this rarely bites; in real claims data it
  removes a lot of people.

### 3. Question 2: inclusion criteria, in two places

ATLAS offers criteria in **two different places**, and the difference matters:

| | **Additional qualifying criteria** (inside entry) | **Inclusion rules** (separate, named) |
|---|---|---|
| Applied | Before the qualifying-event limit | After, one rule at a time |
| Reported | Not shown separately | Each rule gets its own line in the **attrition report** |
| Use for | Defining *which events* count | Restrictions you want to **see the effect of** |

**Recommendation:** put clinical restrictions you might be asked about ("how many did the
age rule remove?") in **named inclusion rules**. Transparency beats compactness.

Each rule is built from **criteria groups**:

- **with at least / exactly / at most N** occurrences of a concept set,
- in a **time window** relative to index (e.g. *between 365 days before and 0 days after*),
- optionally **restricted to the same visit**,
- combined with **ALL / ANY / AT LEAST N** of the group.

"Exactly 0" is how you write an **exclusion**: "with exactly 0 occurrences of *prior SUD
treatment* in the 365 days before index".

### 4. Question 3: exit

| Exit strategy | Membership ends at … | Good for |
|---|---|---|
| **End of continuous observation** (default) | The end of the observation period that contains the index | Chronic conditions |
| **Fixed duration** | Index (or end of the event) + N days | Acute episodes ("30 days after a visit") |
| **End of continuous drug exposure** | When drug exposures stop, allowing a **persistence window** gap | Treatment cohorts |

Optional **censoring events** end membership early (e.g. death, or a new diagnosis).

### 5. Question 4: eras

After exit dates are set, a person may have overlapping or nearby periods. The **era collapse
gap** (in days) merges periods closer than the gap into one era.

| Gap | Effect on `results.cohort` |
|---|---|
| 0 | Only overlapping/touching periods merge: more rows per person |
| 30 | Periods less than 30 days apart merge: fewer, longer rows |

> **Predict before you run (the Lesson 005 habit).** Before generating, write down whether the
> cohort will have *more rows than persons*, *equal* or *fewer*. "Fewer" is impossible, and
> working out why is a good exercise.

### 6. From definition to SQL

When you press **Generate**, this happens:

```
 Your definition (JSON)              stored by WebAPI
        │
        ▼  Circe (circe-be): JSON → OHDSI SQL
        ▼  SqlRender: OHDSI SQL → PostgreSQL dialect, with our schema names
        ▼  WebAPI runs it as a background job on the CDM (source SYNTH_OMOP)
        │
        ├──▶ results.cohort                     (who, from when, to when)
        ├──▶ results.cohort_inclusion_result    (which rules each person passed, as a bitmask)
        ├──▶ results.cohort_inclusion_stats     (per-rule counts)
        └──▶ results.cohort_summary_stats       (totals, used by the attrition report)
```

Two consequences:

1. **The JSON is the definition.** The SQL is *derived* from it. When you share a cohort, share
   the JSON (Export tab); anyone can regenerate the SQL for their own database dialect.
2. **The SQL is readable.** The Export → SQL tab shows exactly what will run. It's long
   (temporary tables for each step), but each block corresponds to a box in the editor. In the
   lab you'll find yours.

### 7. Reading the attrition report

After generation, the **Reporting** tab shows the inclusion report: the starting count, then
each inclusion rule in order with how many people **passed**, and the final count. Read it the
way you read the reconciliation ladder in Lesson 005: every drop needs an explanation you
can state in one sentence. A rule that removes nobody is either redundant or wrong.

---

## Session 2: Analyses built on cohorts

Every analysis below takes **generated cohorts** as input. Generate first, analyse second.

### 8. Characterization

Describes the people in one or more cohorts: demographics, conditions, drugs, procedures,
measured in windows around the index date (e.g. "conditions recorded in the 365 days before
entry"). The building blocks are **feature analyses**. ATLAS ships presets, and you can write
your own.

Use it to answer "who is in this cohort?". It's also the quickest **plausibility check** on a
definition: if your MHD cohort's most common prior condition is something unrelated, the
definition is probably wrong.

### 9. Incidence rates

Counts *new* outcomes in a **target** cohort during a **time at risk (TAR)**:

```
                        people with a new outcome during TAR
 Incidence proportion = ────────────────────────────────────
                            people in the target cohort

                        new outcomes during TAR
 Incidence rate       = ───────────────────────────────  (often × 1,000 person-years)
                        total person-time at risk
```

Settings to watch: the TAR window (e.g. *index + 1 day* to *cohort end*), and whether people
who already had the outcome before index are excluded (usually yes: incidence means *new*).

**For our project:** target = MHD cohort, outcome = SUD cohort. The incidence rate of SUD
among people with MHD is a direct check of the **concurrency** our calibration built in
(Lesson 002). Just remember that in synthetic data, the answer was put there by our module.

### 10. Cohort pathways

Takes a **target** cohort plus several **event** cohorts (e.g. different treatments) and shows
the order in which event cohorts occur after index, as a sunburst chart. Settings: minimum
era duration, combination window (events this close count as "together"), and max path length.

### 11. Estimation and prediction

ATLAS can *design* comparative-effect (CohortMethod) and patient-level prediction (PLP) studies
and export them as **R study packages**; the heavy computation runs in R (HADES), not in
WebAPI. These are out of scope for a synthetic dataset, since there's no real causal signal to
estimate. They're mentioned here so the menu items aren't a mystery.

### 12. A cohort is a hypothesis

A definition is a **claim** that these rules find the people you mean. In real data it will
miss some (sensitivity) and include some wrongly (positive predictive value). OHDSI has tools
for checking:

| Tool | What it does |
|---|---|
| **CohortDiagnostics** (R) | Index-event breakdown, overlap, incidence over time, orphan concepts (codes you missed) |
| **PheValuator** (R) | Estimates sensitivity/specificity/PPV with a probabilistic reference standard |
| **OHDSI Phenotype Library** | Peer-reviewed definitions to start from instead of from scratch |

In our synthetic data, the "truth" is known: it's whatever `concurrent_disorders.json` assigned.
That makes this database an unusually good **training ground** for checking definitions.

---

## Lab (2 × 30 minutes)

### Part A: build, predict, generate (Session 1)

1. Create cohort `MHD adults (course)`:
   - Entry: condition occurrence of `MHD (course)`; limit to **earliest** event per person.
   - Inclusion rule 1, `Adult at index`: age ≥ 18 (as an attribute, or as a demographic criterion).
   - Inclusion rule 2, `365d prior observation`: continuous observation ≥ 365 days before index.
   - Exit: end of continuous observation. Era collapse gap: 0.
2. **Predict** (write it down): the final person count, and whether rule 1 removes anyone. (Hint:
   the module's Guard requires age ≥ 18.)
3. Generate on `SYNTH_OMOP`. Compare with your prediction and with this SQL:

```sql
-- Persons with any MHD condition (standard concept + descendants).
-- Replace 0 with your MHD standard concept_id.
SELECT COUNT(DISTINCT co.person_id)
  FROM cdm.condition_occurrence co
  JOIN cdm.concept_ancestor ca ON ca.descendant_concept_id = co.condition_concept_id
 WHERE ca.ancestor_concept_id = 0;
```

4. Open the attrition report. Explain each drop in one sentence.

### Part B: the "both" cohort (Session 1)

1. Copy the cohort to `MHD + SUD (course)`. Add inclusion rule 3, `Has SUD`: *at least 1*
   condition occurrence of `SUD (course)` **any time** (all days before to all days after index).
2. Generate. Compare the count with the "both" cell from `validate_joint.sql` (Step 8b).
   Which one counts persons, and which counts proportions? Can you reconcile them?

### Part C: read the machine's version (Session 1)

1. **Export → JSON**: find your three inclusion rules in the JSON.
2. **Export → SQL**: find (a) the table the entry events are selected from, (b) the 365-day
   window, (c) where rows are inserted into the cohort table. Write the line numbers down.
3. Query `results.cohort` for your cohort's `cohort_definition_id` (it's in the ATLAS URL):
   rows vs distinct persons. Does it match your era prediction?

### Part D: one analysis (Session 2)

Pick **one**:
- **Incidence rate** of `SUD (course)` (outcome cohort) in `MHD adults (course)` (target),
  TAR = index + 1 day → cohort end. Interpret the rate in one sentence, *and* say why it's not
  evidence about real people.
- **Characterization** of `MHD + SUD (course)`: top 10 conditions in the 365 days before index.
  Is anything surprising? Is it a Synthea artefact?

---

## Check your understanding

1. What's the difference between the attribute "first occurrence in history" and limiting entry events to "earliest event"?
2. Why put a restriction in a named inclusion rule instead of in the entry event's qualifying criteria?
3. Write "no SUD in the year before index" as an ATLAS criterion.
4. You change the era collapse gap from 0 to 30. Can the number of *persons* change? The number of *rows*?
5. Why share a cohort as JSON rather than SQL?
6. An inclusion rule removes nobody. Give two possible explanations.
7. Why can't an incidence rate from this database tell you anything about real patients?

<details>
<summary><strong>Answers</strong></summary>

1. "First occurrence in history" filters the event itself: it must be the person's first such
   event in their whole record. "Earliest event" is a limit applied *after* filtering: keep the
   earliest of whatever qualified. With other filters in play, the earliest qualifying event may
   not be the first in history.
2. Named inclusion rules appear separately in the attrition report, so their effect can be seen,
   checked and reported. Qualifying criteria are applied silently.
3. An inclusion rule with **exactly 0** occurrences of `SUD (course)` between **365 days before**
   and **1 day before** index.
4. Persons: no, because merging periods never removes or adds a person. Rows: yes, they can only
   go down or stay the same, since nearby periods merge into fewer eras.
5. JSON is the definition; SQL is derived from it for one database dialect and one set of schema
   names. JSON runs anywhere; SQL only runs where it was generated.
6. The rule is redundant (an earlier step already guaranteed it, like age ≥ 18 with our module's
   Guard), or it's mis-specified (wrong window, wrong concept set) and never matches what you meant.
7. The data is synthetic: the relationship between MHD and SUD was *put in* by our module's
   probabilities. The rate measures our calibration, not the world.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Index date** | The date of the entry event; all windows are relative to it |
| **Observation window** | Required continuous observation before/after the entry event |
| **Primary event limit** | All / earliest / latest qualifying entry event per person |
| **Inclusion rule** | A named, reported restriction applied after entry |
| **Exit strategy** | How a person's membership ends (end of observation, fixed duration, drug exposure) |
| **Censoring event** | An event that ends membership early |
| **Era collapse gap** | Max days between periods that are merged into one era |
| **Attrition (inclusion) report** | Counts before and after each inclusion rule |
| **Circe** | Turns cohort JSON into OHDSI SQL |
| **Time at risk (TAR)** | The window in which outcomes are counted for an incidence rate |
| **Feature analysis** | A reusable covariate definition used in characterization |

---

## Further reading

- **The Book of OHDSI**, chapter 10 (Defining Cohorts): <https://ohdsi.github.io/TheBookOfOhdsi/Cohorts.html>
- **The Book of OHDSI**, chapter 11 (Characterization: cohort characterization, pathways, incidence): <https://ohdsi.github.io/TheBookOfOhdsi/Characterization.html>
- **The Book of OHDSI**, chapter 16 (Clinical Validity, i.e. phenotype evaluation): <https://ohdsi.github.io/TheBookOfOhdsi/ClinicalValidity.html>
- **Circe** (the cohort engine): <https://github.com/OHDSI/circe-be>
- **CohortDiagnostics**: <https://ohdsi.github.io/CohortDiagnostics/> · **PheValuator**: <https://ohdsi.github.io/PheValuator/>
- **OHDSI Phenotype Library**: <https://ohdsi.github.io/PhenotypeLibrary/>
- OHDSI cohort-building tutorial slides (2025): <https://www.ohdsi.org/wp-content/uploads/2026/01/4.-Tutorial-2025-creating-cohrots-in-ATLAS.pdf>
