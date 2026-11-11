# Synthetic Concurrent-Disorders Data in OMOP CDM 5.4

**A step-by-step setup guide: NSDUH → Synthea → ETL-Synthea → PostgreSQL (OMOP), run locally with Docker Compose**

| | |
|---|---|
| **Status** | **Pilot run end to end** (`pilot-0001`, 2026-11-11): Synthea → ETL-Synthea → OMOP 5.4 loaded and checked. Calibration still uses **placeholder** probabilities; real NSDUH estimates are the next milestone. |
| **Audience** | Engineers who build the pipeline (admin) and analysts who use the resulting database (non-admin) |
| **Pinned versions** | Synthea `v3.3.0`, OMOP CDM `5.4`, ETL-Synthea (`OHDSI/ETL-Synthea`, pinned to a commit), PostgreSQL `16`, Athena vocabulary `v5.0 29-AUG-26` |
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
    - [7c. Pin, record, back up](#7c-pin-record-back-up)
11. [Step 8: Validate](#step-8-validate)
12. [Step 9 (optional): Atlas via OHDSI Broadsea](#step-9-optional-atlas-via-ohdsi-broadsea)
13. [QA checklist](#qa-checklist)
14. [Troubleshooting](#troubleshooting)
15. [Security and usability suggestions](#security-and-usability-suggestions)
16. [Further learning](#further-learning)

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
│   └── 002_calibration.md
│
├── backups/                       # ⚠ gitignored. pg_dump files of loaded databases (Step 7c)
│
├── data/                          # ⚠ gitignored. Large, licensed, or generated.
│   ├── source/
│   │   └── nsduh/2024/            # NSDUH PUF + codebook + Data Users' Guide
│   ├── vocab/
│   │   ├── athena/                # The 10 OMOP vocabulary CSVs ONLY (the ETL reads this folder)
│   │   └── athena-extras/         # Original zip, CPT4 tool, *_METADATA files (kept out of the ETL's way)
│   ├── calibration/               # Output of Step 4 (joint_probabilities.json)
│   ├── synthea-output/
│   │   └── <run-id>/csv/          # One folder per Synthea run
│   └── dqd/                       # Data Quality Dashboard results JSON
│
└── services/
    ├── postgres/
    │   └── initdb/
    │       └── 01_schemas.sql     # Creates synthea / cdm / results schemas
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
        └── sql/
            ├── validate_joint.sql        # Compares OMOP joint counts to targets
            └── patch_missing_deaths.sql  # Restores deaths the standard ETL drops (Step 7b)
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
#
# Usage:
#   docker compose up -d                                   # database
#   docker compose --profile calibrate run --rm calibration
#   docker compose --profile generate  run --rm synthea
#   docker compose --profile etl       run --rm etl
# =============================================================================
name: synthetic-omop

services:

  # ---------------------------------------------------------------------------
  # omop-db: PostgreSQL target for OMOP CDM 5.4
  # Schemas (from initdb/01_schemas.sql):
  #   synthea → raw Synthea staging tables
  #   cdm     → OMOP CDM + vocabulary tables
  #   results → analysis output (Achilles / Atlas / our validation)
  # ---------------------------------------------------------------------------
  omop-db:
    image: postgres:16
    container_name: omop-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${OMOP_DB_NAME}
      POSTGRES_USER: ${OMOP_DB_USER}
      POSTGRES_PASSWORD: ${OMOP_DB_PASSWORD}
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

   > ⚠ **Don't skip CVX.** Synthea codes every **immunization** in CVX. Without it, ETL-Synthea **drops** immunization records rather than mapping them to `0`, so they never reach `drug_exposure`, and the unmapped count stays at zero, which hides the loss. In the pilot, `drug_exposure` held exactly the medication count, so all **2,711** immunizations appear to have gone missing this way (confirm with the reconciliation queries in Step 7a).

   > ⚠ **Don't skip Cancer Modifier.** OMOP maps SNOMED *metastasis* concepts (e.g. `94260004` "Metastatic malignant neoplasm to colon") to **Cancer Modifier**, and Synthea's cancer modules produce them. Without it, Athena leaves the `Maps to` row out of `CONCEPT_RELATIONSHIP.csv` and keeps only the `Maps to value → Positive` half, so those records map to `0`. In the pilot this silently dropped 3 deaths (Step 7b). **General rule:** if a concept has `Maps to value` but no `Maps to`, check its page on Athena; the missing target is usually in a vocabulary you didn't select.
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
| A-007 | SNOMED `94260004` maps to Cancer Modifier 35226112, which needs the Cancer Modifier vocabulary | Athena bundle (Step 3b) | Resolved by adding Cancer Modifier |
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

# Pin ETL-Synthea to a COMMIT SHA once one works (reproducibility).
ARG ETL_SYNTHEA_REF=main
RUN R -q -e "install.packages(c('remotes','DatabaseConnector','SqlRender'), repos='https://cloud.r-project.org')" \
  && R -q -e "remotes::install_github('OHDSI/ETL-Synthea', ref='${ETL_SYNTHEA_REF}', upgrade='never')" \
  && R -q -e "remotes::install_github('OHDSI/DataQualityDashboard', upgrade='never')"

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

Comparing CSV → staging → CDM counts is how the pilot found both of its gaps. `drug_exposure` held exactly the 28,265 medications and apparently none of the 2,711 immunizations (CVX missing), and `cdm.death` was 18 short (7b). Expect `drug_exposure_rows` to be **close to, not exactly**, medications + immunizations, since the ETL can legitimately merge or split some records. A gap the size of a whole source table is never legitimate.

### 7b. Known ETL-Synthea gap: dropped deaths

In the pilot, Synthea recorded **175** deaths but `cdm.death` held only **157**. `insert_death.sql` builds each death from the patient's **death-certification encounter** (SNOMED `308646001`) and **inner-joins** the cause of death to a standard concept. So a death is dropped entirely when:

| Reason | Pilot count | Example |
|---|---|---|
| No death-certification encounter | 8 | Nothing to build the row from |
| Cause code has no standard `Maps to` | 7 | `55680006` "Drug overdose", retired from SNOMED in 2021 (A-006) |
| Cause maps into a vocabulary not downloaded | 3 | `94260004` → Cancer Modifier 35226112 (A-007; fixed by Step 3b) |

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

Afterwards, `cdm.death` should match `deceased_in_synthea` from 7a. With Cancer Modifier in the vocabulary, the ETL itself handles the metastasis causes, so the patch inserts fewer rows (15 rather than 18 in the pilot).

> This is also worth reporting upstream on the OHDSI/ETL-Synthea GitHub: dropping a whole death record over an unmapped cause contradicts the OMOP convention. The diagnostic queries above are a complete reproduction.

### 7c. Pin, record, back up

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

Set `ETL_RUN_DQD=true` and rerun (after `down -v`, because `LoadEventTables` needs empty tables), or run the dashboard separately against the loaded database. Results land in `data/dqd/<run-id>/`. You can view them with `DataQualityDashboard::viewDqDashboard()` from an R session, or in Broadsea (Step 9).

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

## Step 9 (optional): Atlas via OHDSI Broadsea

**OHDSI Broadsea** (<https://github.com/OHDSI/Broadsea>) runs the OHDSI web stack (Atlas, WebAPI, HADES/RStudio and others) with Docker Compose profiles. Use it when analysts need to build cohorts in a UI.

```bash
# Separate folder. Don't merge Broadsea's compose into ours.
git clone https://github.com/OHDSI/Broadsea.git
cd Broadsea
git checkout <latest tagged release>   # pin it; see the Releases page
# Read Broadsea's README for its current .env options for pointing WebAPI at
# an external CDM. In outline: register our omop-db as a WebAPI "source" with
# cdm / vocab / results daimons → schemas cdm / cdm / results.
docker compose --profile default up -d
```

Networking: put both stacks on a shared Docker network, or point Broadsea at `host.docker.internal:5432`. The first option is cleaner.

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
- [ ] Step 7a counts reconcile (`person` = patients, `death` = deceased after the 7b patch)
- [ ] Unmapped-codes worklist (7a query 4) reviewed; new retired codes added to `docs/assumptions.md`
- [ ] ETL-Synthea commit SHA pinned and recorded; database backed up to `backups/`
- [ ] DQD failure rate reviewed; known failures documented
- [ ] `validate_joint.sql` results attached to the run-log row
- [ ] Same run repeated with the same seed produces identical CSV hashes

### For the analyst using the database (non-admin)

- [ ] I've read `cdm.cdm_source.source_description` and `docs/assumptions.md`
- [ ] I understand MHD/SUD come from **survey definitions**, and that specific diagnosis codes are **assumptions**
- [ ] I'm using this for testing, cohort development, education, or methods work, **not** effect estimates
- [ ] I know which `RUN_ID` my analysis used, and I've cited it

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
| `cdm.death` has fewer rows than deceased patients | `insert_death.sql` drops deaths with no death-cert encounter or an unmapped cause | Step 7b: diagnose, then run `patch_missing_deaths.sql` |
| A concept has `Maps to value` but no `Maps to` | Its `Maps to` target is in a vocabulary you didn't download (e.g. Cancer Modifier) | Check the concept on athena.ohdsi.org; add that vocabulary to the bundle and reload |
| Common Synthea codes map to `0` | Synthea uses some SNOMED codes **retired** after it was written (`invalid_reason = 'D'`) | Expected. List them with 7a query 4 and record each in `docs/assumptions.md`; any mapping is a terminology-review decision |
| `LoadVocabFromCsv` errors on unexpected files | Zip, jar, `CONCEPT_CPT4.csv` or `*_METADATA.csv` left in `data/vocab/athena/` | Move them to `athena-extras/` (Step 3b) |

---

## Security and usability suggestions

- **Secrets.** Move `OMOP_DB_PASSWORD` to Docker Compose `secrets:` (a file-based secret) once more than one person uses this. Postgres images support `POSTGRES_PASSWORD_FILE`.
- **Least privilege.** Create a read-only `omop_reader` role for analysts and Atlas, and keep `omop_admin` for the ETL only.
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
