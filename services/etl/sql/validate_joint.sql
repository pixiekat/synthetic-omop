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
