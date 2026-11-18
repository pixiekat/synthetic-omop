# Analysis studies

One `.env` file per analysis. Each file says **which ATLAS cohorts** an analysis uses and
**which settings** it runs with, so every result in `data/analyses/` can be traced back to a
reviewed, version-controlled file.

Run one with:

```bash
docker compose --profile analytics run --rm -e STUDY=<file name without .env> \
  analytics Rscript /app/run_<tool>.R
```

## Rules

- **File names:** letters, digits, `_` and `-` only (they become folder names).
- **Cohort IDs** are the numbers in the ATLAS URL (`…/#/cohortdefinition/3` → `3`). They're
  local to this ATLAS database: after a full reset (`down -v`), IDs restart, so re-check every
  study file.
- **Generate first.** The scripts stop if a cohort has no rows in `results.cohort`.
- **No real patient data or partner codes** in these files: they're committed to Git.
- **One study, one question.** If you change a cohort or setting to answer a different question,
  make a new file rather than editing an old one whose results you've already reported.

## Variables

| Tool | Variable | Required | Meaning |
|---|---|---|---|
| TreatmentPatterns | `TP_TARGET_COHORT_ID` | yes | The population (one cohort) |
| | `TP_EVENT_COHORT_IDS` | yes | Comma-separated "treatment" cohorts |
| | `TP_EXIT_COHORT_IDS` | no | Comma-separated cohorts that end a path |
| | `TP_MIN_CELL_COUNT` | no | Counts below this are censored (default 5) |
| | `TP_MIN_ERA_DURATION`, `TP_COMBINATION_WINDOW`, `TP_MIN_POST_COMBINATION_DURATION` | no | Pathway settings, in days; package defaults if unset |
| CohortContrast | `CC_TARGET_COHORT_ID` | yes | The cohort you're characterising |
| | `CC_CONTROL_COHORT_ID` | no | A comparison cohort; if empty, matched controls are built |
| | `CC_MATCH_RATIO` | no | Controls per target person when matching (default 4) |
| | `CC_DOMAINS` | no | Comma-separated domains (default: all eight) |
| | `CC_PREVALENCE_CUTOFF`, `CC_PRESENCE_FILTER` | no | Filters (defaults 2.5 and 0.2) |
| | `CC_NUM_CORES` | no | Default 1 |
