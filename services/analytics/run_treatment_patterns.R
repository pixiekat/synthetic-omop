#' run_treatment_patterns.R: treatment pathways for one study (Step 10e)
#'
#' Question it answers: after entering the TARGET cohort, which EVENT cohorts
#' (usually treatments) do people go through, in what order and combinations?
#'
#' Inputs: cohorts generated in ATLAS (results.cohort), chosen by ID in a
#'   study file, e.g. services/analytics/studies/mhd-treatments.env:
#'     TP_TARGET_COHORT_ID   one target cohort
#'     TP_EVENT_COHORT_IDS   comma-separated event cohorts (the "treatments")
#'     TP_EXIT_COHORT_IDS    optional, comma-separated exit cohorts
#'     TP_MIN_CELL_COUNT     optional, default 5 (small counts are censored)
#'     TP_MIN_ERA_DURATION, TP_COMBINATION_WINDOW, TP_MIN_POST_COMBINATION_DURATION
#'                           optional; passed to computePathways() ONLY if set,
#'                           otherwise the package's own defaults apply
#'
#' Outputs (data/analyses/<RUN_ID>/treatment-patterns/<STUDY>/):
#'   CSV files from TreatmentPatterns::export(), sunburst.html and sankey.html
#'   (if the plotting packages work), and provenance.json.
#'
#' Usage:
#'   docker compose --profile analytics run --rm -e STUDY=mhd-treatments \
#'     analytics Rscript /app/run_treatment_patterns.R
#'
#' @see https://darwin-eu.github.io/TreatmentPatterns/

source("/app/R/common.R")

suppressPackageStartupMessages(library(TreatmentPatterns))

study <- load_study()
cfg   <- analytics_config()
tool  <- "treatment-patterns"

# --- Which cohorts play which role -----------------------------------------
target_id <- env_int("TP_TARGET_COHORT_ID")
event_ids <- env_int_list("TP_EVENT_COHORT_IDS")
exit_ids  <- env_int_list("TP_EXIT_COHORT_IDS")
if (!length(event_ids)) stop("TP_EVENT_COHORT_IDS must list at least one event cohort.", call. = FALSE)

overlap <- intersect(c(target_id), c(event_ids, exit_ids))
if (length(overlap)) stop("A cohort can't be both target and event/exit: ", paste(overlap, collapse = ", "), call. = FALSE)

# --- Check the cohorts exist and were generated; get their ATLAS names -----
con  <- dbi_connection()
info <- tryCatch(atlas_cohorts(con, c(target_id, event_ids, exit_ids)),
                 finally = DBI::dbDisconnect(con))

# TreatmentPatterns' cohort table: cohortId, cohortName, type.
role <- function(id) if (id == target_id) "target" else if (id %in% exit_ids) "exit" else "event"
cohorts <- data.frame(
  cohortId   = info$cohort_id,
  cohortName = info$cohort_name,
  type       = vapply(info$cohort_id, role, character(1)),
  stringsAsFactors = FALSE
)

# --- Optional pathway settings: pass ONLY the ones the study sets ----------
# This avoids hard-coding defaults here that might differ from the package's.
optional_settings <- list(
  minEraDuration             = "TP_MIN_ERA_DURATION",
  combinationWindow          = "TP_COMBINATION_WINDOW",
  minPostCombinationDuration = "TP_MIN_POST_COMBINATION_DURATION"
)
settings <- list()
for (arg in names(optional_settings)) {
  value <- Sys.getenv(optional_settings[[arg]])
  if (nzchar(value)) settings[[arg]] <- as.integer(value)
}

# --- Compute ---------------------------------------------------------------
# DatabaseConnector route: TreatmentPatterns reads <resultSchema>.<cohortTableName>,
# which is exactly where ATLAS writes generated cohorts (results.cohort).
started <- Sys.time()
andromeda <- do.call(TreatmentPatterns::computePathways, c(
  list(
    cohorts           = cohorts,
    cohortTableName   = "cohort",
    connectionDetails = jdbc_connection_details(),
    cdmSchema         = cfg$cdm_schema,
    resultSchema      = cfg$results_schema
  ),
  settings
))

# --- Export: CSVs + an R6 results object -----------------------------------
out <- output_dir(cfg, tool, study)
min_cell <- as.integer(env_or("TP_MIN_CELL_COUNT", "5"))
results <- TreatmentPatterns::export(
  andromeda    = andromeda,
  outputPath   = out,
  minCellCount = min_cell,
  nonePaths    = TRUE      # also count people with NO treatment path; often the largest group
)

# --- Interactive plots (best effort) ----------------------------------------
# selfcontained = FALSE: a self-contained HTML file needs pandoc, which this
# image doesn't have. The plot then comes as an .html file plus a *_files folder.
save_plot <- function(make_plot, file) {
  tryCatch({
    htmlwidgets::saveWidget(make_plot(), file.path(out, file), selfcontained = FALSE)
    message(sprintf("[plot] %s", file.path(out, file)))
  }, error = function(e) {
    message(sprintf("[plot] skipped %s: %s (the CSVs are still complete)", file, conditionMessage(e)))
  })
}
save_plot(function() results$plotSunburst(), "sunburst.html")
save_plot(function() results$plotSankey(),   "sankey.html")

write_provenance(
  path     = out,
  tool     = tool,
  study    = study,
  cohorts  = cohorts,
  settings = c(settings, list(minCellCount = min_cell, nonePaths = TRUE)),
  packages = c("TreatmentPatterns", "DatabaseConnector")
)

message(sprintf("[done] %s in %.1f minutes → %s", tool,
                as.numeric(difftime(Sys.time(), started, units = "mins")), out))
