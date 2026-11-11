## Optional: add CPT4 to the Athena vocabulary

CPT4 is licensed by the AMA, so Athena doesn't ship CPT4 concepts directly. You get a
`CONCEPT_CPT4.csv` plus a small Java tool (`cpt4.jar`) that uses **your own UMLS API key**
to merge the CPT4 concepts into `CONCEPT.csv`.

**Do you need it?** Usually no, at least for the pilot. Synthea codes most procedures in
SNOMED CT. Without CPT4, the few CPT4-coded procedures load with `procedure_concept_id = 0`
(unmapped), and nothing else is affected. Add it when procedure mapping quality starts to matter.

> ⚠ **Do this BEFORE the first ETL vocabulary load.** The ETL reads `CONCEPT.csv` once
> (`ETL_LOAD_VOCAB=true`). If you merge CPT4 afterwards, the database won't see it until you
> reload the vocabulary, and the simplest clean way to do that is `docker compose down -v`
> followed by a full ETL run.

### Prerequisites

- A UMLS account and API key: <https://uts.nlm.nih.gov/> → **My Profile** → API key.
  The key is personal, so **don't commit it, paste it into tickets, or put it in `.env`**.
- The Synthea image already built (`docker compose --profile generate build synthea`). It
  contains a Java runtime, so you don't need Java installed on your machine.
- Internet access from Docker, because the tool calls the UMLS API.

### Steps

Run these from the project root (`synthetic-omop/`).

```bash
# 1. Put the CPT4 tool and its input next to CONCEPT.csv for now.
#    (They live in athena-extras/ so the ETL loader never sees them.)
cp data/vocab/athena-extras/cpt4.jar         data/vocab/athena/
cp data/vocab/athena-extras/CONCEPT_CPT4.csv data/vocab/athena/

# 2. Back up CONCEPT.csv first, so a failed merge can't leave it half-written.
cp data/vocab/athena/CONCEPT.csv data/vocab/athena-extras/CONCEPT.pre-cpt4.csv
wc -l data/vocab/athena/CONCEPT.csv            # note the line count before

# 3. Read the UMLS key without echoing it or saving it to shell history.
read -rs "UMLS_KEY?UMLS API key: " 2>/dev/null || read -rsp "UMLS API key: " UMLS_KEY
echo

# 4. Run the merge with the Java from the Synthea image, as your own user, so
#    CONCEPT.csv stays owned by you. This is the same command Athena's cpt.sh runs
#    (check with: cat data/vocab/athena-extras/cpt.sh).
docker run --rm \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD/data/vocab/athena:/vocab" -w /vocab \
  --entrypoint java \
  synthetic-omop-synthea \
  -Dumls-apikey="$UMLS_KEY" -jar cpt4.jar 5

# 5. Forget the key straight away.
unset UMLS_KEY

# 6. Check: CONCEPT.csv should have grown, and contain CPT4 rows.
wc -l data/vocab/athena/CONCEPT.csv
grep -c $'\tCPT4\t' data/vocab/athena/CONCEPT.csv

# 7. Put the helper files back in athena-extras/ so the ETL only sees vocabulary tables.
mv data/vocab/athena/cpt4.jar data/vocab/athena/CONCEPT_CPT4.csv data/vocab/athena-extras/
ls data/vocab/athena                            # should be the 10 standard CSVs again
```

The `read` line in step 3 handles both zsh (`read "VAR?prompt"`) and bash (`read -p`).

### If something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `401` / authentication error | Wrong or expired UMLS key | Regenerate the key on the UTS profile page and rerun |
| `UnknownHostException` / timeout | Docker can't reach the internet, or a proxy is in the way | Check `docker run --rm alpine wget -qO- https://uts.nlm.nih.gov` |
| `Unable to access jarfile cpt4.jar` | Step 1 skipped, or wrong `-w` folder | Copy `cpt4.jar` into `data/vocab/athena/` and rerun |
| `CONCEPT.csv` line count didn't change | Merge didn't run, or `CONCEPT_CPT4.csv` wasn't in the folder | Restore from `CONCEPT.pre-cpt4.csv` and repeat steps 1–6 |
| `Permission denied` writing `CONCEPT.csv` | Folder not owned by you | `sudo chown -R "$(id -u):$(id -g)" data/vocab` |

### Record it

In `docs/run-log.md`, note **"CPT4 merged: yes/no"** next to the vocabulary release
(e.g. `v5.0 29-AUG-26 + CPT4`). Two databases built from the "same" Athena release give
different procedure mappings depending on whether CPT4 was merged.

Once you've confirmed the merge worked, you can delete `CONCEPT.pre-cpt4.csv` from
`athena-extras/` to recover the ~0.9 GB.
