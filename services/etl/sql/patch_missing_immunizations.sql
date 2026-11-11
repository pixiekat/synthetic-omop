/**
 * patch_missing_immunizations.sql
 *
 * Restores immunizations that ETL-Synthea's insert_drug_exposure.sql drops.
 * Two causes were confirmed in pilot-0001 (26 of 2,711 records):
 *
 *   1. LEADING ZEROS: Synthea writes single-digit CVX codes as '3', '8'; the CVX
 *      vocabulary writes them as '03', '08'. The ETL compares them as text, so
 *      '3' never matches '03', and the inner join drops the record.
 *      (MMR = 03, Hep B pediatric = 08.)
 *
 *   2. VOCABULARY FILTER: the immunization section requires the standard
 *      target to be in CVX itself (insert_drug_exposure.sql, v540, line 127:
 *      `target_vocabulary_id = 'CVX'`). COVID-19 codes 207 / 208 are
 *      non-standard in recent vocabulary releases and "Maps to" concepts in
 *      another vocabulary, so the filter rejects them.
 *
 * What this patch does differently:
 *   - pads single-digit codes ONLY for the lookup; drug_source_value keeps
 *     Synthea's original code, so staging stays untouched (Lesson 001)
 *   - accepts a standard CVX concept as-is, OR follows "Maps to" to any valid,
 *     standard, Drug-domain concept, in any vocabulary
 *   - anything still unmappable is kept with drug_concept_id = 0 (OMOP
 *     convention), never dropped
 *
 * Copies drug_type_concept_id from the immunization rows the ETL DID load, so
 * patched rows match them, rather than hard-coding a type concept.
 *
 * Run AFTER run_etl.R, and after patch_missing_deaths.sql (order doesn't matter
 * between the two). Safe to rerun: it only inserts immunizations that aren't
 * already in cdm.drug_exposure (same person, source code and date).
 *
 * Record it in docs/assumptions.md (A-008) and docs/run-log.md.
 *
 * @see services/etl/sql/patch_missing_deaths.sql (same pattern)
 * @see README.md, Step 7a (per-code reconciliation query)
 */

BEGIN;

WITH
-- ---------------------------------------------------------------------------
-- The drug_type_concept_id the ETL used for immunizations it DID load.
-- Falls back to 32817 (EHR) only if no immunization loaded at all.
-- ---------------------------------------------------------------------------
type_template AS (
  SELECT COALESCE(
           (SELECT de.drug_type_concept_id
              FROM cdm.drug_exposure de
              JOIN synthea.immunizations i
                ON i.code = de.drug_source_value
             GROUP BY de.drug_type_concept_id
             ORDER BY COUNT(*) DESC
             LIMIT 1),
           32817) AS drug_type_concept_id
),

-- ---------------------------------------------------------------------------
-- Staged immunizations that never reached drug_exposure.
-- A record counts as "present" if the same person has the same source code
-- on the same date.
-- ---------------------------------------------------------------------------
missing AS (
  SELECT i.*,
         per.person_id,
         -- Pad single-digit codes for the LOOKUP only: '3' -> '03'.
         -- (Not LPAD: Postgres LPAD truncates longer strings, so
         --  LPAD('207', 2, '0') would wrongly give '20'.)
         CASE WHEN i.code ~ '^[0-9]$' THEN '0' || i.code ELSE i.code END AS cvx_code
    FROM synthea.immunizations i
    JOIN cdm.person per
      ON per.person_source_value = i.patient
   WHERE NOT EXISTS (
           SELECT 1
             FROM cdm.drug_exposure de
            WHERE de.person_id                = per.person_id
              AND de.drug_source_value        = i.code
              AND de.drug_exposure_start_date = CAST(i.date AS date)
         )
),

-- ---------------------------------------------------------------------------
-- Resolve each missing record to a standard concept.
-- DISTINCT ON keeps one row per staged record, even if a code has several
-- "Maps to" targets (lowest target concept_id wins, deterministically).
-- ---------------------------------------------------------------------------
resolved AS (
  SELECT DISTINCT ON (m.person_id, m.code, m.date, m.encounter)
         m.person_id,
         m.code                                   AS drug_source_value,
         CAST(m.date AS date)                     AS start_date,
         CAST(m.date AS timestamp)                AS start_datetime,
         m.encounter,
         COALESCE(src.concept_id, 0)              AS drug_source_concept_id,
         COALESCE(
           CASE WHEN src.standard_concept = 'S' THEN src.concept_id END,  -- standard CVX: use as-is
           tgt.concept_id,                                                -- else follow Maps to
           0                                                              -- else unmapped (kept!)
         )                                        AS drug_concept_id
    FROM missing m
    LEFT JOIN cdm.concept src
           ON src.vocabulary_id = 'CVX'
          AND src.concept_code  = m.cvx_code
    LEFT JOIN cdm.concept_relationship cr
           ON cr.concept_id_1    = src.concept_id
          AND cr.relationship_id = 'Maps to'
          AND cr.invalid_reason IS NULL
    LEFT JOIN cdm.concept tgt
           ON tgt.concept_id       = cr.concept_id_2
          AND tgt.domain_id        = 'Drug'      -- right table for a vaccine
          AND tgt.standard_concept = 'S'
          AND tgt.invalid_reason  IS NULL        -- ANY vocabulary, not just CVX
   ORDER BY m.person_id, m.code, m.date, m.encounter, tgt.concept_id
)

INSERT INTO cdm.drug_exposure (
  drug_exposure_id,
  person_id,
  drug_concept_id,
  drug_exposure_start_date,
  drug_exposure_start_datetime,
  drug_exposure_end_date,
  drug_exposure_end_datetime,
  drug_type_concept_id,
  visit_occurrence_id,
  drug_source_value,
  drug_source_concept_id
)
SELECT
  -- drug_exposure_id has no sequence in the CDM DDL, so continue from the max
  (SELECT COALESCE(MAX(drug_exposure_id), 0) FROM cdm.drug_exposure)
    + ROW_NUMBER() OVER (ORDER BY r.person_id, r.start_datetime, r.drug_source_value),
  r.person_id,
  r.drug_concept_id,
  r.start_date,
  r.start_datetime,
  r.start_date,                 -- a vaccine dose is a single-day exposure
  r.start_datetime,
  t.drug_type_concept_id,
  vo.visit_occurrence_id,       -- linked via the Synthea encounter, if found (see note below)
  r.drug_source_value,          -- Synthea's ORIGINAL code, e.g. '3', for traceability
  r.drug_source_concept_id
FROM resolved r
CROSS JOIN type_template t
LEFT JOIN cdm.visit_occurrence vo
       ON vo.person_id          = r.person_id
      AND vo.visit_source_value = r.encounter;

-- Show the immunization rows this patch is responsible for (from any run).
-- The ETL itself never loads these two kinds, so they identify patched rows:
--   * a single-digit source code ('3', '8'): the ETL can't match these
--   * a target outside CVX (or 0): the ETL's CVX-only filter rejects these
SELECT de.drug_source_value,
       de.drug_concept_id,
       c.vocabulary_id                   AS target_vocabulary,
       COUNT(*)                          AS patched_rows,
       COUNT(de.visit_occurrence_id)     AS linked_to_visit
  FROM cdm.drug_exposure de
  LEFT JOIN cdm.concept c ON c.concept_id = de.drug_concept_id
 WHERE de.drug_source_value IN (SELECT DISTINCT code FROM synthea.immunizations)
   AND (de.drug_source_value ~ '^[0-9]$'
        OR c.vocabulary_id IS DISTINCT FROM 'CVX')
 GROUP BY 1, 2, 3
 ORDER BY 1;

COMMIT;

/*
 * NOTE on visit_occurrence_id:
 * This assumes ETL-Synthea stores the Synthea encounter ID in
 * visit_occurrence.visit_source_value. If "linked_to_visit" above is 0, check:
 *
 *   SELECT visit_source_value FROM cdm.visit_occurrence LIMIT 5;
 *
 * If those aren't encounter UUIDs, the restored rows are still correct;
 * they just aren't linked to a visit (the column is nullable).
 */
