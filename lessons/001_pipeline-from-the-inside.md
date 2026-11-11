# Lesson 001: The Pipeline from the Inside

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | 60–75 minutes (lecture + lab) |
| **Prerequisites** | Basic command line (`cd`, `ls`), a little SQL (`SELECT … FROM … WHERE`) |
| **Project** | `synthetic-omop`: Synthea → ETL-Synthea → PostgreSQL (OMOP CDM 5.4), run locally with Docker Compose |
| **Next lesson** | 002: Calibration (why we estimate disorders *jointly*) |

## Learning objectives

By the end of this lesson you should be able to:

1. Explain **why** synthetic data and a Common Data Model exist.
2. Describe what Docker **images, containers, services and profiles** are, using `compose.yaml` as the example.
3. Explain how containers **find each other** on a Compose network, and how the host reaches them.
4. Tell the difference between **bind mounts** and **named volumes**, and predict what `down` vs `down -v` does.
5. Describe the **database → schema → table** hierarchy, and why the project uses a staging schema.
6. Trace one record through **Extract, Transform, Load**.
7. Explain what OMOP **standard concepts** and the **"Maps to"** relationship are for.

---

## 0. Why this exists at all

Two problems motivate everything in this project:

1. **Real patient data is locked down**, and rightly so (HIPAA, IRB review). You can't hand it to
   students or test software against it freely. *Synthetic* data looks like patient data but
   describes no real person.
2. **Every hospital stores data differently.** One system calls a field `dx_code`, another
   `diagnosis`. One codes in ICD-10, another in SNOMED. A study written for Hospital A won't run
   at Hospital B. A **Common Data Model** (OMOP) fixes this by giving everyone the same tables and
   the same codes, so one query runs everywhere.

The pipeline produces synthetic data, then converts it into that common shape.

---

## 1. Containers: an apartment building

Think of `compose.yaml` as the **floor plan for an apartment building**. Each *service*
(`omop-db`, `synthea`, `etl`, `calibration`) is an **apartment**:

- Each has its own furniture: Postgres in one, Java in another, R in a third. They never
  conflict over software versions.
- Apartments can be torn down and rebuilt identically from the plan. That's what
  `docker compose build` does.
- An **image** is the blueprint for one apartment. A **container** is an apartment someone is
  living in right now.

**Profiles** are why only the database "moves in" with a plain `docker compose up`. The other
services are built on demand, one step at a time, when you ask for them with `--profile`.

---

## 2. How containers find each other: the building's intercom

```
 Your laptop (host)
 ┌───────────────────────────────────────────────────────────┐
 │  127.0.0.1:5432  ◀── the building's front door (DBeaver)  │
 │        │                                                  │
 │  ┌─────┼─────── Compose network (the intercom) ────────┐  │
 │  │     ▼                                               │  │
 │  │  [omop-db]  ◀── "omop-db:5432" ──  [etl]            │  │
 │  │   Postgres                          R + ETL-Synthea │  │
 │  │                                                     │  │
 │  │  [synthea]   [calibration]   (don't use the DB)     │  │
 │  └─────────────────────────────────────────────────────┘  │
 └───────────────────────────────────────────────────────────┘
```

**Inside** the building, apartments call each other **by service name**. The ETL dials
`omop-db`, and Docker's built-in DNS connects the call. That's why `compose.yaml` says:

```yaml
DB_SERVER: omop-db/${OMOP_DB_NAME}   # hostname = the service name, not an IP address
```

The `ports:` line installs a **front door** so *you*, outside the building, can reach Postgres:

```yaml
ports:
  - "127.0.0.1:${OMOP_DB_PORT:-5432}:5432"   # host_ip:host_port:container_port
```

Binding to `127.0.0.1` means the door opens only from your own machine, not from anyone else on
your network. That's a small configuration choice with a real security effect.

---

## 3. Where data lives: apartments are disposable, storage units aren't

When a container is removed, everything written *inside* it disappears. Data that matters has
to live somewhere outside the container. The project uses two kinds of outside storage:

| Kind | In this project | Analogy | Where you can see it |
|---|---|---|---|
| **Bind mount** | `./data/synthea-output:/output` | A window into a folder in *your* home | The `data/` folder on your machine |
| **Named volume** | `omop-pgdata` | A storage unit Docker manages for you | Not directly; try `docker volume inspect synthetic-omop_omop-pgdata` |

This explains a command pair that trips people up:

| Command | Containers | Named volumes (your database) |
|---|---|---|
| `docker compose down` | Removed | **Kept** |
| `docker compose down -v` | Removed | **Deleted** |

### Case study: the bugs we actually hit

Each of these was a lesson about this layer, and each is a classic exam question in disguise.

| Error | What was really going on | Concept |
|---|---|---|
| `mkdir: Permission denied` | A bind mount is your *real* folder, so Linux file ownership applies. The container ran as UID 1001; the folder belongs to UID 1000. Linux checks the **number**, not the username. Fix: `user: "1000:1000"`. | UIDs, bind mounts |
| `Unable to access jarfile` | The same idea, inside the image: the jar was owned by root with mode `600` (only the owner may read it). Fix: `ADD --chmod=0644`. | File modes |
| `role "root" does not exist` | `.env` is read by **Compose**, not by your **shell**, so `$OMOP_DB_USER` was empty in the terminal and psql fell back to your OS username. | Separate environments |
| `sudo` didn't help | `sudo` elevated the Docker *client* on the host. The process *inside* the container still ran as the image's user. | Host vs container |

---

## 4. Database → schema → table: a filing cabinet

- **Database** (`synthetic_concurrent`): the whole filing cabinet.
- **Schema** (`synthea`, `cdm`, `results`): the drawers.
- **Table** (`person`, `concept`, `condition_occurrence`…): the folders inside a drawer.

| Schema | What lands there |
|---|---|
| `synthea` | Raw Synthea CSVs as staging tables (`patients`, `conditions`, …), *exactly as they arrived* |
| `cdm` | OMOP tables (`person`, `condition_occurrence`, `visit_occurrence`, …) plus the Athena vocabulary (`concept`, `concept_relationship`, …) |
| `results` | Output of analyses (Data Quality Dashboard, later Atlas) |

Why three drawers? This is a standard pattern called **staging**:

- `synthea` keeps the raw input untouched. If something looks wrong later, you can compare the
  output against the original.
- `cdm` is the cleaned, standardized product.
- `results` keeps analysis output separate, so it never contaminates the source data.

---

## 5. ETL: Extract, Transform, Load

That's the `etl` container's whole job. Following one synthetic diagnosis through it:

**Extract.** A row from `conditions.csv` is loaded into `synthea.conditions`:

```
START=2025-03-14  PATIENT=a1b2…  CODE=370143000  DESCRIPTION=Major depressive disorder (disorder)
```

**Transform.** The row is reshaped to OMOP's rules:

| Synthea field | OMOP field | What changes |
|---|---|---|
| `PATIENT` (UUID) | `person_id` | Becomes an integer key |
| `CODE` (SNOMED) | `condition_concept_id` | **Mapped to a standard concept** (section 6) |
| `CODE` (SNOMED) | `condition_source_value` | Original kept for traceability |
| `START` | `condition_start_date` | Renamed and typed as a date |

**Load.** The result is inserted as a row in `cdm.condition_occurrence`.

Multiply that by every row in every CSV, and that's an ETL run.

---

## 6. Vocabularies: the Rosetta Stone

The same clinical idea, "major depressive disorder," has different codes in SNOMED, ICD-10,
Read codes and others. If Hospital A codes in ICD-10 and Hospital B in SNOMED, a shared query
breaks.

OMOP's answer is the **Athena vocabulary** (about 6 GB of CSVs in this project):

- Every code from every vocabulary becomes a row in `cdm.concept`, with its own `concept_id`.
- For each *idea*, one concept is marked **standard** (`standard_concept = 'S'`).
- `cdm.concept_relationship` holds **"Maps to"** links from each non-standard code to its
  standard equivalent.

So analyses are written against **standard concept_ids**, and they work no matter which coding
system the source data used. That portability is the whole point of a Common Data Model.

---

## Lab: explore the database

Run these once the ETL has finished. Connect with DBeaver or pgAdmin at `localhost:5432`
(database `synthetic_concurrent`, user and password from your `.env`), or use:

```bash
docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

**Query 1: is SNOMED's MDD code a standard concept?**

```sql
SELECT concept_id, concept_name, vocabulary_id, standard_concept
  FROM cdm.concept
 WHERE vocabulary_id = 'SNOMED'
   AND concept_code = '370143000';
```

**Query 2: what does ICD-10 F32.9 (MDD, single episode) map to?**

```sql
SELECT c1.concept_code   AS icd10_code,
       c2.concept_id     AS standard_concept_id,
       c2.concept_name,
       c2.vocabulary_id
  FROM cdm.concept c1
  JOIN cdm.concept_relationship cr
    ON cr.concept_id_1    = c1.concept_id
   AND cr.relationship_id = 'Maps to'
  JOIN cdm.concept c2
    ON c2.concept_id = cr.concept_id_2
 WHERE c1.vocabulary_id = 'ICD10CM'
   AND c1.concept_code  = 'F32.9';
```

> Notice what comes back. It may not be the SNOMED code you'd guess. That gap between
> "the code someone recorded" and "the standard concept" is exactly what OMOP manages.

**Query 3: the module's diagnoses, as OMOP stores them**

```sql
SELECT co.person_id,
       co.condition_start_date,
       c.concept_name,
       co.condition_source_value
  FROM cdm.condition_occurrence co
  JOIN cdm.concept c
    ON c.concept_id = co.condition_concept_id
 WHERE co.condition_source_value IN ('370143000', '7200002')
 LIMIT 10;
```

**Query 4 (stretch): watch a load in progress**

```sql
-- Estimated row counts per table; useful while the vocabulary is loading
SELECT schemaname, relname, n_live_tup
  FROM pg_stat_user_tables
 WHERE schemaname IN ('synthea', 'cdm')
 ORDER BY n_live_tup DESC
 LIMIT 15;
```

---

## Check your understanding

1. You run `docker compose down`, then `docker compose up -d`. Is your OMOP data still there?
   What about after `docker compose down -v`?
2. Why can the `etl` container reach `omop-db:5432`, while your laptop must use
   `localhost:5432`?
3. Why keep the raw `synthea` schema at all, once `cdm` is populated?
4. A query filters on `condition_source_value = '370143000'`. Why is that worse than filtering
   on `condition_concept_id`?
5. Why did `sudo docker compose run` *not* fix the permission error?

<details>
<summary><strong>Answers</strong></summary>

1. **Yes** after `down`, because the named volume `omop-pgdata` persists. **No** after
   `down -v`, because `-v` deletes named volumes.
2. Inside the Compose network, Docker's DNS resolves **service names**. From outside, traffic
   goes through the **published port** on the host.
3. **Traceability and debugging.** You can always check the standardized data against what
   actually arrived.
4. It only catches data coded in SNOMED with that exact code. The standard `concept_id` catches
   the same clinical idea **however it was coded at the source**. That portability is OMOP's purpose.
5. `sudo` elevated the Docker CLI on the **host**. The process **inside** the container still ran
   as the image's user, which didn't own the folder.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Image** | A read-only blueprint for a container |
| **Container** | A running instance of an image |
| **Service** | A named container definition in `compose.yaml` |
| **Profile** | A label that keeps a service from starting unless asked for |
| **Bind mount** | A host folder mapped into a container |
| **Named volume** | Docker-managed storage that outlives containers |
| **Schema** | A namespace ("drawer") for tables inside a database |
| **Staging** | Keeping raw input separate from the cleaned product |
| **ETL** | Extract, Transform, Load: moving data from one shape to another |
| **Concept** | One coded idea in the OMOP vocabulary, with a `concept_id` |
| **Standard concept** | The one concept OMOP chooses to represent an idea (`standard_concept = 'S'`) |
| **"Maps to"** | The relationship linking a non-standard code to its standard concept |

---

## Further reading

- **The Book of OHDSI**, chapters 4 (Common Data Model) and 5 (Standardized Vocabularies).
  Free, and the clearest source for sections 4–6: <https://ohdsi.github.io/TheBookOfOhdsi/>
- **Docker docs: "Networking in Compose"** and **"Volumes"**, the primary sources for
  sections 2–3: <https://docs.docker.com/compose/how-tos/networking/> ·
  <https://docs.docker.com/engine/storage/volumes/>
- **EHDEN Academy**: free, structured OMOP CDM and vocabulary courses:
  <https://academy.ehden.eu/>
- **Linux file permissions** (`chmod`, `chown`, UIDs and GIDs): any short tutorial on these
  explains half of the bugs in section 3.
