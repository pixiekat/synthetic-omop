# Run log

<!--
  One entry per Synthea RUN (a RUN_ID), with one sub-entry per ETL LOAD of that run.
  A run is "this synthetic population"; a load is "that population, put into OMOP
  with this vocabulary and these patches". Reloading the same run with a new
  vocabulary is a new LOAD, not a new run: the patients haven't changed.

  Rules:
    * Newest run at the top of the index; entries below in the same order.
    * Never edit a finished entry's numbers. If something was wrong, add a
      "Correction" note with the date, so the history stays honest.
    * Every "TODO" is something to fill in before the entry is considered done.
    * Assumption IDs (A-001 …) refer to docs/assumptions.md.

  Handy commands for filling in an entry:
    sha256sum services/synthea/config/* services/synthea/modules/*   # config/module hashes
    sha256sum backups/<file>.dump                                     # backup checksum
    grep -P '^None\t' data/vocab/athena/VOCABULARY.csv                # vocabulary release
    cut -f1 data/vocab/athena/VOCABULARY.csv | sort                   # vocabularies in bundle
    docker compose --profile etl run --rm --entrypoint Rscript etl \
      -e 'cat(packageDescription("ETLSyntheaBuilder")$RemoteSha, "\n")'  # ETL-Synthea SHA
-->

## Index

| Run | Date | Purpose | Calibrated? | Latest load | Status |
|---|---|---|---|---|---|
| [pilot-0001](#pilot-0001) | 2026-11-11 | Plumbing test of the full pipeline | ❌ Placeholder probabilities (A-004) | [Load 2](#pilot-0001--load-2) | ✅ Loaded, reconciled; TODOs open |

---

## pilot-0001

### Purpose

First end-to-end test: Synthea → ETL-Synthea → OMOP CDM 5.4. **Not calibrated.** Uses uniform
0.25 placeholder probabilities for one stratum only (women 35–49). Never use it for estimates.

### Generation (Synthea)

| Item | Value |
|---|---|
| Date | 2026-11-11 |
| Synthea | v3.3.0 (`synthea-with-dependencies.jar`) |
| Command | See `data/synthea-output/pilot-0001/COMMAND.txt` |
| Seed (population / clinician) | 12345 / 12345 |
| Population requested (`-p`) | 1,000 living |
| Population exported | **1,175** (1,000 living + 175 deceased) |
| Age range / state | 18–85 / Massachusetts |
| History exported | 2 years (`exporter.years_of_history = 2`) |
| Config hash (`synthea.local.properties`) | TODO |
| Module hash (`concurrent_disorders.json`) | TODO |
| Calibration input | None: placeholder 0.25 per cell, F 35–49 only (A-004) |
| NSDUH file | Downloaded (`NSDUH_2024_Tab.txt`), not yet used |

**Joint draw check** (people, from `conditions.csv`):

| mhd_only | sud_only | both |
|---|---|---|
| 35 | 35 | 28 |

Expected ≈ 33 each (stratum ≈ 131 people × 0.25); all within about one standard error. ✅

---

### pilot-0001 / Load 1

**Vocabulary:** v5.0 29-AUG-26, Athena bundle "OMOP Synthetic": **defaults only** (no CVX,
no Cancer Modifier). CPT4 not merged.

| Check | Result |
|---|---|
| ETL completed | ✅ |
| `cdm.person` | 1,175 |
| `cdm.death` (ETL) | 157 of 175 deceased: 18 dropped |
| `cdm.death` (after `patch_missing_deaths.sql`) | 175 ✅ |
| `cdm.drug_exposure` | 28,265 = medications only; **0 of 2,711 immunizations** (no CVX) |

**Findings that led to Load 2:**
- 18 deaths dropped by `insert_death.sql`: 8 with no death-certification encounter,
  7 with retired cause `55680006` "Drug overdose" (A-006), 3 with cause `94260004`
  mapping into Cancer Modifier, which wasn't downloaded (A-007).
- All immunizations dropped: CVX missing from the bundle, so nothing could map.
  The unmapped-drug count read **0**, which hid the loss.

Superseded by Load 2. Database wiped (`down -v`); no backup kept.

---

### pilot-0001 / Load 2

**Vocabulary:** v5.0 29-AUG-26 (Athena `v20260829`), bundle
"2026-11-11-with-cvx-cancer-modifiers": defaults **+ CVX + Cancer Modifier**.
**CPT4 merged: no** (UMLS licence pending; deferred to the official build).

| Item | Value |
|---|---|
| Date | 2026-11-11 |
| ETL-Synthea commit | TODO (pin it: README Step 7d) |
| CDM version | 5.4 |
| `LoadVocabFromCsv` | 1,056 s (~18 min) |
| `LoadEventTables` | 169 s |
| Vocabulary rows | `concept` = 6,482,105 = rows in `CONCEPT.csv` ✅ |
| Load warnings | `fread` "improper quoting" healed on HCPCS `A4719` (concept 2614984), harmless; `type_convert()` notice, harmless |

**Patches applied** (in order):

| Patch | Result | Assumption |
|---|---|---|
| `patch_missing_deaths.sql` | `INSERT 0 18` | A-005 |
| `patch_missing_immunizations.sql` | `INSERT 0 26` | A-008 |

**Reconciliation** (README Step 7a):

| Check | ETL alone | After patches | Target | |
|---|---|---|---|---|
| Deaths | 157 | **175** | 175 deceased in Synthea | ✅ |
| Immunizations in `drug_exposure` | 2,685 | **2,711** | 2,711 staged | ✅ |
| Per-code immunization query | 4 codes short | TODO: rerun, expect **no rows** | No rows | ⏳ |

**Death causes after the patch:**

| Source code | Meaning | `cause_concept_id` | Rows | Why |
|---|---|---|---|---|
| `94260004` | Metastatic malignant neoplasm to colon | 35226112 (Cancer Modifier, Measurement) | 3 | Mapping now exists; ETL drops it anyway (Condition-only filter); patch restores with real cause |
| `55680006` | Drug overdose (retired 2021) | 0 | 7 | No standard mapping (A-006); pending terminology review |
| *(none)* | No death-certification encounter | 0 | 8 | Nothing to map |

**Immunizations restored by the patch:**

| Source code | Vaccine | `drug_concept_id` | Target vocabulary | Rows | Linked to a visit |
|---|---|---|---|---|---|
| `3` | MMR (CVX `03`) | 40213183 | CVX | 6 | 5 |
| `8` | Hep B pediatric (CVX `08`) | 40213304 | CVX | 2 | 2 |
| `207` | COVID-19 mRNA | 37003518 | RxNorm | 8 | 7 |
| `208` | COVID-19 mRNA | 37003436 | RxNorm | 10 | 9 |

Three restored rows aren't linked to a visit, most likely because ETL-Synthea merged those
encounters into other visits. The rows are still valid.

**ETL-Synthea behaviour confirmed by reading its SQL** (v540, at the commit above):

| File | Lines | Behaviour |
|---|---|---|
| `insert_death.sql` | 30–33 | Inner join on cause; keeps only `source_domain_id` and `target_domain_id = 'Condition'` |
| `insert_drug_exposure.sql` | 127, 132 | Immunizations: `target_vocabulary_id = 'CVX'` and `source_vocabulary_id = 'CVX'` |

Candidate for an upstream issue on OHDSI/ETL-Synthea: both drop records instead of keeping
them with `concept_id = 0`.

**Validation** (README Step 8):

| Check | Result |
|---|---|
| Data Quality Dashboard | TODO (not run) |
| `validate_joint.sql` | TODO (needs the module's standard concept_ids from 7a query 5) |
| Unmapped-codes worklist (7a query 4) | TODO: review, add retired codes to `docs/assumptions.md` |

**Artefacts:**

| Item | Value |
|---|---|
| Backup file | `backups/omop-pilot-0001-cvx-cancermod-patched.dump` |
| Backup sha256 | TODO |
| Backup stored at | TODO (shared/team location; never in git) |

**Open items:**
- [ ] Rerun the per-code immunization reconciliation; record "no rows".
- [ ] Pin ETL-Synthea SHA; record above.
- [ ] Back up; record sha256 and storage location.
- [ ] Record config and module hashes in the Generation table.
- [ ] Run DQD and `validate_joint.sql`.
- [ ] Decide on candidate mappings for `55680006` (A-006): terminology review.

---

<!--
==========================================================================
TEMPLATE: copy everything below this line for a new run, and fill it in.
Add the run to the Index table at the top.
==========================================================================

## <run-id>

### Purpose

<Why this run exists; whether its probabilities are calibrated.>

### Generation (Synthea)

| Item | Value |
|---|---|
| Date | YYYY-MM-DD |
| Synthea | v3.3.0 |
| Command | See `data/synthea-output/<run-id>/COMMAND.txt` |
| Seed (population / clinician) | |
| Population requested (`-p`) | |
| Population exported | (living + deceased) |
| Age range / state | |
| History exported | |
| Config hash | |
| Module hash | |
| Calibration input | `data/calibration/joint_probabilities.json`, sha256: |
| NSDUH file | |

**Joint draw check:**

| mhd_only | sud_only | both |
|---|---|---|
| | | |

---

### <run-id> / Load 1

**Vocabulary:** <release>, bundle "<name>": <vocabularies beyond defaults>. CPT4 merged: yes/no.

| Item | Value |
|---|---|
| Date | |
| ETL-Synthea commit | |
| CDM version | 5.4 |
| `LoadVocabFromCsv` | |
| `LoadEventTables` | |
| Vocabulary rows | `concept` = … (= CSV rows?) |
| Load warnings | |

**Patches applied:**

| Patch | Result | Assumption |
|---|---|---|
| `patch_missing_deaths.sql` | INSERT 0 … | A-005 |
| `patch_missing_immunizations.sql` | INSERT 0 … | A-008 |

**Reconciliation:**

| Check | ETL alone | After patches | Target | |
|---|---|---|---|---|
| Deaths | | | | |
| Immunizations | | | | |
| Per-code immunization query | | | No rows | |

**Validation:**

| Check | Result |
|---|---|
| Data Quality Dashboard | |
| `validate_joint.sql` | |
| Unmapped-codes worklist | |

**Artefacts:**

| Item | Value |
|---|---|
| Backup file | |
| Backup sha256 | |
| Backup stored at | |

**Open items:**
- [ ]
-->
