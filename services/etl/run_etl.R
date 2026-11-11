#' run_etl.R: load one Synthea run into OMOP CDM 5.4 on omop-db.
#'
#' The call order follows the OHDSI ETL-Synthea documentation:
#'   CreateCDMTables → CreateSyntheaTables → LoadSyntheaTables →
#'   LoadVocabFromCsv → CreateMapAndRollupTables → (CreateExtraIndices) →
#'   LoadEventTables → (DQD)
#'
#' Step toggles (env vars, "true"/"false"):
#'   ETL_CREATE_CDM  create the OMOP tables (first run only)
#'   ETL_LOAD_VOCAB  load Athena CSVs (slow; first run only)
#'   ETL_RUN_DQD     run the Data Quality Dashboard afterwards
#'
#' @see https://ohdsi.github.io/ETL-Synthea/
#' @see https://ohdsi.github.io/DataQualityDashboard/

library(DatabaseConnector)
library(ETLSyntheaBuilder)

#' Read a boolean env var, with a default.
#' @param name     Env var name.
#' @param default  Value used when the variable is unset.
#' @return logical
env_flag <- function(name, default = FALSE) {
  val <- tolower(Sys.getenv(name, unset = if (default) "true" else "false"))
  val %in% c("true", "1", "yes")
}

# --- Configuration ----------------------------------------------------------
cdm_version     <- "5.4"
synthea_version <- "3.3.0"         # MUST match the Synthea release that made the CSVs
cdm_schema      <- "cdm"
synthea_schema  <- "synthea"
run_id          <- Sys.getenv("RUN_ID")
synthea_dir     <- file.path("/data/synthea-output", run_id, "csv")
vocab_dir       <- "/data/vocab"

stopifnot(nzchar(run_id), dir.exists(synthea_dir))

cd <- createConnectionDetails(
  dbms         = "postgresql",
  server       = Sys.getenv("DB_SERVER"),    # "omop-db/synthetic_concurrent"
  port         = as.integer(Sys.getenv("DB_PORT", "5432")),
  user         = Sys.getenv("DB_USER"),
  password     = Sys.getenv("DB_PASSWORD"),  # from .env; never hard-code
  pathToDriver = Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
)

#' Time a step and print a clear log line.
#' @param label  Human-readable step name.
#' @param expr   Expression to evaluate.
step <- function(label, expr) {
  message(sprintf("[%s] ▶ %s", format(Sys.time(), "%H:%M:%S"), label))
  t <- system.time(force(expr))
  message(sprintf("[%s] ✔ %s (%.0fs)", format(Sys.time(), "%H:%M:%S"), label, t[["elapsed"]]))
}

# --- 1. OMOP tables (first run) ---------------------------------------------
if (env_flag("ETL_CREATE_CDM", TRUE)) {
  step("CreateCDMTables", CreateCDMTables(cd, cdmSchema = cdm_schema, cdmVersion = cdm_version))
}

# --- 2. Synthea staging (every run; replaces the previous run's staging) -----
step("CreateSyntheaTables", CreateSyntheaTables(cd, syntheaSchema = synthea_schema, syntheaVersion = synthea_version))
step("LoadSyntheaTables",   LoadSyntheaTables(cd, syntheaSchema = synthea_schema, syntheaFileLoc = synthea_dir))

# --- 3. Vocabulary (first run; slow) ----------------------------------------
if (env_flag("ETL_LOAD_VOCAB", TRUE)) {
  step("LoadVocabFromCsv", LoadVocabFromCsv(cd, cdmSchema = cdm_schema, vocabFileLoc = vocab_dir))
}

# --- 4. Mapping + events ------------------------------------------------------
step("CreateMapAndRollupTables", CreateMapAndRollupTables(
  cd, cdmSchema = cdm_schema, syntheaSchema = synthea_schema,
  cdmVersion = cdm_version, syntheaVersion = synthea_version))

step("CreateExtraIndices", CreateExtraIndices(
  cd, cdmSchema = cdm_schema, syntheaSchema = synthea_schema, syntheaVersion = synthea_version))

step("LoadEventTables", LoadEventTables(
  cd, cdmSchema = cdm_schema, syntheaSchema = synthea_schema,
  cdmVersion = cdm_version, syntheaVersion = synthea_version,
  cdmSourceName         = "Synthetic concurrent disorders",
  cdmSourceAbbreviation = "SYNCD",
  cdmSourceDescription  = paste(
    "Synthetic clinical histories calibrated to NSDUH 2024 public survey estimates.",
    "Clinical timelines contain documented simulation assumptions.",
    sprintf("Run: %s.", run_id))))

# --- 5. Optional: Data Quality Dashboard -------------------------------------
if (env_flag("ETL_RUN_DQD")) {
  step("DataQualityDashboard", DataQualityDashboard::executeDqChecks(
    connectionDetails     = cd,
    cdmDatabaseSchema     = cdm_schema,
    resultsDatabaseSchema = "results",
    cdmSourceName         = "SYNCD",
    cdmVersion            = cdm_version,
    outputFolder          = file.path("/data/dqd", run_id)))
}

message("Done. Run the validation SQL next (services/etl/sql/validate_joint.sql).")
