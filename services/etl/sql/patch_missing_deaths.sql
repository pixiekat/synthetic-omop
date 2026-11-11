/**
 * services/etl/sql/patch_missing_deaths.sql
 *
 * Restores deceased patients that ETL-Synthea's insert_death.sql drops when the
 * cause of death has no standard "Maps to" concept, or there's no
 * death-certification encounter (SNOMED 308646001).
 *
 * OMOP convention: an unmapped value keeps its row with concept_id = 0, and the
 * original code stays in *_source_value. We never guess a mapping here.
 *
 * Run AFTER run_etl.R. Record it in docs/run-log.md (deviation from standard ETL).
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
