/**
 * 02_register_source.sql: tell WebAPI where our CDM lives (Step 9c)
 *
 * Run AFTER WebAPI has started once (its Flyway migrations create the
 * webapi.source and webapi.source_daimon tables this script writes to).
 * Safe to rerun: inserts only what's missing, and refreshes the connection
 * string each time (picks up a rotated OHDSI_APP_PASSWORD).
 *
 * Concepts
 *   source  One database WebAPI can query, identified by source_key.
 *   daimon  Tells WebAPI which SCHEMA plays which ROLE inside that source:
 *
 *     daimon_type  meaning      our schema   priority*
 *     -----------  -----------  -----------  ---------
 *     0            CDM          cdm          0
 *     1            Vocabulary   cdm          1
 *     2            Results      results      1
 *     5            Temp         temp         0
 *
 *   * With several sources, the highest-priority Vocabulary/Results daimon is
 *     the default Atlas uses for concept search and reports.
 *
 * Invocation:
 *
 *   docker compose exec -T omop-db sh -c 'psql -v ON_ERROR_STOP=1 \
 *     -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
 *     -v db_name="$POSTGRES_DB" -v app_pw="$OHDSI_APP_PASSWORD"' \
 *     < services/atlas/sql/02_register_source.sql
 *
 * Then restart WebAPI so it reloads its source list:
 *   docker compose --profile atlas restart webapi
 *
 * @see https://github.com/OHDSI/WebAPI/wiki/CDM-Configuration
 */

\set source_key  'SYNTH_OMOP'
\set source_name 'Synthetic Concurrent Disorders (local)'

-- Fail early, with a clear message, if WebAPI hasn't created its tables yet.
SELECT to_regclass('webapi.source') IS NOT NULL AS webapi_ready
\gset
\if :webapi_ready
\else
  \echo 'ERROR: webapi.source does not exist yet. Start WebAPI and wait for /WebAPI/info first (Step 9b).'
  DO $$ BEGIN RAISE EXCEPTION 'WebAPI tables missing'; END $$;
\endif

BEGIN;

-- ---------------------------------------------------------------------------
-- The source row. The JDBC URL uses the Compose service name "omop-db" and the
-- INTERNAL port 5432: WebAPI connects container-to-container, not via the host.
-- ---------------------------------------------------------------------------
INSERT INTO webapi.source (source_id, source_name, source_key, source_connection, source_dialect)
SELECT nextval('webapi.source_sequence'), :'source_name', :'source_key', 'placeholder', 'postgresql'
 WHERE NOT EXISTS (SELECT 1 FROM webapi.source WHERE source_key = :'source_key');

-- Always (re)write the connection, so a password change only needs a rerun.
UPDATE webapi.source
   SET source_name       = :'source_name',
       source_connection = 'jdbc:postgresql://omop-db:5432/' || :'db_name'
                           || '?user=ohdsi_app&password=' || :'app_pw'
 WHERE source_key = :'source_key';

-- ---------------------------------------------------------------------------
-- The daimons, one row per (source, daimon_type), inserted only if missing.
-- ---------------------------------------------------------------------------
INSERT INTO webapi.source_daimon (source_daimon_id, source_id, daimon_type, table_qualifier, priority)
SELECT nextval('webapi.source_daimon_sequence'), s.source_id, d.daimon_type, d.table_qualifier, d.priority
  FROM webapi.source s
 CROSS JOIN (VALUES (0, 'cdm',     0),
                    (1, 'cdm',     1),
                    (2, 'results', 1),
                    (5, 'temp',    0)) AS d(daimon_type, table_qualifier, priority)
 WHERE s.source_key = :'source_key'
   AND NOT EXISTS (SELECT 1
                     FROM webapi.source_daimon sd
                    WHERE sd.source_id   = s.source_id
                      AND sd.daimon_type = d.daimon_type);

COMMIT;

-- ---------------------------------------------------------------------------
-- Show the result (password hidden) so it lands in your terminal scrollback.
-- ---------------------------------------------------------------------------
SELECT s.source_id, s.source_key, s.source_name,
       regexp_replace(s.source_connection, 'password=[^&]*', 'password=***') AS source_connection,
       sd.daimon_type, sd.table_qualifier, sd.priority
  FROM webapi.source s
  JOIN webapi.source_daimon sd USING (source_id)
 WHERE s.source_key = :'source_key'
 ORDER BY sd.daimon_type;
