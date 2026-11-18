#' common.R: shared helpers for every analytics script (Step 10)
#'
#' Each run_<tool>.R script does source("/app/R/common.R") first, so the
#' configuration, connection and safety-check logic lives in ONE place (DRY).
#'
#' Connection model
#'   All analyses connect as the least-privilege role ohdsi_app (Step 9b):
#'   it can READ cdm and results.cohort, WRITE results, and owns the scratch
#'   schema. It cannot change clinical data, so a bug in an analysis package
#'   can't damage the CDM.
#'
#' Environment (set on the analytics service in compose.yaml):
#'   RUN_ID                          which load we're analysing (output folder)
#'   DB_HOST, DB_NAME, DB_PORT       for DBI/RPostgres (CDMConnector)
#'   DB_SERVER                       "host/dbname" form for DatabaseConnector
#'   DB_USER, DB_PASSWORD            ohdsi_app credentials
#'   STUDY                           name of a file in /app/studies/<STUDY>.env
#'
#' @see services/analytics/studies/README.md for the study-file format

# ---------------------------------------------------------------------------
# Small environment helpers
# ---------------------------------------------------------------------------

#' Read a required environment variable, failing with a clear message.
#' @param name  Variable name.
#' @return character(1)
env_required <- function(name) {
  value <- Sys.getenv(name)
  if (!nzchar(value)) {
    stop(sprintf("Environment variable %s is required but empty. See README Step 10.", name),
         call. = FALSE)
  }
  value
}

#' Read an optional environment variable with a default.
#' @param name     Variable name.
#' @param default  Returned when unset or empty.
#' @return character(1)
env_or <- function(name, default) {
  value <- Sys.getenv(name)
  if (nzchar(value)) value else default
}

#' Read a comma-separated list of integers, e.g. "3, 4,5" -> c(3L, 4L, 5L).
#' Empty -> integer(0). Anything that isn't an integer is an error, not a silent NA.
#' @param name  Variable name.
#' @return integer vector
env_int_list <- function(name) {
  raw <- gsub("\\s", "", Sys.getenv(name))
  if (!nzchar(raw)) return(integer(0))
  parts <- strsplit(raw, ",", fixed = TRUE)[[1]]
  if (!all(grepl("^[0-9]+$", parts))) {
    stop(sprintf("%s must be comma-separated integers, got '%s'.", name, raw), call. = FALSE)
  }
  as.integer(parts)
}

#' Read exactly one integer.
#' @param name  Variable name.
#' @return integer(1)
env_int <- function(name) {
  values <- env_int_list(name)
  if (length(values) != 1) stop(sprintf("%s must be exactly one integer.", name), call. = FALSE)
  values
}

# ---------------------------------------------------------------------------
# Study files and configuration
# ---------------------------------------------------------------------------

#' Load /app/studies/<STUDY>.env into the environment.
#' Study files hold cohort IDs and settings, so every analysis is a reviewable,
#' version-controlled file rather than a command someone typed once.
#' @return character(1) the study name
load_study <- function() {
  study <- env_required("STUDY")
  if (!grepl("^[A-Za-z0-9_-]+$", study)) {
    stop("STUDY may only contain letters, digits, _ and - (it's a file name).", call. = FALSE)
  }
  path <- file.path("/app/studies", paste0(study, ".env"))
  if (!file.exists(path)) stop(sprintf("Study file not found: %s", path), call. = FALSE)
  readRenviron(path)
  message(sprintf("[study] loaded %s", path))
  study
}

#' Fixed schema layout of this project, plus the run's output root.
#' @return list
analytics_config <- function() {
  run_id <- env_required("RUN_ID")
  list(
    run_id         = run_id,
    cdm_schema     = "cdm",                # CDM tables AND vocabulary
    results_schema = "results",            # ATLAS writes generated cohorts to results.cohort
    scratch_schema = "analytics_scratch",  # owned by ohdsi_app; safe to empty (Step 10b)
    output_root    = file.path("/data/analyses", run_id)
  )
}

#' Create (recursively) and return an output folder for one tool and study.
#' Recursive on purpose: Achilles crashed because a parent folder was missing.
#' @param cfg    From analytics_config().
#' @param tool   e.g. "treatment-patterns".
#' @param study  Study name.
#' @return character(1) absolute path
output_dir <- function(cfg, tool, study) {
  ensure_dir(file.path(cfg$output_root, tool, study))
}

#' Create a folder (and any missing parents) and confirm it exists.
#' @param path  Folder to create.
#' @return character(1) the same path
ensure_dir <- function(path) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(path)) stop(sprintf("Could not create %s (check data/analyses ownership).", path), call. = FALSE)
  path
}

# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------

#' DatabaseConnector (JDBC) details, as used by TreatmentPatterns and ETL-Synthea.
#' @return connectionDetails
jdbc_connection_details <- function() {
  DatabaseConnector::createConnectionDetails(
    dbms         = "postgresql",
    server       = env_required("DB_SERVER"),
    port         = as.integer(env_or("DB_PORT", "5432")),
    user         = env_required("DB_USER"),
    password     = env_required("DB_PASSWORD"),
    pathToDriver = env_or("DATABASECONNECTOR_JAR_FOLDER", "/opt/jdbc")
  )
}

#' DBI connection (RPostgres), as used by CDMConnector and CohortContrast.
#' @return DBIConnection; the caller must DBI::dbDisconnect() it.
dbi_connection <- function() {
  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = env_required("DB_HOST"),
    dbname   = env_required("DB_NAME"),
    port     = as.integer(env_or("DB_PORT", "5432")),
    user     = env_required("DB_USER"),
    password = env_required("DB_PASSWORD")
  )
}

# ---------------------------------------------------------------------------
# ATLAS cohorts: names and "was it generated?" check
# ---------------------------------------------------------------------------

#' Look up ATLAS cohort names, and refuse to continue if any cohort is unknown
#' or has never been generated on this database.
#'
#' Why: every tool here reads results.cohort. A cohort that exists in ATLAS but
#' was never generated has ZERO rows, and most tools then produce empty (or
#' misleading) output instead of an error. Better to stop here, loudly.
#'
#' @param con  DBI connection.
#' @param ids  Integer cohort definition IDs (from the ATLAS URL).
#' @return data.frame(cohort_id, cohort_name, persons)
atlas_cohorts <- function(con, ids) {
  ids <- unique(as.integer(ids))
  if (!length(ids) || anyNA(ids)) stop("No valid cohort IDs given.", call. = FALSE)

  # IDs are validated integers, so inlining them is safe from SQL injection.
  id_list <- paste(ids, collapse = ", ")
  info <- DBI::dbGetQuery(con, sprintf("
    SELECT cd.id   AS cohort_id,
           cd.name AS cohort_name,
           (SELECT COUNT(DISTINCT c.subject_id)
              FROM results.cohort c
             WHERE c.cohort_definition_id = cd.id) AS persons
      FROM webapi.cohort_definition cd
     WHERE cd.id IN (%s)
     ORDER BY cd.id", id_list))

  unknown <- setdiff(ids, info$cohort_id)
  if (length(unknown)) {
    stop(sprintf("Cohort ID(s) not found in ATLAS: %s", paste(unknown, collapse = ", ")), call. = FALSE)
  }
  empty <- info$cohort_id[info$persons == 0]
  if (length(empty)) {
    stop(sprintf(paste("Cohort ID(s) %s have no rows in results.cohort.",
                       "Generate them on SYNTH_OMOP in ATLAS first."),
                 paste(empty, collapse = ", ")), call. = FALSE)
  }

  message("[cohorts]")
  for (i in seq_len(nrow(info))) {
    message(sprintf("  %4d  %-50s %6d persons", info$cohort_id[i], info$cohort_name[i], info$persons[i]))
  }
  info
}

# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------

#' Write provenance.json next to the results: what ran, on what, with which
#' versions and settings. The analysis equivalent of a run-log entry.
#' @param path      Output folder.
#' @param tool      Tool name.
#' @param study     Study name.
#' @param cohorts   data.frame from atlas_cohorts().
#' @param settings  Named list of the settings actually used.
#' @param packages  Character vector of package names to record versions for.
write_provenance <- function(path, tool, study, cohorts, settings, packages) {
  cfg <- analytics_config()
  versions <- vapply(packages, function(p) as.character(utils::packageVersion(p)), character(1))
  jsonlite::write_json(
    list(
      tool      = tool,
      study     = study,
      run_id    = cfg$run_id,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      r_version = as.character(getRversion()),
      packages  = as.list(versions),
      cohorts   = cohorts,
      settings  = settings
    ),
    file.path(path, "provenance.json"),
    auto_unbox = TRUE, pretty = TRUE
  )
  message(sprintf("[provenance] %s", file.path(path, "provenance.json")))
}
