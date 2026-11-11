/**
 * 01_schemas.sql
 *
 * Runs ONCE when the omop-pgdata volume is first created.
 * To rerun it: docker compose down -v (this deletes all data).
 *
 * synthea → raw Synthea CSV staging (ETL-Synthea writes here)
 * cdm     → OMOP CDM 5.4 tables + Athena vocabulary
 * results → Achilles / Atlas results + our validation output
 */
CREATE SCHEMA IF NOT EXISTS synthea;
CREATE SCHEMA IF NOT EXISTS cdm;
CREATE SCHEMA IF NOT EXISTS results;
