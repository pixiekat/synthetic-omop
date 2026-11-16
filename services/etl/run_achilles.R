#' run_achilles.R: characterize the loaded CDM for Atlas's "Data Sources" pages (Step 9e)
#'
#' Achilles counts things (people per year of birth, conditions per concept,
#' observation-period lengths …) and writes the counts to results.achilles_*.
#' Atlas reads those tables to draw its Data Sources reports and to show
#' record counts next to concepts in search results.
#'
#' Run it after every ETL load (the counts describe ONE load), as the admin role
#' (it creates tables in results; 01_roles_and_schemas.sql's default privileges
#' then give ohdsi_app access to them automatically).
#'
#' Usage (needs the etl image rebuilt with Achilles, see the Dockerfile):
#'   docker compose --profile etl run --rm etl Rscript /app/run_achilles.R
#'
#' Env vars (already set on the etl service in compose.yaml):
#'   DB_SERVER, DB_PORT, DB_USER, DB_PASSWORD, RUN_ID
#'
#' @see https://ohdsi.github.io/Achilles/
#' @see https://github.com/OHDSI/WebAPI/wiki/CDM-Configuration

library(DatabaseConnector)
library(Achilles)

# --- Configuration ----------------------------------------------------------
cdm_schema     <- "cdm"
vocab_schema   <- "cdm"       # our vocabulary lives alongside the CDM tables
results_schema <- "results"
run_id         <- Sys.getenv("RUN_ID")

stopifnot(nzchar(run_id))

#' Same connection pattern as run_etl.R (DRY candidate: move to a shared
#' services/etl/connection.R and source() it from both scripts).
cd <- createConnectionDetails(
  dbms         = "postgresql",
  server       = Sys.getenv("DB_SERVER"),
  port         = as.integer(Sys.getenv("DB_PORT", "5432")),
  user         = Sys.getenv("DB_USER"),
  password     = Sys.getenv("DB_PASSWORD"),
  pathToDriver = Sys.getenv("DATABASECONNECTOR_JAR_FOLDER", "/opt/jdbc")
)

# Achilles creates outputFolder with a NON-recursive dir.create(), so a missing
# parent (/tmp/achilles-output) makes it fail, and it only crashes at the very
# end, when it reads its own log back to merge the scratch tables. Create the
# whole path ourselves first.
output_folder <- file.path("/tmp/achilles-output", run_id)
dir.create(output_folder, recursive = TRUE, showWarnings = FALSE)
stopifnot(dir.exists(output_folder))

message(sprintf("[achilles] run %s: characterizing %s → %s", run_id, cdm_schema, results_schema))
started <- Sys.time()

Achilles::achilles(
  connectionDetails       = cd,
  cdmDatabaseSchema       = cdm_schema,
  resultsDatabaseSchema   = results_schema,
  vocabDatabaseSchema     = vocab_schema,
  sourceName              = paste0("Synthetic Concurrent Disorders (", run_id, ")"),
  cdmVersion              = "5.4",
  createTable             = TRUE,    # drop and recreate achilles_* (fresh counts per load)
  smallCellCount          = 5,       # counts below this are suppressed, the habit to keep for real data
  numThreads              = 1,       # PostgreSQL + 1 thread is the simplest, most predictable setting
  optimizeAtlasCache      = TRUE,    # builds results.achilles_result_concept_count for Atlas search
  outputFolder            = output_folder
)

message(sprintf("[achilles] done in %.1f minutes",
                as.numeric(difftime(Sys.time(), started, units = "mins"))))
message("[achilles] restart WebAPI so Atlas drops its cached (empty) reports:")
message("           docker compose --profile atlas restart webapi")
