/**
 * 01_roles_and_schemas.sql: prepare omop-db for WebAPI/Atlas (Step 9b)
 *
 * Run BEFORE the first WebAPI start, as the admin role. Safe to rerun: every
 * statement checks first or is idempotent, and the password is re-applied each
 * time (so rotating OHDSI_APP_PASSWORD in .env just means rerunning this).
 *
 * What it creates
 *   role   ohdsi_app   Least-privilege login used by WebAPI for BOTH of its jobs:
 *                      (1) its own application tables (schema webapi), and
 *                      (2) querying our CDM as a registered "source".
 *   schema webapi      WebAPI's own tables. Created EMPTY here; WebAPI's Flyway
 *                      migrations fill it on first start.
 *   schema temp        Scratch space WebAPI uses while generating cohorts.
 *
 * What ohdsi_app can do
 *   cdm      read only    (the ETL, as the admin role, stays the only writer)
 *   results  read + write (cohort generation, Achilles reports)
 *   webapi   owner
 *   temp     owner
 *
 * Invocation (from the project root; variables come from omop-db's environment):
 *
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
 *     -v admin_role="$POSTGRES_USER" -v app_pw="$OHDSI_APP_PASSWORD"' \
 *     < services/atlas/sql/01_roles_and_schemas.sql
 *
 * psql variable syntax used below:
 *   :'var'  → the value as a quoted SQL literal   ('s3cret')
 *   :"var"  → the value as a quoted identifier    ("omop_admin")
 *
 * @see https://www.postgresql.org/docs/16/app-psql.html#APP-PSQL-INTERPOLATION
 */

-- ---------------------------------------------------------------------------
-- Guard rails: fail loudly on a missing or URL-unsafe password.
-- The password ends up inside a JDBC URL (02_register_source.sql), where
-- characters like @ : / ? & # would break parsing, so we require a plain
-- alphanumeric password (make it long instead of "complex").
-- ---------------------------------------------------------------------------
SELECT length(:'app_pw') >= 16                AS pw_long_enough,
       :'app_pw' ~ '^[A-Za-z0-9_-]+$'         AS pw_url_safe
\gset

\if :pw_long_enough
\else
  \echo 'ERROR: OHDSI_APP_PASSWORD is empty or shorter than 16 characters. Set it in .env, then: docker compose up -d omop-db'
  DO $$ BEGIN RAISE EXCEPTION 'OHDSI_APP_PASSWORD too short'; END $$;
\endif

\if :pw_url_safe
\else
  \echo 'ERROR: OHDSI_APP_PASSWORD may only contain letters, digits, _ and - (it goes into a JDBC URL).'
  DO $$ BEGIN RAISE EXCEPTION 'OHDSI_APP_PASSWORD not URL-safe'; END $$;
\endif

-- ---------------------------------------------------------------------------
-- Role: create once, then (re)set the password every run.
-- ---------------------------------------------------------------------------
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ohdsi_app') AS need_role
\gset

\if :need_role
  CREATE ROLE ohdsi_app LOGIN;
  \echo 'Created role ohdsi_app.'
\else
  \echo 'Role ohdsi_app exists... skipping create.'
\endif

ALTER ROLE ohdsi_app WITH LOGIN PASSWORD :'app_pw';

-- ---------------------------------------------------------------------------
-- Schemas WebAPI owns.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS webapi AUTHORIZATION ohdsi_app;
CREATE SCHEMA IF NOT EXISTS temp   AUTHORIZATION ohdsi_app;

-- If the schemas already existed under another owner, hand them over.
ALTER SCHEMA webapi OWNER TO ohdsi_app;
ALTER SCHEMA temp   OWNER TO ohdsi_app;

-- ---------------------------------------------------------------------------
-- cdm: read only.
-- ---------------------------------------------------------------------------
GRANT USAGE  ON SCHEMA cdm                TO ohdsi_app;
GRANT SELECT ON ALL TABLES IN SCHEMA cdm  TO ohdsi_app;

-- Tables the admin creates in cdm LATER (e.g. a fresh ETL) get the same grant.
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_role" IN SCHEMA cdm
  GRANT SELECT ON TABLES TO ohdsi_app;

-- ---------------------------------------------------------------------------
-- results: read and write (cohort tables, Achilles output, concept hierarchy).
-- ---------------------------------------------------------------------------
GRANT USAGE, CREATE ON SCHEMA results                 TO ohdsi_app;
GRANT ALL ON ALL TABLES    IN SCHEMA results          TO ohdsi_app;
GRANT ALL ON ALL SEQUENCES IN SCHEMA results          TO ohdsi_app;

-- Covers tables made later by the admin: the results DDL (9d) and Achilles (9e).
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_role" IN SCHEMA results
  GRANT ALL ON TABLES    TO ohdsi_app;
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_role" IN SCHEMA results
  GRANT ALL ON SEQUENCES TO ohdsi_app;

\echo '01_roles_and_schemas.sql finished.'
