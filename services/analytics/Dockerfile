# =============================================================================
# services/analytics/Dockerfile: R image for cohort-level analyses (Step 10)
#
# Kept SEPARATE from services/etl on purpose: the ETL image stays pinned and
# lean, and upgrading an analysis package can never break a data load.
#
# Packages:
#   TreatmentPatterns  treatment pathways (sunburst / Sankey)    DARWIN EU, CRAN
#   CohortContrast     concept enrichment, target vs control      Univ. Tartu, CRAN
#
# Same R version as the etl image, so Docker can share the base layers.
# =============================================================================
FROM rocker/r-ver:4.4.2

# System dependencies:
#   default-jdk                  DatabaseConnector (JDBC), used by TreatmentPatterns
#   libpq-dev                    RPostgres (DBI driver), used by CDMConnector / CohortContrast
#   libxml2/libssl/libcurl -dev  common build dependencies for R packages
#   python3 + venv + pip         CohortContrast's results viewer uses Python helpers (Step 10g)
#   libglpk-dev libgmp-dev       igraph (needed by networkD3, the Sankey plots): the pre-built
#                                binary installs without them but then FAILS TO LOAD
RUN apt-get update && apt-get install -y --no-install-recommends \
      default-jdk libpq-dev libxml2-dev libssl-dev libcurl4-openssl-dev \
      libglpk-dev libgmp-dev \
      python3 python3-venv python3-pip \
  && R CMD javareconf \
  && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Package source: a DATED snapshot of Posit Package Manager, Linux binaries.
#   - Binaries: arrow and duckdb install in seconds instead of compiling for
#     many minutes.
#   - Dated: rebuilding next month installs exactly the same versions
#     (reproducibility, like pinning ETL_SYNTHEA_REF). Bump it deliberately.
# The rocker base image already sets the HTTP user agent PPM needs to serve
# binaries; this line only replaces the repository URL. Its pre-set snapshot
# is from when R 4.4.2 was current, too old for these packages.
# ---------------------------------------------------------------------------
ARG CRAN_SNAPSHOT=2026-11-16
RUN . /etc/os-release \
  && printf "options(repos = c(CRAN = 'https://p3m.dev/cran/__linux__/%s/%s'))\n" \
       "$VERSION_CODENAME" "$CRAN_SNAPSHOT" >> /usr/local/lib/R/etc/Rprofile.site

# Install, then CHECK. `R -e "install.packages(...)"` exits 0 even when an
# install fails (Lesson 008, case 2), so the last command turns a missing
# package into a failed build. It prints each failure's actual LOAD error,
# because "installed but won't load" usually means a missing system library,
# and the error message names it.
RUN R -q -e "install.packages(c( \
      'DatabaseConnector', 'SqlRender', 'DBI', 'RPostgres', 'CDMConnector', \
      'TreatmentPatterns', 'CohortContrast', \
      'jsonlite', 'htmlwidgets', 'sunburstR', 'networkD3', 'plotly'))" \
  && R -q -e "pkgs <- c('DatabaseConnector','SqlRender','DBI','RPostgres','CDMConnector', \
                        'TreatmentPatterns','CohortContrast','jsonlite','htmlwidgets', \
                        'sunburstR','networkD3','plotly'); \
              errs <- vapply(pkgs, function(p) tryCatch({ loadNamespace(p); '' }, \
                             error = function(e) conditionMessage(e)), character(1)); \
              bad <- errs[nzchar(errs)]; \
              for (p in names(bad)) message('CANNOT LOAD ', p, ': ', bad[[p]]); \
              if (length(bad)) quit(status = 1)"

# PostgreSQL JDBC driver at BUILD time, so runs work offline (same as etl).
ENV DATABASECONNECTOR_JAR_FOLDER=/opt/jdbc
RUN mkdir -p /opt/jdbc \
  && R -q -e "DatabaseConnector::downloadJdbcDrivers('postgresql', pathToDriver = '/opt/jdbc')"

# Unprivileged user LAST: everything above needed root to install.
RUN useradd --create-home analytics
USER analytics
WORKDIR /app

# No default analysis: you always say which script and which study to run.
CMD ["Rscript", "-e", "cat('Usage: docker compose --profile analytics run --rm -e STUDY=<name> analytics Rscript /app/run_<tool>.R\\n')"]
