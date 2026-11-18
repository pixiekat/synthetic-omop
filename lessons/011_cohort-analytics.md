# Lesson 011: Cohort Analytics: Contrasts, Treatment Patterns and Comorbidity

| | |
|---|---|
| **Course level** | Second to third year undergraduate (health informatics / data science) |
| **Estimated time** | 2 × 90-minute lectures + 3-hour lab |
| **Prerequisites** | Lessons 006–007 (ATLAS, cohort definitions), 009 (eras, gaps and islands), 010 (concept hierarchies); introductory statistics (proportions, 2×2 tables, p-values) |
| **Project files** | README Step 10; `services/analytics/`; `data/analyses/<RUN_ID>/`; Comorbidity4j (next integration step) |
| **Previous lesson** | 010: Athena and the OMOP Standardized Vocabularies |

> **A warning that applies to every result in this lesson.** Our database is **synthetic**. Every
> association you find was put there by a simulation: our module's calibrated probabilities, plus
> Synthea's own disease modules. So these analyses can't tell you anything about real patients.
> What they *can* do is check the simulation ("did the MHD–SUD association we designed come
> out?"), and teach you the methods on data where nobody can be harmed by a mistake.

## Learning objectives

By the end of this lesson you should be able to:

1. Place an analysis in OHDSI's three families (**characterization**, **estimation**, **prediction**), and say what each can and can't claim.
2. Design cohorts for an analysis: roles (target, control, event, outcome), time windows, and why the **cohort table** is the interface between tools.
3. Build a **2×2 table** from the CDM, and compute prevalence, relative risk, odds ratio and phi by hand.
4. Explain **multiple testing**, and choose between Bonferroni and Benjamini–Hochberg.
5. Explain how **CohortContrast** finds enriched concepts, and why the choice of control decides what "enriched" means.
6. Step through the **TreatmentPatterns** algorithm by hand on a single timeline, and predict how each setting changes the result.
7. Explain what **Comorbidity4j** computes, the known biases of its measures, and what directionality adds.
8. Report results responsibly: small-cell censoring, provenance, and the descriptive-vs-causal line.

---

## Lecture 1: Cohorts as the unit of analysis, and comparing them

### 1. Three families of analysis

OHDSI groups observational analyses into three kinds. Knowing which one you're doing tells you
which claims you're allowed to make.

| Family | Question | Example | Can it claim cause? |
|---|---|---|---|
| **Characterization** | What happened, to whom, how often? | "60% of the MHD cohort started an antidepressant first" | **No.** Descriptive only |
| **Population-level estimation** | Does exposure X *cause* a change in outcome Y? | "Does drug A raise the risk of Y compared with drug B?" | Yes, *if* the design controls confounding |
| **Patient-level prediction** | Who will have Y? | "Which patients will develop SUD within a year?" | No. Prediction isn't causation |

**Everything in this lesson is characterization.** CohortContrast, TreatmentPatterns and
Comorbidity4j all describe patterns. An "enriched" concept or a strong comorbidity is a
**hypothesis**, not a finding of cause.

### 2. Cohorts, again, at a higher level

Lesson 007 built cohorts. Here's how analyses *use* them:

| Role | Meaning | Tool that uses it |
|---|---|---|
| **Target** | The population you're describing | All three |
| **Control** | The comparison population | CohortContrast |
| **Event** | Things that happen to the target, e.g. treatments | TreatmentPatterns |
| **Exit** | Something that ends a pathway | TreatmentPatterns (optional) |
| **Outcome** | The thing you're counting (incidence, estimation) | ATLAS incidence rates; estimation studies |

#### The cohort table is the interface

```
 ATLAS (definition JSON) ──Generate──▶ results.cohort ──▶ TreatmentPatterns
                                      (4 columns:     ──▶ CohortContrast
                                       id, person,    ──▶ (Comorbidity4j uses CDM tables directly)
                                       start, end)
```

This design matters: the **definition** lives in one place, every tool consumes the **same
four-column table**, and so tools written by different groups (OHDSI, DARWIN EU, Tartu) work
together without knowing about each other. That's the same principle as the CDM itself, applied
one level up.

Three practical consequences, all built into `services/analytics/R/common.R`:

1. **Generate before you analyse.** A defined-but-never-generated cohort has **zero rows**, and
   most tools then return empty output instead of an error. The scripts check this first.
2. **Cohort IDs are local.** They're ATLAS's database IDs: reset the database and they restart.
   That's why study files are reviewed whenever ATLAS is rebuilt.
3. **A cohort is time-bounded.** `cohort_start_date`/`cohort_end_date` define *when* a person
   counts. Every tool's time windows are relative to them.

#### Building a control: the "MHD only" cohort

The CohortContrast study compares "MHD + SUD" with "MHD only". "MHD only" is MHD with an
inclusion rule of **exactly 0** SUD occurrences, at **any time** (Lesson 007, section 3). Notice
the choice: "any time" means someone diagnosed with SUD *after* the study window is still
excluded. Whether that's right depends on the question, and that decision is design, not code.

### 3. The 2×2 table: the core of comparison

Almost every comparison in this lesson starts from one table. For two binary properties A and
B (e.g. "has MHD" and "has SUD") in a population of N people:

| | B present | B absent | Total |
|---|---|---|---|
| **A present** | a | b | a + b |
| **A absent** | c | d | c + d |
| **Total** | a + c | b + d | N |

From it:

| Measure | Formula | Reads as |
|---|---|---|
| **Prevalence of B in A** | a / (a + b) | "Of people with A, what share have B?" |
| **Relative risk (RR)** | [a/(a+b)] / [c/(c+d)] | "How many times more common is B with A than without?" |
| **Odds ratio (OR)** | (a·d) / (b·c) | Ratio of odds; ≈ RR when B is rare |
| **Phi (φ)** | (a·d − b·c) / √[(a+b)(c+d)(a+c)(b+d)] | Correlation of two yes/no variables, −1 to 1 |
| **Chi-squared (χ²)** | N·φ² | Test statistic for "no association" |

Comorbidity research often uses a related form of RR: observed co-occurrence divided by what
you'd expect if A and B were independent, **RR = a·N / [(a+b)(a+c)]**. Same idea ("more than
chance?"), different denominator. Always check which formula a tool uses before comparing
numbers across tools.

> **The denominator is a design decision.** N = "everyone in `cdm.person`" gives a different RR
> from N = "adults observed during 2025–26". Our module only assigns MHD/SUD to adults inside the
> export window, so including children in N dilutes every prevalence. Lab 2 makes you choose.

### 4. Multiple testing

CohortContrast tests **every concept** that passes its filters: hundreds, maybe thousands.
Comorbidity4j tests **every pair** of diseases: with 300 diagnoses, that's 44,850 pairs. At
p < 0.05, about 1 in 20 tests of a *true null* comes out "significant" by chance alone. So 44,850
tests produce roughly 2,000 false positives, before a single real association.

| Correction | Controls | Effect |
|---|---|---|
| **Bonferroni** | Family-wise error: P(*any* false positive) ≤ α | Divide α by the number of tests. Very strict; misses real effects |
| **Holm**, **Hochberg**, **Hommel** | Family-wise error, step-wise | Less strict than Bonferroni, same guarantee (Hochberg/Hommel under extra assumptions) |
| **Benjamini–Hochberg (BH)** | False discovery rate: expected *share* of false positives among findings ≤ q | The usual choice for exploratory screening |
| **Benjamini–Yekutieli (BY)** | FDR under any dependence between tests | Stricter than BH |

**Rule of thumb:** for exploratory screening (which all three tools are), use **FDR (BH)**, and
treat the results as a shortlist for review, not a list of facts.

### 5. CohortContrast: which concepts are enriched?

CohortContrast takes a **target** and a **control**, collects every concept each person has in
the chosen domains (drugs, conditions, measurements …), and asks for each concept whether it's
over-represented in the target.

```
 target persons ─┐                                       ┌─▶ prevalence in target   ─┐
                 ├─▶ concepts per person, per domain ─▶ ─┤                          ├─▶ filters ─▶ tests ─▶ enriched list
 control persons ┘                                       └─▶ prevalence in control  ─┘
```

| Step | Setting (our study file) | What it does |
|---|---|---|
| Filter by presence | `presenceFilter = 0.2` | Drop concepts that fewer than 20% of target persons have |
| Filter by enrichment | `prevalenceCutOff = 2.5` | Keep concepts at least 2.5× more prevalent in target than control |
| Test | `runChi2YTests = TRUE` | Chi-squared test for two proportions, with **Yates' continuity correction** (more conservative for small counts) |
| Optional | `runLogitTests`, hierarchy and correlation combining, temporal-bias removal | Model-based tests; merge redundant concepts (e.g. a drug and its ingredient); reduce artefacts of *when* things are recorded |

#### The control decides the question

| Control | Question you're actually asking |
|---|---|
| **"MHD only"** (our study) | What distinguishes people with *both* conditions from people with MHD alone? |
| **Matched controls** (`createControlCohortMatching`) | What distinguishes the target from similar people (matched on demographics) in the general population? |
| **Inverse controls** (`createControlCohortInverse`) | What distinguishes the target from everyone else? |

Same target, three controls, three different answers, all correct for their own question.
**Confounding** is the reason matching exists: if the target is older than the control, every
age-related condition will look "enriched". Matching on age and sex removes *those* differences,
but not others you didn't match on.

---

## Lecture 2: Treatment patterns and comorbidity

### 6. TreatmentPatterns: from eras to pathways

TreatmentPatterns (Markus et al., 2022) turns a target cohort plus event cohorts into **ordered
treatment sequences**. The settings and their defaults:

| Setting | Default | Meaning |
|---|---|---|
| `minEraDuration` | 0 | Drop event eras shorter than this (days) |
| `eraCollapseSize` | 30 | Merge two eras of the **same** event less than this many days apart |
| `combinationWindow` | 30 | Two different events overlapping by at least this long become a **combination** (e.g. A+B) |
| `minPostCombinationDuration` | 30 | Drop pieces shorter than this that are left before or after a combination |
| `overlapMethod` | `"truncate"` | Overlap too short to be a combination: cut the earlier event at the start of the next |
| `filterTreatments` | `"First"` | `"First"`: keep only each treatment's first occurrence; `"Changes"`: drop consecutive repeats; `"All"`: keep everything |
| `maxPathLength` | 5 | Keep at most this many steps per path |

Our study file sets none of these, so the package defaults apply. The script passes a setting
only when the study file sets it.

#### A worked example: one person, defaults

Days are relative to the person's target index date.

```
 Raw event eras:      A: 0────────90          A: 200────260   A: 280──300
                      B:          60─────────150

 1. Era collapse (30):  A 200–260 and A 280–300 are 20 days apart (< 30) → one era A 200–300

 2. Combination (30):   A (0–90) and B (60–150) overlap for 30 days (60–90) → A+B for 60–90
                        leaving A 0–60 (60 days) and B 90–150 (60 days)

 3. Min post-combination (30): A 0–60 and B 90–150 are both ≥ 30 days → kept

 4. Sequence:           A → A+B → B → A

 5. filterTreatments:   "First"   → A → A+B → B          (the second A isn't a first occurrence)
                        "Changes" → A → A+B → B → A      (no consecutive repeats to drop)

 6. maxPathLength (5):  fewer than 5 steps → unchanged
```

Then the paths of **every** person are counted, censored (counts below `minCellCount` are
hidden), and drawn:

| Plot | Shows | Good for |
|---|---|---|
| **Sunburst** | Rings outward = first, second, third treatment; slice size = share of people | "What do people start on, and what comes next?" |
| **Sankey** | Flows between treatment steps | Switching between treatments |

> **Boundaries are where tools differ.** Is an overlap of *exactly* 30 days a combination? Is a
> gap of *exactly* 30 collapsed? The worked example avoids the edge on purpose. Lab 3 makes you
> find out from the output, which is the Lesson 009 habit of not guessing.

#### `nonePaths`: the people without a path

Our script sets `nonePaths = TRUE`, so people in the target with **no** event appear as "None".
In synthetic data that's often the biggest group, because Synthea only prescribes what its
modules model, and our module only assigns **diagnoses**. Leaving them out would make the
treated minority look like the whole cohort: a classic way charts mislead.

### 7. Comorbidity4j: which diseases go together?

Comorbidity4j is a Java tool (version 3.5) that screens **every pair** of diagnoses in a
population for co-occurrence. It reads three OMOP tables (person, visit occurrence and condition
occurrence, exported as files), and for each pair computes:

| Output | What it is |
|---|---|
| **Relative risk** (with confidence interval) | Section 3 |
| **Odds ratio** (with confidence interval) | Section 3 |
| **Phi** | Section 3 |
| **Comorbidity score** | A log-scaled score of observed vs expected co-occurrence (from the comorbidity literature) |
| **Fisher's exact test**, raw and **adjusted** | The adjustment is your choice of Bonferroni, Benjamini–Hochberg, Holm, Hochberg, Benjamini–Yekutieli or Hommel (section 4) |
| **Sex ratio** | Is the comorbidity equally likely in women and men? |
| **Directionality** (optional) | Does A tend to come *before* B? |

Results come as a tab-separated table, a heatmap and a disease network.

#### Known biases of the measures

The comorbidity-network literature documents two biases worth knowing before you read a network:

- **φ underestimates** pairs where one disease is rare and the other common.
- **RR overestimates** links between rare diseases, and underestimates those between common ones.

So rank by **one** measure, filter by significance, and look at the counts behind any striking
number. A relative risk of 40 based on 3 people is a curiosity, not a finding.

#### Directionality: order, not cause

With directionality on, a pair counts only when the diagnoses are at least some number of days
apart, in a consistent order (the tool's own benchmarks used 14 days). That tells you "A tends
to be recorded before B". It doesn't tell you A causes B: recording order reflects *care
pathways* (what gets diagnosed first, and where) as much as disease biology.

#### Granularity is a design decision

Comorbidity4j treats every distinct diagnosis code as its own disease. With SNOMED, "major
depressive disorder, single episode" and "… recurrent" are two "diseases", which splits the
signal and multiplies the tests. A common fix is to **roll diagnoses up** to a chosen ancestor
level with `concept_ancestor` (Lesson 010) **before** exporting. Which level to use is a
clinical decision, and belongs in `docs/assumptions.md`.

### 8. Reporting responsibly

| Practice | Why | In this project |
|---|---|---|
| **Censor small cells** | Small counts can identify people in real data | `TP_MIN_CELL_COUNT` (default 5); note any synthetic-only lowering |
| **Correct for multiple testing** | Thousands of tests guarantee false positives | Fisher-adjusted in Comorbidity4j; chi-squared + filters in CohortContrast |
| **Record provenance** | A result is only checkable if you know what produced it | `provenance.json` per result; run log; study files in Git |
| **State the family** | Descriptive results get read as causal | Say "characterization" in every write-up |
| **State the data's nature** | Synthetic results get quoted as real | "Synthetic; calibrated to NSDUH 2024; not evidence about patients" |
| **Follow a reporting guideline** | Others can judge and repeat the work | RECORD (the extension of STROBE for routinely collected health data) |

---

## Lab (3 hours)

### Lab 1: design before you run (25 minutes, on paper)

For the two example studies in `services/analytics/studies/`:

1. Write each cohort's role (target, control, event) and its time window in one line.
2. For the CohortContrast study, write the question each of the three possible controls (section 5) would answer. Which one does our study file use, and why might a reviewer prefer another?
3. Predict: will "MHD + SUD vs MHD only" find SUD itself as an enriched concept? (Think about how the cohorts are defined before you answer.)

### Lab 2: a 2×2 table by hand (40 minutes)

Compute the MHD–SUD association yourself, before any tool does it for you.

```sql
-- Replace 0 and 0 with your MHD and SUD standard concept_ids (Lesson 006, Part 3).
-- Denominator: everyone in cdm.person. Change it to adults in the export window and compare.
WITH mhd AS (
  SELECT DISTINCT co.person_id
    FROM cdm.condition_occurrence co
    JOIN cdm.concept_ancestor ca ON ca.descendant_concept_id = co.condition_concept_id
   WHERE ca.ancestor_concept_id = 0          -- MHD
), sud AS (
  SELECT DISTINCT co.person_id
    FROM cdm.condition_occurrence co
    JOIN cdm.concept_ancestor ca ON ca.descendant_concept_id = co.condition_concept_id
   WHERE ca.ancestor_concept_id = 0          -- SUD
), counts AS (
  SELECT (SELECT COUNT(*) FROM cdm.person)::numeric               AS n,
         (SELECT COUNT(*) FROM mhd)::numeric                      AS a_plus_b,   -- has MHD
         (SELECT COUNT(*) FROM sud)::numeric                      AS a_plus_c,   -- has SUD
         (SELECT COUNT(*) FROM mhd JOIN sud USING (person_id))::numeric AS a     -- has both
), cells AS (
  SELECT n, a,
         a_plus_b - a           AS b,
         a_plus_c - a           AS c,
         n - a_plus_b - a_plus_c + a AS d
    FROM counts
)
SELECT n, a, b, c, d,
       ROUND(a / NULLIF(a + b, 0), 4)                                        AS prev_sud_given_mhd,
       ROUND((a / NULLIF(a + b, 0)) / NULLIF(c / NULLIF(c + d, 0), 0), 3)    AS relative_risk,
       ROUND((a * n) / NULLIF((a + b) * (a + c), 0), 3)                      AS rr_observed_vs_expected,
       ROUND((a * d) / NULLIF(b * c, 0), 3)                                  AS odds_ratio,
       ROUND((a * d - b * c) / NULLIF(SQRT((a + b) * (c + d) * (a + c) * (b + d)), 0), 4) AS phi
  FROM cells;
```

1. Check that a + b + c + d = N. If it doesn't, your cells are wrong: find out why before going on.
2. Compare `prev_sud_given_mhd` with the calibration targets (Lesson 002, `validate_joint.sql`). Are they the same quantity? (Hint: the module's probabilities are about *assignment*, and the CDM counts *recorded diagnoses*.)
3. Change the denominator to adults with an observation period covering the export window. Which measures change a lot, and which barely move? Why does the odds ratio move least?

### Lab 3: TreatmentPatterns, predicted then run (45 minutes)

1. **By hand:** redo the worked example in section 6 with `combinationWindow = 45`. Then with `eraCollapseSize = 15`. Write the final path for each, with `filterTreatments = "First"`.
2. **Find the boundary:** with defaults, what happens if A and B overlap for exactly 30 days? Write your prediction.
3. **Run it:** build event cohorts in ATLAS for the drug classes that actually appear in Data Sources → Drug Exposure. Generate them, create a study file, and run `run_treatment_patterns.R` (README 10e).
4. **Read it:** open `sunburst.html`. What share is "None"? Rerun with `TP_COMBINATION_WINDOW=7` in a *new* study file. Which slices change, and does that match your prediction from step 1?

### Lab 4: CohortContrast, read critically (40 minutes)

1. Run the `mhd-sud-vs-mhd` study (README 10f).
2. For the top 10 enriched concepts, sort each into: **(a)** part of the cohort definitions themselves (your Lab 1 prediction), **(b)** something our module or a Synthea module plausibly produces, **(c)** unexplained.
3. How many concepts were tested in total (before filters)? With that number, how many "significant" results would you expect by chance at p < 0.05?
4. Run it again with matched controls (a new study file with `CC_CONTROL_COHORT_ID` empty). Which concepts appear in one result and not the other? Explain each in one sentence using section 5's table.

### Lab 5: prepare for Comorbidity4j (30 minutes)

Comorbidity4j is the next integration step. Before it exists, predict its output:

1. From Lab 2, write down the MHD–SUD relative risk (both forms), odds ratio and phi.
2. Comorbidity4j will test *every* pair of diagnoses. Count the distinct condition concepts in `cdm.condition_occurrence`. How many pairs is that? How strict would Bonferroni be at α = 0.05?
3. Pick a roll-up level for diagnoses (section 7, granularity). Write the `concept_ancestor` query that would map each condition to that level, and record the choice as a draft entry in `docs/assumptions.md`.
4. When the integration is done: does Comorbidity4j's MHD–SUD pair match your Lab 2 numbers? If not, which formula or denominator explains the difference?

---

## Check your understanding

1. A TreatmentPatterns sunburst shows 70% of patients start on drug A. Can you say drug A is the best first treatment?
2. Why is the cohort table a good interface between tools from different groups?
3. Give the 2×2 formulas for RR, OR and φ. When are RR and OR close?
4. 10,000 tests at p < 0.05: how many false positives would you expect if nothing were real? What does BH control that Bonferroni doesn't?
5. CohortContrast finds a drug "enriched" in the target. Name two non-causal explanations.
6. Why does the choice of control change what "enriched" means? Give an example with our cohorts.
7. Two eras of drug A are 20 days apart. With default settings, how many A eras are there? And if they were 40 days apart?
8. Why does `nonePaths = TRUE` matter for honest charts?
9. Why can φ and RR rank the same disease pairs differently?
10. Comorbidity4j finds "A usually precedes B". Does A cause B?
11. In our synthetic data, Comorbidity4j finds a strong MHD–SUD association. What does that tell you, and what doesn't it?

<details>
<summary><strong>Answers</strong></summary>

1. No. It's characterization: it describes what happened. Which treatment is *best* is an
   estimation question, needing comparison groups and confounding control.
2. Every tool reads the same four columns (ID, person, start, end), so a definition made once in
   ATLAS can be used by any tool without re-implementing it. The definition and the analysis are
   decoupled.
3. RR = [a/(a+b)] / [c/(c+d)]; OR = ad/bc; φ = (ad − bc)/√[(a+b)(c+d)(a+c)(b+d)]. RR ≈ OR when
   the outcome is rare (a and c small next to b and d).
4. About 500. BH controls the *proportion* of false discoveries among results called significant
   (FDR). Bonferroni controls the chance of *any* false positive (FWER), so it is much stricter.
5. Any two of: it's part of how the cohorts were defined; confounding (e.g. the target is older);
   differences in how often people are seen (more visits means more recorded concepts); a
   simulation artefact; chance (multiple testing).
6. "Enriched" always means "relative to the control". Against "MHD only", the comparison isolates
   what goes with SUD *among people with MHD*. Against matched general-population controls, MHD
   itself (and everything that comes with it) would also appear enriched.
7. One era (20 < 30, so they collapse). With 40 days between them, two eras.
8. Without it, the chart shows only people *with* a pathway, so a treated minority looks like the
   whole cohort.
9. They answer different questions and have opposite biases: φ penalizes pairs where one disease
   is rare and the other common; RR inflates rare–rare pairs.
10. No. It shows recording order, which reflects care pathways as well as biology. Causal claims
    need an estimation design.
11. That the simulation produced the association it was calibrated to produce (a successful
    *validation*). It says nothing about real patients.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Characterization** | Descriptive analysis of what happened to whom; no causal claims |
| **Target / control / event cohort** | The described population / the comparison / things that happen to the target |
| **2×2 table** | Counts of four combinations of two yes/no properties |
| **Relative risk / odds ratio** | Ratios of risk / of odds between two groups |
| **Phi (φ)** | Correlation between two binary variables |
| **Multiple testing** | Running many tests inflates false positives; needs correction |
| **FWER / FDR** | Chance of any false positive / expected share of false positives among findings |
| **Enrichment** | A concept more prevalent in the target than in the control |
| **Confounding** | A third factor that makes two things look related |
| **Era collapse / combination window** | Merging same-treatment eras / defining combination therapy by overlap |
| **Sunburst / Sankey** | Ring chart of treatment sequences / flow chart of switches |
| **Comorbidity** | Two conditions occurring in the same person more than chance would predict |
| **Directionality** | Whether one diagnosis tends to be recorded before another |
| **Small-cell censoring** | Hiding counts below a threshold to protect privacy |

---

## Further reading

- **The Book of OHDSI**, chapter 11 (Characterization: cohort characterization, treatment pathways, incidence): <https://ohdsi.github.io/TheBookOfOhdsi/Characterization.html>
- **Markus A, Verhamme K, Kors J, Rijnbeek P (2022).** TreatmentPatterns: an R package to facilitate the standardized development and analysis of treatment patterns across disease domains. *Computer Methods and Programs in Biomedicine.* doi:10.1016/j.cmpb.2022.107081
- **TreatmentPatterns documentation**: <https://darwin-eu.github.io/TreatmentPatterns/>
- **CohortContrast documentation and wiki**: <https://healthinformaticsut.github.io/CohortContrast/> · <https://github.com/HealthInformaticsUT/CohortContrast/wiki>
- **Comorbidity4j documentation** (scores, table format, OMOP input): <https://comorbidity4j.readthedocs.io/>
- **Comorbidity networks and the biases of φ and RR**: *Applied Network Science* (2018): <https://appliednetsci.springeropen.com/articles/10.1007/s41109-018-0101-4>
- **Benjamini & Hochberg (1995)**, "Controlling the false discovery rate", *JRSS B*: the original FDR paper, short and readable.
- **RECORD statement** (reporting guideline for routinely collected health data): <https://www.record-statement.org/>
