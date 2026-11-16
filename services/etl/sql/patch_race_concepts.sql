/**
 * patch_race_concepts.sql: map Synthea race values the standard ETL leaves at 0
 *
 * ⚠ DO NOT RUN until terminology review approves A-009 (docs/assumptions.md).
 *
 * Background (pilot-0001): ETL-Synthea maps only white / black / asian.
 * 30 of 1,175 persons got race_concept_id = 0:
 *   native   13  → 8657  American Indian or Alaska Native            (OMB category)
 *   hawaiian  8  → 8557  Native Hawaiian or Other Pacific Islander   (OMB category)
 *   other     9  → stays 0. The only candidate, 8522 "Other Race", is
 *                  non-standard and retired (invalid_reason = 'D').
 *
 * Why the category-level concepts: Synthea records the broad US Census/OMB
 * categories, so a more specific concept (e.g. 1546513 "Hawaiian") would claim
 * detail the source doesn't have. The specific concepts are descendants of
 * these, so "include descendants" analyses still find these persons.
 *
 * Safety
 *   - Targets are checked against cdm.concept: they must exist, be in the Race
 *     vocabulary, be standard ('S') and valid. Otherwise NOTHING changes.
 *   - Only rows still at 0 are updated, so reruns change nothing (idempotent).
 *   - race_source_value is never touched: the original value stays traceable.
 *   - Runs in one transaction; the summary at the end shows the result.
 *
 * After running: rerun Achilles (Step 9e) and restart WebAPI, or Atlas keeps
 * showing the old "No matching concept" slice.
 *
 * Invocation:
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < services/etl/sql/patch_race_concepts.sql
 *
 * @see docs/assumptions.md A-009
 * @see README Step 7 (patch conventions), Lesson 005 section 5 (responsible patching)
 */

BEGIN;

-- ---------------------------------------------------------------------------
-- The approved mapping, in ONE place (DRY). Add rows here only after review.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE race_map (
  race_source_value text PRIMARY KEY,
  target_concept_id integer NOT NULL
) ON COMMIT DROP;

INSERT INTO race_map VALUES
  ('native',   8657),   -- American Indian or Alaska Native
  ('hawaiian', 8557);   -- Native Hawaiian or Other Pacific Islander

-- ---------------------------------------------------------------------------
-- Guard: every target must be a standard, valid Race concept in THIS vocabulary.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(m.race_source_value || ' → ' || m.target_concept_id, ', ')
    INTO bad
    FROM race_map m
    LEFT JOIN cdm.concept c
           ON c.concept_id       = m.target_concept_id
          AND c.vocabulary_id    = 'Race'
          AND c.standard_concept = 'S'
          AND c.invalid_reason IS NULL
   WHERE c.concept_id IS NULL;

  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Not a standard, valid Race concept in this vocabulary: %. Nothing changed.', bad;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- The update: only persons still unmapped (idempotent).
-- ---------------------------------------------------------------------------
UPDATE cdm.person p
   SET race_concept_id = m.target_concept_id
  FROM race_map m
 WHERE p.race_source_value = m.race_source_value
   AND p.race_concept_id   = 0;

COMMIT;

-- ---------------------------------------------------------------------------
-- Summary: the whole race distribution after the patch.
-- Expected for pilot-0001: native 13 → 8657, hawaiian 8 → 8557, other 9 → 0.
-- ---------------------------------------------------------------------------
SELECT p.race_source_value,
       p.race_concept_id,
       COALESCE(c.concept_name, 'No matching concept') AS concept_name,
       COUNT(*)                                        AS persons
  FROM cdm.person p
  LEFT JOIN cdm.concept c ON c.concept_id = p.race_concept_id
 GROUP BY 1, 2, 3
 ORDER BY p.race_concept_id, persons DESC;
