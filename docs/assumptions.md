  # Simulation assumptions

  | ID | Assumption | Where | Status |
  |---|---|---|---|
  | A-001 | Disorder onset falls inside the 24-month export window (Guard `year >= 2025`) | `concurrent_disorders.json` → `Wait_Until_Adult_In_Window` | Placeholder |
  | A-002 | Survey "any mental illness" is coded as major depressive disorder (SNOMED 370143000) | `MHD_Onset`, `Both_MHD_Onset` | Needs clinical review |
  | A-003 | Survey "substance use disorder" is coded as alcoholism (SNOMED 7200002) | `SUD_Onset`, `Both_SUD_Onset` | Needs clinical review |
  | A-004 | Probabilities are uniform 0.25 placeholders for F 35–49 only | `Assign_Profile` | Pilot only, replace from NSDUH |
