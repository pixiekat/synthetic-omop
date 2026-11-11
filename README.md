# Synthetic Concurrent-Disorders Data in OMOP CDM 5.4

**A step-by-step setup guide: NSDUH → Synthea → ETL-Synthea → PostgreSQL (OMOP), run locally with Docker Compose**

| | |
|---|---|
| **Status** | Draft framework. The stack has not been run end to end yet, so expect to adjust things. |
| **Audience** | Engineers who build the pipeline (admin) and analysts who use the resulting database (non-admin) |
| **Pinned versions** | Synthea `v3.3.0`, OMOP CDM `5.4`, ETL-Synthea (`OHDSI/ETL-Synthea`, pinned to a commit), PostgreSQL `16` |
| **Source notes** | Builds on the OMOP project's planning notes. The method is unchanged; this guide adds the local Docker setup. |

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
├── README.md                      # Short version of this guide
│
├── docs/
│   ├── assumptions.md             # Every simulation assumption, numbered (A-001 …)
│   └── run-log.md                 # One row per generation run (provenance)
│
├── data/                          # ⚠ gitignored. Large, licensed, or generated.
│   ├── source/
│   │   └── nsduh/2024/            # NSDUH PUF + codebook + Data Users' Guide
│   ├── vocab/
│   │   └── athena/                # Unzipped Athena bundle (CONCEPT.csv etc.)
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
            └── validate_joint.sql # Compares OMOP joint counts to targets
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
    environment:
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
    environment:
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
2. Select at least **SNOMED, RxNorm, RxNorm Extension, LOINC, CVX, and Gender/Race/Ethnicity/Visit/Domain** (the defaults include most of these). Synthea also emits some CPT4 procedure codes. CPT4 needs your UMLS key and running `cpt.sh` after download, as Athena's instructions describe.
3. Unzip into `data/vocab/athena/` so that `CONCEPT.csv` sits directly in that folder.
4. Write the **vocabulary release version** into `docs/run-log.md`. It's in `VOCABULARY.csv` under the row `vocabulary_id = 'None'`.

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

### `services/synthea/modules/concurrent_disorders.json` (skeleton, abbreviated)

```json
{
  "name": "Concurrent Disorders (NSDUH-calibrated)",
  "remarks": [
    "Parent module: assigns ONE joint MHD/SUD profile per adult, drawn from",
    "NSDUH 2024 weighted joint estimates by age x sex (data/calibration).",
    "Diagnosis codes are SIMULATION ASSUMPTIONS. See docs/assumptions.md A-001..A-004.",
    "Only one stratum is shown filled in; generate the rest from joint_probabilities.json."
  ],
  "gmf_version": 2,
  "states": {

    "Initial": {
      "type": "Initial",
      "direct_transition": "Wait_Until_Adult_In_Window"
    },

    "Wait_Until_Adult_In_Window": {
      "type": "Guard",
      "remarks": "A-001: onset placed inside the 24-month export window. Align 'year' with the simulation end date.",
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
      "remarks": "Joint draw. NEVER replace this with two independent draws.",
      "complex_transition": [
        {
          "condition": {
            "condition_type": "And",
            "conditions": [
              { "condition_type": "Gender", "gender": "F" },
              { "condition_type": "Age", "operator": ">=", "quantity": 35, "unit": "years" },
              { "condition_type": "Age", "operator": "<",  "quantity": 50, "unit": "years" }
            ]
          },
          "distributions": [
            { "distribution": 0.0, "transition": "Set_Neither" },
            { "distribution": 0.0, "transition": "Set_MHD_Only" },
            { "distribution": 0.0, "transition": "Set_SUD_Only" },
            { "distribution": 0.0, "transition": "Set_Both" }
          ]
        },
        {
          "remarks": "Fallback: should never fire if every stratum is listed above.",
          "distributions": [
            { "distribution": 1.0, "transition": "Set_Neither" }
          ]
        }
      ]
    },

    "Set_Neither":  { "type": "SetAttribute", "attribute": "concurrent_profile", "value": "neither",  "direct_transition": "Terminal" },
    "Set_MHD_Only": { "type": "SetAttribute", "attribute": "concurrent_profile", "value": "mhd_only", "direct_transition": "MHD_Encounter" },
    "Set_SUD_Only": { "type": "SetAttribute", "attribute": "concurrent_profile", "value": "sud_only", "direct_transition": "SUD_Encounter" },
    "Set_Both":     { "type": "SetAttribute", "attribute": "concurrent_profile", "value": "both",     "direct_transition": "Both_Encounter" },

    "MHD_Encounter": {
      "type": "Encounter",
      "encounter_class": "ambulatory",
      "reason": null,
      "codes": [{ "system": "SNOMED-CT", "code": "185345009", "display": "Encounter for symptom (procedure)" }],
      "direct_transition": "MHD_Onset"
    },
    "MHD_Onset": {
      "type": "ConditionOnset",
      "remarks": "A-002: survey 'any mental illness' → MDD. PLACEHOLDER, needs clinical review.",
      "target_encounter": "MHD_Encounter",
      "assign_to_attribute": "mhd_condition",
      "codes": [{ "system": "SNOMED-CT", "code": "370143000", "display": "Major depressive disorder (disorder)" }],
      "direct_transition": "End_MHD_Encounter"
    },
    "End_MHD_Encounter": { "type": "EncounterEnd", "direct_transition": "Terminal" },

    "SUD_Encounter":     { "...": "same pattern as MHD_Encounter → SUD_Onset → EncounterEnd" },
    "Both_Encounter":    { "...": "one encounter, TWO ConditionOnset states, so the episodes overlap by construction" },

    "Terminal": { "type": "Terminal" }
  }
}
```

**Next things to add, roughly in order of value:**

1. All strata from `joint_probabilities.json`. A 30-line script that renders the `complex_transition` array from the JSON is worth writing, so nobody ever hand-copies probabilities.
2. Follow-up visits and treatment (`MedicationOrder`, `CarePlanStart`), each tagged with an assumption ID.
3. **Prevent duplicates.** Synthea's built-in modules (e.g. `opioid_addiction`, `alcohol`, `depression` screening) can generate overlapping conditions. Either disable them with `-m` module filtering in `run.sh`, or check for them in validation (Step 8).

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
ADD https://github.com/synthetichealth/synthea/releases/download/${SYNTHEA_VERSION}/synthea-with-dependencies.jar /synthea/synthea.jar

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

# Save the exact invocation for the run log.
printf '%q ' java -jar /synthea/synthea.jar "${ARGS[@]}" "${SYNTHEA_STATE}" > "${OUT}/COMMAND.txt"

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

# Leave the rest at defaults until there's a reason to change them.
# Every change here goes in docs/run-log.md.
```

Run it:

```bash
docker compose --profile generate build synthea
docker compose --profile generate run --rm synthea
ls data/synthea-output/pilot-0001/csv/     # patients.csv, conditions.csv, encounters.csv …
```

Add a row to **`docs/run-log.md`**:

| run_id | date | synthea | seed | pop | config hash | module hash | vocab release | NSDUH file | notes |
|---|---|---|---|---|---|---|---|---|---|
| pilot-0001 | 2026-11-xx | v3.3.0 | 12345 | 1000 | `sha256sum …` | `sha256sum …` | v5.0 xx-XXX-26 | NSDUH_2024_Tab.txt | first pilot |

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
docker compose --profile etl build etl
# First run: creates the CDM and loads the vocabulary. This can take a long time.
docker compose --profile etl run --rm etl
```

---

## Step 8: Validate

### 8a. Structural: Data Quality Dashboard

Set `ETL_RUN_DQD=true` and rerun, or run the dashboard separately. Results land in `data/dqd/<run-id>/`. You can view them with `DataQualityDashboard::viewDqDashboard()` from an R session, or in Broadsea (Step 9).

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
 * map to. Look them up in cdm.concept / cdm.concept_relationship ('Maps to').
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
- [ ] ETL finished without errors; `cdm.cdm_source` row describes the run
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
| `initdb` schemas missing | Volume already existed, so init scripts were skipped | `docker compose down -v` (deletes data) and start again |
| ETL: `Java heap space` | Large vocabulary load | Add `ENV _JAVA_OPTIONS=-Xmx4g` to the ETL Dockerfile |
| ETL: column mismatch in `LoadSyntheaTables` | `synthea_version` in `run_etl.R` ≠ the jar that produced the CSVs | Make them match (3.3.0) |
| Many `condition_concept_id = 0` | Vocabulary bundle missing SNOMED, or a custom code has no mapping | Re-download with SNOMED; map custom codes with Usagi (<https://ohdsi.github.io/Usagi/>) and have someone review them |
| Joint proportions skewed high | Built-in Synthea modules adding the same disorders | Filter modules with `-m`, or exclude them in validation |
| Nobody in the "both" cell | Guard `year` is later than the simulation end date | Line the Guard up with the run's end date (A-001) |
| Port 5432 in use | Local Postgres already running | Set `OMOP_DB_PORT=5433` in `.env` |

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
