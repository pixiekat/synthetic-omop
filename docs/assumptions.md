# Simulation assumptions

  | ID | Assumption | Where | Status |
  |---|---|---|---|
  | A-001 | Disorder onset falls inside the 24-month export window (Guard `year >= 2025`) | `concurrent_disorders.json` → `Wait_Until_Adult_In_Window` | Placeholder |
  | A-002 | Survey "any mental illness" is coded as major depressive disorder (SNOMED 370143000) | `MHD_Onset`, `Both_MHD_Onset` | Needs clinical review |
  | A-003 | Survey "substance use disorder" is coded as alcoholism (SNOMED 7200002) | `SUD_Onset`, `Both_SUD_Onset` | Needs clinical review |
  | A-004 | Probabilities are uniform 0.25 placeholders for F 35–49 only | `Assign_Profile` | Pilot only, replace from NSDUH |
  | A-005 | dropped deaths restored with cause_concept_id = 0 (patch). |
  | A-006 | 55680006 Drug overdose was retired in 2021. Candidate mappings (607147 Overdose, 4053782 Overdose of opiate) are pending terminology review. Unmapped until then. |
  | A-007 | 94260004 is valid but unmapped. Suspected missing Cancer Modifier vocabulary; check and re-download. |
  | A-007 | resolved. The cause was the missing Cancer Modifier vocabulary, and the fix is to include it in the Athena bundle. |

### A-009: Race values not mapped by ETL-Synthea

- **Observed (pilot-0001):** 30 of 1,175 persons have `race_concept_id = 0`:
  `native` 13, `other` 9, `hawaiian` 8. `white`, `black` and `asian` map normally.
- **Effect:** these persons appear as "No matching concept" in Atlas and drop out of
  race-stratified results; the smallest groups are the ones affected.
- **Candidate mappings (pending terminology review):** `native` → American Indian or
  Alaska Native; `hawaiian` → Native Hawaiian or Other Pacific Islander; `other` → keep 0.
  Concept IDs to be confirmed in the loaded vocabulary (standard, valid).
- **Decision:** none yet. `race_source_value` keeps the original value, so the mapping
  can be applied later without regenerating data.
- **Owner:** terminology review (with A-006).
