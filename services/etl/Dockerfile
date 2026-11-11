# R + Java (DatabaseConnector talks to Postgres via JDBC, so it needs rJava).
FROM rocker/r-ver:4.4.2

# System dependencies: JDK for rJava, plus build headers for R packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
      default-jdk libxml2-dev libssl-dev libcurl4-openssl-dev \
  && R CMD javareconf \
  && rm -rf /var/lib/apt/lists/*

# Pin ETL-Synthea to a COMMIT SHA once one works (reproducibility).
ARG ETL_SYNTHEA_REF=main
RUN R -q -e "install.packages(c('remotes','DatabaseConnector','SqlRender'), repos='https://cloud.r-project.org')" \
  && R -q -e "remotes::install_github('OHDSI/ETL-Synthea', ref='${ETL_SYNTHEA_REF}', upgrade='never')" \
  && R -q -e "remotes::install_github('OHDSI/DataQualityDashboard', upgrade='never')"

# Download the Postgres JDBC driver at BUILD time so runs work offline.
ENV DATABASECONNECTOR_JAR_FOLDER=/opt/jdbc
RUN mkdir -p /opt/jdbc \
  && R -q -e "DatabaseConnector::downloadJdbcDrivers('postgresql', pathToDriver='/opt/jdbc')"

RUN useradd --create-home etl
USER etl
WORKDIR /app
CMD ["Rscript", "/app/run_etl.R"]
