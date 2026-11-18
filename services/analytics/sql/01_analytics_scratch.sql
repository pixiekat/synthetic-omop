/**
 * 01_analytics_scratch.sql: scratch schema for analysis packages (Step 10b)
 *
 * Run once, as the admin role, AFTER services/atlas/sql/01_roles_and_schemas.sql
 * (which creates the ohdsi_app role). Safe to rerun.
 *
 * Why a separate schema?
 *   CohortContrast (via CDMConnector) needs a "write schema" for intermediate
 *   tables, and its docs describe that schema as temporary ("will be
 *   deleted"). So it gets its own throwaway schema. It must never be WebAPI's
 *   temp schema, and never cdm or results. Emptying or dropping it can't
 *   hurt anything else.
 *
 * Invocation:
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < services/analytics/sql/01_analytics_scratch.sql
 */

-- Fail clearly if Step 9b hasn't been run yet.
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ohdsi_app') AS have_role
\gset
\if :have_role
\else
  \echo 'ERROR: role ohdsi_app does not exist. Run services/atlas/sql/01_roles_and_schemas.sql first (Step 9b).'
  DO $$ BEGIN RAISE EXCEPTION 'ohdsi_app missing'; END $$;
\endif

CREATE SCHEMA IF NOT EXISTS analytics_scratch AUTHORIZATION ohdsi_app;
ALTER SCHEMA analytics_scratch OWNER TO ohdsi_app;

-- The analyses read ATLAS cohort NAMES from webapi.cohort_definition.
-- ohdsi_app already owns the webapi schema, so no extra grant is needed;
-- this check just makes that assumption visible.
SELECT has_schema_privilege('ohdsi_app', 'webapi', 'USAGE')  AS can_read_webapi,
       has_schema_privilege('ohdsi_app', 'cdm', 'USAGE')     AS can_read_cdm,
       has_schema_privilege('ohdsi_app', 'results', 'USAGE') AS can_read_results;

\echo '01_analytics_scratch.sql finished.'
