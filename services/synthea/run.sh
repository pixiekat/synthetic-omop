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
