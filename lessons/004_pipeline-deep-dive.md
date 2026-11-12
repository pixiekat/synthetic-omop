# Lesson 004: Deep Dive into NSDUH, Synthea, Athena and the ETL

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | Two sessions of 75–90 minutes (lecture + lab); sections 1–2, then 3–5 |
| **Prerequisites** | Lessons 001–003 |
| **Project files** | `services/calibration/`, `services/synthea/`, `data/vocab/athena/`, `services/etl/`, `docs/run-log.md` |
| **Previous lesson** | 003: OMOP Concepts |
| **Next lesson** | 005: Where Did 18 Deaths Go? (reconciling counts through an ETL) |

> Lessons 001–003 used these four tools. This lesson opens each one up: where it comes from,
> how it works inside, what it can and can't tell you, and what each one taught us during
> the pilot. NSDUH facts are taken from SAMHSA's own documentation (see **Sources**).

## Learning objectives

By the end of this lesson you should be able to:

1. Describe **who NSDUH surveys**, how, and the main limits of a cross-sectional, self-reported survey.
2. Explain why NSDUH's **"any mental illness"** is a *model-based* estimate, and why it **excludes** substance use disorders.
3. Explain what a **public use file** is, and why its estimates differ slightly from SAMHSA's published ones.
4. Describe how **Synthea** simulates a life: demographics, modules as **state machines**, attributes, and exporters.
5. Explain what an **Athena bundle** contains, how vocabulary selection changes the files, and why releases must be recorded.
6. Walk through **ETL-Synthea's stages**, and explain the role of `source_to_standard_vocab_map`.
7. Identify where **design choices** in each tool showed up as real problems in the pilot.
8. Trace the **provenance chain**: which version of what produced a given row.

---

## 0. The four parts, and what each hands to the next

```
 ┌────────────┐  probabilities  ┌────────────┐  CSV files   ┌──────────────┐  OMOP rows  ┌────────────┐
 │   NSDUH    │ ──────────────▶ │  Synthea   │ ───────────▶ │ ETL-Synthea  │ ──────────▶ │  Postgres  │
 │ (the real  │  "how common,   │ (simulated │  "what       │ (reshape +   │             │  OMOP 5.4  │
 │  world)    │   together"     │   lives)   │   happened"  │   map codes) │             │            │
 └────────────┘                 └────────────┘              └──────┬───────┘             └────────────┘
                                                                   │ needs
                                                            ┌──────┴───────┐
                                                            │    Athena    │  "what every code means,
                                                            │ vocabularies │   and how codes relate"
                                                            └──────────────┘
```

Each arrow is a **hand-off**, and each hand-off is a place where meaning can change or be lost.
Most of this lesson is about those hand-offs.

---

## 1. NSDUH: the real-world anchor

### 1.1 What it is

The **National Survey on Drug Use and Health** is run every year by SAMHSA. It measures
substance use, mental illness and treatment in the **civilian, noninstitutionalized population
aged 12 or older**. The survey has existed under different names since 1971 and has been called
NSDUH since 2002.

### 1.2 Who is *not* in it

The excluded groups are: **active-duty military**, people in **institutional group quarters**
(hospitals, prisons, nursing homes, treatment centres), and **people who are homeless and not in
shelters**. SAMHSA notes this is a small share of the population (under 2%), but warns that if
these groups' drug use or mental illness differs, estimates can be slightly off, especially for
less common drugs such as heroin.

> **For this project:** people in residential treatment or psychiatric inpatient care are
> exactly the groups NSDUH can't see. Our synthetic population represents people living in the
> community, and the README says so.

### 1.3 How it's collected, and what that limits

| Feature | What it means | What it limits |
|---|---|---|
| **Self-report** | Answers come from the respondent | Depends on honesty and memory; some under- and over-reporting is expected |
| **Cross-sectional** | Each person is interviewed once, never followed up | Gives a snapshot of who has what *now*, not how it develops. That's why our Synthea timings are assumptions (A-001) |
| **Mode changes** | Web interviewing was added in late 2020, alongside in-person | **2020-and-later data can't be compared or pooled with 2019-and-earlier.** The 2021 data also breaks from 2020 |
| **Survey weights** | Each respondent stands for many people (Lesson 002) | Unweighted counts give wrong estimates |

### 1.4 "Any mental illness" is a *model*, not a diagnosis

This is the most important NSDUH fact for this project.

NSDUH doesn't diagnose anyone. Between **2008 and 2012**, the **Mental Health Surveillance
Study (MHSS)** had clinicians re-interview a subsample of adult respondents, about 5,000 in
total, to reach real clinical diagnoses. Statisticians then built a **prediction model**: using
answers from the main survey (psychological distress and functional impairment scales), it
predicts the probability that a person meets criteria for **serious mental illness (SMI)**.

That model is applied to **every** adult respondent. People above one cut-point are classed as
SMI. A **lower** cut-point on the same model gives **any mental illness (AMI)**. SAMHSA's own
tables note that these estimates are **based on a predictive model and are not direct measures
of diagnostic status**.

> **Analogy:** a weather forecast says "70% chance of rain." NSDUH's AMI is closer to a forecast
> crossing a threshold than to someone looking out of the window. It's very good at describing
> a *population*, and says much less about any *one person*.

### 1.5 AMI excludes substance use disorders, by definition

AMI is defined as a diagnosable mental, behavioural or emotional disorder **other than a
developmental or substance use disorder**. Two consequences:

- **No double counting.** "Both MHD and SUD" in our 2×2 table really means two *different*
  conditions. A substance use disorder is never counted as the mental illness.
- **Our A-002 is a big leap.** Turning AMI (a model-based, broad category) into "major
  depressive disorder" (a specific diagnosis) is exactly the kind of assumption that needs
  clinical review, and the lesson explains why.

### 1.6 Public use files (PUFs)

We use the **public use file**, not the restricted data:

- PUFs are **full datasets treated with confidentiality protections** ("disclosure avoidance"):
  most **geographic variables are removed**, and other variables may be altered.
- So estimates from the PUF are **comparable to, but not identical to**, SAMHSA's published
  figures. A small mismatch when you check your calibration against a SAMHSA report is
  **expected**, not a bug.
- Use the **codebook for the exact year**. Variable names and definitions change between years.
  That's why `config.json` keeps its variable names in one place for you to check.

---

## 2. Synthea: simulated lives

### 2.1 What it is

**Synthea** is an open-source synthetic patient generator from MITRE. It simulates whole
lifetimes, from birth to the end of the simulation or death, and writes out the medical records
those lives would produce. No real patient data goes in, so there's no PHI to come out.

### 2.2 How a patient's life is built

1. **Demographics first.** Each person gets an age, sex, race, ethnicity, location and
   socioeconomic attributes, drawn from census-based population data for the state and city
   you choose (`Massachusetts` in our runs).
2. **Time advances in fixed steps** (configurable). At each step, every **module** gets a turn
   to move that person forward.
3. **Modules** decide what happens: a cold, a vaccine, a diabetes diagnosis, a pregnancy. Each
   module is a **state machine** (next section).
4. **Exporters** turn the finished life into records: CSV (what our ETL reads), FHIR, and others.

### 2.3 Modules are state machines

A **state machine** is a set of **states** a person can be in, plus **transitions** saying which
state comes next. Synthea's are written in JSON (the *Generic Module Framework*). Our
`concurrent_disorders.json` uses most of the common building blocks:

| State type | What it does | In our module |
|---|---|---|
| `Initial` | Where every person starts (at birth) | `Initial` |
| `Guard` | Waits until a condition is true | `Wait_Until_Adult_In_Window` (age ≥ 18 and year ≥ 2025) |
| `SetAttribute` | Stores a value on the person, readable by other modules | `concurrent_profile = "both"` … |
| `Encounter` / `EncounterEnd` | Opens and closes a healthcare visit | `MHD_Encounter`, `Both_Encounter` … |
| `ConditionOnset` | Records a diagnosis at an encounter | `MHD_Onset`, `Both_SUD_Onset` … |
| `Terminal` | The end of this module for this person | `Terminal` |

Other common types include `Delay`, `MedicationOrder`, `Procedure`, `Death` and `CallSubmodule`.

And the ways to choose the next state:

| Transition | Behaviour | In our module |
|---|---|---|
| `direct_transition` | Always go to one state | Most states |
| `distributed_transition` | Pick at random, with given probabilities | (not used) |
| `conditional_transition` | First matching condition wins | The keep-patients module |
| `complex_transition` | Conditions **and** probabilities: "if woman 35–49, then 25/25/25/25" | `Assign_Profile`, the joint draw |

### 2.4 Attributes: how modules talk to each other

Modules don't call each other directly; they share **attributes** stored on the person. Our module
sets `concurrent_profile`, and the keep-patients module reads it. Built-in modules work the same
way, so **a built-in module can react to, or add to, what ours does.**

> **What the pilot taught us:** 7 deaths from "Drug overdose" came from Synthea's built-in
> `opioid_addiction` module, not ours. Built-in modules keep running alongside custom ones.
> Calibrating our module doesn't calibrate theirs.

### 2.5 Reproducibility

| Control | What it does |
|---|---|
| `-s` seed | Same seed + same config + same modules = the same population |
| `-cs` clinician seed | Controls clinician assignment |
| `-p` population | Number of **living** people; people who die are exported *in addition* (1,000 → 1,175 in the pilot) |
| `exporter.years_of_history` | How far back the export goes (2 years for us) |
| `COMMAND.txt` | Our `run.sh` saves the exact command next to every run |

### 2.6 What Synthea is not

- **Not clinically validated for research conclusions.** It's for testing, teaching and methods development.
- **Not up to date on codes.** Its modules use codes that were current when they were written.
  The pilot met a SNOMED code retired in 2021 (`55680006`), and CVX codes without the leading
  zero (`3` rather than `03`).
- **Not calibrated to your question by default.** That's why we built our own parent module.

---

## 3. Athena: the vocabulary service

### 3.1 What it is

**Athena** (<https://athena.ohdsi.org>) is OHDSI's website for browsing and downloading the
**Standardized Vocabularies**: every concept, relationship and hierarchy from Lesson 003. The
OHDSI vocabulary team builds a new **release** periodically. Ours is `v5.0 29-AUG-26`.

### 3.2 What's in a bundle

You choose vocabularies and receive a zip of tab-separated files, one per vocabulary table:

| File | Contents |
|---|---|
| `CONCEPT.csv` | Every concept (6,482,105 rows in our bundle) |
| `CONCEPT_RELATIONSHIP.csv` | Pairs of concepts and how they relate (`Maps to`, `Is a` …) |
| `CONCEPT_ANCESTOR.csv` | Every ancestor–descendant pair (the 63M-row table) |
| `CONCEPT_SYNONYM.csv` | Alternative names, in several languages |
| `VOCABULARY.csv` | The vocabularies included, and the release version (row `None`) |
| `DOMAIN.csv`, `CONCEPT_CLASS.csv`, `RELATIONSHIP.csv` | Lists of domains, classes and relationship types |
| `DRUG_STRENGTH.csv`, `PACK_CONTENT.csv` | Drug ingredient amounts and pack contents |

Extras (not loaded): `CONCEPT_CPT4.csv` + `cpt4.jar` (CPT4, see below), `*_METADATA.csv`, `readme.txt`.

### 3.3 Selection changes the files

A bundle isn't "the vocabulary with some parts hidden." **Choosing vocabularies changes which
relationships you receive.** A relationship pointing into a vocabulary you didn't select is
**left out**. In the pilot:

| Missing vocabulary | Effect we saw |
|---|---|
| **Cancer Modifier** | `94260004`'s `Maps to` row was absent; only `Maps to value → Positive` arrived |
| **CVX** | No immunization code could map at all |

Some vocabularies also carry **licence conditions**. CPT4 belongs to the AMA, so Athena ships a
tool that merges it in using **your own UMLS API key** (free, but the licence is reviewed by NLM).

### 3.4 Treat the vocabulary as versioned data

The same Synthea data, loaded with two different bundles, gave different databases. So the
vocabulary is an **input** just like the patients, and gets recorded the same way:
**release + bundle contents + CPT4 yes/no**, in `docs/run-log.md`.

> **Small print:** Athena's files are tab-separated, and a few concept names contain quote
> characters (HCPCS `A4719`). R's reader warns and "heals" these. The way to be sure nothing was
> lost is to compare `CONCEPT.csv` row counts with the loaded table (see the lab, Part C).

---

## 4. The ETL: ETL-Synthea under the hood

### 4.1 The stages

ETL-Synthea is an R package from OHDSI. Our `run_etl.R` calls its functions in this order:

| Stage | What it does | Pilot timing |
|---|---|---|
| `CreateCDMTables` | Creates empty OMOP 5.4 tables in `cdm` | seconds |
| `CreateSyntheaTables` | Creates staging tables in `synthea` | seconds |
| `LoadSyntheaTables` | Copies the CSVs into staging, unchanged (**Extract**) | seconds |
| `LoadVocabFromCsv` | Loads the Athena bundle into `cdm` | **~18 min** |
| `CreateMapAndRollupTables` | Builds lookup tables, and groups encounters into visits | minutes |
| `CreateExtraIndices` | Indexes to speed up the next stage | ~16 s |
| `LoadEventTables` | Runs one SQL script per OMOP table (**Transform + Load**) | ~3 min |

### 4.2 The lookup table: `source_to_standard_vocab_map`

Instead of following `Maps to` by hand in every script, ETL-Synthea **precomputes** one lookup
table: for each source code, which standard concept it maps to, and in which domain and
vocabulary. A real row from the pilot:

| Column | Value |
|---|---|
| `source_code` | `94260004` |
| `source_concept_id` | 4311765 |
| `source_vocabulary_id` | SNOMED |
| `source_domain_id` | Condition |
| `target_concept_id` | 35226112 (Metastasis to colon) |
| `target_vocabulary_id` | Cancer Modifier |
| `target_domain_id` | **Measurement** |

Every `insert_*.sql` script then **joins** staging data to this table. *How* it joins (inner or
left, and with which filters) decides what survives.

### 4.3 The insert scripts

`LoadEventTables` runs one script per OMOP table. From the pilot's log, in order:
`location` → `care_site` → `person` → `observation_period` → `provider` → `visit_occurrence` →
`visit_detail` → `condition_occurrence` → `observation` → `measurement` →
`procedure_occurrence` → `drug_exposure` → `condition_era` → `drug_era` → `cdm_source` →
`device_exposure` → `death` → `payer_plan_period` → `cost`.

Two are worth explaining:

- **Visits first.** Clinical rows link to a `visit_occurrence`, so visits must exist before
  conditions or drugs. ETL-Synthea also **rolls up** some encounters into a single visit, which
  is why 3 patched immunizations couldn't be linked to one.
- **Eras are derived.** `condition_era` and `drug_era` aren't in Synthea's output. They're
  *computed* summaries ("continuously on this drug from date A to date B"), built from rows
  already loaded.

### 4.4 Design choices are filters

Each script makes assumptions about what a valid row looks like. In the pilot, three of them
dropped records:

| Script | Filter | Dropped |
|---|---|---|
| `insert_death.sql` | Inner join; cause must be **Condition** → **Condition** | 18 deaths |
| `insert_drug_exposure.sql` (immunizations) | Target vocabulary must be **CVX** | 18 COVID vaccines |
| Same script | Source code must match CVX **as text** | 8 vaccines (`3` ≠ `03`) |

The underlying lesson is about joins:

| Join | Unmatched row… | Result |
|---|---|---|
| **Inner** join | is **dropped** | Clean-looking output, silent loss |
| **Left** join + `COALESCE(…, 0)` | is **kept** with `concept_id = 0` | Visible, reviewable gap (OMOP convention) |

Our two patches are left-join versions of the dropped cases. **A patch is a deviation from the
standard ETL**, so each one gets an assumption ID (A-005, A-008) and an entry in the run log.

### 4.5 Reading the source

You don't have to guess what an ETL does. The package's SQL ships inside the container:

```bash
docker compose --profile etl run --rm --entrypoint sh etl -c \
  'ls "$(Rscript -e "cat(system.file(\"sql/sql_server/cdm_version/v540\", package=\"ETLSyntheaBuilder\"))")"'
```

The scripts are written in SQL Server dialect and translated to Postgres at run time (by the
OHDSI **SqlRender** package), which is why the folder is called `sql_server`.

---

## 5. Putting it together: provenance

Every row in the final database exists because of a specific version of **four** inputs. If any
one changes, the row can change:

| Stage | What to record | Where |
|---|---|---|
| NSDUH | Year, file name, codebook, variable mapping (`config.json`) | run log + `config.json` in git |
| Calibration | Hash of `joint_probabilities.json` | run log |
| Synthea | Version, seeds, config + module hashes, `COMMAND.txt` | run log + git |
| Athena | Release, bundle contents, CPT4 yes/no | run log |
| ETL | ETL-Synthea commit SHA, CDM version, patches applied | run log + Dockerfile |

And what each stage **can't** tell you:

| Stage | Can't tell you |
|---|---|
| NSDUH | Individual diagnoses; timing; anyone in institutions; precise local geography |
| Synthea | Whether a simulated pathway is clinically realistic; current codes |
| Athena | Whether *your* data's codes are included (only checking does that) |
| ETL | What it silently dropped (only reconciliation does that) |

---

## Lab

### Part A: NSDUH (codebook reading; about 20 minutes)

Open the 2024 codebook in `data/source/nsduh/2024/`.

1. Find the variable for **past-year any mental illness**. What values can it take? Which value
   means "yes"? Is there an explanation of how it's derived?
2. Find a **past-year substance use disorder** variable. Which DSM version's criteria does the
   codebook say it uses?
3. Find the **analysis weight** and the **design variables** (strata and clusters) the Data
   Users' Guide says to use for variance estimates.
4. Compare your answers with `services/calibration/config.example.json`. Which placeholder
   names need replacing?

### Part B: Synthea (about 20 minutes)

```bash
# 1. Copy the Synthea jar out of the image, so you can look inside it.
#    -T matters: without it, Compose attaches a terminal, which corrupts binary output.
docker compose --profile generate run --rm -T --entrypoint cat synthea /synthea/synthea.jar > /tmp/synthea.jar
unzip -tq /tmp/synthea.jar    # "No errors detected" = a clean copy

# 2. List the built-in modules
unzip -l /tmp/synthea.jar | grep -E 'modules/[a-z_]+\.json$' | wc -l
unzip -l /tmp/synthea.jar | grep -E 'modules/opioid_addiction\.json'

# 3. Read the opioid module's state names and types
unzip -p /tmp/synthea.jar modules/opioid_addiction.json | python3 -c '
import json, sys
m = json.load(sys.stdin)
for name, s in m["states"].items():
    print(s["type"].ljust(20), name)' | head -40
```

4. Find the state in `opioid_addiction.json` that produces the overdose death. What's its code?
   Does it match the `55680006` we found in `cdm.death`?
5. Open our `concurrent_disorders.json` in the module builder
   (<https://synthetichealth.github.io/module-builder/>). Draw the path a woman aged 40 takes
   if she's assigned "both".

### Part C: Athena (about 10 minutes)

```bash
# Which vocabularies did this bundle include, and which release?
cut -f1 data/vocab/athena/VOCABULARY.csv | sort
grep -P '^None\t' data/vocab/athena/VOCABULARY.csv

# Row counts: CSV vs database (they should match)
echo "csv: $(( $(wc -l < data/vocab/athena/CONCEPT_RELATIONSHIP.csv) - 1 ))"
```

```sql
SELECT COUNT(*) FROM cdm.concept_relationship;

-- Relationships pointing into Cancer Modifier: zero in the pilot's first bundle
SELECT COUNT(*)
  FROM cdm.concept_relationship cr
  JOIN cdm.concept c ON c.concept_id = cr.concept_id_2
 WHERE c.vocabulary_id = 'Cancer Modifier'
   AND cr.relationship_id = 'Maps to';
```

### Part D: the ETL (about 20 minutes)

```sql
-- 1. The lookup table for our module's codes
SELECT source_code, source_vocabulary_id, target_concept_id, target_vocabulary_id, target_domain_id
  FROM cdm.source_to_standard_vocab_map
 WHERE source_code IN ('370143000', '7200002') AND source_vocabulary_id = 'SNOMED';

-- 2. Staging vs CDM, table by table
SELECT 'conditions' AS t, (SELECT COUNT(*) FROM synthea.conditions) AS staged,
       (SELECT COUNT(*) FROM cdm.condition_occurrence) AS in_cdm
UNION ALL
SELECT 'encounters', (SELECT COUNT(*) FROM synthea.encounters),
       (SELECT COUNT(*) FROM cdm.visit_occurrence);
```

```bash
# 3. Read the filters in the condition script
docker compose --profile etl run --rm --entrypoint sh etl -c \
  'f=$(Rscript -e "cat(system.file(\"sql\", package=\"ETLSyntheaBuilder\"))"); \
   find "$f" -path "*v540*" -name "insert_condition_occurrence.sql" | xargs grep -n -i -E "join|domain|vocabulary"'
```

4. From query 2, are there fewer visits than encounters? Explain why using section 4.3.
5. From step 3, does `insert_condition_occurrence.sql` use an inner join with a domain filter,
   like `insert_death.sql` does? If so, what kind of condition could it drop?

---

## Check your understanding

1. Name two groups NSDUH doesn't survey, and one way that could matter for an SUD project.
2. Why can't you combine NSDUH 2019 with NSDUH 2024 to get a bigger sample?
3. In one sentence: why is NSDUH's AMI not a diagnosis?
4. A colleague worries that "both MHD and SUD" double-counts people whose only problem is substance use. Are they right?
5. Your calibration estimate from the PUF is 0.3 points away from SAMHSA's published figure. Bug?
6. What does `-p 1000` actually guarantee in Synthea?
7. Why could adding CVX to the Athena bundle change the *relationships* file, not just add CVX concepts?
8. What's the difference between an inner join and a left join for an ETL, and which matches OMOP's convention?
9. Why do `condition_era` and `drug_era` have no Synthea CSV of their own?

<details>
<summary><strong>Answers</strong></summary>

1. Any two of: active-duty military; people in institutions (hospitals, prisons, nursing homes,
   **treatment centres**); homeless people not in shelters. People in residential SUD
   treatment are exactly the population an SUD project cares about, and they're excluded.
2. Web interviewing (added in late 2020) broke comparability. Data from 2020 onward can't be
   pooled or compared with 2019 and earlier.
3. It's a **predicted** classification from a statistical model (built from clinician
   interviews in 2008–2012) applied to survey answers, not a clinical assessment of the person.
4. **No.** AMI is defined to **exclude** substance use disorders, so the two categories never overlap by definition.
5. **Probably not.** PUFs have disclosure-avoidance treatments, so their estimates are
   comparable to, but not identical to, the published ones.
6. 1,000 **living** people at the end of the simulation. Anyone who died is exported in addition.
7. Athena leaves out relationships pointing into vocabularies you didn't select. Adding CVX
   brings in the relationships *to* CVX concepts as well.
8. An inner join **drops** rows that don't match; a left join **keeps** them (with
   `concept_id = 0` after `COALESCE`). The left join matches OMOP's convention.
9. They're **derived** by the ETL from rows already loaded (condition and drug exposures
   combined into continuous periods), not generated by Synthea.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **NSDUH** | SAMHSA's annual survey of substance use and mental health, ages 12+ |
| **Civilian, noninstitutionalized** | NSDUH's target population: excludes active military, institutions, and unsheltered homeless people |
| **Cross-sectional** | Each person is surveyed once, with no follow-up |
| **MHSS** | Mental Health Surveillance Study (2008–2012): clinician interviews used to build NSDUH's mental illness model |
| **AMI / SMI** | Any / serious mental illness: model-based classifications, not diagnoses |
| **PUF** | Public use file: survey data with confidentiality protections applied |
| **Disclosure avoidance** | Methods (e.g. removing geography) that prevent identifying respondents |
| **Synthea** | Open-source simulator that generates synthetic patient lifetimes and records |
| **Module** | A Synthea state machine describing one disease or care process |
| **State machine** | States plus rules for moving between them |
| **Attribute** | A value stored on a simulated person, shared between modules |
| **Exporter** | The Synthea component that writes records (CSV, FHIR, …) |
| **Athena** | OHDSI's site for browsing and downloading the Standardized Vocabularies |
| **Bundle** | A downloaded set of selected vocabularies from one release |
| **ETL-Synthea** | OHDSI's R package that converts Synthea CSVs into OMOP |
| **source_to_standard_vocab_map** | ETL-Synthea's precomputed lookup from source codes to standard concepts |
| **Inner / left join** | Drop vs keep rows that don't match |
| **Era** | A derived OMOP row summarising a continuous period of a condition or drug |
| **Provenance** | The record of which inputs and versions produced a result |

---

## Further reading

- **NSDUH Data Users' Guide** (in `data/source/nsduh/2024/`): survey design, weights, variance.
- **NSDUH Methodological Summary and Definitions** reports, linked from the PUF page.
- **Synthea wiki**: especially *Generic Module Framework* and *Basic Setup and Running*:
  <https://github.com/synthetichealth/synthea/wiki>
- **The Book of OHDSI**: chapter 5 (Standardized Vocabularies) and chapter 6
  (Extract Transform Load): <https://ohdsi.github.io/TheBookOfOhdsi/>
- **ETL-Synthea documentation**: <https://ohdsi.github.io/ETL-Synthea/>
- **White Rabbit and Rabbit-in-a-Hat**: OHDSI tools for profiling source data and *designing*
  an ETL. Worth a look before writing one for real hospital data.

## Sources

NSDUH facts in section 1 are drawn from:

- SAMHSA, *NSDUH: Public-use Data (2024)*, population covered, exclusions, cross-sectional
  design, self-report limits, web-mode comparability break, PUF disclosure avoidance:
  <https://www.samhsa.gov/data/data-we-collect/nsduh-national-survey-drug-use-and-health/datafiles/2024>
- SAMHSA, *2018 NSDUH Detailed Tables, Section 8*, AMI definition (excludes developmental and
  substance use disorders; model-based, not diagnostic):
  <https://www.samhsa.gov/data/sites/default/files/cbhsq-reports/NSDUHDetailedTabs2018R2/NSDUHDetTabsSect8pe2018.htm>
- NCBI Bookshelf (SAMHSA/CBHSQ methodology report), the MHSS and the SMI/AMI cut-point model:
  <https://www.ncbi.nlm.nih.gov/books/NBK531549/>
- Kott, P. (2015), *Estimating mental illness among adults in the United States: revisions to
  2008 estimation procedures* (CBHSQ methodology report), ~5,000 MHSS clinical interviews, 2008–2012.
