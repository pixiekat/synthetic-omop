# Synthetic Concurrent-Disorders Data in OMOP CDM 5.4

**A step-by-step setup guide: NSDUH → Synthea → ETL-Synthea → PostgreSQL (OMOP), run locally with Docker Compose**

| | |
|---|---|
| **Status** | **Pilot run end to end** (`pilot-0001`, 2026-11-11): Synthea → ETL-Synthea → OMOP 5.4 loaded and checked. Calibration still uses **placeholder** probabilities; real NSDUH estimates are the next milestone. |
| **Audience** | Engineers who build the pipeline (admin) and analysts who use the resulting database (non-admin) |
| **Pinned versions** | Synthea `v3.3.0`, OMOP CDM `5.4`, ETL-Synthea (`OHDSI/ETL-Synthea`, pinned to a commit), PostgreSQL `16`, Athena vocabulary `v5.0 29-AUG-26`, WebAPI `2.15.1` + Atlas `2.15.0` (optional, Step 9) |
| **Atlas status** | **Running on the pilot machine** (2026-11-16): WebAPI 2.15.1 + Atlas 2.15.0, source `SYNTH_OMOP` registered, Achilles loaded (30,747 `achilles_results` rows), Data Sources reports working. Still to do: the 9f cohort smoke test. |
| **Analyses status** | Step 10 (TreatmentPatterns, CohortContrast) is **new and not yet run**. Next: Comorbidity4j, then PatientExploreR (trial run) |
| **Source notes** | Builds on the OMOP project's planning notes. The method is unchanged; this guide adds the local Docker setup. |
| **Lessons** | Teaching material for this pipeline lives in [`lessons/`](lessons/) (see [Further learning](#further-learning)). |

---

## Table of contents

1. [What we're building (and what we're not)](#1-what-were-building-and-what-were-not)
2. [Prerequisites](#2-prerequisites)
3. [Project layout](#3-project-layout)
4. [Step 1: Scaffold the repository](#step-1-scaffold-the-repository)
5. [Step 2: Docker Compose stack](#step-2-docker-compose-stack)
6. [Step 3: Download the source data (NSDUH and Athena)](#step-3-download-the-source-data-nsduh-and-athena)
7. [Step 4: Estimate the joint disorder distribution](#step-4-estimate-the-joint-disorder-distribution)
8. [Step 5: Build the Synthea parent module](#step-5-build-the-synthea-parent-module)
9. [Step 6: Generate the synthetic population](#step-6-generate-the-synthetic-population)
10. [Step 7: Load into OMOP with ETL-Synthea](#step-7-load-into-omop-with-etl-synthea)
    - [7a. Verify the load](#7a-verify-the-load)
    - [7b. Known ETL-Synthea gap: dropped deaths](#7b-known-etl-synthea-gap-dropped-deaths)
    - [7c. Known ETL-Synthea gap: dropped immunizations](#7c-known-etl-synthea-gap-dropped-immunizations)
    - [7d. Pin, record, back up](#7d-pin-record-back-up)
11. [Step 8: Validate](#step-8-validate)
12. [Step 9 (optional): ATLAS and WebAPI](#step-9-optional-atlas-and-webapi)
    - [9a. How the pieces fit](#9a-how-the-pieces-fit)
    - [9b. Prepare the database and start WebAPI](#9b-prepare-the-database-and-start-webapi)
    - [9c. Register our CDM as a source](#9c-register-our-cdm-as-a-source)
    - [9d. Create the results tables](#9d-create-the-results-tables)
    - [9e. Run Achilles (Data Sources reports)](#9e-run-achilles-data-sources-reports)
    - [9f. Open Atlas and check it](#9f-open-atlas-and-check-it)
    - [9g. Alternative: full Broadsea](#9g-alternative-full-broadsea)
13. [Step 10 (optional): Cohort analyses: TreatmentPatterns and CohortContrast](#step-10-optional-cohort-analyses-treatmentpatterns-and-cohortcontrast)
    - [10a. How it fits](#10a-how-it-fits)
    - [10b. Prepare (once)](#10b-prepare-once)
    - [10c. Define and generate the cohorts in ATLAS](#10c-define-and-generate-the-cohorts-in-atlas)
    - [10d. Study files](#10d-study-files)
    - [10e. Run TreatmentPatterns](#10e-run-treatmentpatterns)
    - [10f. Run CohortContrast](#10f-run-cohortcontrast)
    - [10g. The CohortContrast viewer (to finish after the first run)](#10g-the-cohortcontrast-viewer-to-finish-after-the-first-run)
    - [10h. Shared helpers](#10h-shared-helpers)
14. [QA checklist](#qa-checklist)
15. [Troubleshooting](#troubleshooting)
16. [Security and usability suggestions](#security-and-usability-suggestions)
17. [Further learning](#further-learning)

---

## 1. What we're building (and what we're not)

```
 ┌──────────────┐   weighted joint    ┌──────────────┐   CSV    ┌──────────────┐   SQL    ┌──────────────┐
 │  NSDUH 2024  │ ──probabilities──▶  │   Synthea    │ ───────▶ │ ETL-Synthea  │ ───────▶ │  PostgreSQL  │
 │  public file │   (calibration)     │ + our module │          │  (R / HADES) │          │  OMOP 5.4    │
 └──────────────┘                     └──────────────┘          └──────────────┘          └──────┬───────┘
                                                                                                 │
                                         Athena vocabularies (SNOMED, RxNorm, LOINC) ────────────┤
                                                                                                 ▼
                                                                          DQD + our validation SQL (+ Atlas, optional)
```

**In scope:**

- A synthetic adult population (18+) in which mental health disorder (MHD) and substance use disorder (SUD) occur together at frequencies taken from **joint** NSDUH estimates within age and sex strata. The two disorders are never sampled independently.
- Four comparison groups: **neither / MHD only / SUD only / both**.
- 24 months of simulated history loaded into OMOP CDM 5.4.
- Recorded provenance: seeds, versions, configuration, and assumptions.

**Out of scope, or not supported by this design:**

- **Disease trajectories.** NSDUH is cross-sectional, so onset timing, relapse, and visit cadence are *simulation assumptions*, and we document them as such.
- **Specific diagnoses taken from survey categories.** "Any mental illness" does not become "major depressive disorder" unless we explicitly assume it and record that assumption.
- **Treatment-effectiveness research.** Passing OMOP checks shows structural quality, not clinical realism.
- **Inpatient or residential populations.** NSDUH covers the civilian, noninstitutionalized population.

> **Note:** Synthea output is synthetic and contains no PHI, so this stack can run on a laptop. Do **not** point it at a database or volume that holds real patient data.

---

## 2. Prerequisites

| Tool | Why | Check |
|---|---|---|
| Docker Engine 24+ with Compose v2 | Runs everything below | `docker compose version` |
| ~40 GB free disk | Athena vocabularies take several GB unzipped, and Postgres needs more again once they're loaded | `df -h` |
| 8 GB+ RAM available to Docker | Loading the vocabulary and the ETL are memory-hungry | Docker settings |
| Athena account | Vocabulary download | <https://athena.ohdsi.org/> |
| UMLS API key (optional) | Only needed if you include CPT4 in the vocabulary bundle | <https://uts.nlm.nih.gov/> |
| A SQL client (DBeaver, psql, pgAdmin) | Inspecting results | |

Java, R and Python are **not** needed on the host. Each runs inside its own container.

---

## 3. Project layout

Each service gets its own folder holding its Dockerfile, config and code. Data lives in one place, split into what you download and what the pipeline generates.

```
synthetic-omop/
├── .editorconfig                  # 2-space indent everywhere, LF line endings
├── .env.example                   # Copy to .env; never commit .env
├── .gitignore                     # Keeps data/ and secrets out of git
├── compose.yaml                   # The whole stack, organised by profiles
├── README.md                      # This guide
│
├── docs/
│   ├── assumptions.md             # Every simulation assumption, numbered (A-001 …)
│   └── run-log.md                 # One row per generation run (provenance)
│
├── lessons/                       # Teaching material: lectures, labs, self-check questions
│   ├── 001_pipeline-from-the-inside.md
│   ├── 002_calibration.md
│   ├── 003_omop-concepts.md
│   ├── 004_pipeline-deep-dive.md
│   ├── 005_where-did-18-deaths-go.md
│   ├── 006_intro-to-atlas.md
│   ├── 007_atlas-deep-dive.md
│   ├── 008_our-atlas-setup-and-the-ui.md
│   ├── 009_synthea-to-cdm-internals.md
│   ├── 010_athena-and-the-vocabularies.md
│   └── 011_cohort-analytics.md
│
├── backups/                       # ⚠ gitignored. pg_dump files of loaded databases (Step 7d)
│
├── data/                          # ⚠ gitignored. Large, licensed, or generated.
│   ├── source/
│   │   └── nsduh/2024/            # NSDUH PUF + codebook + Data Users' Guide
│   ├── vocab/
│   │   ├── athena/                # The 10 OMOP vocabulary CSVs ONLY (the ETL reads this folder)
│   │   └── athena-extras/         # Original zip, CPT4 tool, *_METADATA files (kept out of the ETL's way)
│   ├── analyses/                  # Step 10 results: <RUN_ID>/<tool>/<study>/ (gitignored with data/)
│   ├── atlas/                     # Generated results DDL from WebAPI (Step 9d), kept for provenance
│   ├── calibration/               # Output of Step 4 (joint_probabilities.json)
│   ├── synthea-output/
│   │   └── <run-id>/csv/          # One folder per Synthea run
│   └── dqd/                       # Data Quality Dashboard results JSON
│
└── services/
    ├── postgres/
    │   └── initdb/
    │       └── 01_schemas.sql     # Creates synthea / cdm / results schemas
    ├── analytics/                 # Optional cohort analyses (Step 10)
    │   ├── Dockerfile             # R + TreatmentPatterns + CohortContrast (dated package snapshot)
    │   ├── R/common.R             # Shared helpers: config, connections, cohort checks, provenance
    │   ├── run_treatment_patterns.R
    │   ├── run_cohort_contrast.R
    │   ├── sql/01_analytics_scratch.sql   # Throwaway write schema, owned by ohdsi_app
    │   └── studies/               # One committed .env per analysis (cohort IDs + settings)
    ├── atlas/                     # Optional OHDSI web stack (Step 9)
    │   ├── nginx.conf             # One front door: /atlas → Atlas, /WebAPI → WebAPI
    │   └── sql/
    │       ├── 01_roles_and_schemas.sql   # ohdsi_app role; webapi + temp schemas; grants
    │       └── 02_register_source.sql     # Registers omop-db as a WebAPI source (daimons)
    ├── calibration/
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   ├── config.example.json    # NSDUH variable names → our definitions
    │   └── estimate_joint.py      # Weighted joint probabilities by stratum
    ├── synthea/
    │   ├── Dockerfile
    │   ├── run.sh                 # Wraps java -jar with our flags
    │   ├── config/
    │   │   └── synthea.local.properties
    │   ├── modules/
    │   │   └── concurrent_disorders.json   # Parent module (Step 5)
    │   └── keep/
    │       └── keep_concurrent.json        # Optional: keep only "both" patients
    └── etl/
        ├── Dockerfile
        ├── run_etl.R              # ETL-Synthea call sequence, step toggles
        ├── run_achilles.R         # Characterization for Atlas's Data Sources pages (Step 9e)
        └── sql/
            ├── validate_joint.sql               # Compares OMOP joint counts to targets
            ├── patch_missing_deaths.sql         # Restores deaths the standard ETL drops (Step 7b)
            ├── patch_missing_immunizations.sql  # Restores immunizations the standard ETL drops (Step 7c)
            └── patch_race_concepts.sql          # Maps native/hawaiian race (A-009); run only after review
```

---

## Step 1: Scaffold the repository

```bash
# Create the tree in one go. Brace expansion needs bash or zsh.
mkdir -p synthetic-omop/{docs,data/{source/nsduh/2024,vocab/athena,calibration,synthea-output,dqd}} \
  synthetic-omop/services/{postgres/initdb,calibration,synthea/{config,modules,keep},etl/sql}
cd synthetic-omop
git init   # local only; commit when you've reviewed things
```

> Create the `data/` folders yourself, as above. If Docker creates a missing bind-mount folder, it makes it **owned by root**, and the pipeline containers (which run as your UID) then can't write to it.

### `.editorconfig`

```ini
# EditorConfig: https://editorconfig.org
# Keeps indentation consistent across editors and across the team.
root = true

[*]
charset = utf-8
end_of_line = lf
indent_style = space
indent_size = 2
insert_final_newline = true
trim_trailing_whitespace = true

# Markdown uses trailing double-space as a hard line break, so keep it.
[*.md]
trim_trailing_whitespace = false

# Python convention is 4 spaces (PEP 8). Change this to 2 if you prefer
# house style over PEP 8, but keep it consistent within the repo.
[*.py]
indent_size = 4
```

### `.gitignore`

```gitignore
# Secrets
.env

# Everything under data/ is large, licensed (Athena, NSDUH terms) or generated.
# Keep the folder structure with .gitkeep files.
data/**
!data/**/
!data/**/.gitkeep

# Database dumps: large, and they contain the full licensed vocabulary
backups/
*.dump

# R / Python cruft
.Rhistory
.RData
__pycache__/
*.pyc
```

### `.env.example`

```dotenv
# ---------------------------------------------------------------------------
# Copy to .env and fill in. .env is gitignored. Do not commit real passwords.
# ---------------------------------------------------------------------------

# PostgreSQL (OMOP target)
OMOP_DB_NAME=synthetic_concurrent
OMOP_DB_USER=omop_admin
OMOP_DB_PASSWORD=change-me-to-something-long
# Bound to 127.0.0.1 in compose.yaml, so it isn't exposed to the network.
OMOP_DB_PORT=5432

# Your HOST user/group IDs. Run `id -u` and `id -g` and paste the numbers here.
# The calibration, synthea and etl containers run as this user, so files they
# write into ./data are owned by you and not by an unknown in-image user.
LOCAL_UID=1000
LOCAL_GID=1000

# Synthea run parameters. Change RUN_ID for every run (see docs/run-log.md).
RUN_ID=pilot-0001
SYNTHEA_SEED=12345
SYNTHEA_POPULATION=1000
SYNTHEA_AGE_RANGE=18-85
SYNTHEA_STATE=Massachusetts

# ETL step toggles (see services/etl/run_etl.R)
ETL_CREATE_CDM=true
ETL_LOAD_VOCAB=true
ETL_RUN_DQD=false

# --- Optional: ATLAS / WebAPI (Step 9, profile "atlas") ----------------------
# Login for the least-privilege ohdsi_app role WebAPI uses. It goes into a JDBC
# URL, so letters, digits, _ and - ONLY, and at least 16 characters.
# Generate one with:  openssl rand -hex 24
OHDSI_APP_PASSWORD=change-me-hex-from-openssl
# Keep WebAPI and Atlas on the same minor version (2.15 ↔ 2.15).
WEBAPI_VERSION=2.15.1
ATLAS_VERSION=2.15.0
# Host port for the Atlas/WebAPI proxy (bound to 127.0.0.1).
ATLAS_PORT=8080
```

---

## Step 2: Docker Compose stack

Services sit behind **profiles**, so the plain `docker compose up` starts only the database. Every other step runs on purpose, one at a time, which makes each step easier to rerun, inspect and debug.

### `compose.yaml`

```yaml
# =============================================================================
# Synthetic concurrent-disorders → OMOP CDM 5.4, local stack
#
# Profiles (run one step at a time):
#   (none)      → omop-db only
#   calibrate   → estimate joint disorder probabilities from NSDUH (Step 4)
#   generate    → run Synthea with our module (Step 6)
#   etl         → load Synthea CSV + Athena vocab into OMOP (Step 7)
#   atlas       → OHDSI WebAPI + Atlas + proxy, optional (Step 9)
#   analytics   → TreatmentPatterns, CohortContrast, optional (Step 10)
#
# Usage:
#   docker compose up -d                                   # database
#   docker compose --profile calibrate run --rm calibration
#   docker compose --profile generate  run --rm synthea
#   docker compose --profile etl       run --rm etl
#   docker compose --profile atlas     up -d               # long-running web stack
#   docker compose --profile analytics run --rm -e STUDY=<name> analytics Rscript /app/run_<tool>.R
# =============================================================================
name: synthetic-omop

services:

  # ---------------------------------------------------------------------------
  # omop-db: PostgreSQL target for OMOP CDM 5.4
  # Schemas (from initdb/01_schemas.sql):
  #   synthea → raw Synthea staging tables
  #   cdm     → OMOP CDM + vocabulary tables
  #   results → analysis output (Achilles / Atlas / our validation)
  # Created later by services/atlas/sql/01_roles_and_schemas.sql (Step 9):
  #   webapi  → WebAPI's own application tables
  #   temp    → WebAPI scratch space for cohort generation
  # ---------------------------------------------------------------------------
  omop-db:
    image: postgres:16
    container_name: omop-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${OMOP_DB_NAME}
      POSTGRES_USER: ${OMOP_DB_USER}
      POSTGRES_PASSWORD: ${OMOP_DB_PASSWORD}
      # Not used by Postgres itself. It's here so the Step 9 setup scripts can
      # read it INSIDE the container ($OHDSI_APP_PASSWORD), the same way the
      # other psql commands in this guide read $POSTGRES_USER.
      OHDSI_APP_PASSWORD: ${OHDSI_APP_PASSWORD:-}
    ports:
      # Localhost only. Remove "127.0.0.1:" ONLY if you know you need LAN access.
      - "127.0.0.1:${OMOP_DB_PORT:-5432}:5432"
    volumes:
      - omop-pgdata:/var/lib/postgresql/data
      # Scripts here run once, the first time the volume is created.
      - ./services/postgres/initdb:/docker-entrypoint-initdb.d:ro
    # Vocabulary loads are write-heavy. These settings suit a laptop
    # (local dev) and should NOT be copied to production.
    command: >
      postgres
        -c shared_buffers=1GB
        -c maintenance_work_mem=1GB
        -c max_wal_size=4GB
        -c synchronous_commit=off
    shm_size: 1gb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${OMOP_DB_USER} -d ${OMOP_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10

  # ---------------------------------------------------------------------------
  # calibration: Python, reads NSDUH and writes joint probabilities per stratum
  # ---------------------------------------------------------------------------
  calibration:
    profiles: ["calibrate"]
    build: ./services/calibration
    # Run as YOUR host user so output in ./data/calibration is writable (and owned by you).
    user: "${LOCAL_UID}:${LOCAL_GID}"
    environment:
      HOME: /tmp                                  # your UID has no home dir in the image
    volumes:
      - ./data/source/nsduh:/data/source:ro       # read-only input
      - ./data/calibration:/data/calibration      # output
      - ./services/calibration:/app:ro            # code + config
    command: ["python", "-I", "/app/estimate_joint.py", "--config", "/app/config.json"]

  # ---------------------------------------------------------------------------
  # synthea: Java, generates the population from our parent module
  # ---------------------------------------------------------------------------
  synthea:
    profiles: ["generate"]
    build:
      context: ./services/synthea
      args:
        SYNTHEA_VERSION: v3.3.0
    # Run as YOUR host user. Without this, the in-image "synthea" user (a different
    # UID) can't write to ./data/synthea-output, and mkdir fails with "Permission denied".
    user: "${LOCAL_UID}:${LOCAL_GID}"
    environment:
      HOME: /tmp                                # Java wants a writable home; your UID has none in the image
      RUN_ID: ${RUN_ID}
      SYNTHEA_SEED: ${SYNTHEA_SEED}
      SYNTHEA_POPULATION: ${SYNTHEA_POPULATION}
      SYNTHEA_AGE_RANGE: ${SYNTHEA_AGE_RANGE}
      SYNTHEA_STATE: ${SYNTHEA_STATE}
    volumes:
      - ./services/synthea/config:/synthea/config:ro
      - ./services/synthea/modules:/synthea/modules:ro
      - ./services/synthea/keep:/synthea/keep:ro
      - ./data/synthea-output:/output

  # ---------------------------------------------------------------------------
  # etl: R with OHDSI ETLSyntheaBuilder (+ optional DataQualityDashboard)
  # ---------------------------------------------------------------------------
  etl:
    profiles: ["etl"]
    build: ./services/etl
    depends_on:
      omop-db:
        condition: service_healthy
    # Run as YOUR host user so DQD output in ./data/dqd is writable.
    user: "${LOCAL_UID}:${LOCAL_GID}"
    environment:
      HOME: /tmp
      DB_SERVER: omop-db/${OMOP_DB_NAME}      # DatabaseConnector "host/dbname" form
      DB_PORT: "5432"                         # internal port, not the host port
      DB_USER: ${OMOP_DB_USER}
      DB_PASSWORD: ${OMOP_DB_PASSWORD}
      RUN_ID: ${RUN_ID}
      ETL_CREATE_CDM: ${ETL_CREATE_CDM}
      ETL_LOAD_VOCAB: ${ETL_LOAD_VOCAB}
      ETL_RUN_DQD: ${ETL_RUN_DQD}
    volumes:
      - ./data/synthea-output:/data/synthea-output:ro
      - ./data/vocab/athena:/data/vocab:ro
      - ./data/dqd:/data/dqd
      - ./services/etl:/app:ro

  # ===========================================================================
  # Optional OHDSI web stack (Step 9). Nothing below starts without
  # `--profile atlas`.
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # webapi: OHDSI WebAPI (Java/Spring), the REST backend Atlas talks to.
  # Two database jobs, both on omop-db as the least-privilege ohdsi_app role:
  #   DATASOURCE_* / FLYWAY_*  → its OWN tables in schema "webapi"
  #                              (Flyway creates them on first start)
  #   webapi.source rows       → where the CDM lives (Step 9c registers it)
  # ---------------------------------------------------------------------------
  webapi:
    profiles: ["atlas"]
    image: ohdsi/webapi:${WEBAPI_VERSION:-2.15.1}
    container_name: ohdsi-webapi
    restart: unless-stopped
    depends_on:
      omop-db:
        condition: service_healthy
    environment:
      JAVA_OPTS: "-Xmx2g"
      # --- WebAPI's own database (schema webapi) ---
      DATASOURCE_DRIVERCLASSNAME: org.postgresql.Driver
      DATASOURCE_URL: jdbc:postgresql://omop-db:5432/${OMOP_DB_NAME}
      DATASOURCE_USERNAME: ohdsi_app
      DATASOURCE_PASSWORD: ${OHDSI_APP_PASSWORD}
      DATASOURCE_OHDSI_SCHEMA: webapi
      SPRING_JPA_PROPERTIES_HIBERNATE_DEFAULT_SCHEMA: webapi
      SPRING_JPA_PROPERTIES_HIBERNATE_DIALECT: org.hibernate.dialect.PostgreSQLDialect
      SPRING_BATCH_REPOSITORY_TABLEPREFIX: webapi.BATCH_
      # --- Flyway: builds/upgrades the webapi schema on startup ---
      FLYWAY_DATASOURCE_DRIVERCLASSNAME: org.postgresql.Driver
      FLYWAY_DATASOURCE_URL: jdbc:postgresql://omop-db:5432/${OMOP_DB_NAME}
      FLYWAY_DATASOURCE_USERNAME: ohdsi_app
      FLYWAY_DATASOURCE_PASSWORD: ${OHDSI_APP_PASSWORD}
      FLYWAY_LOCATIONS: classpath:db/migration/postgresql
      FLYWAY_SCHEMAS: webapi
      FLYWAY_PLACEHOLDERS_OHDSISCHEMA: webapi
      FLYWAY_TABLE: schema_history
      # --- Security: OFF. Acceptable ONLY because this is synthetic data on
      # 127.0.0.1. Anyone who can reach the port can edit anything in Atlas.
      SECURITY_PROVIDER: DisabledSecurity
      SECURITY_CORS_ENABLED: "true"
      SECURITY_ORIGIN: "http://localhost:${ATLAS_PORT:-8080}"
    # No "ports:". WebAPI is reached only through atlas-proxy.

  # ---------------------------------------------------------------------------
  # atlas: the Atlas web app (static files served by nginx inside the image).
  # WEBAPI_URL is read by YOUR BROWSER, not by this container, so it must be
  # an address the browser can reach (localhost), never "webapi:8080".
  # ---------------------------------------------------------------------------
  atlas:
    profiles: ["atlas"]
    image: ohdsi/atlas:${ATLAS_VERSION:-2.15.0}
    container_name: ohdsi-atlas
    restart: unless-stopped
    depends_on:
      - webapi
    environment:
      WEBAPI_URL: "http://localhost:${ATLAS_PORT:-8080}/WebAPI/"

  # ---------------------------------------------------------------------------
  # atlas-proxy: one origin for both apps (see services/atlas/nginx.conf).
  # ---------------------------------------------------------------------------
  atlas-proxy:
    profiles: ["atlas"]
    image: nginx:1.27-alpine
    container_name: ohdsi-proxy
    restart: unless-stopped
    depends_on:
      - atlas
      - webapi
    ports:
      - "127.0.0.1:${ATLAS_PORT:-8080}:8080"
    volumes:
      - ./services/atlas/nginx.conf:/etc/nginx/conf.d/default.conf:ro

  # ===========================================================================
  # Optional analyses (Step 10). Nothing below starts without
  # `--profile analytics`. One-shot runs, like etl.
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # analytics: R image with TreatmentPatterns and CohortContrast.
  # Connects as the least-privilege ohdsi_app role (reads cdm + results.cohort,
  # writes only results and analytics_scratch). Which cohorts and settings to
  # use come from a committed study file: -e STUDY=<name>.
  # ---------------------------------------------------------------------------
  analytics:
    profiles: ["analytics"]
    build: ./services/analytics
    depends_on:
      omop-db:
        condition: service_healthy
    # Your host user, so results in ./data/analyses belong to you.
    user: "${LOCAL_UID}:${LOCAL_GID}"
    environment:
      HOME: /tmp
      RUN_ID: ${RUN_ID}
      DB_HOST: omop-db                         # DBI/RPostgres form (CDMConnector)
      DB_NAME: ${OMOP_DB_NAME}
      DB_SERVER: omop-db/${OMOP_DB_NAME}       # DatabaseConnector "host/dbname" form
      DB_PORT: "5432"                          # internal port, not the host port
      DB_USER: ohdsi_app
      DB_PASSWORD: ${OHDSI_APP_PASSWORD}
    volumes:
      - ./services/analytics:/app:ro           # scripts, helpers and study files
      - ./data/analyses:/data/analyses         # results, per RUN_ID

volumes:
  omop-pgdata:
```

### `services/postgres/initdb/01_schemas.sql`

```sql
/**
 * 01_schemas.sql
 *
 * Runs ONCE when the omop-pgdata volume is first created.
 * To rerun it: docker compose down -v (this deletes all data).
 *
 * synthea → raw Synthea CSV staging (ETL-Synthea writes here)
 * cdm     → OMOP CDM 5.4 tables + Athena vocabulary
 * results → Achilles / Atlas results + our validation output
 */
CREATE SCHEMA IF NOT EXISTS synthea;
CREATE SCHEMA IF NOT EXISTS cdm;
CREATE SCHEMA IF NOT EXISTS results;
```

Start the database and check it:

```bash
cp .env.example .env && $EDITOR .env
docker compose up -d
docker compose ps                      # omop-db should be "healthy"

# Single quotes matter: $POSTGRES_USER / $POSTGRES_DB expand INSIDE the
# container (where compose set them), not in your host shell.
docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dn"'
```

> **Gotcha:** `.env` is read by Docker Compose, **not** by your shell. A host command like `psql -U "$OMOP_DB_USER"` expands to an empty string, so psql falls back to your OS user and fails with `role "root" does not exist`. Either use the in-container form above, or load `.env` into your shell first with `set -a; . ./.env; set +a`.

---

## Step 3: Download the source data (NSDUH and Athena)

### 3a. NSDUH 2024 public use file

From <https://www.samhsa.gov/data/data-we-collect/nsduh-national-survey-drug-use-and-health/datafiles>, download **three things together**:

1. The data file. Pick the delimited/tab format; Stata or SAS also work with pandas.
2. The **codebook**
3. The **Data Users' Guide**

Put all three in `data/source/nsduh/2024/`. Record the file names and download date in `docs/run-log.md`.

> If you only need aggregate tables, the SAMHSA online analysis system (<https://datatools.samhsa.gov/>) can produce weighted crosstabs without the microdata. You can then hand-enter `joint_probabilities.json` and skip the calibration container.

### 3b. Athena vocabularies

1. Sign in at <https://athena.ohdsi.org/> → **Download**.
2. Start from Athena's **defaults** and **add CVX and Cancer Modifier**. Neither is a default, and Synthea needs both. Core vocabularies like UCUM, Visit, Domain and the Type concepts come with every bundle automatically.

   > ⚠ **Don't skip CVX.** Synthea codes every **immunization** in CVX. Without it, ETL-Synthea **drops** immunization records rather than mapping them to `0`, so they never reach `drug_exposure`, and the unmapped count stays at zero, which hides the loss. In the pilot (no CVX), `drug_exposure` held exactly the 28,265 medications and no immunizations. Reloading with CVX brought back **2,685 of 2,711**. The remaining 26 fail two hard-coded ETL filters and are restored by a patch (Step 7c).

   > ⚠ **Don't skip Cancer Modifier.** OMOP maps SNOMED *metastasis* concepts (e.g. `94260004` "Metastatic malignant neoplasm to colon") to **Cancer Modifier**, and Synthea's cancer modules produce them. Without it, Athena leaves the `Maps to` row out of `CONCEPT_RELATIONSHIP.csv` and keeps only the `Maps to value → Positive` half, so those records map to `0`. Without it, those concepts can't map at all. (Deaths with these causes *also* need the Step 7b patch, because `insert_death.sql` only accepts Condition-domain causes, and Cancer Modifier concepts are Measurements.) **General rule:** if a concept has `Maps to value` but no `Maps to`, check its page on Athena; the missing target is usually in a vocabulary you didn't select.
3. Unzip into `data/vocab/athena/` so that `CONCEPT.csv` sits directly in that folder.
4. **Optional: merge CPT4** (see 3c) **before** moving files around and before the first ETL run.
5. **Move the non-vocabulary files out** so the ETL loader only sees OMOP tables:
   ```bash
   mkdir -p data/vocab/athena-extras
   cd data/vocab/athena
   mv vocabulary_download_v5_*.zip cpt4.jar cpt.sh cpt.bat readme.txt \
      CONCEPT_CPT4.csv CONCEPT_METADATA.csv CONCEPT_RELATIONSHIP_METADATA.csv \
      ../athena-extras/
   cd - >/dev/null
   ls data/vocab/athena    # 10 CSVs: CONCEPT, CONCEPT_ANCESTOR, CONCEPT_CLASS, CONCEPT_RELATIONSHIP,
                           # CONCEPT_SYNONYM, DOMAIN, DRUG_STRENGTH, PACK_CONTENT, RELATIONSHIP, VOCABULARY
   ```
6. Write the **vocabulary release version** into `docs/run-log.md`:
   ```bash
   grep -P '^None\t' data/vocab/athena/VOCABULARY.csv     # e.g. "v5.0 29-AUG-26"
   ```
7. Check disk space (`df -h .`). The loaded vocabulary takes roughly 2–3× the CSV size in the Docker volume.

### 3c. Optional: CPT4

CPT4 is AMA-licensed, so Athena ships `CONCEPT_CPT4.csv` plus `cpt4.jar`, which merges CPT4 into `CONCEPT.csv` using **your own UMLS API key** (<https://uts.nlm.nih.gov/> → My Profile). **For the pilot you can skip it.** Synthea codes most procedures in SNOMED, so without CPT4 only a handful of procedures end up with `procedure_concept_id = 0`.

> ⚠ Merge **before** the first ETL vocabulary load. If you merge afterwards, you need `docker compose down -v` and a full ETL to reload the vocabulary.

No Java on the host is needed, because this borrows the Synthea image's runtime:

```bash
# If you've already moved the helpers to athena-extras/, bring them back for the moment
cp data/vocab/athena-extras/{cpt4.jar,CONCEPT_CPT4.csv} data/vocab/athena/ 2>/dev/null || true
cp data/vocab/athena/CONCEPT.csv data/vocab/athena-extras/CONCEPT.pre-cpt4.csv   # backup

read -rs "UMLS_KEY?UMLS API key: " 2>/dev/null || read -rsp "UMLS API key: " UMLS_KEY; echo   # zsh || bash

docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/data/vocab/athena:/vocab" -w /vocab \
  --entrypoint java \
  synthetic-omop-synthea \
  -Dumls-apikey="$UMLS_KEY" -jar cpt4.jar 5           # same as Athena's cpt.sh

unset UMLS_KEY
grep -c $'\tCPT4\t' data/vocab/athena/CONCEPT.csv    # > 0 means it merged
mv data/vocab/athena/{cpt4.jar,CONCEPT_CPT4.csv} data/vocab/athena-extras/
```

Record **"CPT4 merged: yes/no"** next to the vocabulary release in `run-log.md`. The same Athena release gives different procedure mappings with and without it.

---

## Step 4: Estimate the joint disorder distribution

This step matters most for the method. We estimate the four-cell joint distribution *within* each stratum and never multiply marginal prevalences together.

### `services/calibration/Dockerfile`

```dockerfile
# Small, pinned Python image for the calibration step.
FROM python:3.12-slim

# Don't write .pyc files, and flush logs immediately so `docker compose run` shows progress.
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Run as non-root.
RUN useradd --create-home calib
USER calib
```

### `services/calibration/requirements.txt`

```text
pandas==2.2.*
numpy==2.*
pyreadstat==1.2.*   # Only needed if you read the SAS/SPSS/Stata versions
```

### `services/calibration/config.example.json`

Copy this to `config.json`. **Check every variable name against the 2024 codebook.** The names below are placeholders that show the shape of the config; NSDUH recodes and renames variables between years.

```json
{
  "_comment": "Map NSDUH variables to our definitions. VERIFY every name in the 2024 codebook.",
  "input_file": "/data/source/2024/NSDUH_2024_Tab.txt",
  "input_format": "tsv",
  "output_file": "/data/calibration/joint_probabilities.json",

  "weight_var": "ANALWT2_C",
  "age_var": "CATAG6",
  "sex_var": "IRSEX",

  "adult_filter": { "var": "CATAG6", "exclude_values": [1] },

  "mhd": {
    "var": "AMIYR_U",
    "present_values": [1],
    "absent_values": [0],
    "definition": "Any mental illness, past year (survey-defined; NOT a clinical diagnosis)"
  },
  "sud": {
    "var": "SUD_PLACEHOLDER",
    "present_values": [1],
    "absent_values": [0],
    "definition": "Past-year substance use disorder per DSM-5 survey criteria"
  },

  "age_groups": { "2": "18-25", "3": "26-34", "4": "35-49", "5": "50-64", "6": "65+" },
  "sex_labels": { "1": "M", "2": "F" },

  "min_unweighted_n": 50,
  "collapse_order": ["sex", "age"]
}
```

### `services/calibration/estimate_joint.py`

```python
"""
estimate_joint.py

Estimate the weighted JOINT distribution of mental health disorder (MHD)
and substance use disorder (SUD) within age x sex strata, from the NSDUH
public use file.

Output: joint_probabilities.json, with one entry per stratum:
  {
    "stratum": {"age": "35-49", "sex": "F"},
    "unweighted_n": 4123,
    "collapsed_from": null,
    "p": {"neither": 0.71, "mhd_only": 0.19, "sud_only": 0.04, "both": 0.06}
  }

IMPORTANT LIMITATIONS (also documented in docs/assumptions.md):
  * POINT ESTIMATES ONLY. This script applies the analysis weight but does
    not use the survey design (strata/PSU) to compute variance. For
    confidence intervals use R's `survey` package or Python's `samplics`
    with the design variables listed in the Data Users' Guide.
  * Survey categories stay survey categories. "Any mental illness" is
    NOT turned into a specific diagnosis here. That happens, as an explicit
    assumption, in the Synthea module (Step 5).

@see https://www.samhsa.gov/data/data-we-collect/nsduh-national-survey-drug-use-and-health
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import pandas as pd

# The four cells we always estimate together. Order matters: it's the order
# the Synthea module's distributed transitions are written in.
CELLS = ("neither", "mhd_only", "sud_only", "both")


def load_config(path: str) -> dict:
    """
    Load the JSON config that maps NSDUH variables to our definitions.

    @param path  Path to config.json.
    @return      Parsed config dictionary.
    """
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_nsduh(cfg: dict) -> pd.DataFrame:
    """
    Read the NSDUH file, keeping only the columns we need (lower memory use).

    @param cfg  Config dict (uses input_file, input_format, and variable names).
    @return     DataFrame restricted to the needed columns.
    """
    cols = [cfg["weight_var"], cfg["age_var"], cfg["sex_var"],
            cfg["mhd"]["var"], cfg["sud"]["var"]]
    fmt = cfg.get("input_format", "tsv")

    if fmt == "tsv":
        return pd.read_csv(cfg["input_file"], sep="\t", usecols=cols, low_memory=False)
    if fmt == "stata":
        return pd.read_stata(cfg["input_file"], columns=cols, convert_categoricals=False)
    raise ValueError(f"Unsupported input_format: {fmt}")


def recode_flag(series: pd.Series, spec: dict) -> pd.Series:
    """
    Turn a raw NSDUH variable into True / False / NA.

    Codes not listed in present_values or absent_values (missing, refused,
    legitimate skip, etc.) become NA EXPLICITLY, so they are never silently
    counted as "absent".

    @param series  Raw column.
    @param spec    {"present_values": [...], "absent_values": [...]}
    @return        Nullable boolean Series.
    """
    out = pd.Series(pd.NA, index=series.index, dtype="boolean")
    out[series.isin(spec["present_values"])] = True
    out[series.isin(spec["absent_values"])] = False
    return out


def assign_cell(mhd: pd.Series, sud: pd.Series) -> pd.Series:
    """
    Combine the two flags into one of the four CELLS.

    @param mhd  Nullable boolean MHD flag.
    @param sud  Nullable boolean SUD flag.
    @return     Categorical Series of cell labels (NA if either flag is NA).
    """
    cell = pd.Series(pd.NA, index=mhd.index, dtype="object")
    cell[(~mhd) & (~sud)] = "neither"
    cell[(mhd) & (~sud)] = "mhd_only"
    cell[(~mhd) & (sud)] = "sud_only"
    cell[(mhd) & (sud)] = "both"
    return cell


def weighted_joint(df: pd.DataFrame, weight_var: str) -> dict:
    """
    Weighted proportion of each cell within one stratum.

    @param df          Rows for a single stratum (cell column already set).
    @param weight_var  Name of the analysis-weight column.
    @return            {cell: proportion}, summing to 1.0.
    """
    totals = df.groupby("cell")[weight_var].sum()
    grand = totals.sum()
    return {c: round(float(totals.get(c, 0.0) / grand), 6) for c in CELLS}


def main() -> None:
    """Entry point: load → recode → stratify → estimate → collapse sparse → write."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    cfg = load_config(args.config)

    df = load_nsduh(cfg)

    # Adults only. CATAG6 = 1 is ages 12-17 (verify in the codebook).
    flt = cfg["adult_filter"]
    df = df[~df[flt["var"]].isin(flt["exclude_values"])].copy()

    # Explicit recoding: unknowns become NA, then are dropped and COUNTED.
    df["mhd"] = recode_flag(df[cfg["mhd"]["var"]], cfg["mhd"])
    df["sud"] = recode_flag(df[cfg["sud"]["var"]], cfg["sud"])
    n_before = len(df)
    df = df.dropna(subset=["mhd", "sud"])
    print(f"Dropped {n_before - len(df)} rows with unknown MHD/SUD status "
          f"({(n_before - len(df)) / n_before:.1%}). Record this in run-log.md.")

    df["cell"] = assign_cell(df["mhd"], df["sud"])
    df["age"] = df[cfg["age_var"]].astype(str).map(cfg["age_groups"])
    df["sex"] = df[cfg["sex_var"]].astype(str).map(cfg["sex_labels"])

    results = []
    for (age, sex), grp in df.groupby(["age", "sex"]):
        entry = {"stratum": {"age": age, "sex": sex},
                 "unweighted_n": int(len(grp)),
                 "collapsed_from": None,
                 "p": weighted_joint(grp, cfg["weight_var"])}

        # Sparse-cell handling: if any cell has too few respondents, fall
        # back to the age-only stratum (both sexes pooled). The "collapsed_from"
        # field records this so it shows up in validation.
        cell_counts = grp["cell"].value_counts()
        if (cell_counts.reindex(CELLS, fill_value=0) < cfg["min_unweighted_n"]).any():
            pooled = df[df["age"] == age]
            entry["p"] = weighted_joint(pooled, cfg["weight_var"])
            entry["collapsed_from"] = f"age={age} (sexes pooled)"

        results.append(entry)

    out = {
        "source": "NSDUH 2024 PUF",
        "definitions": {"mhd": cfg["mhd"]["definition"], "sud": cfg["sud"]["definition"]},
        "note": "Weighted point estimates; no design-based variance. See docs/assumptions.md.",
        "strata": results,
    }
    Path(cfg["output_file"]).write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"Wrote {len(results)} strata → {cfg['output_file']}")


if __name__ == "__main__":
    main()
```

Run it:

```bash
cp services/calibration/config.example.json services/calibration/config.json
$EDITOR services/calibration/config.json          # fix the variable names from the codebook
docker compose --profile calibrate run --rm calibration
cat data/calibration/joint_probabilities.json
```

---

## Step 5: Build the Synthea parent module

The parent module:

1. Waits until the person is an adult **and** inside the simulated history window.
2. **Draws one joint profile** using an age × sex `complex_transition` whose distributions come straight from `joint_probabilities.json`.
3. Stores the profile as a patient attribute (`concurrent_profile`).
4. Records the diagnoses at an encounter, so the two conditions overlap in time when the profile is `both`.

> ⚠ **The SNOMED codes below are placeholders for clinical and terminology review.** Mapping "any mental illness" to *major depressive disorder*, or "SUD" to *alcohol use disorder*, is a **simulation assumption**. Log it as `A-00x` in `docs/assumptions.md`. You can also add a weighted sub-distribution across several specific diagnoses.

Build or edit this visually in the module builder (<https://synthetichealth.github.io/module-builder/>) and export the JSON. The structure is:

### `services/synthea/modules/concurrent_disorders.json`

> **Synthea JSON gotchas.** Every `remarks` field, at module **and** state level, must be an **array of strings**. A plain string fails with `Expected BEGIN_ARRAY but was STRING at path $.remarks`. Every state needs a `type`, and every transition must name a state that exists. Each stratum's `distributions` must sum to 1.

> **The `0.25` values are uniform placeholders** for testing the plumbing. Replace them with the NSDUH estimates from `joint_probabilities.json` before any real run.

```json
{
  "name": "Concurrent Disorders (NSDUH-calibrated)",
  "remarks": [
    "Parent module: assigns ONE joint MHD/SUD profile per adult.",
    "Probabilities MUST come from data/calibration/joint_probabilities.json (NSDUH 2024, weighted, by age x sex).",
    "The 0.25 values below are UNIFORM PLACEHOLDERS for plumbing tests only. They are NOT NSDUH estimates.",
    "Only one stratum (F, 35-49) is shown; add one complex_transition entry per stratum.",
    "Diagnosis codes are SIMULATION ASSUMPTIONS (docs/assumptions.md A-002, A-003) pending clinical review.",
    "NOTE: in Synthea module JSON, every 'remarks' field must be an ARRAY of strings, never a plain string."
  ],
  "gmf_version": 2,
  "states": {

    "Initial": {
      "type": "Initial",
      "direct_transition": "Wait_Until_Adult_In_Window"
    },

    "Wait_Until_Adult_In_Window": {
      "type": "Guard",
      "remarks": [
        "A-001: onset placed inside the 24-month export window (exporter.years_of_history = 2).",
        "Keep 'year' aligned with the simulation end date, or nobody ever passes this guard."
      ],
      "allow": {
        "condition_type": "And",
        "conditions": [
          { "condition_type": "Age", "operator": ">=", "quantity": 18, "unit": "years" },
          { "condition_type": "Date", "operator": ">=", "year": 2025 }
        ]
      },
      "direct_transition": "Assign_Profile"
    },

    "Assign_Profile": {
      "type": "Simple",
      "remarks": [
        "Joint draw: one of four profiles per person, per stratum.",
        "NEVER replace this with two independent MHD / SUD draws."
      ],
      "complex_transition": [
        {
          "condition": {
            "condition_type": "And",
            "conditions": [
              { "condition_type": "Gender", "gender": "F" },
              { "condition_type": "Age", "operator": ">=", "quantity": 35, "unit": "years" },
              { "condition_type": "Age", "operator": "<", "quantity": 50, "unit": "years" }
            ]
          },
          "distributions": [
            { "distribution": 0.25, "transition": "Set_Neither" },
            { "distribution": 0.25, "transition": "Set_MHD_Only" },
            { "distribution": 0.25, "transition": "Set_SUD_Only" },
            { "distribution": 0.25, "transition": "Set_Both" }
          ]
        },
        {
          "distributions": [
            { "distribution": 1.0, "transition": "Set_Neither" }
          ]
        }
      ]
    },

    "Set_Neither": {
      "type": "SetAttribute",
      "attribute": "concurrent_profile",
      "value": "neither",
      "direct_transition": "Terminal"
    },
    "Set_MHD_Only": {
      "type": "SetAttribute",
      "attribute": "concurrent_profile",
      "value": "mhd_only",
      "direct_transition": "MHD_Encounter"
    },
    "Set_SUD_Only": {
      "type": "SetAttribute",
      "attribute": "concurrent_profile",
      "value": "sud_only",
      "direct_transition": "SUD_Encounter"
    },
    "Set_Both": {
      "type": "SetAttribute",
      "attribute": "concurrent_profile",
      "value": "both",
      "direct_transition": "Both_Encounter"
    },

    "MHD_Encounter": {
      "type": "Encounter",
      "encounter_class": "ambulatory",
      "codes": [
        { "system": "SNOMED-CT", "code": "185345009", "display": "Encounter for symptom (procedure)" }
      ],
      "direct_transition": "MHD_Onset"
    },
    "MHD_Onset": {
      "type": "ConditionOnset",
      "remarks": ["A-002: survey 'any mental illness' -> MDD. PLACEHOLDER, needs clinical review."],
      "target_encounter": "MHD_Encounter",
      "assign_to_attribute": "mhd_condition",
      "codes": [
        { "system": "SNOMED-CT", "code": "370143000", "display": "Major depressive disorder (disorder)" }
      ],
      "direct_transition": "End_MHD_Encounter"
    },
    "End_MHD_Encounter": {
      "type": "EncounterEnd",
      "direct_transition": "Terminal"
    },

    "SUD_Encounter": {
      "type": "Encounter",
      "encounter_class": "ambulatory",
      "codes": [
        { "system": "SNOMED-CT", "code": "185345009", "display": "Encounter for symptom (procedure)" }
      ],
      "direct_transition": "SUD_Onset"
    },
    "SUD_Onset": {
      "type": "ConditionOnset",
      "remarks": ["A-003: survey 'substance use disorder' -> alcoholism. PLACEHOLDER, needs clinical review."],
      "target_encounter": "SUD_Encounter",
      "assign_to_attribute": "sud_condition",
      "codes": [
        { "system": "SNOMED-CT", "code": "7200002", "display": "Alcoholism (disorder)" }
      ],
      "direct_transition": "End_SUD_Encounter"
    },
    "End_SUD_Encounter": {
      "type": "EncounterEnd",
      "direct_transition": "Terminal"
    },

    "Both_Encounter": {
      "type": "Encounter",
      "remarks": ["One encounter, two diagnoses: the active periods overlap by construction."],
      "encounter_class": "ambulatory",
      "codes": [
        { "system": "SNOMED-CT", "code": "185345009", "display": "Encounter for symptom (procedure)" }
      ],
      "direct_transition": "Both_MHD_Onset"
    },
    "Both_MHD_Onset": {
      "type": "ConditionOnset",
      "remarks": ["A-002 (see MHD_Onset)."],
      "target_encounter": "Both_Encounter",
      "assign_to_attribute": "mhd_condition",
      "codes": [
        { "system": "SNOMED-CT", "code": "370143000", "display": "Major depressive disorder (disorder)" }
      ],
      "direct_transition": "Both_SUD_Onset"
    },
    "Both_SUD_Onset": {
      "type": "ConditionOnset",
      "remarks": ["A-003 (see SUD_Onset)."],
      "target_encounter": "Both_Encounter",
      "assign_to_attribute": "sud_condition",
      "codes": [
        { "system": "SNOMED-CT", "code": "7200002", "display": "Alcoholism (disorder)" }
      ],
      "direct_transition": "End_Both_Encounter"
    },
    "End_Both_Encounter": {
      "type": "EncounterEnd",
      "direct_transition": "Terminal"
    },

    "Terminal": {
      "type": "Terminal"
    }
  }
}
```

**Next things to add, roughly in order of value:**

1. All strata from `joint_probabilities.json`. A 30-line script that renders the `complex_transition` array from the JSON is worth writing, so nobody ever hand-copies probabilities.
2. Follow-up visits and treatment (`MedicationOrder`, `CarePlanStart`), each tagged with an assumption ID.
3. **Prevent duplicates.** Synthea's built-in modules (e.g. `opioid_addiction`, `alcohol`, `depression` screening) can generate overlapping conditions. Either disable them with `-m` module filtering in `run.sh`, or check for them in validation (Step 8). **Confirmed in the pilot:** 7 deaths from "Drug overdose" came from the built-in `opioid_addiction` module, not ours, so it *is* adding SUD-related records on top of the calibrated draw.

### `docs/assumptions.md` (starter)

Every simulation choice and every deviation from the standard ETL gets an ID, so the module's `remarks`, the run log and any write-up can point to the same place.

```markdown
# Simulation assumptions

| ID | Assumption | Where | Status |
|---|---|---|---|
| A-001 | Disorder onset falls inside the 24-month export window (Guard `year >= 2025`) | `concurrent_disorders.json` → `Wait_Until_Adult_In_Window` | Placeholder |
| A-002 | Survey "any mental illness" is coded as major depressive disorder (SNOMED 370143000) | `MHD_Onset`, `Both_MHD_Onset` | Needs clinical review |
| A-003 | Survey "substance use disorder" is coded as alcoholism (SNOMED 7200002) | `SUD_Onset`, `Both_SUD_Onset` | Needs clinical review |
| A-004 | Probabilities are uniform 0.25 placeholders for F 35–49 only | `Assign_Profile` | Pilot only; replace from NSDUH |
| A-005 | Deaths dropped by ETL-Synthea are restored with `cause_concept_id = 0` | `services/etl/sql/patch_missing_deaths.sql` | Applied after every ETL |
| A-006 | SNOMED `55680006` "Drug overdose" was retired in 2021 and has no `Maps to`; candidates 607147 "Overdose" / 4053782 "Overdose of opiate" | `cdm.death`, `cdm.condition_occurrence` | Unmapped (`0`) pending terminology review |
| A-007 | SNOMED `94260004` maps to Cancer Modifier 35226112 (Measurement domain), which needs the Cancer Modifier vocabulary | Athena bundle (Step 3b); `cdm.death` via patch | Mapping resolved by adding Cancer Modifier; deaths still restored by the patch (ETL accepts Condition-domain causes only) |
| A-008 | Immunizations dropped by ETL-Synthea (single-digit CVX codes `3`/`8` vs `03`/`08`; COVID `207`/`208` mapping outside CVX) are restored, with unmappable codes kept as `0` | `services/etl/sql/patch_missing_immunizations.sql` | Applied after every ETL |
| A-009 | ETL-Synthea maps only `white`/`black`/`asian` race. pilot-0001: 30 of 1,175 persons at `0` (`native` 13, `other` 9, `hawaiian` 8). Proposed: `native` → 8657 American Indian or Alaska Native, `hawaiian` → 8557 Native Hawaiian or Other Pacific Islander (OMB categories; both standard and valid in the loaded vocabulary). `other` stays `0`: its only candidate, 8522 Other Race, is retired | `cdm.person`; `services/etl/sql/patch_race_concepts.sql` (tested, **not applied**) | Pending terminology review; affects race-stratified results for the smallest groups |
```

### `services/synthea/keep/keep_concurrent.json` (optional)

Use this only when the deliverable is the "both" cohort alone. Filtering **does not calibrate** anything: it discards the other patients, so always keep a full unfiltered run as well.

```json
{
  "name": "Keep: concurrent disorders only",
  "gmf_version": 2,
  "states": {
    "Initial": {
      "type": "Initial",
      "conditional_transition": [
        {
          "condition": { "condition_type": "Attribute", "attribute": "concurrent_profile", "operator": "==", "value": "both" },
          "transition": "Keep"
        },
        { "transition": "Terminal" }
      ]
    },
    "Keep": { "type": "Terminal" },
    "Terminal": { "type": "Terminal" }
  }
}
```

---

## Step 6: Generate the synthetic population

### `services/synthea/Dockerfile`

```dockerfile
# Synthea runs on Java 17 (LTS). The upstream project recommends an LTS JDK.
FROM eclipse-temurin:17-jre

ARG SYNTHEA_VERSION=v3.3.0
WORKDIR /synthea

# Pull the release jar (bundled with dependencies) for a pinned version.
# VERIFY the asset name on the release page; it has been
# "synthea-with-dependencies.jar" for the 3.x line.
#
# --chmod=0644 is REQUIRED: remote ADD saves files as 600 root:root, and the
# container runs as your host UID (compose `user:`), which couldn't read it
# ("Unable to access jarfile"). --chmod needs BuildKit (default in modern Docker).
ADD --chmod=0644 https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar /synthea/synthea.jar

COPY run.sh /synthea/run.sh
RUN chmod 0755 /synthea/run.sh \
  && useradd --create-home synthea
USER synthea

ENTRYPOINT ["/synthea/run.sh"]
```

### `services/synthea/run.sh`

```bash
#!/usr/bin/env bash
#
# run.sh: one reproducible Synthea run.
#
# Every run writes to /output/$RUN_ID so runs never overwrite each other.
# The exact command line is saved next to the output, as provenance.
#
# Env (from compose / .env):
#   RUN_ID, SYNTHEA_SEED, SYNTHEA_POPULATION, SYNTHEA_AGE_RANGE, SYNTHEA_STATE
# Optional:
#   KEEP_MODULE=/synthea/keep/keep_concurrent.json  → keep only matching patients
#
set -euo pipefail

OUT="/output/${RUN_ID:?RUN_ID must be set}"

# Refuse to overwrite an existing run. Bump RUN_ID instead.
if [[ -d "$OUT" ]]; then
  echo "Output ${OUT} already exists. Choose a new RUN_ID." >&2
  exit 1
fi
mkdir -p "$OUT"

ARGS=(
  -s "${SYNTHEA_SEED}"                       # population seed (reproducibility)
  -cs "${SYNTHEA_SEED}"                      # clinician seed, kept equal for simplicity
  -p "${SYNTHEA_POPULATION}"
  -a "${SYNTHEA_AGE_RANGE}"
  -c /synthea/config/synthea.local.properties
  -d /synthea/modules                        # our local modules are added to the built-ins
  --exporter.baseDirectory="${OUT}/"
)

# Optional cohort filter (see Step 5, "keep" module)
if [[ -n "${KEEP_MODULE:-}" ]]; then
  ARGS+=( -k "${KEEP_MODULE}" )
fi

# Save the exact invocation for the run log (the trailing echo adds a final newline).
{ printf '%q ' java -jar /synthea/synthea.jar "${ARGS[@]}" "${SYNTHEA_STATE}"; echo; } > "${OUT}/COMMAND.txt"

exec java -jar /synthea/synthea.jar "${ARGS[@]}" "${SYNTHEA_STATE}"
```

### `services/synthea/config/synthea.local.properties`

```properties
# Overrides on top of Synthea's built-in synthea.properties.
# CSV is REQUIRED by ETL-Synthea. FHIR is optional but handy for spot-checks.
exporter.csv.export = true
exporter.fhir.export = true

# 24 months of history in the export (A-001 depends on this matching the module's Guard).
exporter.years_of_history = 2

# Optional: the X12 claims exporter is on by default and nothing downstream uses it.
# Turning it off keeps each run folder smaller. Keep metadata/ (on by default): it
# records the run's settings, which is useful provenance.
# exporter.x12.export = false

# Leave the rest at defaults until there's a reason to change them.
# Every change here goes in docs/run-log.md.
```

Run it:

```bash
docker compose --profile generate build synthea
docker compose --profile generate run --rm synthea
ls data/synthea-output/pilot-0001/csv/     # patients.csv, conditions.csv, encounters.csv …
```

**Quick sanity check before the ETL.** This confirms the module ran and the joint draw produced all three non-"neither" groups. It counts *people*, not rows:

```bash
cd data/synthea-output/pilot-0001/csv
echo "patients: $(( $(wc -l < patients.csv) - 1 ))"

awk -F',' '
  # Find columns by header name, so this survives Synthea column changes
  NR==1 { for (i=1;i<=NF;i++) { if ($i=="PATIENT") p=i; if ($i=="CODE") c=i }; next }
  $c=="370143000" { mhd[$p]=1 }     # MDD (A-002)
  $c=="7200002"   { sud[$p]=1 }     # alcoholism (A-003)
  END {
    for (x in mhd) if (x in sud) both++; else m++
    for (x in sud) if (!(x in mhd)) s++
    printf "mhd_only=%d  sud_only=%d  both=%d\n", m, s, both
  }' conditions.csv
cd - >/dev/null
```

> **Why more patients than `-p`?** Synthea's `-p` sets the number of **living** patients. People who die during their simulated lifetime are exported too, and `-a 18-85` constrains only the living, so deaths can date back decades. The pilot asked for 1,000 and got **1,175** (175 deceased). Check `DEATHDATE` in `patients.csv`.

Add a row to **`docs/run-log.md`** (the pilot, as an example):

| run_id | date | synthea | seed | pop | vocab release | CPT4 | ETL-Synthea SHA | notes |
|---|---|---|---|---|---|---|---|---|
| pilot-0001 | 2026-11-11 | v3.3.0 | 12345 | 1000 (1,175 incl. 175 deceased) | v5.0 29-AUG-26 | no | `<sha>` | **Placeholder 0.25 probabilities**, F 35–49 only. Plumbing test, NOT calibrated. Joint cells: mhd_only 35 / sud_only 35 / both 28. ETL dropped 18 deaths (Step 7b); patched. |

Add config and module hashes (`sha256sum services/synthea/config/* services/synthea/modules/*`) in a notes column or a linked file, so any run can be reproduced exactly.

---

## Step 7: Load into OMOP with ETL-Synthea

### `services/etl/Dockerfile`

```dockerfile
# R + Java (DatabaseConnector talks to Postgres via JDBC, so it needs rJava).
FROM rocker/r-ver:4.4.2

# System dependencies: JDK for rJava, plus build headers for R packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
      default-jdk libxml2-dev libssl-dev libcurl4-openssl-dev \
  && R CMD javareconf \
  && rm -rf /var/lib/apt/lists/*

# ETL-Synthea pinned to the commit that loaded pilot-0001 (Step 7d; see docs/run-log.md).
# TODO: pin DataQualityDashboard too (ARG DQD_REF + ref='${DQD_REF}').
ARG ETL_SYNTHEA_REF=9ee6eb1b933c70af7b80711332aa92327af1f7c5
# The last line fails the build if any package didn't install. `R -e` exits 0
# even when an install fails, so without it a broken image still says "Built".
# Note R package names differ from repo names (OHDSI/ETL-Synthea → ETLSyntheaBuilder).
RUN R -q -e "install.packages(c('remotes','DatabaseConnector','SqlRender'), repos='https://cloud.r-project.org')" \
  && R -q -e "remotes::install_github('OHDSI/ETL-Synthea', ref='${ETL_SYNTHEA_REF}', upgrade='never')" \
  && R -q -e "remotes::install_github('OHDSI/DataQualityDashboard', upgrade='never')" \
  && R -q -e "pkgs <- c('remotes','DatabaseConnector','SqlRender','ETLSyntheaBuilder','DataQualityDashboard'); \
              missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]; \
              if (length(missing)) { message('MISSING R packages: ', paste(missing, collapse = ', ')); quit(status = 1) }"

# Achilles: characterization tables for Atlas's Data Sources pages (Step 9e).
# Its own layer, so adding it doesn't rebuild the ETL layers above.
#
# Gotcha: `R -e "install.packages(...)"` exits 0 even when the install FAILS
# (R only prints a warning), so Docker happily reports "Built". The
# requireNamespace() check turns a failed install into a failed build.
RUN R -q -e "install.packages('Achilles', repos='https://cloud.r-project.org'); \
             if (!requireNamespace('Achilles', quietly = TRUE)) quit(status = 1)"

# Download the Postgres JDBC driver at BUILD time so runs work offline.
ENV DATABASECONNECTOR_JAR_FOLDER=/opt/jdbc
RUN mkdir -p /opt/jdbc \
  && R -q -e "DatabaseConnector::downloadJdbcDrivers('postgresql', pathToDriver='/opt/jdbc')"

RUN useradd --create-home etl
USER etl
WORKDIR /app
CMD ["Rscript", "/app/run_etl.R"]
```

### `services/etl/run_etl.R`

```r
#' run_etl.R: load one Synthea run into OMOP CDM 5.4 on omop-db.
#'
#' The call order follows the OHDSI ETL-Synthea documentation:
#'   CreateCDMTables → CreateSyntheaTables → LoadSyntheaTables →
#'   LoadVocabFromCsv → CreateMapAndRollupTables → (CreateExtraIndices) →
#'   LoadEventTables → (DQD)
#'
#' Step toggles (env vars, "true"/"false"):
#'   ETL_CREATE_CDM  create the OMOP tables (first run only)
#'   ETL_LOAD_VOCAB  load Athena CSVs (slow; first run only)
#'   ETL_RUN_DQD     run the Data Quality Dashboard afterwards
#'
#' @see https://ohdsi.github.io/ETL-Synthea/
#' @see https://ohdsi.github.io/DataQualityDashboard/

library(DatabaseConnector)
library(ETLSyntheaBuilder)

#' Read a boolean env var, with a default.
#' @param name     Env var name.
#' @param default  Value used when the variable is unset.
#' @return logical
env_flag <- function(name, default = FALSE) {
  val <- tolower(Sys.getenv(name, unset = if (default) "true" else "false"))
  val %in% c("true", "1", "yes")
}

# --- Configuration ----------------------------------------------------------
cdm_version     <- "5.4"
synthea_version <- "3.3.0"         # MUST match the Synthea release that made the CSVs
cdm_schema      <- "cdm"
synthea_schema  <- "synthea"
run_id          <- Sys.getenv("RUN_ID")
synthea_dir     <- file.path("/data/synthea-output", run_id, "csv")
vocab_dir       <- "/data/vocab"

stopifnot(nzchar(run_id), dir.exists(synthea_dir))

cd <- createConnectionDetails(
  dbms         = "postgresql",
  server       = Sys.getenv("DB_SERVER"),    # "omop-db/synthetic_concurrent"
  port         = as.integer(Sys.getenv("DB_PORT", "5432")),
  user         = Sys.getenv("DB_USER"),
  password     = Sys.getenv("DB_PASSWORD"),  # from .env; never hard-code
  pathToDriver = Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
)

#' Time a step and print a clear log line.
#' @param label  Human-readable step name.
#' @param expr   Expression to evaluate.
step <- function(label, expr) {
  message(sprintf("[%s] ▶ %s", format(Sys.time(), "%H:%M:%S"), label))
  t <- system.time(force(expr))
  message(sprintf("[%s] ✔ %s (%.0fs)", format(Sys.time(), "%H:%M:%S"), label, t[["elapsed"]]))
}

# --- 1. OMOP tables (first run) ---------------------------------------------
if (env_flag("ETL_CREATE_CDM", TRUE)) {
  step("CreateCDMTables", CreateCDMTables(cd, cdmSchema = cdm_schema, cdmVersion = cdm_version))
}

# --- 2. Synthea staging (every run; replaces the previous run's staging) -----
step("CreateSyntheaTables", CreateSyntheaTables(cd, syntheaSchema = synthea_schema, syntheaVersion = synthea_version))
step("LoadSyntheaTables",   LoadSyntheaTables(cd, syntheaSchema = synthea_schema, syntheaFileLoc = synthea_dir))

# --- 3. Vocabulary (first run; slow) ----------------------------------------
if (env_flag("ETL_LOAD_VOCAB", TRUE)) {
  step("LoadVocabFromCsv", LoadVocabFromCsv(cd, cdmSchema = cdm_schema, vocabFileLoc = vocab_dir))
}

# --- 4. Mapping + events ------------------------------------------------------
step("CreateMapAndRollupTables", CreateMapAndRollupTables(
  cd, cdmSchema = cdm_schema, syntheaSchema = synthea_schema,
  cdmVersion = cdm_version, syntheaVersion = synthea_version))

step("CreateExtraIndices", CreateExtraIndices(
  cd, cdmSchema = cdm_schema, syntheaSchema = synthea_schema, syntheaVersion = synthea_version))

step("LoadEventTables", LoadEventTables(
  cd, cdmSchema = cdm_schema, syntheaSchema = synthea_schema,
  cdmVersion = cdm_version, syntheaVersion = synthea_version,
  cdmSourceName         = "Synthetic concurrent disorders",
  cdmSourceAbbreviation = "SYNCD",
  cdmSourceDescription  = paste(
    "Synthetic clinical histories calibrated to NSDUH 2024 public survey estimates.",
    "Clinical timelines contain documented simulation assumptions.",
    sprintf("Run: %s.", run_id))))

# --- 5. Optional: Data Quality Dashboard -------------------------------------
if (env_flag("ETL_RUN_DQD")) {
  step("DataQualityDashboard", DataQualityDashboard::executeDqChecks(
    connectionDetails     = cd,
    cdmDatabaseSchema     = cdm_schema,
    resultsDatabaseSchema = "results",
    cdmSourceName         = "SYNCD",
    cdmVersion            = cdm_version,
    outputFolder          = file.path("/data/dqd", run_id)))
}

message("Done. Run the validation SQL next (services/etl/sql/validate_joint.sql).")
```

> **Rerunning onto the same database:** `LoadEventTables` expects empty event tables. The simplest clean reset is `docker compose down -v` followed by a full ETL, which reloads the vocabulary as well. Once that gets slow, load the vocabulary into its own schema once and copy it per run; the ETL-Synthea docs describe a copy-from-schema option. Treat that as an optimisation for later.

Run it:

```bash
docker compose --profile etl build etl      # 10–20 min the first time (R packages compile)
# First run: creates the CDM and loads the vocabulary. This can take a long time.
docker compose --profile etl run --rm etl
```

The `step()` logging prints `▶` / `✔` with timings for each stage. In the pilot, `LoadEventTables` alone took about 3 minutes; the vocabulary load is the long part. To watch a load in progress (row counts are estimates, and update as each table's load commits):

```bash
docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
  SELECT schemaname, relname, n_live_tup
    FROM pg_stat_user_tables
   WHERE schemaname IN ('"'"'synthea'"'"','"'"'cdm'"'"')
   ORDER BY n_live_tup DESC LIMIT 15;"'
```

### 7a. Verify the load

Connect with DBeaver or pgAdmin at `localhost:5432` (database and credentials from `.env`), or open psql in the container:

```bash
docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

```sql
-- 1. Core tables populated? person should match the patients.csv count (1,175 in the pilot)
SELECT 'person' AS t, COUNT(*) FROM cdm.person
UNION ALL SELECT 'observation_period',   COUNT(*) FROM cdm.observation_period
UNION ALL SELECT 'visit_occurrence',     COUNT(*) FROM cdm.visit_occurrence
UNION ALL SELECT 'condition_occurrence', COUNT(*) FROM cdm.condition_occurrence
UNION ALL SELECT 'drug_exposure',        COUNT(*) FROM cdm.drug_exposure
UNION ALL SELECT 'measurement',          COUNT(*) FROM cdm.measurement
UNION ALL SELECT 'death',                COUNT(*) FROM cdm.death;

-- 2. The provenance row the ETL wrote
SELECT cdm_source_name, cdm_source_abbreviation, vocabulary_version, source_description
  FROM cdm.cdm_source;

-- 3. How much failed to map? Lower is better.
SELECT ROUND(100.0 * AVG((condition_concept_id = 0)::int), 2) AS pct_unmapped_conditions
  FROM cdm.condition_occurrence;

-- 4. Your vocabulary-review worklist: the most common unmapped condition codes
SELECT condition_source_value, COUNT(*) AS n
  FROM cdm.condition_occurrence
 WHERE condition_concept_id = 0
 GROUP BY condition_source_value
 ORDER BY n DESC
 LIMIT 20;

-- 5. Standard concept_ids for the module's codes. These replace the "0"
--    placeholders in services/etl/sql/validate_joint.sql (Step 8b).
SELECT DISTINCT co.condition_source_value, co.condition_concept_id, c.concept_name
  FROM cdm.condition_occurrence co
  JOIN cdm.concept c ON c.concept_id = co.condition_concept_id
 WHERE co.condition_source_value IN ('370143000', '7200002');
```

**Reconcile counts at every stage.** "Zero unmapped" is *not* proof that nothing was lost: when the ETL **drops** a row instead of mapping it to `0`, the unmapped count stays clean while records disappear. Compare staging with the CDM directly:

```sql
-- Deaths: deceased patients in staging vs rows in cdm.death (if these differ, see 7b)
SELECT (SELECT COUNT(*) FROM synthea.patients WHERE deathdate IS NOT NULL) AS deceased_in_synthea,
       (SELECT COUNT(*) FROM cdm.death)                                    AS rows_in_cdm_death;

-- Drugs: medications + immunizations staged vs rows in cdm.drug_exposure
SELECT (SELECT COUNT(*) FROM synthea.medications)   AS medications_staged,
       (SELECT COUNT(*) FROM synthea.immunizations) AS immunizations_staged,
       (SELECT COUNT(*) FROM cdm.drug_exposure)     AS drug_exposure_rows;

-- Immunizations specifically: did any land in drug_exposure? (0 here = CVX missing)
SELECT COUNT(*) AS immunizations_in_cdm
  FROM cdm.drug_exposure
 WHERE drug_source_value IN (SELECT DISTINCT code FROM synthea.immunizations);
```

Comparing CSV → staging → CDM counts is how the pilot found both of its gaps. Without CVX, `drug_exposure` held exactly the 28,265 medications and none of the 2,711 immunizations (with CVX: 2,685), and `cdm.death` was 18 short (7b).

To find *which* records are missing, compare per code rather than in total:

```sql
-- Immunization codes whose staged count doesn't match what reached drug_exposure
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
``` Expect `drug_exposure_rows` to be **close to, not exactly**, medications + immunizations, since the ETL can legitimately merge or split some records. A gap the size of a whole source table is never legitimate.

### 7b. Known ETL-Synthea gap: dropped deaths

In the pilot, Synthea recorded **175** deaths but `cdm.death` held only **157**, both before and after adding the Cancer Modifier and CVX vocabularies. `insert_death.sql` builds each death from the patient's **death-certification encounter** (SNOMED `308646001`) and **inner-joins** the cause to ETL-Synthea's lookup table, accepting only Condition-domain causes. This is confirmed in the package SQL (`cdm_version/v540/insert_death.sql`, lines 30–33):

```sql
join @cdm_schema.source_to_standard_vocab_map srctostdvm
 ...
 and srctostdvm.target_domain_id = 'Condition'
 and srctostdvm.source_domain_id = 'Condition'
```

So a death is dropped entirely when:

| Reason | Pilot count | Example | After the patch |
|---|---|---|---|
| No death-certification encounter | 8 | Nothing to build the row from | Restored, cause `0` |
| Cause code has no standard `Maps to` | 7 | `55680006` "Drug overdose", retired from SNOMED in 2021 (A-006) | Restored, cause `0` |
| Cause maps to a **non-Condition** domain | 3 | `94260004` → Cancer Modifier 35226112, a **Measurement** (A-007) | Restored **with** cause 35226112, if Cancer Modifier is loaded |

That goes against OMOP's own convention, which is to **keep the record** with `concept_id = 0` when a value doesn't map. It also matters here specifically: in an SUD project, the deaths dropped most were **drug overdoses**.

**Diagnose:**

```sql
-- Which deceased patients are missing, and do they have a death-cert encounter?
SELECT p.id,
       COUNT(e.id) FILTER (WHERE e.code = '308646001') AS death_cert_encounters
  FROM synthea.patients p
  JOIN cdm.person per ON per.person_source_value = p.id
  LEFT JOIN cdm.death d ON d.person_id = per.person_id
  LEFT JOIN synthea.encounters e ON e.patient = p.id
 WHERE p.deathdate IS NOT NULL
   AND d.person_id IS NULL
 GROUP BY p.id;

-- For those that do: what's the cause, and does it map?
SELECT p.id, e.reasoncode, e.reasondescription,
       c.concept_id AS source_concept_id, c.standard_concept, c.invalid_reason,
       cr.concept_id_2 AS maps_to_standard_id
  FROM synthea.patients p
  JOIN cdm.person per ON per.person_source_value = p.id
  LEFT JOIN cdm.death d ON d.person_id = per.person_id
  JOIN synthea.encounters e ON e.patient = p.id AND e.code = '308646001'
  LEFT JOIN cdm.concept c ON c.concept_code = e.reasoncode AND c.vocabulary_id = 'SNOMED'
  LEFT JOIN cdm.concept_relationship cr
         ON cr.concept_id_1 = c.concept_id AND cr.relationship_id = 'Maps to'
 WHERE p.deathdate IS NOT NULL
   AND d.person_id IS NULL;
```

To read the exact SQL the ETL ran:

```bash
docker compose --profile etl run --rm --entrypoint sh etl -c \
  'f=$(Rscript -e "cat(system.file(\"sql\", package=\"ETLSyntheaBuilder\"))"); \
   find "$f" -name "insert_death.sql" | head -1 | xargs cat'
```

**Fix: `services/etl/sql/patch_missing_deaths.sql`.** Run it after every ETL. It never guesses a mapping.

```sql
/**
 * patch_missing_deaths.sql
 *
 * Restores deceased patients that ETL-Synthea's insert_death.sql drops when the
 * cause of death has no standard "Maps to" concept, or there's no
 * death-certification encounter (SNOMED 308646001).
 *
 * OMOP convention: an unmapped value keeps its row with concept_id = 0, and the
 * original code stays in *_source_value. We never guess a mapping here.
 *
 * Run AFTER run_etl.R. Record it in docs/run-log.md (assumption A-005).
 * Safe to rerun: it only inserts people who aren't already in cdm.death.
 */
INSERT INTO cdm.death (
  person_id, death_date, death_datetime, death_type_concept_id,
  cause_concept_id, cause_source_value, cause_source_concept_id
)
SELECT DISTINCT ON (per.person_id)               -- one row per person, even with duplicate encounters
       per.person_id,
       p.deathdate,
       p.deathdate::timestamp,
       32817,                                     -- EHR, matching the ETL's own rows
       COALESCE(cr.concept_id_2, 0),              -- standard cause if it maps, else 0 (unmapped)
       e.reasoncode,                              -- original SNOMED cause, kept for traceability
       COALESCE(c.concept_id, 0)                  -- source concept, if the code exists in the vocab
  FROM synthea.patients p
  JOIN cdm.person per
    ON per.person_source_value = p.id
  LEFT JOIN cdm.death d
    ON d.person_id = per.person_id
  LEFT JOIN synthea.encounters e                  -- the cause lives on the death-cert encounter
    ON e.patient = p.id AND e.code = '308646001'
  LEFT JOIN cdm.concept c
    ON c.concept_code = e.reasoncode AND c.vocabulary_id = 'SNOMED'
  LEFT JOIN cdm.concept_relationship cr
    ON cr.concept_id_1 = c.concept_id
   AND cr.relationship_id = 'Maps to'
   AND cr.invalid_reason IS NULL
 WHERE p.deathdate IS NOT NULL
   AND d.person_id IS NULL                        -- only people the ETL dropped
 ORDER BY per.person_id;
```

```bash
docker compose exec -T omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < services/etl/sql/patch_missing_deaths.sql
```

Afterwards, `cdm.death` should match `deceased_in_synthea` from 7a. In the pilot, the patch reported `INSERT 0 18` and the totals reconciled at **175 / 175**. The Cancer Modifier vocabulary doesn't change how many rows the patch inserts, because the ETL's domain filter still drops those three. What it changes is the **quality** of the restored rows: the patch has no domain filter, so the metastasis deaths get their real cause (35226112) instead of `0`.

> This is worth reporting upstream on the OHDSI/ETL-Synthea GitHub: an inner join plus a Condition-only domain filter drops whole death records, which contradicts the OMOP convention of keeping unmapped values with `concept_id = 0`. The diagnostic queries above and the lines quoted from `insert_death.sql` are a complete reproduction.

### 7c. Known ETL-Synthea gap: dropped immunizations

With CVX loaded, **2,685 of 2,711** pilot immunizations reached `drug_exposure`. The per-code query in 7a showed the missing **26** came from four codes, with two separate causes, both confirmed in the package SQL (`cdm_version/v540/insert_drug_exposure.sql`):

| Codes | Records | Cause |
|---|---|---|
| `3` (MMR), `8` (Hep B pediatric) | 8 | **Leading zeros.** Synthea writes `3`; CVX writes `03`. Codes are text, so `'3' ≠ '03'` and the inner join (`source_vocabulary_id = 'CVX'`, line 132) finds nothing |
| `207`, `208` (COVID-19 mRNA) | 18 | **Vocabulary filter.** Line 127 requires `target_vocabulary_id = 'CVX'`, but these codes are non-standard in current releases and `Maps to` concepts in another vocabulary |

It's the same family of bug as 7b: a hard-coded filter that assumes what the standard concept looks like (Condition domain there, CVX vocabulary here) breaks when the vocabulary changes.

> Note how the CVX restriction protects the lookup: in ETL-Synthea's map, `source_code = '3'` also exists in Race ("Black or African American"), SOPT, UB04 and others. Codes are only unique **within** a vocabulary (Lesson 003).

**Fix: `services/etl/sql/patch_missing_immunizations.sql`.** Run it after every ETL. It:

- pads single-digit codes **only for the lookup**, so `drug_source_value` keeps Synthea's original `3` and staging is never modified;
- uses a standard CVX concept as-is, **or** follows `Maps to` to any valid, standard, Drug-domain concept, in any vocabulary;
- keeps anything still unmappable with `drug_concept_id = 0`, never dropping it;
- copies `drug_type_concept_id` from the immunizations the ETL did load, links each row to its visit through the Synthea encounter where one exists, and is safe to rerun.

```bash
docker compose exec -T omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < services/etl/sql/patch_missing_immunizations.sql
```

It prints a summary of the rows it's responsible for. In the pilot, expect `INSERT 0 26`, then rerun the 7a per-code query: it should return **no rows**.

> Tested before first use against a mock CDM 5.4 `drug_exposure` (all NOT NULL constraints), covering padded codes, the Race-code collision, cross-vocabulary `Maps to`, an unmappable code, a missing visit, and a second run (inserts nothing). The test caught one bug: Postgres `LPAD('207', 2, '0')` **truncates** to `'20'`, so the patch pads with an explicit single-digit check instead.

### 7d. Pin, record, back up

Once an ETL run succeeds:

1. **Pin ETL-Synthea** to the commit that worked, so the next build gets identical code:
   ```bash
   docker compose --profile etl run --rm --entrypoint Rscript etl \
     -e 'cat(packageDescription("ETLSyntheaBuilder")$RemoteSha, "\n")'
   ```
   Put the SHA in `ARG ETL_SYNTHEA_REF=<sha>` in `services/etl/Dockerfile`, and in the run log.
2. **Record** the run in `docs/run-log.md`: vocabulary release, CPT4 yes/no, ETL SHA, any patches applied.
3. **Back up** the loaded database, so you never sit through the vocabulary load again for the same release:
   ```bash
   mkdir -p backups
   docker compose exec -T omop-db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
     > "backups/omop-$(grep ^RUN_ID .env | cut -d= -f2).dump"
   ```
   Restore into a fresh volume with:
   ```bash
   docker compose exec -T omop-db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' \
     < backups/omop-pilot-0001.dump
   ```
   `backups/` is gitignored: dumps are large and contain the licensed vocabulary.

---

## Step 8: Validate

### 8a. Structural: Data Quality Dashboard

Set `ETL_RUN_DQD=true` and rerun (after `down -v`, because `LoadEventTables` needs empty tables), or run the dashboard separately against the loaded database. Results land in `data/dqd/<run-id>/`. You can view them with `DataQualityDashboard::viewDqDashboard()` from an R session. Atlas (Step 9) doesn't display DQD results; its Data Sources pages come from Achilles instead.

### 8b. Population: joint distribution vs targets

### `services/etl/sql/validate_joint.sql`

```sql
/**
 * validate_joint.sql
 *
 * Rebuilds each person's MHD/SUD profile from OMOP and compares the
 * proportions with the calibration targets.
 *
 * Replace the concept lists with the STANDARD concept_ids your module codes
 * map to. Query 5 in Step 7a lists them for you.
 *
 * @see docs/assumptions.md: the diagnosis code choices are assumptions.
 */
WITH adults AS (
  SELECT p.person_id,
         p.gender_concept_id,
         EXTRACT(YEAR FROM op.observation_period_end_date) - p.year_of_birth AS age_at_end
    FROM cdm.person p
    JOIN cdm.observation_period op USING (person_id)
   WHERE EXTRACT(YEAR FROM op.observation_period_end_date) - p.year_of_birth >= 18
),
flags AS (
  SELECT a.person_id,
         a.gender_concept_id,
         a.age_at_end,
         BOOL_OR(co.condition_concept_id IN (/* MHD standard concept_ids */ 0)) AS mhd,
         BOOL_OR(co.condition_concept_id IN (/* SUD standard concept_ids */ 0)) AS sud
    FROM adults a
    LEFT JOIN cdm.condition_occurrence co USING (person_id)
   GROUP BY a.person_id, a.gender_concept_id, a.age_at_end
)
SELECT CASE
         WHEN age_at_end BETWEEN 18 AND 25 THEN '18-25'
         WHEN age_at_end BETWEEN 26 AND 34 THEN '26-34'
         WHEN age_at_end BETWEEN 35 AND 49 THEN '35-49'
         WHEN age_at_end BETWEEN 50 AND 64 THEN '50-64'
         ELSE '65+'
       END AS age_group,
       gender_concept_id,
       COUNT(*)                                                         AS n,
       ROUND(AVG(CASE WHEN NOT COALESCE(mhd,false) AND NOT COALESCE(sud,false) THEN 1 ELSE 0 END)::numeric, 4) AS p_neither,
       ROUND(AVG(CASE WHEN     COALESCE(mhd,false) AND NOT COALESCE(sud,false) THEN 1 ELSE 0 END)::numeric, 4) AS p_mhd_only,
       ROUND(AVG(CASE WHEN NOT COALESCE(mhd,false) AND     COALESCE(sud,false) THEN 1 ELSE 0 END)::numeric, 4) AS p_sud_only,
       ROUND(AVG(CASE WHEN     COALESCE(mhd,false) AND     COALESCE(sud,false) THEN 1 ELSE 0 END)::numeric, 4) AS p_both
  FROM flags
 GROUP BY 1, 2
 ORDER BY 1, 2;
```

**How to read it.** With 1,000 patients, small strata will drift from the targets by chance. Compare at 10,000 before concluding the module is wrong. A **systematic** excess of MHD or SUD usually means a Synthea built-in module is adding conditions on top of ours (see Step 5, "Prevent duplicates").

### 8c. Full validation matrix

| Dimension | Check | Owner |
|---|---|---|
| Disorder frequency | Marginals vs weighted NSDUH | Engineer |
| Concurrency | Joint cells and P(SUD \| MHD) vs NSDUH | Engineer + methodologist |
| Subgroups | Repeat by age × sex | Engineer |
| Chronology | "Both" profiles have overlapping condition periods; treatment after diagnosis | Engineer |
| Clinical plausibility | Clinician reviews ~20 sampled records, including rare cells | Clinician |
| Mapping quality | `condition_concept_id = 0` count; domain mismatches | Engineer (DQD) |
| Reproducibility | Same seed + config + module → identical output hash | Engineer |

---

## Step 9 (optional): ATLAS and WebAPI

**ATLAS** is OHDSI's web tool for working with an OMOP database without writing SQL: searching the vocabulary, building **concept sets** and **cohort definitions**, generating cohorts, and browsing **Data Sources** reports. **WebAPI** is the Java backend that does the actual database work for it.

This step adds both to *our* Compose file as an optional `atlas` profile, pointed at the `omop-db` we already loaded. Nothing changes for Steps 1–8, and none of it starts unless you ask for it.

> **Versions.** Pinned to **WebAPI 2.15.1 + Atlas 2.15.0**, the current stable 2.x line on Docker Hub. **WebAPI 3.0** was released very recently, with a security rework (Spring Security replaces Shiro), a new Flyway baseline, and i18n removed. **Atlas 3.0** (a Vue rebuild) was in public preview in July 2026, with a final release planned for later in 2026. Revisit the pin once Atlas 3.0 is released and Broadsea supports it. **Never mix majors:** Atlas 2.x needs WebAPI 2.x.

### 9a. How the pieces fit

```
 Your browser
     │  http://localhost:8080
     ▼
 ┌──────────────────────── atlas-proxy (nginx) ────────────────────────┐
 │   /atlas/  ──▶ atlas   (static JavaScript app, runs IN the browser)  │
 │   /WebAPI/ ──▶ webapi  (Java REST API, the only part touching the DB)│
 └──────────────────────────────────────────────────────────┬──────────┘
                                                            │ JDBC, as role ohdsi_app
                                                            ▼
 omop-db / synthetic_concurrent
   ├── webapi   WebAPI's own tables (cohort definitions, concept sets, jobs)   owner
   ├── cdm      OMOP CDM + vocabulary (from Step 7)                            read only
   ├── results  cohorts, Achilles counts, concept hierarchy                    read + write
   └── temp     scratch tables during cohort generation                        owner
```

Three ideas to hold on to:

1. **Atlas never talks to the database.** It's a web page in your browser that calls WebAPI. That's why `WEBAPI_URL` in `compose.yaml` says `localhost`: the *browser* resolves it, not a container.
2. **WebAPI uses the database twice.** Once for its own bookkeeping (schema `webapi`, built by **Flyway** migrations on first start), and once to query our CDM, which it learns about from rows in `webapi.source` and `webapi.source_daimon` (9c).
3. **Least privilege.** WebAPI connects as a dedicated role, `ohdsi_app`, that can read `cdm` but never change it. The ETL stays the only writer of clinical data.

### 9b. Prepare the database and start WebAPI

**1. Set the password** in `.env` (letters, digits, `_` and `-` only, at least 16 characters, because it ends up inside a JDBC URL):

```bash
openssl rand -hex 24          # paste the output into .env as OHDSI_APP_PASSWORD=
```

**2. Recreate the database container** so it picks up the new variable. Only the container is replaced; the `omop-pgdata` volume, and everything loaded in Step 7, stays.

```bash
docker compose up -d omop-db
docker compose exec omop-db sh -c 'test -n "$OHDSI_APP_PASSWORD" && echo "password visible in container"'
```

**3. Create the role, schemas and grants.** Safe to rerun.

```bash
docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v admin_role="$POSTGRES_USER" -v app_pw="$OHDSI_APP_PASSWORD"' \
  < services/atlas/sql/01_roles_and_schemas.sql
```

#### `services/atlas/sql/01_roles_and_schemas.sql`

```sql
/**
 * 01_roles_and_schemas.sql: prepare omop-db for WebAPI/Atlas (Step 9b)
 *
 * Run BEFORE the first WebAPI start, as the admin role. Safe to rerun: every
 * statement checks first or is idempotent, and the password is re-applied each
 * time (so rotating OHDSI_APP_PASSWORD in .env just means rerunning this).
 *
 * What it creates
 *   role   ohdsi_app   Least-privilege login used by WebAPI for BOTH of its jobs:
 *                      (1) its own application tables (schema webapi), and
 *                      (2) querying our CDM as a registered "source".
 *   schema webapi      WebAPI's own tables. Created EMPTY here; WebAPI's Flyway
 *                      migrations fill it on first start.
 *   schema temp        Scratch space WebAPI uses while generating cohorts.
 *
 * What ohdsi_app can do
 *   cdm      read only    (the ETL, as the admin role, stays the only writer)
 *   results  read + write (cohort generation, Achilles reports)
 *   webapi   owner
 *   temp     owner
 *
 * Invocation (from the project root; variables come from omop-db's environment):
 *
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
 *     -v admin_role="$POSTGRES_USER" -v app_pw="$OHDSI_APP_PASSWORD"' \
 *     < services/atlas/sql/01_roles_and_schemas.sql
 *
 * psql variable syntax used below:
 *   :'var'  → the value as a quoted SQL literal   ('s3cret')
 *   :"var"  → the value as a quoted identifier    ("omop_admin")
 *
 * @see https://www.postgresql.org/docs/16/app-psql.html#APP-PSQL-INTERPOLATION
 */

-- ---------------------------------------------------------------------------
-- Guard rails: fail loudly on a missing or URL-unsafe password.
-- The password ends up inside a JDBC URL (02_register_source.sql), where
-- characters like @ : / ? & # would break parsing, so we require a plain
-- alphanumeric password (make it long instead of "complex").
-- ---------------------------------------------------------------------------
SELECT length(:'app_pw') >= 16                AS pw_long_enough,
       :'app_pw' ~ '^[A-Za-z0-9_-]+$'         AS pw_url_safe
\gset

\if :pw_long_enough
\else
  SELECT length(:'app_pw') AS pw_len
  \gset
  \echo 'ERROR: OHDSI_APP_PASSWORD inside omop-db is' :pw_len 'characters (need 16+). Check, in order:'
  \echo '  1. .env sets it:              grep -c ^OHDSI_APP_PASSWORD= .env'
  \echo '  2. compose.yaml passes it:    docker compose config | grep OHDSI_APP_PASSWORD'
  \echo '     (omop-db -> environment: needs  OHDSI_APP_PASSWORD: ${OHDSI_APP_PASSWORD:-} )'
  \echo '  3. container was recreated:   docker compose up -d omop-db   (should say Recreated)'
  DO $$ BEGIN RAISE EXCEPTION 'OHDSI_APP_PASSWORD too short'; END $$;
\endif

\if :pw_url_safe
\else
  \echo 'ERROR: OHDSI_APP_PASSWORD may only contain letters, digits, _ and - (it goes into a JDBC URL).'
  DO $$ BEGIN RAISE EXCEPTION 'OHDSI_APP_PASSWORD not URL-safe'; END $$;
\endif

-- ---------------------------------------------------------------------------
-- Role: create once, then (re)set the password every run.
-- ---------------------------------------------------------------------------
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ohdsi_app') AS need_role
\gset

\if :need_role
  CREATE ROLE ohdsi_app LOGIN;
  \echo 'Created role ohdsi_app.'
\else
  \echo 'Role ohdsi_app exists... skipping create.'
\endif

ALTER ROLE ohdsi_app WITH LOGIN PASSWORD :'app_pw';

-- ---------------------------------------------------------------------------
-- Schemas WebAPI owns.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS webapi AUTHORIZATION ohdsi_app;
CREATE SCHEMA IF NOT EXISTS temp   AUTHORIZATION ohdsi_app;

-- If the schemas already existed under another owner, hand them over.
ALTER SCHEMA webapi OWNER TO ohdsi_app;
ALTER SCHEMA temp   OWNER TO ohdsi_app;

-- ---------------------------------------------------------------------------
-- cdm: read only.
-- ---------------------------------------------------------------------------
GRANT USAGE  ON SCHEMA cdm                TO ohdsi_app;
GRANT SELECT ON ALL TABLES IN SCHEMA cdm  TO ohdsi_app;

-- Tables the admin creates in cdm LATER (e.g. a fresh ETL) get the same grant.
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_role" IN SCHEMA cdm
  GRANT SELECT ON TABLES TO ohdsi_app;

-- ---------------------------------------------------------------------------
-- results: read and write (cohort tables, Achilles output, concept hierarchy).
-- ---------------------------------------------------------------------------
GRANT USAGE, CREATE ON SCHEMA results                 TO ohdsi_app;
GRANT ALL ON ALL TABLES    IN SCHEMA results          TO ohdsi_app;
GRANT ALL ON ALL SEQUENCES IN SCHEMA results          TO ohdsi_app;

-- Covers tables made later by the admin: the results DDL (9d) and Achilles (9e).
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_role" IN SCHEMA results
  GRANT ALL ON TABLES    TO ohdsi_app;
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_role" IN SCHEMA results
  GRANT ALL ON SEQUENCES TO ohdsi_app;

\echo '01_roles_and_schemas.sql finished.'
```

**4. Start the web stack** and wait for WebAPI. The first start runs WebAPI's Flyway migrations (many of them), so give it a few minutes.

```bash
docker compose --profile atlas up -d
docker compose --profile atlas logs -f webapi        # Ctrl-C once it settles

# Ready when this prints JSON containing "version":"2.15.1"
until curl -fsS http://localhost:8080/WebAPI/info; do sleep 10; done; echo
```

Check that Flyway built the schema:

```bash
docker compose exec omop-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT COUNT(*) AS webapi_tables FROM information_schema.tables WHERE table_schema = '\''webapi'\''"'
```

#### `services/atlas/nginx.conf`

```nginx
# =============================================================================
# services/atlas/nginx.conf: one front door for Atlas and WebAPI
#
# Why a proxy at all?
#   Atlas is a web page that runs in YOUR BROWSER and calls WebAPI over HTTP.
#   If the two lived on different ports (say 8081 and 8080), the browser would
#   treat every call as cross-origin, and WebAPI would need CORS configured
#   correctly. Serving both from one address avoids that whole class of error:
#
#     http://localhost:8080/          → redirects to /atlas/
#     http://localhost:8080/atlas/    → atlas container  (static Atlas app)
#     http://localhost:8080/WebAPI/   → webapi container (Java REST API)
#
#   This is the same idea as Broadsea's Traefik proxy, written out by hand so
#   you can read it.
#
# @see https://nginx.org/en/docs/http/ngx_http_proxy_module.html
# =============================================================================

server {
  listen 8080;

  # Keep redirects relative ("Location: /atlas/"), so they still work when the
  # host port in .env (ATLAS_PORT) isn't 8080.
  absolute_redirect off;

  # Cohort generation and the results DDL can take minutes on a full vocabulary.
  proxy_read_timeout 600s;
  proxy_send_timeout 600s;

  # Pass the original host and scheme through, so WebAPI builds correct links.
  proxy_set_header Host              $http_host;
  proxy_set_header X-Real-IP         $remote_addr;
  proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;

  # Bare address → Atlas.
  location = / {
    return 302 /atlas/;
  }

  # The Atlas image serves the app under /atlas/ itself, so the path is passed
  # through unchanged (no trailing slash on proxy_pass = no prefix stripping).
  # @see README Troubleshooting if /atlas/ returns 404.
  location /atlas/ {
    proxy_pass http://atlas:8080;
  }

  # WebAPI's context path is /WebAPI (capital W-A-P-I, case-sensitive).
  location /WebAPI/ {
    proxy_pass http://webapi:8080;
  }
}
```

To stop just the web stack (the database keeps running): `docker compose --profile atlas stop atlas-proxy atlas webapi`.

### 9c. Register our CDM as a source

WebAPI now runs, but it doesn't know our CDM exists. A **source** is one database it can query; its **daimons** say which schema plays which role (CDM, Vocabulary, Results, Temp).

```bash
docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v db_name="$POSTGRES_DB" -v app_pw="$OHDSI_APP_PASSWORD"' \
  < services/atlas/sql/02_register_source.sql

# WebAPI caches its source list at startup, so restart it, then confirm.
docker compose --profile atlas restart webapi
until curl -fsS http://localhost:8080/WebAPI/info >/dev/null; do sleep 5; done
curl -fsS http://localhost:8080/WebAPI/source/sources; echo     # should list SYNTH_OMOP
```

#### `services/atlas/sql/02_register_source.sql`

```sql
/**
 * 02_register_source.sql: tell WebAPI where our CDM lives (Step 9c)
 *
 * Run AFTER WebAPI has started once (its Flyway migrations create the
 * webapi.source and webapi.source_daimon tables this script writes to).
 * Safe to rerun: inserts only what's missing, and refreshes the connection
 * string each time (picks up a rotated OHDSI_APP_PASSWORD).
 *
 * Concepts
 *   source  One database WebAPI can query, identified by source_key.
 *   daimon  Tells WebAPI which SCHEMA plays which ROLE inside that source:
 *
 *     daimon_type  meaning      our schema   priority*
 *     -----------  -----------  -----------  ---------
 *     0            CDM          cdm          0
 *     1            Vocabulary   cdm          1
 *     2            Results      results      1
 *     5            Temp         temp         0
 *
 *   * With several sources, the highest-priority Vocabulary/Results daimon is
 *     the default Atlas uses for concept search and reports.
 *
 * Invocation:
 *
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
 *     -v db_name="$POSTGRES_DB" -v app_pw="$OHDSI_APP_PASSWORD"' \
 *     < services/atlas/sql/02_register_source.sql
 *
 * Then restart WebAPI so it reloads its source list:
 *   docker compose --profile atlas restart webapi
 *
 * @see https://github.com/OHDSI/WebAPI/wiki/CDM-Configuration
 */

\set source_key  'SYNTH_OMOP'
\set source_name 'Synthetic Concurrent Disorders (local)'

-- Fail early, with a clear message, if WebAPI hasn't created its tables yet.
SELECT to_regclass('webapi.source') IS NOT NULL AS webapi_ready
\gset
\if :webapi_ready
\else
  \echo 'ERROR: webapi.source does not exist yet. Start WebAPI and wait for /WebAPI/info first (Step 9b).'
  DO $$ BEGIN RAISE EXCEPTION 'WebAPI tables missing'; END $$;
\endif

BEGIN;

-- ---------------------------------------------------------------------------
-- The source row. The JDBC URL uses the Compose service name "omop-db" and the
-- INTERNAL port 5432: WebAPI connects container-to-container, not via the host.
-- ---------------------------------------------------------------------------
INSERT INTO webapi.source (source_id, source_name, source_key, source_connection, source_dialect)
SELECT nextval('webapi.source_sequence'), :'source_name', :'source_key', 'placeholder', 'postgresql'
 WHERE NOT EXISTS (SELECT 1 FROM webapi.source WHERE source_key = :'source_key');

-- Always (re)write the connection, so a password change only needs a rerun.
UPDATE webapi.source
   SET source_name       = :'source_name',
       source_connection = 'jdbc:postgresql://omop-db:5432/' || :'db_name'
                           || '?user=ohdsi_app&password=' || :'app_pw'
 WHERE source_key = :'source_key';

-- ---------------------------------------------------------------------------
-- The daimons, one row per (source, daimon_type), inserted only if missing.
-- ---------------------------------------------------------------------------
INSERT INTO webapi.source_daimon (source_daimon_id, source_id, daimon_type, table_qualifier, priority)
SELECT nextval('webapi.source_daimon_sequence'), s.source_id, d.daimon_type, d.table_qualifier, d.priority
  FROM webapi.source s
 CROSS JOIN (VALUES (0, 'cdm',     0),
                    (1, 'cdm',     1),
                    (2, 'results', 1),
                    (5, 'temp',    0)) AS d(daimon_type, table_qualifier, priority)
 WHERE s.source_key = :'source_key'
   AND NOT EXISTS (SELECT 1
                     FROM webapi.source_daimon sd
                    WHERE sd.source_id   = s.source_id
                      AND sd.daimon_type = d.daimon_type);

COMMIT;

-- ---------------------------------------------------------------------------
-- Show the result (password hidden) so it lands in your terminal scrollback.
-- ---------------------------------------------------------------------------
SELECT s.source_id, s.source_key, s.source_name,
       regexp_replace(s.source_connection, 'password=[^&]*', 'password=***') AS source_connection,
       sd.daimon_type, sd.table_qualifier, sd.priority
  FROM webapi.source s
  JOIN webapi.source_daimon sd USING (source_id)
 WHERE s.source_key = :'source_key'
 ORDER BY sd.daimon_type;
```

### 9d. Create the results tables

Cohort generation and the reports need tables in `results` (cohort, cohort_inclusion, concept_hierarchy and others). WebAPI **generates** the DDL for us, with our schema names filled in and translated to PostgreSQL by SqlRender. We save it, read it, then run it as the admin role.

```bash
mkdir -p data/atlas
curl -fsS "http://localhost:8080/WebAPI/ddl/results?dialect=postgresql&schema=results&vocabSchema=cdm&tempSchema=temp&initConceptHierarchy=true" \
  -o data/atlas/results_ddl.sql

grep -c -i "create table" data/atlas/results_ddl.sql     # sanity check: a non-zero count
less data/atlas/results_ddl.sql                          # read before you run

docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < data/atlas/results_ddl.sql
```

- `initConceptHierarchy=true` fills `results.concept_hierarchy` from the full vocabulary. Expect this part to take several minutes.
- The DDL is written to run **once**. A second run fails with "already exists", which is harmless.
- `ohdsi_app` gets access to the new tables automatically, through the **default privileges** set in 01.

### 9e. Run Achilles (Data Sources reports)

Without Achilles, cohorts and vocabulary search work, but **Data Sources** is empty and concept search shows no record counts. Achilles fills `results.achilles_*`. Rerun it after **every** ETL load: the counts describe one load.

```bash
docker compose --profile etl build etl                    # once: adds Achilles to the image
docker compose --profile etl run --rm etl Rscript /app/run_achilles.R
docker compose --profile atlas restart webapi             # drop cached (empty) reports
```

Record how long it took in `docs/run-log.md`.

#### `services/etl/run_achilles.R`

```r
#' run_achilles.R: characterize the loaded CDM for Atlas's "Data Sources" pages (Step 9e)
#'
#' Achilles counts things (people per year of birth, conditions per concept,
#' observation-period lengths …) and writes the counts to results.achilles_*.
#' Atlas reads those tables to draw its Data Sources reports and to show
#' record counts next to concepts in search results.
#'
#' Run it after every ETL load (the counts describe ONE load), as the admin role
#' (it creates tables in results; 01_roles_and_schemas.sql's default privileges
#' then give ohdsi_app access to them automatically).
#'
#' Usage (needs the etl image rebuilt with Achilles, see the Dockerfile):
#'   docker compose --profile etl run --rm etl Rscript /app/run_achilles.R
#'
#' Env vars (already set on the etl service in compose.yaml):
#'   DB_SERVER, DB_PORT, DB_USER, DB_PASSWORD, RUN_ID
#'
#' @see https://ohdsi.github.io/Achilles/
#' @see https://github.com/OHDSI/WebAPI/wiki/CDM-Configuration

library(DatabaseConnector)
library(Achilles)

# --- Configuration ----------------------------------------------------------
cdm_schema     <- "cdm"
vocab_schema   <- "cdm"       # our vocabulary lives alongside the CDM tables
results_schema <- "results"
run_id         <- Sys.getenv("RUN_ID")

stopifnot(nzchar(run_id))

#' Same connection pattern as run_etl.R (DRY candidate: move to a shared
#' services/etl/connection.R and source() it from both scripts).
cd <- createConnectionDetails(
  dbms         = "postgresql",
  server       = Sys.getenv("DB_SERVER"),
  port         = as.integer(Sys.getenv("DB_PORT", "5432")),
  user         = Sys.getenv("DB_USER"),
  password     = Sys.getenv("DB_PASSWORD"),
  pathToDriver = Sys.getenv("DATABASECONNECTOR_JAR_FOLDER", "/opt/jdbc")
)

# Achilles creates outputFolder with a NON-recursive dir.create(), so a missing
# parent (/tmp/achilles-output) makes it fail, and it only crashes at the very
# end, when it reads its own log back to merge the scratch tables. Create the
# whole path ourselves first.
output_folder <- file.path("/tmp/achilles-output", run_id)
dir.create(output_folder, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(output_folder))

message(sprintf("[achilles] run %s: characterizing %s → %s", run_id, cdm_schema, results_schema))
started <- Sys.time()

Achilles::achilles(
  connectionDetails       = cd,
  cdmDatabaseSchema       = cdm_schema,
  resultsDatabaseSchema   = results_schema,
  vocabDatabaseSchema     = vocab_schema,
  sourceName              = paste0("Synthetic Concurrent Disorders (", run_id, ")"),
  cdmVersion              = "5.4",
  createTable             = TRUE,    # drop and recreate achilles_* (fresh counts per load)
  smallCellCount          = 5,       # counts below this are suppressed, the habit to keep for real data
  numThreads              = 1,       # PostgreSQL + 1 thread is the simplest, most predictable setting
  optimizeAtlasCache      = TRUE,    # builds results.achilles_result_concept_count for Atlas search
  outputFolder            = output_folder
)

message(sprintf("[achilles] done in %.1f minutes",
                as.numeric(difftime(Sys.time(), started, units = "mins"))))
message("[achilles] restart WebAPI so Atlas drops its cached (empty) reports:")
message("           docker compose --profile atlas restart webapi")
```

### 9f. Open Atlas and check it

Open **<http://localhost:8080/atlas/>**.

| Check | Where in Atlas | Expected |
|---|---|---|
| WebAPI reachable | Home page | No "Unable to connect to an instance of the WebAPI" banner |
| Source registered | **Configuration** | `SYNTH_OMOP` listed with CDM, Vocabulary, Results and Temp |
| Vocabulary works | **Search** → `depressive disorder` | Concepts listed; RC / DRC counts appear after 9e |
| Achilles loaded | **Data Sources** → `SYNTH_OMOP` → Dashboard | Person count = `SELECT COUNT(*) FROM cdm.person` |
| Cohorts generate | Smoke-test cohort, below | Count matches the SQL count |

**Smoke-test cohort (reconciliation again; see Lesson 005).** In Atlas, build a concept set from your MHD diagnosis's **standard** concept with *Include descendants* ticked. Make a cohort definition whose entry event is a *Condition occurrence* of that set, then **Generate** it on `SYNTH_OMOP`. Compare the person count with SQL:

```sql
-- Replace 0 with the standard concept_id you used in the Atlas concept set.
SELECT COUNT(DISTINCT co.person_id) AS persons
  FROM cdm.condition_occurrence co
  JOIN cdm.concept_ancestor ca ON ca.descendant_concept_id = co.condition_concept_id
 WHERE ca.ancestor_concept_id = 0;
```

They should match, or Atlas should be slightly *lower*: by default, Atlas counts only events that fall **inside an observation period**. If they differ, explain the difference before trusting either number.

> **Keep your work.** Atlas definitions live in the `webapi` schema, inside `omop-pgdata`. `docker compose down -v` deletes them along with the CDM. Export important cohort definitions as JSON (cohort → **Export** tab) into the repo, e.g. `docs/cohorts/`.

### 9g. Alternative: full Broadsea

**OHDSI Broadsea** (<https://github.com/OHDSI/Broadsea>) is the community's full Docker deployment: Atlas, WebAPI, HADES/RStudio, Solr vocabulary search, Ares, security providers (basic, LDAP, AD), Traefik and HTTPS. Move to it when you need a shared, logged-in server rather than a single-user laptop stack. Keep it in its own folder, **pin a tagged release**, and register `omop-db` with the same source and daimon layout as 9c. Since Broadsea 3.5, passwords live in files under `./secrets` (Docker secrets), not in `.env`.

---

## Step 10 (optional): Cohort analyses: TreatmentPatterns and CohortContrast

Step 9 gave you ATLAS for **defining** cohorts. This step adds two R packages that **analyse** them:

| Package | Question it answers | Maintainer |
|---|---|---|
| **TreatmentPatterns** | After entering a cohort, which treatments do people go through, in what order and combinations? (sunburst and Sankey) | DARWIN EU / Erasmus MC, CRAN |
| **CohortContrast** | Which concepts are over-represented in a target cohort compared with a control? (enrichment) | University of Tartu, CRAN |

> **Status:** new, and **not yet run end to end**. The SQL was tested on PostgreSQL 16, and the
> Compose service resolves cleanly. The R scripts follow each package's documented API, but
> haven't run against these package versions yet. Record the first run in `docs/run-log.md`.

### 10a. How it fits

```
 ATLAS (Step 9): define cohorts → Generate on SYNTH_OMOP
        │
        ▼
 results.cohort          ← the hand-off point: every tool reads cohorts from here, by ID
        │
        ├──▶ analytics: run_treatment_patterns.R ──▶ data/analyses/<RUN_ID>/treatment-patterns/<study>/
        └──▶ analytics: run_cohort_contrast.R    ──▶ data/analyses/<RUN_ID>/cohort-contrast/<study>/
```

Design choices, and why:

| Choice | Why |
|---|---|
| **ATLAS is the cohort hub** | Every tool uses the same reviewed definitions. No cohort logic is duplicated in R |
| **A separate `analytics` image** | The ETL image stays pinned and lean; upgrading an analysis package can't break a load |
| **A dated package snapshot** (`CRAN_SNAPSHOT`) | Pre-built binaries (fast), and the same versions on every rebuild |
| **Connects as `ohdsi_app`** | Least privilege: reads `cdm`, can't change it |
| **`analytics_scratch` schema** | CohortContrast's write schema is described as temporary, so it's kept away from WebAPI's `temp` |
| **Committed study files** | Each analysis is a reviewable file: cohort IDs plus settings (`services/analytics/studies/`) |
| **`provenance.json` per result** | What ran, on which load, with which package versions and settings |

### 10b. Prepare (once)

```bash
# 1. Scratch schema (needs Step 9b's ohdsi_app role)
docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < services/analytics/sql/01_analytics_scratch.sql

# 2. Results folder, owned by you (the container runs as your user)
mkdir -p data/analyses

# 3. Build the image, keeping the log (minutes with binaries; much longer if anything compiles)
docker compose --profile analytics build --progress=plain analytics 2>&1 | tee /tmp/analytics-build.log

# 4. Prove the packages load (the Dockerfile also checks this)
docker compose --profile analytics run --rm analytics Rscript -e \
  "for (p in c('TreatmentPatterns','CohortContrast','CDMConnector')) cat(p, as.character(packageVersion(p)), '\n')"
```

#### `services/analytics/Dockerfile`

```dockerfile
# =============================================================================
# services/analytics/Dockerfile: R image for cohort-level analyses (Step 10)
#
# Kept SEPARATE from services/etl on purpose: the ETL image stays pinned and
# lean, and upgrading an analysis package can never break a data load.
#
# Packages:
#   TreatmentPatterns  treatment pathways (sunburst / Sankey)    DARWIN EU, CRAN
#   CohortContrast     concept enrichment, target vs control      Univ. Tartu, CRAN
#
# Same R version as the etl image, so Docker can share the base layers.
# =============================================================================
FROM rocker/r-ver:4.4.2

# System dependencies:
#   default-jdk                  DatabaseConnector (JDBC), used by TreatmentPatterns
#   libpq-dev                    RPostgres (DBI driver), used by CDMConnector / CohortContrast
#   libxml2/libssl/libcurl -dev  common build dependencies for R packages
#   python3 + venv + pip         CohortContrast's results viewer uses Python helpers (Step 10g)
#   libglpk-dev libgmp-dev       igraph (needed by networkD3, the Sankey plots): the pre-built
#                                binary installs without them but then FAILS TO LOAD
RUN apt-get update && apt-get install -y --no-install-recommends \
      default-jdk libpq-dev libxml2-dev libssl-dev libcurl4-openssl-dev \
      libglpk-dev libgmp-dev \
      python3 python3-venv python3-pip \
  && R CMD javareconf \
  && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Package source: a DATED snapshot of Posit Package Manager, Linux binaries.
#   - Binaries: arrow and duckdb install in seconds instead of compiling for
#     many minutes.
#   - Dated: rebuilding next month installs exactly the same versions
#     (reproducibility, like pinning ETL_SYNTHEA_REF). Bump it deliberately.
# The rocker base image already sets the HTTP user agent PPM needs to serve
# binaries; this line only replaces the repository URL. Its pre-set snapshot
# is from when R 4.4.2 was current, too old for these packages.
# ---------------------------------------------------------------------------
ARG CRAN_SNAPSHOT=2026-11-16
RUN . /etc/os-release \
  && printf "options(repos = c(CRAN = 'https://p3m.dev/cran/__linux__/%s/%s'))\n" \
       "$VERSION_CODENAME" "$CRAN_SNAPSHOT" >> /usr/local/lib/R/etc/Rprofile.site

# Install, then CHECK. `R -e "install.packages(...)"` exits 0 even when an
# install fails (Lesson 008, case 2), so the last command turns a missing
# package into a failed build. It prints each failure's actual LOAD error,
# because "installed but won't load" usually means a missing system library,
# and the error message names it.
RUN R -q -e "install.packages(c( \
      'DatabaseConnector', 'SqlRender', 'DBI', 'RPostgres', 'CDMConnector', \
      'TreatmentPatterns', 'CohortContrast', \
      'jsonlite', 'htmlwidgets', 'sunburstR', 'networkD3', 'plotly'))" \
  && R -q -e "pkgs <- c('DatabaseConnector','SqlRender','DBI','RPostgres','CDMConnector', \
                        'TreatmentPatterns','CohortContrast','jsonlite','htmlwidgets', \
                        'sunburstR','networkD3','plotly'); \
              errs <- vapply(pkgs, function(p) tryCatch({ loadNamespace(p); '' }, \
                             error = function(e) conditionMessage(e)), character(1)); \
              bad <- errs[nzchar(errs)]; \
              for (p in names(bad)) message('CANNOT LOAD ', p, ': ', bad[[p]]); \
              if (length(bad)) quit(status = 1)"

# PostgreSQL JDBC driver at BUILD time, so runs work offline (same as etl).
ENV DATABASECONNECTOR_JAR_FOLDER=/opt/jdbc
RUN mkdir -p /opt/jdbc \
  && R -q -e "DatabaseConnector::downloadJdbcDrivers('postgresql', pathToDriver = '/opt/jdbc')"

# Unprivileged user LAST: everything above needed root to install.
RUN useradd --create-home analytics
USER analytics
WORKDIR /app

# No default analysis: you always say which script and which study to run.
CMD ["Rscript", "-e", "cat('Usage: docker compose --profile analytics run --rm -e STUDY=<name> analytics Rscript /app/run_<tool>.R\\n')"]
```

#### `services/analytics/sql/01_analytics_scratch.sql`

```sql
/**
 * 01_analytics_scratch.sql: scratch schema for analysis packages (Step 10b)
 *
 * Run once, as the admin role, AFTER services/atlas/sql/01_roles_and_schemas.sql
 * (which creates the ohdsi_app role). Safe to rerun.
 *
 * Why a separate schema?
 *   CohortContrast (via CDMConnector) needs a "write schema" for intermediate
 *   tables, and its docs describe that schema as temporary ("will be
 *   deleted"). So it gets its own throwaway schema. It must never be WebAPI's
 *   temp schema, and never cdm or results. Emptying or dropping it can't
 *   hurt anything else.
 *
 * Invocation:
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < services/analytics/sql/01_analytics_scratch.sql
 */

-- Fail clearly if Step 9b hasn't been run yet.
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ohdsi_app') AS have_role
\gset
\if :have_role
\else
  \echo 'ERROR: role ohdsi_app does not exist. Run services/atlas/sql/01_roles_and_schemas.sql first (Step 9b).'
  DO $$ BEGIN RAISE EXCEPTION 'ohdsi_app missing'; END $$;
\endif

CREATE SCHEMA IF NOT EXISTS analytics_scratch AUTHORIZATION ohdsi_app;
ALTER SCHEMA analytics_scratch OWNER TO ohdsi_app;

-- The analyses read ATLAS cohort NAMES from webapi.cohort_definition.
-- ohdsi_app already owns the webapi schema, so no extra grant is needed;
-- this check just makes that assumption visible.
SELECT has_schema_privilege('ohdsi_app', 'webapi', 'USAGE')  AS can_read_webapi,
       has_schema_privilege('ohdsi_app', 'cdm', 'USAGE')     AS can_read_cdm,
       has_schema_privilege('ohdsi_app', 'results', 'USAGE') AS can_read_results;

\echo '01_analytics_scratch.sql finished.'
```

### 10c. Define and generate the cohorts in ATLAS

Each study needs its cohorts **generated** on `SYNTH_OMOP`. The scripts stop with a clear
message if a cohort has no rows. Lesson 007's lab builds the first two:

| Cohort | Used by | Notes |
|---|---|---|
| `MHD adults (course)` | TreatmentPatterns target | Lesson 007, Part A |
| `MHD + SUD (course)` | CohortContrast target | Lesson 007, Part B |
| `MHD only` | CohortContrast control | MHD, with **exactly 0** SUD occurrences any time |
| One cohort per treatment | TreatmentPatterns events | Entry = drug exposure of a concept set (e.g. an ATC class with descendants) |

> **Check what Synthea actually prescribes first:** ATLAS → Data Sources → `SYNTH_OMOP` → **Drug
> Exposure**. Synthea only generates the treatments its modules model, and our module only
> assigns **diagnoses**, so some treatment classes may be empty. An empty event cohort is a
> finding about the simulation, not a bug in the tool.

### 10d. Study files

A study file names the cohorts (by the ID in their ATLAS URL) and the settings. Copy an
example, put in your IDs, and commit it.

```bash
cp services/analytics/studies/example-mhd-treatments.env services/analytics/studies/mhd-treatments.env
```

The variables are listed in `services/analytics/studies/README.md`.

#### `services/analytics/studies/example-mhd-treatments.env`

```dotenv
# =============================================================================
# example-mhd-treatments: TreatmentPatterns study (Step 10e)
#
# Question: after a first MHD diagnosis, which treatment cohorts do adults
# go through, and in what order?
#
# The IDs below are PLACEHOLDERS. Replace them with your own ATLAS cohort IDs
# (the number in the cohort's URL), generate each cohort on SYNTH_OMOP, then:
#
#   docker compose --profile analytics run --rm -e STUDY=example-mhd-treatments \
#     analytics Rscript /app/run_treatment_patterns.R
# =============================================================================

# Target: e.g. "MHD adults (course)" from Lesson 007.
TP_TARGET_COHORT_ID=1

# Events: one cohort per treatment you want in the pathways, e.g. drug-class
# cohorts built in ATLAS from concept sets (antidepressants, SUD medications …).
# Check Data Sources → Drug Exposure first: Synthea only prescribes what its
# modules model, so some classes may be empty in synthetic data.
TP_EVENT_COHORT_IDS=2,3

# Optional
TP_MIN_CELL_COUNT=5
```

#### `services/analytics/studies/example-mhd-sud-vs-mhd.env`

```dotenv
# =============================================================================
# example-mhd-sud-vs-mhd: CohortContrast study (Step 10f)
#
# Question: which concepts are over-represented in people with BOTH MHD and
# SUD, compared with people with MHD only?
#
# The IDs below are PLACEHOLDERS. Replace them with your own ATLAS cohort IDs,
# generate both cohorts on SYNTH_OMOP, then:
#
#   docker compose --profile analytics run --rm -e STUDY=example-mhd-sud-vs-mhd \
#     analytics Rscript /app/run_cohort_contrast.R
#
# Remember: in synthetic data, any difference you find was put there by the
# simulation (our module plus Synthea's own modules). That makes it a good
# check of the simulation, and not evidence about real people.
# =============================================================================

# Target: e.g. "MHD + SUD (course)" from Lesson 007.
CC_TARGET_COHORT_ID=4

# Control: e.g. an "MHD only" cohort (MHD, with exactly 0 SUD occurrences).
# Leave empty to let CohortContrast build matched controls instead.
CC_CONTROL_COHORT_ID=5

# Optional (defaults shown)
CC_PREVALENCE_CUTOFF=2.5
CC_PRESENCE_FILTER=0.2
CC_NUM_CORES=1
```

### 10e. Run TreatmentPatterns

```bash
docker compose --profile analytics run --rm -e STUDY=mhd-treatments \
  analytics Rscript /app/run_treatment_patterns.R
```

Output in `data/analyses/<RUN_ID>/treatment-patterns/mhd-treatments/`:

- the CSV files from `TreatmentPatterns::export()` (pathways, counts by age/sex/year, attrition, event durations);
- `sunburst.html` and `sankey.html` (each with a `*_files` folder next to it). Open them in your browser;
- `provenance.json`.

Counts below `TP_MIN_CELL_COUNT` (default 5) are **censored**. With about 1,200 synthetic
patients, many paths will be small. That's the privacy habit to keep for real data, so lower it
only for synthetic runs, and say so in the study file.

#### `services/analytics/run_treatment_patterns.R`

```r
#' run_treatment_patterns.R: treatment pathways for one study (Step 10e)
#'
#' Question it answers: after entering the TARGET cohort, which EVENT cohorts
#' (usually treatments) do people go through, in what order and combinations?
#'
#' Inputs: cohorts generated in ATLAS (results.cohort), chosen by ID in a
#'   study file, e.g. services/analytics/studies/mhd-treatments.env:
#'     TP_TARGET_COHORT_ID   one target cohort
#'     TP_EVENT_COHORT_IDS   comma-separated event cohorts (the "treatments")
#'     TP_EXIT_COHORT_IDS    optional, comma-separated exit cohorts
#'     TP_MIN_CELL_COUNT     optional, default 5 (small counts are censored)
#'     TP_MIN_ERA_DURATION, TP_COMBINATION_WINDOW, TP_MIN_POST_COMBINATION_DURATION
#'                           optional; passed to computePathways() ONLY if set,
#'                           otherwise the package's own defaults apply
#'
#' Outputs (data/analyses/<RUN_ID>/treatment-patterns/<STUDY>/):
#'   CSV files from TreatmentPatterns::export(), sunburst.html and sankey.html
#'   (if the plotting packages work), and provenance.json.
#'
#' Usage:
#'   docker compose --profile analytics run --rm -e STUDY=mhd-treatments \
#'     analytics Rscript /app/run_treatment_patterns.R
#'
#' @see https://darwin-eu.github.io/TreatmentPatterns/

source("/app/R/common.R")

suppressPackageStartupMessages(library(TreatmentPatterns))

study <- load_study()
cfg   <- analytics_config()
tool  <- "treatment-patterns"

# --- Which cohorts play which role -----------------------------------------
target_id <- env_int("TP_TARGET_COHORT_ID")
event_ids <- env_int_list("TP_EVENT_COHORT_IDS")
exit_ids  <- env_int_list("TP_EXIT_COHORT_IDS")
if (!length(event_ids)) stop("TP_EVENT_COHORT_IDS must list at least one event cohort.", call. = FALSE)

overlap <- intersect(c(target_id), c(event_ids, exit_ids))
if (length(overlap)) stop("A cohort can't be both target and event/exit: ", paste(overlap, collapse = ", "), call. = FALSE)

# --- Check the cohorts exist and were generated; get their ATLAS names -----
con  <- dbi_connection()
info <- tryCatch(atlas_cohorts(con, c(target_id, event_ids, exit_ids)),
                 finally = DBI::dbDisconnect(con))

# TreatmentPatterns' cohort table: cohortId, cohortName, type.
role <- function(id) if (id == target_id) "target" else if (id %in% exit_ids) "exit" else "event"
cohorts <- data.frame(
  cohortId   = info$cohort_id,
  cohortName = info$cohort_name,
  type       = vapply(info$cohort_id, role, character(1)),
  stringsAsFactors = FALSE
)

# --- Optional pathway settings: pass ONLY the ones the study sets ----------
# This avoids hard-coding defaults here that might differ from the package's.
optional_settings <- list(
  minEraDuration             = "TP_MIN_ERA_DURATION",
  combinationWindow          = "TP_COMBINATION_WINDOW",
  minPostCombinationDuration = "TP_MIN_POST_COMBINATION_DURATION"
)
settings <- list()
for (arg in names(optional_settings)) {
  value <- Sys.getenv(optional_settings[[arg]])
  if (nzchar(value)) settings[[arg]] <- as.integer(value)
}

# --- Compute ---------------------------------------------------------------
# DatabaseConnector route: TreatmentPatterns reads <resultSchema>.<cohortTableName>,
# which is exactly where ATLAS writes generated cohorts (results.cohort).
started <- Sys.time()
andromeda <- do.call(TreatmentPatterns::computePathways, c(
  list(
    cohorts           = cohorts,
    cohortTableName   = "cohort",
    connectionDetails = jdbc_connection_details(),
    cdmSchema         = cfg$cdm_schema,
    resultSchema      = cfg$results_schema
  ),
  settings
))

# --- Export: CSVs + an R6 results object -----------------------------------
out <- output_dir(cfg, tool, study)
min_cell <- as.integer(env_or("TP_MIN_CELL_COUNT", "5"))
results <- TreatmentPatterns::export(
  andromeda    = andromeda,
  outputPath   = out,
  minCellCount = min_cell,
  nonePaths    = TRUE      # also count people with NO treatment path; often the largest group
)

# --- Interactive plots (best effort) ----------------------------------------
# selfcontained = FALSE: a self-contained HTML file needs pandoc, which this
# image doesn't have. The plot then comes as an .html file plus a *_files folder.
save_plot <- function(make_plot, file) {
  tryCatch({
    htmlwidgets::saveWidget(make_plot(), file.path(out, file), selfcontained = FALSE)
    message(sprintf("[plot] %s", file.path(out, file)))
  }, error = function(e) {
    message(sprintf("[plot] skipped %s: %s (the CSVs are still complete)", file, conditionMessage(e)))
  })
}
save_plot(function() results$plotSunburst(), "sunburst.html")
save_plot(function() results$plotSankey(),   "sankey.html")

write_provenance(
  path     = out,
  tool     = tool,
  study    = study,
  cohorts  = cohorts,
  settings = c(settings, list(minCellCount = min_cell, nonePaths = TRUE)),
  packages = c("TreatmentPatterns", "DatabaseConnector")
)

message(sprintf("[done] %s in %.1f minutes → %s", tool,
                as.numeric(difftime(Sys.time(), started, units = "mins")), out))
```

### 10f. Run CohortContrast

```bash
docker compose --profile analytics run --rm -e STUDY=mhd-sud-vs-mhd \
  analytics Rscript /app/run_cohort_contrast.R
```

Output in `data/analyses/<RUN_ID>/cohort-contrast/mhd-sud-vs-mhd/`: CohortContrast's study
folder (parquet files, `metadata.json`) and `provenance.json`.

Leave `CC_CONTROL_COHORT_ID` empty and CohortContrast builds **matched** controls instead
(`CC_MATCH_RATIO` per target person).

#### `services/analytics/run_cohort_contrast.R`

```r
#' run_cohort_contrast.R: concept enrichment, target vs control (Step 10f)
#'
#' Question it answers: which concepts (drugs, conditions, measurements …) are
#' over-represented in the TARGET cohort compared with a CONTROL cohort?
#'
#' Inputs, from a study file (services/analytics/studies/<STUDY>.env):
#'   CC_TARGET_COHORT_ID    one ATLAS cohort (generated)
#'   CC_CONTROL_COHORT_ID   optional ATLAS cohort; if empty, CohortContrast builds
#'                          MATCHED controls (CC_MATCH_RATIO per target person)
#'   CC_MATCH_RATIO         optional, default 4
#'   CC_DOMAINS             optional, comma-separated; default all eight domains
#'   CC_PREVALENCE_CUTOFF   optional, default 2.5 (the package docs' example value)
#'   CC_PRESENCE_FILTER     optional, default 0.2 (same)
#'   CC_NUM_CORES           optional, default 1 (predictable in a container)
#'
#' Outputs (data/analyses/<RUN_ID>/cohort-contrast/<STUDY>/):
#'   the CohortContrast study folder (parquet files + metadata.json) and
#'   provenance.json. Explore it with the viewer (Step 10g).
#'
#' Usage:
#'   docker compose --profile analytics run --rm -e STUDY=mhd-sud-vs-mhd \
#'     analytics Rscript /app/run_cohort_contrast.R
#'
#' @see https://healthinformaticsut.github.io/CohortContrast/

source("/app/R/common.R")

suppressPackageStartupMessages({
  library(CDMConnector)
  library(CohortContrast)
})

study <- load_study()
cfg   <- analytics_config()
tool  <- "cohort-contrast"

target_id  <- env_int("CC_TARGET_COHORT_ID")
control_id <- env_int_list("CC_CONTROL_COHORT_ID")   # 0 or 1 values
if (length(control_id) > 1) stop("CC_CONTROL_COHORT_ID takes at most one cohort.", call. = FALSE)

domains <- strsplit(env_or("CC_DOMAINS",
  "Drug,Condition,Measurement,Observation,Procedure,Visit,Visit detail,Death"), ",", fixed = TRUE)[[1]]
domains <- trimws(domains)

db <- dbi_connection()
on.exit(DBI::dbDisconnect(db), add = TRUE)

info <- atlas_cohorts(db, c(target_id, control_id))

# --- CDM reference -----------------------------------------------------------
# writeSchema: CohortContrast's docs describe it as a schema for temporary
# tables that "will be deleted". So it gets its OWN throwaway schema
# (analytics_scratch), never WebAPI's temp schema. The prefix keeps tables
# identifiable if a run is interrupted.
cdm <- CDMConnector::cdmFromCon(
  con            = db,
  cdmSchema      = cfg$cdm_schema,
  achillesSchema = cfg$results_schema,
  writeSchema    = c(schema = cfg$scratch_schema, prefix = "cc_")
)

# --- Target and control --------------------------------------------------------
target_table <- CohortContrast::cohortFromCohortTable(
  cdm = cdm, db = db, tableName = "cohort",
  schemaName = cfg$results_schema, cohortId = target_id)

if (length(control_id)) {
  control_table <- CohortContrast::cohortFromCohortTable(
    cdm = cdm, db = db, tableName = "cohort",
    schemaName = cfg$results_schema, cohortId = control_id)
  control_desc <- sprintf("ATLAS cohort %d", control_id)
} else {
  ratio <- as.integer(env_or("CC_MATCH_RATIO", "4"))
  control_table <- CohortContrast::createControlCohortMatching(
    cdm = cdm, targetTable = target_table, ratio = ratio)
  control_desc <- sprintf("matched controls, ratio %d", ratio)
}
message(sprintf("[control] %s", control_desc))

# --- Run -------------------------------------------------------------------
# pathToResults is the PARENT folder; complName is the study folder inside it,
# which CohortContrast creates itself (so we only create the parent).
parent <- ensure_dir(file.path(cfg$output_root, tool))
settings <- list(
  domainsIncluded   = domains,
  prevalenceCutOff  = as.numeric(env_or("CC_PREVALENCE_CUTOFF", "2.5")),
  topK              = FALSE,
  presenceFilter    = as.numeric(env_or("CC_PRESENCE_FILTER", "0.2")),
  getSourceData     = FALSE,
  runChi2YTests     = TRUE,
  runLogitTests     = FALSE,
  createOutputFiles = TRUE,
  numCores          = as.integer(env_or("CC_NUM_CORES", "1"))
)

started <- Sys.time()
data <- do.call(CohortContrast::CohortContrast, c(
  list(
    cdm                       = cdm,
    targetTable               = target_table,
    controlTable              = control_table,
    pathToResults             = parent,
    complementaryMappingTable = NULL,
    complName                 = study
  ),
  settings
))

out <- file.path(parent, study)
write_provenance(
  path     = out,
  tool     = tool,
  study    = study,
  cohorts  = info,
  settings = c(settings, list(control = control_desc)),
  packages = c("CohortContrast", "CDMConnector")
)

message(sprintf("[done] %s in %.1f minutes → %s", tool,
                as.numeric(difftime(Sys.time(), started, units = "mins")), out))
```

### 10g. The CohortContrast viewer (to finish after the first run)

CohortContrast's results viewer uses **Python** helpers (`configurePython()`,
`installPythonDeps()`, `runCohortContrastViewer()`). The image includes Python, but the viewer's
exact arguments (data folder, host, port) aren't in the documentation pages available so far.
So this step starts with discovery, in the image you just built:

```bash
docker compose --profile analytics run --rm analytics Rscript -e \
  "print(args(CohortContrast::runCohortContrastViewer)); print(args(CohortContrast::installPythonDeps))"
```

Then we add a viewer service like `atlas-proxy`: bound to `127.0.0.1` only, with the Python
dependencies installed into a persistent folder rather than the container's throwaway `/tmp`.

### 10h. Shared helpers

#### `services/analytics/R/common.R`

```r
#' common.R: shared helpers for every analytics script (Step 10)
#'
#' Each run_<tool>.R script does source("/app/R/common.R") first, so the
#' configuration, connection and safety-check logic lives in ONE place (DRY).
#'
#' Connection model
#'   All analyses connect as the least-privilege role ohdsi_app (Step 9b):
#'   it can READ cdm and results.cohort, WRITE results, and owns the scratch
#'   schema. It cannot change clinical data, so a bug in an analysis package
#'   can't damage the CDM.
#'
#' Environment (set on the analytics service in compose.yaml):
#'   RUN_ID                          which load we're analysing (output folder)
#'   DB_HOST, DB_NAME, DB_PORT       for DBI/RPostgres (CDMConnector)
#'   DB_SERVER                       "host/dbname" form for DatabaseConnector
#'   DB_USER, DB_PASSWORD            ohdsi_app credentials
#'   STUDY                           name of a file in /app/studies/<STUDY>.env
#'
#' @see services/analytics/studies/README.md for the study-file format

# ---------------------------------------------------------------------------
# Small environment helpers
# ---------------------------------------------------------------------------

#' Read a required environment variable, failing with a clear message.
#' @param name  Variable name.
#' @return character(1)
env_required <- function(name) {
  value <- Sys.getenv(name)
  if (!nzchar(value)) {
    stop(sprintf("Environment variable %s is required but empty. See README Step 10.", name),
         call. = FALSE)
  }
  value
}

#' Read an optional environment variable with a default.
#' @param name     Variable name.
#' @param default  Returned when unset or empty.
#' @return character(1)
env_or <- function(name, default) {
  value <- Sys.getenv(name)
  if (nzchar(value)) value else default
}

#' Read a comma-separated list of integers, e.g. "3, 4,5" -> c(3L, 4L, 5L).
#' Empty -> integer(0). Anything that isn't an integer is an error, not a silent NA.
#' @param name  Variable name.
#' @return integer vector
env_int_list <- function(name) {
  raw <- gsub("\\s", "", Sys.getenv(name))
  if (!nzchar(raw)) return(integer(0))
  parts <- strsplit(raw, ",", fixed = TRUE)[[1]]
  if (!all(grepl("^[0-9]+$", parts))) {
    stop(sprintf("%s must be comma-separated integers, got '%s'.", name, raw), call. = FALSE)
  }
  as.integer(parts)
}

#' Read exactly one integer.
#' @param name  Variable name.
#' @return integer(1)
env_int <- function(name) {
  values <- env_int_list(name)
  if (length(values) != 1) stop(sprintf("%s must be exactly one integer.", name), call. = FALSE)
  values
}

# ---------------------------------------------------------------------------
# Study files and configuration
# ---------------------------------------------------------------------------

#' Load /app/studies/<STUDY>.env into the environment.
#' Study files hold cohort IDs and settings, so every analysis is a reviewable,
#' version-controlled file rather than a command someone typed once.
#' @return character(1) the study name
load_study <- function() {
  study <- env_required("STUDY")
  if (!grepl("^[A-Za-z0-9_-]+$", study)) {
    stop("STUDY may only contain letters, digits, _ and - (it's a file name).", call. = FALSE)
  }
  path <- file.path("/app/studies", paste0(study, ".env"))
  if (!file.exists(path)) stop(sprintf("Study file not found: %s", path), call. = FALSE)
  readRenviron(path)
  message(sprintf("[study] loaded %s", path))
  study
}

#' Fixed schema layout of this project, plus the run's output root.
#' @return list
analytics_config <- function() {
  run_id <- env_required("RUN_ID")
  list(
    run_id         = run_id,
    cdm_schema     = "cdm",                # CDM tables AND vocabulary
    results_schema = "results",            # ATLAS writes generated cohorts to results.cohort
    scratch_schema = "analytics_scratch",  # owned by ohdsi_app; safe to empty (Step 10b)
    output_root    = file.path("/data/analyses", run_id)
  )
}

#' Create (recursively) and return an output folder for one tool and study.
#' Recursive on purpose: Achilles crashed because a parent folder was missing.
#' @param cfg    From analytics_config().
#' @param tool   e.g. "treatment-patterns".
#' @param study  Study name.
#' @return character(1) absolute path
output_dir <- function(cfg, tool, study) {
  ensure_dir(file.path(cfg$output_root, tool, study))
}

#' Create a folder (and any missing parents) and confirm it exists.
#' @param path  Folder to create.
#' @return character(1) the same path
ensure_dir <- function(path) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(path)) stop(sprintf("Could not create %s (check data/analyses ownership).", path), call. = FALSE)
  path
}

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------

#' DatabaseConnector (JDBC) details, as used by TreatmentPatterns and ETL-Synthea.
#' @return connectionDetails
jdbc_connection_details <- function() {
  DatabaseConnector::createConnectionDetails(
    dbms         = "postgresql",
    server       = env_required("DB_SERVER"),
    port         = as.integer(env_or("DB_PORT", "5432")),
    user         = env_required("DB_USER"),
    password     = env_required("DB_PASSWORD"),
    pathToDriver = env_or("DATABASECONNECTOR_JAR_FOLDER", "/opt/jdbc")
  )
}

#' DBI connection (RPostgres), as used by CDMConnector and CohortContrast.
#' @return DBIConnection; the caller must DBI::dbDisconnect() it.
dbi_connection <- function() {
  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = env_required("DB_HOST"),
    dbname   = env_required("DB_NAME"),
    port     = as.integer(env_or("DB_PORT", "5432")),
    user     = env_required("DB_USER"),
    password = env_required("DB_PASSWORD")
  )
}

# ---------------------------------------------------------------------------
# ATLAS cohorts: names and "was it generated?" check
# ---------------------------------------------------------------------------

#' Look up ATLAS cohort names, and refuse to continue if any cohort is unknown
#' or has never been generated on this database.
#'
#' Why: every tool here reads results.cohort. A cohort that exists in ATLAS but
#' was never generated has ZERO rows, and most tools then produce empty (or
#' misleading) output instead of an error. Better to stop here, loudly.
#'
#' @param con  DBI connection.
#' @param ids  Integer cohort definition IDs (from the ATLAS URL).
#' @return data.frame(cohort_id, cohort_name, persons)
atlas_cohorts <- function(con, ids) {
  ids <- unique(as.integer(ids))
  if (!length(ids) || anyNA(ids)) stop("No valid cohort IDs given.", call. = FALSE)

  # IDs are validated integers, so inlining them is safe from SQL injection.
  id_list <- paste(ids, collapse = ", ")
  info <- DBI::dbGetQuery(con, sprintf("
    SELECT cd.id   AS cohort_id,
           cd.name AS cohort_name,
           (SELECT COUNT(DISTINCT c.subject_id)
              FROM results.cohort c
             WHERE c.cohort_definition_id = cd.id) AS persons
      FROM webapi.cohort_definition cd
     WHERE cd.id IN (%s)
     ORDER BY cd.id", id_list))

  unknown <- setdiff(ids, info$cohort_id)
  if (length(unknown)) {
    stop(sprintf("Cohort ID(s) not found in ATLAS: %s", paste(unknown, collapse = ", ")), call. = FALSE)
  }
  empty <- info$cohort_id[info$persons == 0]
  if (length(empty)) {
    stop(sprintf(paste("Cohort ID(s) %s have no rows in results.cohort.",
                       "Generate them on SYNTH_OMOP in ATLAS first."),
                 paste(empty, collapse = ", ")), call. = FALSE)
  }

  message("[cohorts]")
  for (i in seq_len(nrow(info))) {
    message(sprintf("  %4d  %-50s %6d persons", info$cohort_id[i], info$cohort_name[i], info$persons[i]))
  }
  info
}

# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------

#' Write provenance.json next to the results: what ran, on what, with which
#' versions and settings. The analysis equivalent of a run-log entry.
#' @param path      Output folder.
#' @param tool      Tool name.
#' @param study     Study name.
#' @param cohorts   data.frame from atlas_cohorts().
#' @param settings  Named list of the settings actually used.
#' @param packages  Character vector of package names to record versions for.
write_provenance <- function(path, tool, study, cohorts, settings, packages) {
  cfg <- analytics_config()
  versions <- vapply(packages, function(p) as.character(utils::packageVersion(p)), character(1))
  jsonlite::write_json(
    list(
      tool      = tool,
      study     = study,
      run_id    = cfg$run_id,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      r_version = as.character(getRversion()),
      packages  = as.list(versions),
      cohorts   = cohorts,
      settings  = settings
    ),
    file.path(path, "provenance.json"),
    auto_unbox = TRUE, pretty = TRUE
  )
  message(sprintf("[provenance] %s", file.path(path, "provenance.json")))
}
```

---

## QA checklist

### For the engineer running the pipeline (admin)

- [ ] `.env` created from `.env.example`; password is not the default; `.env` is not tracked by git
- [ ] `omop-db` shows **healthy**; `\dn` lists `synthea`, `cdm`, `results`
- [ ] NSDUH variable names in `config.json` checked against the **2024** codebook
- [ ] Calibration log shows the % of rows dropped as unknown, and it's recorded in `run-log.md`
- [ ] Every stratum in `joint_probabilities.json` sums to 1.0 (±0.000001)
- [ ] Module probabilities generated from JSON, not hand-typed
- [ ] New `RUN_ID`; `COMMAND.txt` present in the output folder
- [ ] `run-log.md` row complete: versions, seed, hashes, vocab release
- [ ] Athena bundle includes **CVX** and **Cancer Modifier** (`cut -f1 data/vocab/athena/VOCABULARY.csv | sort`); only the 10 vocabulary CSVs are in `data/vocab/athena/`
- [ ] ETL finished without errors; `cdm.cdm_source` row describes the run
- [ ] Step 7a counts reconcile (`person` = patients, `death` = deceased after the 7b patch, per-code immunizations query empty after the 7c patch)
- [ ] Unmapped-codes worklist (7a query 4) reviewed; new retired codes added to `docs/assumptions.md`
- [ ] ETL-Synthea commit SHA pinned and recorded; database backed up to `backups/`
- [ ] DQD failure rate reviewed; known failures documented
- [ ] `validate_joint.sql` results attached to the run-log row
- [ ] Same run repeated with the same seed produces identical CSV hashes

**If you run Atlas (Step 9):**

- [ ] `OHDSI_APP_PASSWORD` generated (`openssl rand -hex 24`), not the example value; `01_roles_and_schemas.sql` finished without errors
- [ ] `/WebAPI/info` reports `2.15.1`; Atlas and WebAPI on the same minor version
- [ ] Source `SYNTH_OMOP` has 4 daimons: cdm / cdm / results / temp
- [ ] Results DDL saved in `data/atlas/` and applied once
- [ ] Achilles rerun after **every** ETL load, then WebAPI restarted
- [ ] Smoke-test cohort count reconciles with the SQL count (9f)
- [ ] Ports bound to `127.0.0.1` only (security is disabled in this setup)

**If you run analyses (Step 10):**

- [ ] The analytics image builds, and the package check prints TreatmentPatterns, CohortContrast and CDMConnector versions
- [ ] Every cohort in a study file is **generated** on `SYNTH_OMOP` (the scripts stop otherwise)
- [ ] Study files are committed; results under `data/analyses/` are not
- [ ] Each result folder has a `provenance.json`; the run is noted in `docs/run-log.md`
- [ ] Any lowered `TP_MIN_CELL_COUNT` is synthetic-only, and noted in the study file

### For the analyst using the database (non-admin)

- [ ] I've read `cdm.cdm_source.source_description` and `docs/assumptions.md`
- [ ] I understand MHD/SUD come from **survey definitions**, and that specific diagnosis codes are **assumptions**
- [ ] I'm using this for testing, cohort development, education, or methods work, **not** effect estimates
- [ ] I know which `RUN_ID` my analysis used, and I've cited it
- [ ] In Atlas, I've checked which run the `SYNTH_OMOP` source currently holds (Data Sources dashboard, or `cdm.cdm_source`)
- [ ] I export cohort definitions I want to keep as JSON. This Atlas has no logins, and a database reset deletes everything in it

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `FATAL: role "root" does not exist` | `$OMOP_DB_USER` is empty in your host shell, because `.env` is only read by Compose | Use the `sh -c '… $POSTGRES_USER …'` form from Step 2, or `set -a; . ./.env; set +a` |
| `mkdir: Permission denied` (synthea, calibration or etl) | The container's user UID ≠ the owner of the bind-mounted `./data/...` folder. `sudo docker …` doesn't help, because it doesn't change the user *inside* the container | Set `LOCAL_UID`/`LOCAL_GID` in `.env` (from `id -u` / `id -g`), then `sudo chown -R "$(id -u):$(id -g)" data` |
| `Error: Unable to access jarfile /synthea/synthea.jar` | Remote `ADD` saved the jar as `600 root:root`, so the non-root container user can't read it | Use `ADD --chmod=0644 …` in the Synthea Dockerfile, then `docker compose --profile generate build --no-cache synthea` |
| `Output … already exists. Choose a new RUN_ID.` | A previous (possibly failed) run left its folder | Delete `data/synthea-output/<RUN_ID>` or bump `RUN_ID` in `.env` |
| Synthea: `Expected BEGIN_ARRAY but was STRING at path $.remarks` | A `remarks` field in your module is a string | Make every `remarks` (module and state level) an array: `"remarks": ["…"]` |
| `initdb` schemas missing | Volume already existed, so init scripts were skipped | `docker compose down -v` (deletes data) and start again |
| ETL: `Java heap space` | Large vocabulary load | Add `ENV _JAVA_OPTIONS=-Xmx4g` to the ETL Dockerfile |
| ETL: column mismatch in `LoadSyntheaTables` | `synthea_version` in `run_etl.R` ≠ the jar that produced the CSVs | Make them match (3.3.0) |
| Many `condition_concept_id = 0` | Vocabulary bundle missing SNOMED, or a custom code has no mapping | Re-download with SNOMED; map custom codes with Usagi (<https://ohdsi.github.io/Usagi/>) and have someone review them |
| Joint proportions skewed high | Built-in Synthea modules adding the same disorders | Filter modules with `-m`, or exclude them in validation |
| Nobody in the "both" cell | Guard `year` is later than the simulation end date | Line the Guard up with the run's end date (A-001) |
| Port 5432 in use | Local Postgres already running | Set `OMOP_DB_PORT=5433` in `.env` |
| Immunizations missing from `drug_exposure`, yet "0 unmapped" | CVX isn't in the vocabulary bundle, so the ETL drops immunizations instead of mapping them to `0` | Add **CVX** in Athena (Step 3b), reload, then rerun the 7a reconciliation queries |
| A few immunization codes still missing *with* CVX loaded | Single-digit codes (`3` vs `03`) or codes that map outside CVX (e.g. COVID `207`/`208`) | Step 7c: run `patch_missing_immunizations.sql` |
| `cdm.death` has fewer rows than deceased patients | `insert_death.sql` inner-joins the cause and keeps only Condition-domain causes: it drops deaths with no death-cert encounter, an unmapped cause, or a cause mapping to another domain | Step 7b: diagnose, then run `patch_missing_deaths.sql` |
| Atlas Person report shows a **"No matching concept"** slice under Race | ETL-Synthea maps only `white`/`black`/`asian`; `native`, `hawaiian` and `other` get `race_concept_id = 0` | Expected for now (A-009). `SELECT race_source_value, race_concept_id, COUNT(*) FROM cdm.person GROUP BY 1, 2;`. After review: `patch_race_concepts.sql`, then rerun Achilles and restart WebAPI |
| A concept has `Maps to value` but no `Maps to` | Its `Maps to` target is in a vocabulary you didn't download (e.g. Cancer Modifier) | Check the concept on athena.ohdsi.org; add that vocabulary to the bundle and reload |
| Common Synthea codes map to `0` | Synthea uses some SNOMED codes **retired** after it was written (`invalid_reason = 'D'`) | Expected. List them with 7a query 4 and record each in `docs/assumptions.md`; any mapping is a terminology-review decision |
| `LoadVocabFromCsv` warns "Found and resolved improper quoting … `"y set" tubing`" | One HCPCS concept name (`A4719`, concept 2614984) starts with a double quote; `fread` detects and heals it | Harmless. Confirm with `wc -l CONCEPT.csv` (minus header) = `SELECT COUNT(*) FROM cdm.concept` |
| `LoadVocabFromCsv` warns "`type_convert()` only converts columns of type 'character'" | A small table with no text columns | Harmless; ignore |
| `LoadVocabFromCsv` errors on unexpected files | Zip, jar, `CONCEPT_CPT4.csv` or `*_METADATA.csv` left in `data/vocab/athena/` | Move them to `athena-extras/` (Step 3b) |
| Atlas: "Unable to connect to an instance of the WebAPI" | WebAPI is still running Flyway on first start, or `WEBAPI_URL` isn't reachable *from the browser* | Wait for `curl http://localhost:8080/WebAPI/info`; `WEBAPI_URL` must use `localhost` and end in `/WebAPI/`; hard-refresh the page |
| WebAPI log: `password authentication failed for user "ohdsi_app"` | `omop-db` wasn't recreated after adding the variable, or 01 hasn't run since the password changed | `docker compose up -d omop-db`, rerun 01 (and 02), then `docker compose --profile atlas restart webapi` |
| Flyway: `Found non-empty schema(s) "webapi" without schema history table` | Something else created tables in `webapi` | If nothing in it is worth keeping: `DROP SCHEMA webapi CASCADE;`, rerun 01, restart WebAPI |
| `01_roles_and_schemas.sql` says the password is **0 characters**, even after `up -d` | Compose isn't passing the variable to `omop-db`: `.env` lacks it, or your `compose.yaml` lacks `OHDSI_APP_PASSWORD: ${OHDSI_APP_PASSWORD:-}` under `omop-db` → `environment:`. The `:-` default turns a missing value into a silent empty string | `docker compose config \| grep OHDSI_APP_PASSWORD` must show a value; fix `.env` or `compose.yaml`, then `docker compose up -d omop-db` (should say **Recreated**) |
| `01_roles_and_schemas.sql` stops with "not URL-safe" | The password has characters that would break the JDBC URL | Use `openssl rand -hex 24` |
| `http://localhost:8080/atlas/` returns 404 | This Atlas image version serves from `/` instead of `/atlas/` | In `nginx.conf`, change to `proxy_pass http://atlas:8080/;` (the trailing slash strips the prefix), then `docker compose --profile atlas restart atlas-proxy` |
| `SYNTH_OMOP` missing in Atlas after 9c | WebAPI caches sources at startup | `docker compose --profile atlas restart webapi`, or Atlas **Configuration** → *Clear Configuration Cache* |
| `Error in library(Achilles) : there is no package called 'Achilles'` after a "successful" build | `R -e "install..."` exits 0 even when the install fails, so the image built without it | Use the Dockerfile's `requireNamespace()` check; rebuild with `--progress=plain` and read the real error |
| Data Sources shows **"Error loading report"** (Person, Procedure …), or is empty; search shows no RC/DRC counts | Achilles hasn't run (`results.achilles_*` missing), or hasn't run since the last load. The static `/atlas/…` requests in DevTools are fine (304 = cached); the failing one is a `/WebAPI/cdmresults/…` call returning 500 | Check `SELECT to_regclass('results.achilles_results');` (null = never ran). Run Step 9e, restart WebAPI, hard-refresh. Still failing? Read `docker compose --profile atlas logs webapi` |
| Cohort generation fails: `permission denied for schema results` / `temp` | Grants missing (e.g. after a `down -v` and reload) | Rerun 01; it's idempotent |
| Results DDL rerun: `relation … already exists` | The DDL is meant to run once | Harmless; skip it |
| Step 10 script: `Cohort ID(s) … have no rows in results.cohort` | The cohort exists in ATLAS but wasn't generated (or was generated before a reload) | ATLAS → the cohort → **Generation** tab → Generate on `SYNTH_OMOP`; rerun |
| Step 10 script: `Cohort ID(s) not found in ATLAS` | Wrong ID in the study file, or ATLAS was reset (`down -v` restarts IDs) | Check the number in the cohort's ATLAS URL; update the study file |
| Step 10 script: `Study file not found` | `STUDY` doesn't match a file in `services/analytics/studies/` | `-e STUDY=name` without `.env`; letters, digits, `_` and `-` only |
| Step 10: `Could not create /data/analyses/…` | `data/analyses` missing, or owned by root | `mkdir -p data/analyses` as yourself (Step 10b) |
| Analytics build fails with `CANNOT LOAD <pkg>: …` (log still says `DONE (<pkg>)`) | The binary **installed** but a **system library** it links to is missing (e.g. networkD3 → igraph → `libglpk`) | The message names the missing `.so` file; add its `-dev` package to the Dockerfile's `apt-get` line and rebuild |
| TreatmentPatterns: `sunburst.html` skipped | A plotting package failed | The CSVs are still complete; the error message names the cause |
| Port 8080 already in use | Another local service | Set `ATLAS_PORT=8090` in `.env`; `WEBAPI_URL` and `SECURITY_ORIGIN` follow it automatically. Use the new port in the `curl` commands |

---

## Security and usability suggestions

- **Secrets.** Move `OMOP_DB_PASSWORD` to Docker Compose `secrets:` (a file-based secret) once more than one person uses this. Postgres images support `POSTGRES_PASSWORD_FILE`.
- **Least privilege.** Done for Atlas: WebAPI runs as `ohdsi_app`, which can only read `cdm` (Step 9b). Still to do: a read-only `omop_reader` role for analysts' direct SQL, keeping `omop_admin` for the ETL only.
- **Atlas has no login in this setup** (`SECURITY_PROVIDER: DisabledSecurity`). That's acceptable for synthetic data on `127.0.0.1`, and not acceptable for anything shared or containing real data. Before others use it, move to Broadsea (9g) with a security provider and HTTPS.
- **The `ohdsi_app` password is stored in plain text** in `webapi.source.source_connection`, because that's how WebAPI 2.x connects to sources. It's one more reason that role can't write clinical data. Rotate it by changing `.env`, then rerunning 01 and 02.
- **Pin everything.** Pin image digests (`postgres:16@sha256:…`), the ETL-Synthea commit SHA, and the Broadsea tag. "Latest" makes reproducibility impossible.
- **Localhost binding** is already set. Keep it unless there's a reviewed need to change it.
- **DRY.** The age bands appear in `config.json`, the module and `validate_joint.sql`. Make `config.json` the single source and render the other two from it.
- **Accessibility of outputs.** In validation reports, label tables with real headers, never encode meaning by colour alone, and write the plain-language takeaway first ("the 'both' group is within 1 percentage point of target in all strata"). Non-technical reviewers will thank you.

---

## Further learning

Lessons and lectures can be found in the [`lessons/`](lessons/) folder, complete with lectures, lab work, and self-check questions to learn more:

| Lesson | Covers |
|---|---|
| [001: The Pipeline from the Inside](lessons/001_pipeline-from-the-inside.md) | Containers, Compose networking, volumes, schemas, ETL, OMOP vocabularies |
| [002: Calibration](lessons/002_calibration.md) | Survey weights, joint vs marginal probability, strata, sparse cells, sampling noise |
| [003: OMOP Concepts](lessons/003_omop-concepts.md) | Concepts, standard vs non-standard, domains, `Maps to`, hierarchies, deprecation, `concept_id = 0` |
| [004: Pipeline Deep Dive](lessons/004_pipeline-deep-dive.md) | NSDUH design and limits (AMI as a model), Synthea modules, Athena bundles, ETL-Synthea stages and filters, provenance |
| [005: Where Did 18 Deaths Go?](lessons/005_where-did-18-deaths-go.md) | Case study: reconciling counts through the ETL, six failure modes, responsible patching, writing it up |
| [006: Introduction to ATLAS](lessons/006_intro-to-atlas.md) | What ATLAS is for, its three parts, concept sets, cohorts and eras, a tour of the menu, pre-computed vs on-demand results |
| [007: ATLAS Deep Dive](lessons/007_atlas-deep-dive.md) | Cohort logic (entry, inclusion, exit, eras), attrition reports, JSON → SQL via Circe, characterization, incidence, pathways, phenotype evaluation |
| [008: Our ATLAS Setup and the UI](lessons/008_our-atlas-setup-and-the-ui.md) | Our stack end to end, WebAPI's two database jobs, following a click to a table, caches, real setup failures by layer, backups |
| [009: From Synthea to the CDM, the ETL Internals](lessons/009_synthea-to-cdm-internals.md) | 2nd–3rd year: data contracts, staging, surrogate keys, visit roll-up and eras as gaps-and-islands, domain routing, idempotency/atomicity, ETL testing; labs rebuild parts of the ETL by hand |
| [010: Athena and the Standardized Vocabularies](lessons/010_athena-and-the-vocabularies.md) | 2nd–3rd year: how the vocabularies are built and released (Feb/Aug; old releases not downloadable), the data model, standard concepts, mapping patterns, `concept_ancestor` as a transitive closure, upgrades, licensing, local 2-billion concepts; labs include a vocabulary audit of our own Synthea codes |
| [011: Cohort Analytics](lessons/011_cohort-analytics.md) | 2nd–3rd year: characterization vs estimation vs prediction, cohorts as the interface between tools, 2×2 tables (RR, OR, φ), multiple testing, CohortContrast enrichment, the TreatmentPatterns algorithm step by step, Comorbidity4j and its biases, responsible reporting |

Further reading:

- **The Book of OHDSI.** Free, and the clearest explanation of the CDM, vocabularies and ETL: <https://ohdsi.github.io/TheBookOfOhdsi/>
- **EHDEN Academy.** Free OMOP/ETL courses: <https://academy.ehden.eu/>
- **Synthea wiki.** Start with the Generic Module Framework pages: <https://github.com/synthetichealth/synthea/wiki>
- **OHDSI Forums**, especially the *Implementers* and *Developers* categories: <https://forums.ohdsi.org/>
- **NSDUH Data Users' Guide.** Read the weighting and variance sections before any uncertainty work.
- **Survey statistics.** Lumley, *Complex Surveys: A Guide to Analysis Using R* (the `survey` package author), for when you add confidence intervals.

### Reference links

- NSDUH data files: <https://www.samhsa.gov/data/data-we-collect/nsduh-national-survey-drug-use-and-health/datafiles>
- SAMHSA online analysis: <https://datatools.samhsa.gov/>
- Synthea: <https://github.com/synthetichealth/synthea> · Module builder: <https://synthetichealth.github.io/module-builder/>
- Keep Patients module: <https://github.com/synthetichealth/synthea/wiki/Keep-Patients-Module>
- OMOP CDM 5.4: <https://ohdsi.github.io/CommonDataModel/cdm54.html>
- Athena: <https://athena.ohdsi.org/> · Usagi: <https://ohdsi.github.io/Usagi/>
- ETL-Synthea: <https://github.com/OHDSI/ETL-Synthea> · docs: <https://ohdsi.github.io/ETL-Synthea/>
- Data Quality Dashboard: <https://ohdsi.github.io/DataQualityDashboard/>
- Broadsea: <https://github.com/OHDSI/Broadsea>
- WebAPI: <https://github.com/OHDSI/WebAPI> · CDM configuration (sources, daimons, results DDL): <https://github.com/OHDSI/WebAPI/wiki/CDM-Configuration>
- Atlas: <https://github.com/OHDSI/Atlas> · wiki: <https://github.com/OHDSI/Atlas/wiki>
- Achilles: <https://ohdsi.github.io/Achilles/>
- Atlas 3.0 preview (July 2026): <https://www.ohdsi.org/wp-content/uploads/2026/07/ATLAS-3.0-Preview.pdf>
