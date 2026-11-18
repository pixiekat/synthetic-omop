#' run_cohort_contrast.R: concept enrichment, target vs control (Step 10f)
#'
#' Question it answers: which concepts (drugs, conditions, measurements …) are
#' over-represented in the TARGET cohort compared with a CONTROL cohort?
#'
#' Inputs, from a study file (services/analytics/studies/<STUDY>.env):
#'   CC_TARGET_COHORT_ID    one ATLAS cohort (generated)
#'   CC_CONTROL_COHORT_ID   optional ATLAS cohort; if empty, CohortContrast builds
#'                          MATCHED controls (CC_MATCH_RATIO per target person)
#'   CC_MATCH_RATIO         optional, default 4
#'   CC_DOMAINS             optional, comma-separated; default all eight domains
#'   CC_PREVALENCE_CUTOFF   optional, default 2.5 (the package docs' example value)
#'   CC_PRESENCE_FILTER     optional, default 0.2 (same)
#'   CC_NUM_CORES           optional, default 1 (predictable in a container)
#'
#' Outputs (data/analyses/<RUN_ID>/cohort-contrast/<STUDY>/):
#'   the CohortContrast study folder (parquet files + metadata.json) and
#'   provenance.json. Explore it with the viewer (Step 10g).
#'
#' Usage:
#'   docker compose --profile analytics run --rm -e STUDY=mhd-sud-vs-mhd \
#'     analytics Rscript /app/run_cohort_contrast.R
#'
#' @see https://healthinformaticsut.github.io/CohortContrast/

source("/app/R/common.R")

suppressPackageStartupMessages({
  library(CDMConnector)
  library(CohortContrast)
})

study <- load_study()
cfg   <- analytics_config()
tool  <- "cohort-contrast"

target_id  <- env_int("CC_TARGET_COHORT_ID")
control_id <- env_int_list("CC_CONTROL_COHORT_ID")   # 0 or 1 values
if (length(control_id) > 1) stop("CC_CONTROL_COHORT_ID takes at most one cohort.", call. = FALSE)

domains <- strsplit(env_or("CC_DOMAINS",
  "Drug,Condition,Measurement,Observation,Procedure,Visit,Visit detail,Death"), ",", fixed = TRUE)[[1]]
domains <- trimws(domains)

db <- dbi_connection()
on.exit(DBI::dbDisconnect(db), add = TRUE)

info <- atlas_cohorts(db, c(target_id, control_id))

# --- CDM reference -----------------------------------------------------------
# writeSchema: CohortContrast's docs describe it as a schema for temporary
# tables that "will be deleted". So it gets its OWN throwaway schema
# (analytics_scratch), never WebAPI's temp schema. The prefix keeps tables
# identifiable if a run is interrupted.
cdm <- CDMConnector::cdmFromCon(
  con            = db,
  cdmSchema      = cfg$cdm_schema,
  achillesSchema = cfg$results_schema,
  writeSchema    = c(schema = cfg$scratch_schema, prefix = "cc_")
)

# --- Target and control --------------------------------------------------------
target_table <- CohortContrast::cohortFromCohortTable(
  cdm = cdm, db = db, tableName = "cohort",
  schemaName = cfg$results_schema, cohortId = target_id)

if (length(control_id)) {
  control_table <- CohortContrast::cohortFromCohortTable(
    cdm = cdm, db = db, tableName = "cohort",
    schemaName = cfg$results_schema, cohortId = control_id)
  control_desc <- sprintf("ATLAS cohort %d", control_id)
} else {
  ratio <- as.integer(env_or("CC_MATCH_RATIO", "4"))
  control_table <- CohortContrast::createControlCohortMatching(
    cdm = cdm, targetTable = target_table, ratio = ratio)
  control_desc <- sprintf("matched controls, ratio %d", ratio)
}
message(sprintf("[control] %s", control_desc))

# --- Run -------------------------------------------------------------------
# pathToResults is the PARENT folder; complName is the study folder inside it,
# which CohortContrast creates itself (so we only create the parent).
parent <- ensure_dir(file.path(cfg$output_root, tool))
settings <- list(
  domainsIncluded   = domains,
  prevalenceCutOff  = as.numeric(env_or("CC_PREVALENCE_CUTOFF", "2.5")),
  topK              = FALSE,
  presenceFilter    = as.numeric(env_or("CC_PRESENCE_FILTER", "0.2")),
  getSourceData     = FALSE,
  runChi2YTests     = TRUE,
  runLogitTests     = FALSE,
  createOutputFiles = TRUE,
  numCores          = as.integer(env_or("CC_NUM_CORES", "1"))
)

started <- Sys.time()
data <- do.call(CohortContrast::CohortContrast, c(
  list(
    cdm                       = cdm,
    targetTable               = target_table,
    controlTable              = control_table,
    pathToResults             = parent,
    complementaryMappingTable = NULL,
    complName                 = study
  ),
  settings
))

out <- file.path(parent, study)
write_provenance(
  path     = out,
  tool     = tool,
  study    = study,
  cohorts  = info,
  settings = c(settings, list(control = control_desc)),
  packages = c("CohortContrast", "CDMConnector")
)

message(sprintf("[done] %s in %.1f minutes → %s", tool,
                as.numeric(difftime(Sys.time(), started, units = "mins")), out))
