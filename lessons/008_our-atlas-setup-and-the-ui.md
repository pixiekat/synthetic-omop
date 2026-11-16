# Lesson 008: Our ATLAS Setup and the UI, End to End

| | |
|---|---|
| **Course level** | First to second year undergraduate |
| **Estimated time** | 90 minutes (lecture + tracing lab) |
| **Prerequisites** | Lessons 001 (containers, networks, volumes), 006 and 007 |
| **Project files** | `compose.yaml` (profile `atlas`), `services/atlas/nginx.conf`, `services/atlas/sql/01_roles_and_schemas.sql`, `services/atlas/sql/02_register_source.sql`, `services/etl/run_achilles.R`, README Step 9 |
| **Previous lesson** | 007: ATLAS Deep Dive |

> **Port:** the examples use `8080`, the default `ATLAS_PORT`. The pilot machine uses `8086`;
> substitute your own value everywhere.

## Learning objectives

By the end of this lesson you should be able to:

1. Draw our ATLAS stack (containers, network, schemas, roles) from memory, and say why each piece exists.
2. Follow one click in the ATLAS UI all the way to the database table it reads or writes.
3. Explain the **two** database jobs WebAPI does, and which settings control each.
4. Use browser DevTools, `curl` and SQL to see what's happening inside a running system.
5. Diagnose a failure by **layer** (browser, proxy, WebAPI, database, R image) using the stories from this project's own setup.
6. Back up and restore the work people do in ATLAS.

---

## 1. The stack we built

```
 Host (your machine)
 │
 │  127.0.0.1:8080 (ATLAS_PORT)
 ▼
 ┌─────────────── Docker network: synthetic-omop_default ───────────────┐
 │                                                                       │
 │  atlas-proxy (nginx:1.27-alpine)                                      │
 │    /          → 302 to /atlas/                                        │
 │    /atlas/    → atlas:8080     ohdsi/atlas:2.15.0   (static files)    │
 │    /WebAPI/   → webapi:8080    ohdsi/webapi:2.15.1  (Java, Spring)    │
 │                                    │                                  │
 │                                    │ JDBC as ohdsi_app                │
 │                                    ▼                                  │
 │  omop-db (postgres:16)   database synthetic_concurrent                │
 │    ├── webapi   owner ohdsi_app   WebAPI's own tables (Flyway)        │
 │    ├── cdm      read-only         OMOP + vocabulary (Step 7)          │
 │    ├── results  read + write      cohorts, Achilles, hierarchy        │
 │    ├── temp     owner ohdsi_app   scratch during generation           │
 │    └── synthea  (not used by ATLAS) raw staging                       │
 │                                                                       │
 │  etl (one-shot, profile etl)  runs run_achilles.R as omop_admin       │
 └───────────────────────────────────────────────────────────────────────┘
 Volume omop-pgdata holds ALL schemas, including your ATLAS work.
```

### Why each piece exists

| Piece | Why it's there | What breaks without it |
|---|---|---|
| **atlas-proxy** | Puts ATLAS and WebAPI on **one origin**, so the browser never makes cross-origin calls | CORS errors; ATLAS "cannot connect to WebAPI" |
| **atlas** container | Serves the JavaScript app. It does no work of its own | No UI |
| **webapi** | The only thing that talks to the database | Everything |
| **`webapi` schema** | WebAPI's memory: your definitions, sources, job history | WebAPI won't start (Flyway fails) |
| **`ohdsi_app` role** | Least privilege: can read `cdm`, can't change it | n/a (it's a safety feature) |
| **source + daimons** | Tells WebAPI *where* the CDM is and which schema does what | ATLAS shows no data sources |
| **results DDL** | Tables cohort generation and reports write into | Generation fails |
| **Achilles** | Pre-computes Data Sources and RC/DRC | Empty reports, no record counts |

---

## 2. WebAPI's two database jobs

This confuses almost everyone the first time, and it's a common question on the OHDSI forums.
WebAPI connects to databases **for two different reasons**:

| Job | Configured by | Points at | In our setup |
|---|---|---|---|
| **1. Its own bookkeeping** | `DATASOURCE_*` and `FLYWAY_*` env vars in `compose.yaml` | Where WebAPI stores definitions, users, jobs | `omop-db`, schema `webapi` |
| **2. Querying a CDM** | Rows in `webapi.source` and `webapi.source_daimon` (script 02) | Each CDM you can analyse; can be many | `omop-db`, schemas `cdm` / `results` / `temp` |

In larger deployments these are often *different servers*: one small Postgres for WebAPI,
several big CDMs elsewhere. We put both on `omop-db` to keep things simple, but keep the
two jobs separate in your head. That's why there are two setup scripts.

### Flyway: a database that upgrades itself

On first start, WebAPI's **Flyway** runs every migration script in its jar against the empty
`webapi` schema, and records each one in `webapi.schema_history`. On the next start, it only
runs migrations that aren't recorded yet. That's how a WebAPI upgrade (say 2.15 → 2.16)
upgrades its tables without you writing SQL.

```sql
-- How many migrations has Flyway applied, and what was the last?
SELECT COUNT(*), MAX(installed_on) FROM webapi.schema_history;
SELECT version, description FROM webapi.schema_history ORDER BY installed_rank DESC LIMIT 5;
```

### Daimons: one source, four roles

| `daimon_type` | Role | Our schema | Used for |
|---|---|---|---|
| 0 | CDM | `cdm` | Event tables cohorts are built from |
| 1 | Vocabulary | `cdm` | Concept search, concept-set resolution |
| 2 | Results | `results` | Cohort output, Achilles reports |
| 5 | Temp | `temp` | Intermediate tables during generation |

---

## 3. Following a click: UI → endpoint → table

Every screen in ATLAS is a set of HTTP calls to WebAPI. The table below is the map. **Verify
it yourself** in the lab with DevTools: endpoint paths are how the system really works, and
reading them beats memorising them.

| You do this in ATLAS | ATLAS calls (typical WebAPI 2.x path) | WebAPI reads/writes |
|---|---|---|
| Open ATLAS | `GET /WebAPI/info`, `GET /WebAPI/source/sources` | `webapi.source`, `webapi.source_daimon` |
| Search a term | `GET /WebAPI/vocabulary/SYNTH_OMOP/search/…` | `cdm.concept` (+ `results.achilles_result_concept_count` for RC/DRC) |
| Open a concept's hierarchy | `GET /WebAPI/vocabulary/SYNTH_OMOP/concept/{id}/related` | `cdm.concept_ancestor`, `cdm.concept_relationship` |
| Save a concept set | `POST`/`PUT /WebAPI/conceptset/…` | `webapi.concept_set`, `webapi.concept_set_item` |
| Save a cohort definition | `POST`/`PUT /WebAPI/cohortdefinition/…` | `webapi.cohort_definition`, `webapi.cohort_definition_details` (the JSON) |
| Press **Generate** | `GET /WebAPI/cohortdefinition/{id}/generate/SYNTH_OMOP` | Starts a **job** → `webapi.batch_job_execution`; writes `results.cohort*`; status in `webapi.cohort_generation_info` |
| Open **Jobs** | `GET /WebAPI/job/…` | `webapi.batch_job_*` (Spring Batch tables, prefix from `SPRING_BATCH_REPOSITORY_TABLEPREFIX`) |
| Data Sources dashboard | `GET /WebAPI/cdmresults/SYNTH_OMOP/dashboard` | `results.achilles_results`, `results.achilles_results_dist` |
| Profiles | `GET /WebAPI/{sourceKey}/person/{personId}` | `cdm.*` event tables for one person |

Two patterns to notice:

- **Definitions live in `webapi`; results live in `results`.** Deleting `results.cohort` rows
  doesn't delete a definition; it just means you need to generate it again.
- **Generation is asynchronous.** The Generate button starts a background job and returns
  straight away. The UI then *polls* for status. A slow generation is a running job, not a
  frozen page.

---

## 4. Caches: why "I fixed it" sometimes doesn't show

WebAPI caches some things in memory for speed, which surprised us twice during setup:

| Cache | Filled | Goes stale when | Refresh |
|---|---|---|---|
| Source list | At startup | You run script 02 | Restart WebAPI, or ATLAS **Configuration** → *Clear Configuration Cache* |
| Data Sources reports | First view | Achilles reruns | Same |
| Browser (ATLAS app) | Page load | ATLAS image changes | Hard refresh (Ctrl+Shift+R) |

The rule of thumb: **after changing anything WebAPI reads at startup, restart WebAPI.**

---

## 5. Case studies: what actually went wrong during setup

These all happened while setting up this project's pilot. Each failure belongs to one
**layer**, and the fix was found by asking "which layer is this?" first.

### Case 1: "the password is 0 characters" (layer: Compose configuration)

`01_roles_and_schemas.sql` kept reporting an empty `OHDSI_APP_PASSWORD`, even after recreating
the container. Three probes split the problem by layer:

| Probe | Layer it tests | Result |
|---|---|---|
| `grep '^OHDSI_APP_PASSWORD=' .env` | The file Compose reads | 48 characters ✔ |
| `docker compose config \| grep OHDSI_APP_PASSWORD` | What Compose **resolves** | Nothing ✘ |
| `docker compose exec omop-db sh -c 'echo ${#OHDSI_APP_PASSWORD}'` | What the container **sees** | 0 ✘ |

The break was between layers 1 and 2: the variable was in `.env`, but the running
`compose.yaml` didn't have the new line under `omop-db` (it was only in the README's copy).
Two lessons:

- **Documentation drift.** The README and the real file diverged. Any time you copy
  configuration out of a document, diff it afterwards.
- **Silent defaults hide errors.** `${OHDSI_APP_PASSWORD:-}` turns "missing" into "empty"
  without complaint. The script's guard caught it, which is why guards belong at the boundary.

A related clue: `docker compose up -d omop-db` said **Running**, not **Recreated**. Compose only
recreates a container when its resolved configuration changes, so "Running" meant Compose saw
no change.

### Case 2: "there is no package called 'Achilles'" (layer: image build)

The image built "successfully" in 475 seconds, and then had no Achilles in it. Two causes
stacked up:

1. `R -q -e "install…()"` **exits 0 even when the install fails**: R prints a warning, Docker
   sees success. The fix was to make the build check its own result:
   `if (!requireNamespace('Achilles', quietly = TRUE)) quit(status = 1)`.
2. The Achilles line wasn't in the Dockerfile being built. And it must come **before**
   `USER etl`, because an unprivileged user can't write to R's system library.

Lesson: **a green build only means every command's exit code was 0.** Check the thing you
actually wanted (here, that the package loads), not the step that was meant to produce it.

### Case 3: a port that wasn't 8080 (layer: host)

The pilot machine already used 8080, so `ATLAS_PORT=8086`. Because `WEBAPI_URL` and
`SECURITY_ORIGIN` are built from `ATLAS_PORT` in `compose.yaml`, ATLAS kept working. Only the
`curl` commands in the README needed the new port. Deriving values from **one** variable is the
DRY principle protecting you.

### A layer checklist for next time

| Symptom appears in … | Look first at … | Tool |
|---|---|---|
| The browser (banner, blank page) | Is WebAPI up? Is the URL right? | DevTools → Network; `curl …/WebAPI/info` |
| `curl` through the proxy (404, 502) | nginx routing; is the upstream container running? | `docker compose --profile atlas logs atlas-proxy` |
| WebAPI logs (exceptions) | Database login, schema, permissions | `docker compose --profile atlas logs webapi` |
| Database (permission denied) | Role grants (rerun 01) | `\dp`, `\dn+` in psql |
| A one-shot container (R error) | The image: was the package actually installed? | `docker compose run … Rscript -e "packageVersion('…')"` |

---

## 6. The UI, with accessibility in mind

ATLAS is a dense, data-heavy interface. A few habits make it easier for everyone, and
especially for colleagues who rely on zoom, keyboard navigation or screen readers:

- **Browser zoom** (Ctrl/Cmd and +) works well in ATLAS; the layout reflows at 125–150%.
- **Name things descriptively.** "MHD adults, earliest dx, 365d prior obs (course)" is
  readable in lists and by screen readers; "cohort 7" isn't.
- **Use the description fields** on concept sets and cohorts: a one-sentence plain-language
  summary helps every reviewer, technical or not.
- **Export, then read as text.** The cohort definition's **Export** tab includes a
  human-readable text view (a printable summary; the exact label varies by version). It's often
  easier to review than the editor, and it can be pasted into documentation.
- **Don't rely on colour alone** when you build reports from ATLAS output: label series and
  states in words.

---

## 7. Protecting the work people do in ATLAS

Everything saved in ATLAS lives in the `webapi` schema, inside the `omop-pgdata` volume. So
`docker compose down -v` deletes it. In this setup there are no logins, so anyone with the port
can edit or delete anything.

| Protection | How |
|---|---|
| **Back up WebAPI's schema** (small, quick) | `docker compose exec -T omop-db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -n webapi -Fc' > backups/webapi-$(date +%F).dump` |
| **Export definitions to the repo** | Cohort → Export → JSON, saved in e.g. `docs/cohorts/` and reviewed like code |
| **Restore** | `pg_restore` into a fresh `webapi` schema *before* WebAPI starts (so Flyway sees its history) |
| **Add logins** | Move to Broadsea with a security provider (README 9g) before anyone else uses it |

`-T` matters in the `pg_dump` line: without it, Docker allocates a terminal that can corrupt
binary output (the same reason we used it for copying the Synthea jar).

---

## Lab: trace the system (50 minutes)

### Part 1: draw it (10 minutes)

Without looking, draw section 1's diagram: containers, ports, schemas, roles. Then compare
and correct it. Label every arrow with the protocol (HTTP, JDBC) and the user/role.

### Part 2: talk to WebAPI directly (10 minutes)

```bash
curl -s http://localhost:8080/WebAPI/info; echo
curl -s http://localhost:8080/WebAPI/source/sources; echo
curl -s http://localhost:8080/WebAPI/cohortdefinition/ | head -c 600; echo
```

1. Which version does `/info` report? Does it match `WEBAPI_VERSION` in `.env`?
2. In `/source/sources`, find the daimons. Do they match section 2's table?
3. Your cohorts from Lesson 007: which IDs do they have?

### Part 3: watch the browser (15 minutes)

1. Open ATLAS, then DevTools (F12) → **Network**, filter by `WebAPI`.
2. Search for `depressive disorder`. Write down the request URL and method.
3. Open a cohort definition and press **Generate**. List the requests that follow. Which one
   starts the job, and which ones poll for status?
4. Fill in section 3's table with *your* observed paths. Note any differences.

### Part 4: find it in the database (10 minutes)

```sql
-- Your saved definitions (the JSON is in cohort_definition_details.expression)
SELECT id, name, created_date FROM webapi.cohort_definition ORDER BY id;

-- Generation history for each source
SELECT * FROM webapi.cohort_generation_info ORDER BY start_time DESC LIMIT 5;

-- The rows a generation produced
SELECT cohort_definition_id, COUNT(*) AS rows, COUNT(DISTINCT subject_id) AS persons
  FROM results.cohort GROUP BY 1 ORDER BY 1;
```

If a column name differs in your WebAPI version, `\d webapi.cohort_generation_info` shows the
real ones. Looking something up beats guessing.

### Part 5: break it on purpose (5 minutes, optional)

1. `docker compose --profile atlas stop webapi`. Reload ATLAS. What do you see, and in which layer?
2. `docker compose --profile atlas start webapi`. How long until ATLAS works again? (Watch `/info`.)

---

## Check your understanding

1. Name WebAPI's two database jobs and the settings that control each.
2. Why does `WEBAPI_URL` say `localhost` and not `webapi`?
3. You ran script 02, but ATLAS shows no data source. What's the most likely reason, and the fix?
4. Why can `ohdsi_app` write to `results` but not `cdm`? What would go wrong if it could write to `cdm`?
5. In Case 1, which probe located the break, and why were three probes better than one?
6. Why does a green Docker build not prove Achilles is installed?
7. What does `docker compose down -v` delete that you might not expect?

<details>
<summary><strong>Answers</strong></summary>

1. (a) Its own bookkeeping in schema `webapi`, controlled by `DATASOURCE_*`/`FLYWAY_*` env
   vars; (b) querying CDMs, controlled by rows in `webapi.source`/`source_daimon` (script 02).
2. The browser resolves it, not a container. `webapi` only exists on the Docker network; the
   browser runs on the host and reaches WebAPI through the proxy at `localhost:8080`.
3. WebAPI caches its source list at startup. Restart WebAPI, or clear the configuration cache
   in ATLAS.
4. Least privilege: ATLAS needs to write cohorts and reports (`results`), never clinical data.
   With write access to `cdm`, a bug or a wrong click could change the data the ETL loaded, and
   every count since Lesson 005 would be suspect.
5. `docker compose config` (the second probe): `.env` was right, and Compose's resolved config
   was missing it. Three probes, one per layer, show *where* the value is lost rather than just
   *that* it's lost.
6. A build is green when every command exits 0, and `R -e "install…"` exits 0 even when the
   install fails. Only a check that the package loads proves it's there.
7. The `webapi` schema too: every concept set, cohort definition and generation saved in ATLAS.

</details>

---

## Key terms

| Term | One-line definition |
|---|---|
| **Reverse proxy** | A server (nginx) that forwards requests to other services, here giving ATLAS and WebAPI one origin |
| **Origin / CORS** | Scheme + host + port; browsers restrict calls between different origins unless the server allows them |
| **Flyway** | Database-migration tool WebAPI uses to create and upgrade its own schema |
| **Source / daimon** | A CDM WebAPI can query / the role a schema plays in it |
| **Spring Batch job** | WebAPI's background-job mechanism (cohort generation runs as one) |
| **Least privilege** | Give each role only the access its job needs |
| **Documentation drift** | When the docs and the real configuration silently diverge |
| **Layered diagnosis** | Locating a failure by testing each layer in turn |

---

## Further reading

- **WebAPI wiki**, CDM configuration (sources, daimons, results DDL): <https://github.com/OHDSI/WebAPI/wiki/CDM-Configuration>
- **WebAPI source code** (find the endpoints in `src/main/java/org/ohdsi/webapi/service/`): <https://github.com/OHDSI/WebAPI>
- **Broadsea**, for the multi-user, logged-in version of this stack: <https://github.com/OHDSI/Broadsea>
- **Flyway concepts**: <https://documentation.red-gate.com/fd/migrations-184127470.html>
- **MDN: CORS explained**: <https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS>
- **nginx reverse proxy guide**: <https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/>
- **Docker Compose, variable interpolation** (why `:-` hides missing values): <https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/>
