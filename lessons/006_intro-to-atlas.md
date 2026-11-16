# Lesson 006: Introduction to ATLAS

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | 75 minutes (lecture + guided tour lab) |
| **Prerequisites** | Lessons 001 and 003 (OMOP tables, concepts, standard vs non-standard, `Maps to`, hierarchies) |
| **Project files** | README Step 9; a running `atlas` profile |
| **Previous lesson** | 005: Where Did 18 Deaths Go? |
| **Next lessons** | 007: ATLAS Deep Dive · 008: Our ATLAS Setup and the UI |

> **Address used in this lesson:** `http://localhost:8080/atlas/`. If you changed
> `ATLAS_PORT` in `.env`, use your port instead (e.g. `8086`).

## Learning objectives

By the end of this lesson you should be able to:

1. Say what problem ATLAS solves, and who it's for.
2. Describe ATLAS's three moving parts (browser app, WebAPI, CDM database) in one sentence each.
3. Define **concept set**, **cohort**, **cohort definition** and **cohort era** in OHDSI's own terms.
4. Name the main sections of the ATLAS menu and say what each is for.
5. Tell **pre-computed** results (Data Sources) apart from **on-demand** results (cohort generation).
6. Search the vocabulary, read a Data Sources report, and save a first concept set.

---

## 1. Why ATLAS exists

By Lesson 005 you could answer questions about our database, but only by writing SQL:
joins across `condition_occurrence`, `concept_ancestor` and `observation_period`, with
care around dates and domains. That works for engineers. It doesn't work for:

- a **clinician** who knows exactly which patients they mean, but not SQL;
- a **researcher** who needs the *same* definition run on ten hospitals' databases;
- a **reviewer** who needs to read a definition and check it's right.

ATLAS is OHDSI's answer: a web application where you **specify** an analysis by filling
in standard choices, and the software writes and runs the SQL. Two consequences matter:

| Property | What it means for you |
|---|---|
| **Standardized** | Two people making the same choices in ATLAS get the same SQL, so the same answer |
| **Portable** | A definition is saved as JSON. Any other OMOP database can run that JSON unchanged |

ATLAS grew out of several earlier, separate OHDSI tools (a vocabulary browser, a database
characterization tool, a cohort builder, a cohort characterization tool), merged into one
interface in 2016. You'll still see their names in places: **Achilles** (database
characterization) and **Circe** (the cohort definition engine) are both still in use.

---

## 2. Three moving parts

```
  Browser (ATLAS)  ──HTTP/JSON──▶  WebAPI (Java)  ──SQL──▶  PostgreSQL (OMOP CDM)
  what you see                     does the work            where the data lives
```

| Part | One-sentence job |
|---|---|
| **ATLAS** | A JavaScript app that runs *in your browser*; it draws screens and sends requests |
| **WebAPI** | A Java service that stores your definitions and turns them into SQL it runs on the CDM |
| **CDM database** | Our `omop-db`: the `cdm` tables from Step 7, plus `results` for output |

ATLAS **never** connects to the database itself. That's the single most useful fact for
debugging later (Lesson 008).

---

## 3. The vocabulary of ATLAS

These four terms come straight from OHDSI's own definitions. Learn them exactly.

| Term | OHDSI definition | Plain English |
|---|---|---|
| **Concept set** | A list of concepts, with rules for descendants and mapped codes, that together mean one clinical idea | "All the codes that mean *depression*" |
| **Cohort** | A set of persons who satisfy one or more inclusion criteria for a duration of time | "These people, between these dates" |
| **Cohort definition** | The specification for how to identify a cohort | The recipe |
| **Cohort era** | A continuous period during which a person has satisfied a cohort's inclusion criteria | One unbroken stretch of membership |

Two things in the cohort definition surprise most students:

1. **A cohort has dates.** It isn't "people with depression", it's "people with depression
   *from* date A *to* date B". That's why the output table, `results.cohort`, has exactly
   four columns: `cohort_definition_id`, `subject_id`, `cohort_start_date`, `cohort_end_date`.
2. **A person can be in a cohort more than once**, in separate eras, depending on how the
   definition says membership ends.

### The four questions every cohort definition answers

OHDSI teaches cohort building as four questions. Lesson 007 goes through each one in depth.

| # | Question | Example (MHD cohort) |
|---|---|---|
| 1 | What **initial event** defines entry? | A condition occurrence of an MHD concept |
| 2 | What **inclusion criteria** apply to that event? | Age ≥ 18 at the event; 365 days of prior observation |
| 3 | What defines **exit**? | End of continuous observation |
| 4 | How are events combined into **eras**? | Events within 30 days merge into one era |

---

## 4. A tour of the menu

ATLAS's left-hand menu, top to bottom (2.15). Sections marked ★ are the ones this course uses.

| Section | What it's for | Needs |
|---|---|---|
| **Home** | Links and version | n/a |
| ★ **Data Sources** | Pre-computed reports describing a whole database (people, conditions, drugs, data density) | Achilles |
| ★ **Search** | Vocabulary search: find concepts, their hierarchy and mappings | Vocabulary |
| ★ **Concept Sets** | Build and save concept sets | Vocabulary |
| ★ **Cohort Definitions** | Build, generate and inspect cohorts | CDM + results |
| **Characterizations** | Describe a cohort's features (conditions, drugs, demographics) | Generated cohorts |
| **Cohort Pathways** | Sequences of treatments (or events) within a cohort | Generated cohorts |
| **Incidence Rates** | New outcomes per person-time in a population | Generated cohorts |
| ★ **Profiles** | One person's timeline, event by event | CDM |
| **Estimation / Prediction** | Design comparative-effect and prediction studies, exported as R packages | Out of scope here |
| **Jobs** | Status of background work (e.g. cohort generation) | n/a |
| ★ **Configuration** | Which data sources are connected; clear WebAPI's caches | n/a |

### Pre-computed versus on-demand

ATLAS mixes two strategies, and knowing which one a screen uses saves a lot of confusion:

| Strategy | Screens | When the numbers are calculated | So if they look wrong… |
|---|---|---|---|
| **Pre-computed** | Data Sources; record counts (RC/DRC) in Search | When **Achilles** last ran | Rerun Achilles after every load |
| **On-demand** | Cohorts, characterizations, incidence, pathways | When you press **Generate** | Regenerate after every load |

> **Connection to Lesson 005.** After a reload, the CDM changes but these results don't
> update by themselves. Stale results are another kind of silent mismatch between stages.

---

## 5. Concept sets: the building block

Every analysis in ATLAS starts from concept sets. Each entry in a set has three switches:

| Switch | Effect | Default advice |
|---|---|---|
| **Include descendants** | Adds every concept *below* this one in the hierarchy (`concept_ancestor`) | Usually **on** |
| **Include mapped** | Adds non-standard source codes that `Maps to` this concept | **Off** for cohorts (the CDM stores standard concepts); useful for *source* searches |
| **Exclude** | Removes this concept (and, with descendants on, its children) from the set | For carving out exceptions |

The **Included Concepts** tab shows the set *after* those rules are applied. Always read it
before you trust a concept set: one wrong "include descendants" can pull in hundreds of
concepts you didn't mean.

---

## Lab: a guided tour (45 minutes)

Run this against **our** database, source `SYNTH_OMOP`. Write your answers down: Lesson 007
builds on them.

### Part 1: Configuration (5 minutes)

1. Open ATLAS. Is there a "cannot connect to WebAPI" banner? (There shouldn't be.)
2. Go to **Configuration**. Write down the source name, its key, and which daimons it lists.

### Part 2: Data Sources (10 minutes)

1. **Data Sources** → `SYNTH_OMOP` → **Dashboard**. Record the person count.
2. In SQL, run `SELECT COUNT(*) FROM cdm.person;`. Does it match? (It should; if not, when did
   Achilles last run?)
3. Open the **Person** report. Is the age distribution what you'd expect, given
   `SYNTHEA_AGE_RANGE=18-85`?
4. Open the **Condition** report. Find your MHD diagnosis. How many people have it?

### Part 3: Search (10 minutes)

1. **Search** for `depressive disorder`. Filter to **Standard** concepts in the **Condition** domain.
2. Open the concept your Synthea module uses for MHD. Note its `concept_id`.
3. Look at its **Hierarchy** tab: name one parent and one child.
4. What are **RC** and **DRC** in the results grid? (Hint: Record Count, Descendant Record Count.)
   Why might DRC be larger than RC?

### Part 4: Your first concept set (10 minutes)

1. Create a concept set called `MHD (course)`. Add your MHD concept with **Include descendants** on.
2. Open **Included Concepts**. How many concepts did "include descendants" add?
3. Save it. Then create `SUD (course)` the same way, for your SUD concept.

### Part 5: Profiles (10 minutes)

1. Pick any `person_id` (e.g. `SELECT person_id FROM cdm.condition_occurrence LIMIT 1;`).
2. **Profiles** → `SYNTH_OMOP` → enter it. Find the MHD/SUD diagnoses on the timeline.
3. Does the timeline match what the module says should happen (Step 5)?

---

## Check your understanding

1. Why does ATLAS never connect to the database directly, and what does that change when debugging?
2. Give the OHDSI definition of a cohort. Why does "for a duration of time" matter?
3. A colleague reloads the CDM, and the Data Sources dashboard still shows the old person count. Why?
4. What's the difference between RC and DRC?
5. Why is **Include mapped** usually off for concept sets used in cohorts?
6. Name the four questions every cohort definition answers.

<details>
<summary><strong>Answers</strong></summary>

1. ATLAS runs in the browser and only talks to WebAPI. So a database problem shows up as a
   WebAPI error (in WebAPI's logs), never as an ATLAS one. Debugging starts at WebAPI.
2. "A set of persons who satisfy one or more inclusion criteria for a duration of time." The
   duration is what lets analyses ask *when* something happened relative to cohort entry, and
   lets a person be a member more than once.
3. Data Sources reports are **pre-computed by Achilles**. Rerun Achilles, then restart WebAPI
   (or clear its cache in Configuration).
4. RC counts records of *this* concept; DRC counts records of this concept *and all its
   descendants*, so DRC ≥ RC.
5. CDM event tables store **standard** concepts in their `*_concept_id` fields. Mapped
   (non-standard) codes only appear in `*_source_concept_id`, so including them adds nothing
   to a standard-concept cohort and makes the set harder to read.
6. Initial event; inclusion criteria; exit; eras.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **ATLAS** | OHDSI's web application for vocabulary search, cohort definition and standardized analytics |
| **WebAPI** | The Java backend ATLAS calls; stores definitions and runs SQL on the CDM |
| **Source / daimon** | A database WebAPI can query / the role a schema plays in it (CDM, Vocabulary, Results, Temp) |
| **Concept set** | A reusable list of concepts with descendant/mapped/exclude rules |
| **Cohort** | Persons satisfying criteria for a duration of time |
| **Cohort era** | One continuous stretch of cohort membership |
| **Achilles** | R package that pre-computes the Data Sources reports |
| **Circe** | The engine that turns a cohort definition (JSON) into SQL |
| **RC / DRC** | Record count / descendant record count, shown in Search |

---

## Further reading

- **The Book of OHDSI**, chapter 8 (OHDSI Analytics Tools): <https://ohdsi.github.io/TheBookOfOhdsi/OhdsiAnalyticsTools.html>
- **The Book of OHDSI**, chapter 10 (Defining Cohorts): <https://ohdsi.github.io/TheBookOfOhdsi/Cohorts.html>
- **OHDSI public ATLAS demo**, to practise on a different database: <https://atlas-demo.ohdsi.org/>
- **OHDSI tutorials** (recorded cohort-building sessions): <https://www.ohdsi.org/resources/tutorials/>
- **ATLAS wiki**: <https://github.com/OHDSI/Atlas/wiki>
