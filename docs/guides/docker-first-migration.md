# Docker-first gateway and project-local database migration

This guide is for the owner migrating WRAP, ELCC Data Management, Travel Authorization, or Traditional Knowledge development worktrees. It describes proposed consumer changes, not completed adoption. Start with the [four developer UX examples](consumer-developer-examples.md) for the current source-backed command and configuration contracts, including Traditional Knowledge. No consumer compatibility, data restore, network recovery, or RAM saving is established by reading source. Keep production Compose and externally managed production databases outside this migration.

There are two independent cutovers:

1. **Gateway packaging:** replace the machine-wide gateway installation with the self-contained Docker router image. Database ownership and checkout data do not change. Packaging alone does not materially reduce RAM.
2. **Project-local database pooling:** replace repeated database server processes across a project's worktrees with project-owned shared servers. Each checkout retains separate development and test databases and restricted credentials. This is the source of potential RAM reduction; measure it before acceptance.

Never share a database engine between projects. A project server restart or resource limit affects every worktree using it. Application, cache, mail, search, and default-network isolation remain checkout concerns.

## Source baseline and adoption status

The consumer inventory below was read from these local source revisions. Recheck the named owners against the revision selected for a consumer migration PR; local uncommitted changes may also affect a checkout.

| Consumer | Inspected HEAD |
| --- | --- |
| `icefoganalytics/wrap` | `67883eb5612162b8bd67541dfd522148f70e24b1` |
| `icefoganalytics/elcc-data-management` | `474b622cc9cec8f4abb10bd20450e654b275f652` |
| `icefoganalytics/travel-authorization` | `5966448cb387227fa9d7c51b42da4906d0ccc85d` |

The generic [shared-database example](../../examples/shared-databases/README.md) demonstrates the isolation contract using SQL Server 2022 and PostgreSQL 17. It is not a drop-in consumer deployment: WRAP requires a newer full-text-enabled engine, ELCC currently uses SQL Server 2019, and Travel currently uses PostgreSQL 14.4 plus two different SQL Server versions. Consumer engine upgrades require independent restore and behavior evidence.

## Downstream complexity acceptance

Do not replace a consumer's wrapper with a shared-database management CLI. The example keeps only ordinary application command methods and Compose delegation in `bin/dev`. Server startup uses native Compose; the separate project-owner `bin/provision CHECKOUT_NAME` operation selects an internal adapter using `DB_ENGINE`. Shared checkout validation and environment naming are engine-neutral; native clients and permission SQL live inside `provisioning/postgres` and `provisioning/sqlserver`. Engine-specific administration does not enter the consumer command dispatcher or gateway runtime. Development/test connection overrides remain visible in Compose, and migrations/test reset remain application-owned.

For an ELCC-shaped adoption, the intended responsibility delta is:

| Existing owner | Consumer change | Remaining responsibility |
| --- | --- | --- |
| `bin/dev` command methods and Compose delegation | Retain; do not add engine/group dispatch or database deletion commands | Normal application workflow |
| Gateway calls around `up`, `down`, and `run` | Update to the coordinated lifecycle contract; preserve editor-bridge hooks | First-use startup and last-consumer shutdown |
| Checkout `db` service and dependencies on it | Replace with a project-server connection and external network | Project owner starts and maintains the server |
| Administrator-powered application database creation | Remove after explicit database/login provisioning is established | One project-owned provisioning operation per checkout |
| Application migrations and test setup | Retain against separate restricted development/test connections | Consumer owns schema and test cleanup |
| Backup/restore and destructive reset commands | Retarget existing owners, never add parallel generic helpers | Explicit database selection and neighbor-preservation proof |

This is an adoption design, not an applied consumer diff. Sharing reduces repeated server processes but introduces coordinated server maintenance and provisioning. Accept the downstream PR only after reviewing its actual removed/added responsibilities and exercising its existing developer commands. A smaller example file or lower synthetic RAM measurement alone does not establish net downstream simplification.

## A. Swap only the machine-wide gateway

Follow [Docker installation](docker-installation.md) for the local draft build, image transfer, single-file Compose installation, native start/stop commands, and release prerequisites. Require Docker Engine and Compose **2.20.2 or newer**. The default image `ghcr.io/icefoganalytics/local-development-gateway/database-router:0.4.0` is prospective: build that tag locally for draft evaluation; do not assume a published registry image exists. `LOCAL_DEVELOPMENT_GATEWAY_IMAGE` selects an alternate image. The installed router needs no host Ruby library/configuration mounts or runtime source checkout.

Inventory the previous installation's Compose project, containers, image/version labels, port bindings, network ownership, lifecycle caller, and saved Compose file. Save its configuration and image references for rollback. Do not start a second pair on occupied loopback ports 80, 1433, and 5432. Replacing the running machine-wide pair requires coordinated downtime; authorization alone is not evidence that active consumers can tolerate interruption. Preserve `local-gateway` while consumers are attached and leave database volumes alone.

Use **one coordinated lifecycle contract** in every cooperating wrapper. The historical consumer baselines below select gateway gem **0.2.2**. Leaving their existing hooks on that gem is not safe adoption: when no ready gateway exists, it can recreate its bundled bind-mounted installation and bypass the candidate's synchronization.

Update each consumer's existing Gemfile/lock owner to the candidate implementation for isolated evaluation, or the matching released gem after publication is established. Retain `LocalDevelopmentGateway.with_running` around a waiting `up` command and use `with_running(ensure_running: false)` around waiting `down`/`stop` commands. Preserve editor-bridge nesting and command dispatch. Do not `exec` out of the block. Long-running commands retain a pending-operation lock without serializing other checkouts' commands.

Label shared database containers `local-gateway.lifecycle: passive`, and label active app/job/test services `local-gateway.lifecycle: consumer`, including services on private networks only. Unknown attached containers keep the gateway alive. After the final consumer disappears, guarded cleanup stops only the routers and preserves their network, idle databases, and data. For desktop-only access use a named hold. See [lifecycle ownership](../architecture/gateway-lifecycle.md).

Do not add a second manager around retained hooks or remove automatic startup from the normal developer path. Consumer wrappers still need Ruby for other duties; Docker-only router installation does not make those wrappers Ruby-free. Explicit native Compose operation remains available for machine owners, but bypasses the guard. Existing aliases from gem 0.2.2 are not proof of the candidate's alias derivation: validate host resolution and each selected route explicitly.

Before accepting the gateway swap, verify image/version labels, health, HTTP routes, SQL Server/PostgreSQL client connections, and existing TLS/cancellation behavior with disposable clients. Preserve the established loopback ports and network/labels. TCP health alone is not protocol evidence.

**Gateway rollback:** stop only the new pair using its recorded owner, leaving database containers, consumer networks, and volumes intact; restore the previous saved gateway configuration/image and start it through its original owner. Recheck routes. This rollback moves no database data and does not undo a database-pool migration.

## B. Common project-local database cutover

### Establish ownership and names first

For each project, give its shared-server Compose stack a stable project name distinct from every checkout's app stack. Keep the server's persistent volumes and private external network owned by that project. Checkout Compose files reference that network as external; checkout `down` must never stop the shared stack, remove its network, or delete its volumes. Shared-server shutdown is an explicit project-owner operation, coordinated with all worktrees, not an `ensure` block or automatic checkout cleanup.

Allocate a stable checkout key with a collision-resistant suffix rather than relying solely on branch-name sanitization. Use identifier-safe names such as `wrap_wt_a7c91_dev` and `wrap_wt_a7c91_test`, and record their mapping to the actual checkout. Allocate distinct restricted development and test credentials. Repeat for every Travel source database as well. Restrict each login to its assigned database; do not grant `sysadmin`, `dbcreator`, PostgreSQL `SUPERUSER`, or `CREATEDB` to applications. Database-scoped schema/migration and test-reset permissions may be needed; they must not permit access to another checkout or project. Keep administrative provisioning/restore credentials outside app environments and version control.

For PostgreSQL, database separation alone is insufficient because `PUBLIC` normally has `CONNECT`: revoke inappropriate public connection privileges and grant only the intended role, including any intentionally retained maintenance access. For SQL Server, avoid cross-database ownership chaining, trusted databases, and broad server roles. After restore, remap users to the intended scoped logins and remove copied administrative or unrelated application access.

### Change the consumer's existing owners once

Edit the consumer's development Compose and existing `bin/dev` configuration assembly, rather than adding a competing wrapper or asking developers to stack extra flags manually:

- Put the private shared-network attachment and connection configuration on **both** development and `test_api` paths. Include jobs and source integrations where present. A gateway overlay may not be loaded for tests, `run`, migrations, or backup commands; it cannot be the only owner of private database reachability.
- Replace fixed development/test names and administrator credentials with checkout-scoped inputs. Existing literal `environment` values override `env_file`; merely adding a private env file will not replace them. Keep private values in ignored local configuration and pass them through the existing wrapper consistently, without printing secrets.
- Remove the checkout database service definitions and their `depends_on` edges from the development file, and remove their database-service stanzas from `docker-compose.development.gateway.yml`. Otherwise an overlay can resurrect an obsolete service or `up` can continue starting a second engine. Preserve old named volumes and their recorded names; removing a service definition is not permission to remove its data.
- Attach the project server, not each checkout's database, to `local-gateway` for desktop access. Give each server endpoint one project-owned hostname/driver/port label, unique across projects. Keep apps on the project's private network, using the stable server DNS alias directly. Keep HTTP routing labels on checkout apps unchanged. Do not advertise the same database hostname from multiple containers.
- Update the existing SQL console and import/export helpers to use the shared-server owner, explicit destination database, and correct scoped credentials. They must not infer a destination from `POSTGRES_DB` or a container's single development default. Keep one canonical implementation; retire the old `exec db` assumptions rather than wrapping them in another command layer.
- Pre-provision the exact databases administratively. Change automatic creation paths to validate a provisioned database and fail clearly if absent, rather than falling back to server-level creation or granting server administration to apps.

### Transfer data and prove isolation

1. Inventory all checkout volumes, engines/versions, collation/extensions/full-text requirements, database names, writers, and backup owners. Save old config, resolved nonsecret connection mappings, volume names, and backup paths. Do not mount an old data directory into a different engine version.
2. Stop the selected checkout's writers using its existing wrapper. Make a database-native backup of every development database that matters, including Travel source simulators when they contain useful data. Treat SQL Server backups and PostgreSQL dumps as sensitive data. Preserve the original volumes untouched.
3. Restore into **new, explicitly named** databases on the project servers, initially disconnected from apps. SQL Server restore needs explicit `WITH MOVE` destinations for every data/log file, verified from `RESTORE FILELISTONLY`; do not use a generic `REPLACE` against another checkout. PostgreSQL major-version migration uses a supported logical dump/restore path and version-compatible clients, not volume reuse. Validate row counts, migration history, expected text/search behavior, and scoped-user mappings before cutover.
4. Provision independent test databases and run their normal initializers/seeds/reset path with their test credentials. Do not copy development credentials into tests. Assert the connected server, database, and current principal before any reset; deny connection to another checkout's development and test databases. Pre-provisioning must work without server creation privileges.
5. Apply the consumer edits below and recreate only its app resources. Verify development access and a destructive test reset while another checkout retains a sentinel record and usable connection. Stop/down checkout A through its wrapper and prove checkout B and the project servers remain available. Record actual commands/results in the consumer PR; the generic example does not prove consumer adoption.
6. Measure equivalent workloads before and after: same number of worktrees, data, warm-up, query/test load, engine versions, and memory settings. Record process/container inventory plus repeated `docker stats --no-stream` samples covering **all** old/new DB, app, and gateway containers, and host available RAM. Report both total and database-only RAM and any throughput regression. Lowering a memory cap, omitting a source engine, or moving a process outside the measurement is not an equivalent saving. Require a measured reduction in total RAM; do not attribute it to image packaging.

Retain old volumes and backups until the project owner accepts the restore and rollback evidence. Only then schedule separately authorized retirement.

### Database-pool rollback

Stop the affected checkout's writers. If it has written to the new database, export those writes and restore to a compatible rollback destination or explicitly accept their loss before switching; the preserved old volume is a point-in-time snapshot, not a live replica. A SQL Server backup from a newer server cannot simply be restored to an older version. Establish a compatible logical transfer or retain a rollback server on the supported version before accepting an engine upgrade.

Restore the checkout's old development Compose/service/dependency and gateway-overlay configuration, previous restricted/default connection mapping as appropriate, and exact original volume attachment. Start it via the original wrapper, then validate data and test isolation. Do not stop a shared engine used by other checkouts. Do not delete pooled databases until their data is reconciled and their owner approves retirement. Gateway rollback is unnecessary unless the gateway itself failed.

## WRAP: full-text engine, jobs, and hard-coded rollback SQL

**Observed owners:** `docker-compose.development.yml`, `docker-compose.development.gateway.yml`, `db.Dockerfile`, `bin/dev`, `bin/lib/database/command.rb`, `bin/lib/development_environment/command.rb`, `api/src/config.ts`, `api/src/db/db-client.ts`, and `api/src/db/db-client-legacy.ts`.

- Development `api` and `jobs` inherit `AZURE_SQL_HOST`, `AZURE_SQL_USERNAME`, `AZURE_SQL_DATABASE`, `AZURE_SQL_PASSWORD`, and `AZURE_SQL_PORT`; trust uses `DB_TRUST_SERVER_CERTIFICATE`. The current host is `${COMPOSE_PROJECT_NAME}-db`, username is `sa`, and the development name is `${AZURE_SQL_DATABASE:-wrap_development}`. `test_api` overrides the name to literal `wrap_test`. Replace **all five connection fields** consistently for `api`, `jobs`, and `test_api`, with a distinct test database and login/password. Preserve the configured SQL TLS/trust behavior for local development; do not globally weaken production TLS.
- WRAP's environment guard rejects infrastructure-owned declarations in `api/.env.development`. Extend its existing ownership policy deliberately when introducing private database inputs, and run its documented `./bin/dev check-environment` in the consumer migration QA. Do not bypass the guard by scattering database overrides across files. The current database-name interpolation belongs to the host/root `.env`, not the API private env file.
- Test configuration needs a separate check: `api/src/config.ts` loads `api/.env.test` with dotenv `override: true`, so local declarations can replace Compose-selected test connections. The development environment guard does not inspect this ignored test file. Reconcile its declarations locally without exposing values, and assert the effective database identity and principal before initializers as well as destructive resets.
- `db.Dockerfile` builds `wrap-db:full-text` from **SQL Server 2025 CU7, Ubuntu 24.04**, installing `mssql-server-fts`. Preserve that engine capability and backup compatibility; SQL Server 2022 cannot restore a WRAP 2025 backup. Full-text support remains necessary for historical migration replay/rollback, not current runtime search: `20260812014500_create-workflow-search-documents-full-text-catalog.ts` creates the catalog/index; `20261020160018_retire-workflow-search-full-text-index-and-catalog.ts` retires them, and `20261020160020_retire-workflow-search-documents-table.ts` removes the table (all under `api/src/db/migrations`). Follow `docs/architecture/workflow-search.md`: verify historical replay/rollback on disposable data and current Elasticsearch indexing/search after restore, rather than expecting a surviving SQL full-text index.
- `api/src/db/migrations/20250414162002_increase-size-of-workflow-histories-subtitle-field-to-better-support-commenting.ts` has a `down` query against **`wrap_development.dbo.workflow_histories`**. The consumer owner must replace that cross-database reference with the connected database's table before permitting checkout-scoped rollback. Never grant a test login access to `wrap_development` to make this succeed. Audit remaining migrations/raw SQL against the selected consumer revision before adoption.
- Remove development `db`, `api/jobs/test_api` dependency edges to it, and the overlay's `db` TCP route stanza. Preserve `db_data` and its physical volume. Leave Redis, Elasticsearch, mail, and their dependencies alone. `ELASTICSEARCH_INDEX_PREFIX` defaults from `AZURE_SQL_DATABASE` in `api/src/config.ts`; changing the database name also changes that default search namespace. Plan index rebuilding/verification rather than assuming old indexed data follows the database restore.
- `./bin/dev db --export PATH` / `--import PATH` are implemented by `bin/lib/database/command.rb`. Today it discovers `db`, reads its `AZURE_SQL_DATABASE`, executes `BACKUP ... COPY_ONLY` and `RESTORE ... WITH MOVE, REPLACE`, copies a staged `.bak`, and uses `MSSQL_SA_PASSWORD`/`master`. Use the old export **before** removing `db`; stop API and jobs first. Rewrite this owner for explicit project-server and checkout-database selection with administrative operations isolated from app credentials. `bin/dev`'s `sqlcmd` also executes in `db`; migrate it with the same connection contract.
- Use `./bin/dev test api` or `./bin/dev test_api`, not `test-api`. The wrapper also owns `knex`, `migrate`, and `seed`. `api/tests/global-setup.mts` runs initializers; `api/src/initializers/10-ensure-database.ts` attempts server-level fallback/creation; `20-run-migrations.ts` and `30-run-seeds.ts` are the initialization owners. Pre-provision both databases and replace creation assumptions. `api/tests/support/clean-database.ts` disables constraints, deletes rows, and reseeds identities in the connected database: it must only receive the private test connection. Do not use `--skip-setup` for first migration acceptance.
- `bin/dev` loads the gateway overlay for `up`, but its common Compose assembly does not always load it. Keep the private network and dev/test database fields in the base development configuration. Apply the lifecycle choice in section A to this wrapper's `up`/`down` hooks and top-level gateway require; do not retain the 0.2.2 hooks unchanged or add a second gateway-start wrapper.

**Adoption gates:** full-text-capable 2025 server/restore, hard-coded migration correction, environment-owner update, jobs/test connection separation, backup/console retargeting, normal initializers and destructive reset isolation, and search namespace validation. None is established by this gateway draft.

## ELCC Data Management: SQL Server 2019 and base-file test configuration

**Observed owners:** `docker-compose.development.yaml` (note `.yaml`), optional `docker-compose.development.linux.yml`, `docker-compose.development.gateway.yml`, `bin/dev`, `api/src/config.ts`, `api/src/db/db-client.ts`, and `api/src/db/db-migration-client.ts`.

- Replace `DB_HOST`, `DB_USER`, `DB_NAME`, `DB_PASS`, and `DB_PORT` in the base development environment. Current values use `${COMPOSE_PROJECT_NAME}-db`, `sa`, and `elcc_development`; `test_api` hard-codes `elcc_test`. Supply an independent test login/password/name, keeping `DB_TRUST_SERVER_CERTIFICATE` appropriate to the local server. Changing only `api/.env.development` loses to the Compose literals.
- Current development SQL Server is **2019 CU28, Ubuntu 20.04**, not the base production Compose file's `2019-latest`. Select a project-owned supported image and test its restore; SQL Server 2022 is an upgrade, not a neutral packaging change. Preserve original `db_data`; do not attach it to the upgraded engine.
- Remove development `db`, `api` and `test_api` dependencies on it, and the overlay's obsolete `db` route. Put the external private-network attachment on `api` and `test_api` in the base development file so tests do not depend on gateway activation.
- `bin/dev#compose_file_options` combines the `.yaml` base, an optional Linux override, and the gateway overlay only when requested. Its `up` coordinates both `LocalDevelopmentGateway` and `OpenInEditorBridge`; `run` coordinates only the gateway. Apply section A's gateway ownership choice to `up`, `down`, and `run` and the top-level require; preserve the existing editor-bridge behavior. Update `dynamic_environment_variables` only as needed for checkout database inputs rather than introducing another wrapper. Preserve host UID/GID behavior.
- `bin/dev` owns `test api` (also `test_api`), `knex`, `migrate`, `seed`, `db`, and `sqlcmd`. The latter two currently `exec db`; retarget them to explicit shared-server/database connections. The observed `sqlcmd` uses `-H "$DB_HOST"` (workstation name), not `-S` server selection; do not copy that assumption into a remote/shared-server helper. Set server and port explicitly in the consumer fix.
- No export/import implementation was found in this wrapper. Add the project-owned native SQL Server backup/restore procedure to the existing database tooling before migration: explicit source/target names, privileged restore outside the app, `COPY_ONLY` backup, `RESTORE FILELISTONLY` and unique `WITH MOVE` files, then remap restricted users. Do not invent a working `./bin/dev db --export` command for ELCC.
- `api/tests/global-setup.ts` runs `npm run initializers`; `api/src/initializers/10-ensure-database.ts` has creation/fallback logic, `20-run-migrations.ts` runs Knex, and `30-run-seeds.ts` skips seeding entirely when `NODE_ENV` is `test`. Outside tests it selects environment seeds with `SKIP_SEEDING_UNLESS_EMPTY` behavior. Pre-provision and validate both databases, preserving that test seed policy. `api/tests/support/clean-database.ts` performs constraint disabling, deletion and identity reseeding. Execute that reset only against the new checkout test connection and prove a second checkout is intact. Do not use `--skip-setup` to hide provisioning failures.

**Adoption gates:** supported engine/restore decision, new canonical backup procedure, remote console targeting, dev/test credentials and network coverage, and initializers/reset isolation. Source inspection did not establish shared-engine compatibility.

## Travel Authorization: PostgreSQL plus two SQL Server source simulators

**Observed owners:** `docker-compose.development.yml`, `docker-compose.development.gateway.yml`, `bin/dev`, `bin/lib/database/command.rb`, `api/src/config.ts`, `api/src/db/db-client.ts`, and `api/src/integrations/{trav-com-integration,travel-port-integration}`.

| Connection family | Current development / test database | Current engine |
| --- | --- | --- |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_NAME` | `travel_development` / `travel_test` | PostgreSQL `14.4` |
| `TRAVCOM_DB_HOST`, `TRAVCOM_DB_PORT`, `TRAVCOM_DB_USER`, `TRAVCOM_DB_PASS`, `TRAVCOM_DB_NAME` | `trav_com_development` / `trav_com_test` | SQL Server `2022-CU14-ubuntu-22.04` |
| `TRAVELPORT_DB_HOST`, `TRAVELPORT_DB_PORT`, `TRAVELPORT_DB_USER`, `TRAVELPORT_DB_PASS`, `TRAVELPORT_DB_NAME` | `travelport_development` / `travelport_test` | SQL Server `2019-CU28-ubuntu-20.04`, `SQL_Latin1_General_CP1_CI_AS` collation |

- Pool each engine role **within Travel only** across its worktrees. Initially retain separate project-owned TravCom and Travelport SQL Server processes because the observed versions/collation differ. Consolidating those two roles further needs its own compatibility decision. Each checkout needs six independent databases and their scoped dev/test credentials, not just a renamed PostgreSQL database. Never point a development initializer or test reset at a real external production Travelport source.
- Set every field in all three connection families on both `api` and `test_api`; the SQL families also use `TRAVCOM_DB_TRUST_SERVER_CERTIFICATE_ENABLED` and `TRAVELPORT_DB_TRUST_SERVER_CERTIFICATE_ENABLED`. Current test names are Compose literals. The PostgreSQL `app` role is created through `POSTGRES_USER`, which creates a bootstrap superuser in the official image; its friendly name does not make it a restricted app role. The SQL source connections currently use `sa`. Replace all three with scoped credentials.
- Remove development `db`, `db_trav_com`, and `db_travelport`, their `api`/`test_api` dependency edges, and all three database route stanzas from the gateway overlay. Keep `db_data`, `db_trav_com_data`, and `db_travelport_data` preserved. Attach both app/test services to Travel's private external network. Advertise stable project-server routes rather than old checkout-specific `db.*`, `db-trav-com.*`, and `db-travelport.*` routes.
- `bin/dev#compose_file_options` currently includes the gateway overlay for development operations, plus an optional Linux override. Keep the private database contract in the base development file anyway: direct commands or future nongateway test configuration must not change which database is selected. Apply section A's lifecycle choice to `up`, `down`, `stop`, and `run` and the top-level gateway require. Preserve the editor bridge without adding another manager.
- `./bin/dev db --export PATH` exports only PostgreSQL via `pg_dump --format=custom`; `--import PATH` drops/recreates the database then runs `pg_restore --no-owner --exit-on-error --single-transaction`. These are development-only operations in `bin/lib/database/command.rb`, currently executed in `db` using `POSTGRES_USER`/`POSTGRES_DB`. Export before service removal. Rewrite this owner and `bin/dev#psql` to use an explicit shared endpoint/database and appropriately scoped role. Move administrative create/drop to provisioning rather than granting `CREATEDB` to the app. Preserve private backup permissions. Provide native SQL Server backups separately for useful TravCom and Travelport data; the PostgreSQL helper does not cover them.
- PostgreSQL 17 is a major upgrade from 14.4. Use logical dump/restore into a new volume and verify extensions/schema/migrations rather than reusing `db_data`. Keep the old 14.4 volume until rollback is accepted. Validate each SQL source's version/collation and restore independently.
- `api/src/initializers/10-create-database.ts` always connects to the maintenance database **`postgres`** to inspect/create `DB_NAME`. A role restricted to only its private database will not satisfy this as written. Change the initializer to validate the already provisioned target database instead of granting global maintenance access or database-creation privileges. The SQL integrations' `initializers/10-ensure-database.ts` also need their provisioned-target path validated under restricted credentials.
- Main initializers run migrations/seeds; `45-initialize-travel-port-development.ts` dispatches the local Travelport sequence, while both integrations own their own `initializers/20-run-migrations.ts` and `30-run-seeds.ts`. `api/tests/global-setup.ts` runs normal initializers. Keep synthetic-source creation and writable test seeding scoped to their corresponding private source databases; production Travelport's read-only source contract is different.
- `api/tests/support/clean-database.ts` truncates PostgreSQL tables with `RESTART IDENTITY CASCADE`; `clean-trav-com-database.ts` and `clean-travel-port-database.ts` disable SQL constraints, delete rows, and reseed identities. Review their callers and assert all three test database identities before destructive execution. `test_api` also mounts `api/.env.development` as `.env.test`; check this dotenv path alongside Compose precedence so no development or production source credential leaks into tests.
- Require positive database-state assertions, not successful command exits alone: `api/src/initializers/index.ts` catches initialization errors and exits zero; `clean-trav-com-database.ts` catches query failures and returns true. Verify expected migration history, seed records, and post-reset table contents in each target database, alongside untouched neighbor sentinels. Correct error propagation in those existing consumer owners before relying on them as migration acceptance checks.

**Adoption gates:** six-database provisioning, restricted PostgreSQL initializer behavior, both source-simulator reset/seed paths, three native backup/restore paths, PostgreSQL upgrade evidence if selected, and concurrent-checkout isolation. The generic two-engine proof does not establish these consumer behaviors.

## Desktop database clients after pooling

Select the **project shared-server hostname plus explicit checkout database**, not a per-checkout container hostname. SQL Server clients use the gateway's existing loopback port 1433; PostgreSQL clients use 5432. Use the appropriate project's scoped login, and set the database explicitly in every saved connection. A hostname chooses the server process, not the database or authorization boundary. For Travel, retain separate shared-server hostnames for PostgreSQL, TravCom SQL Server, and Travelport SQL Server. Retire obsolete checkout database routes only after saved clients and scripts are migrated; never keep duplicate containers claiming a hostname as a transition strategy.

Before the last app stops, acquire a named hold with `local-development-gateway hold dbeaver`; release it with `local-development-gateway release dbeaver` after closing desktop connections. Passive database servers do not keep routers running by themselves. A live DBeaver TCP connection is not an implicit lifecycle registration.

## Network exhaustion and ownership-aware cleanup (#41)

Database pooling reduces engine count, not necessarily checkout Compose networks. A stopped checkout can still retain containers and network allocations. This procedure diagnoses [issue #41](https://github.com/icefoganalytics/local-development-gateway/issues/41); it is **not verified recovery evidence** and does not mark that issue fixed.

Before removing anything, inspect exact IDs and ownership, including stopped containers:

```sh
docker network ls --no-trunc
docker network inspect NETWORK_ID
docker ps -a --no-trunc --filter network=NETWORK_ID
# For each attached or ownership-related container, including stopped ones:
docker inspect CONTAINER_ID
```

Read `com.docker.compose.project`, `com.docker.compose.network`, container Compose labels (including working directory/config files when present), IPAM subnet/gateway, and actual container network attachments. Compare them with the owning checkout's Compose files, root `.env`/project-name configuration, and `bin/dev` file-selection logic. Do not assume a network belongs to the current directory merely because its name resembles a branch. Resolve which checkout/project owner controls it and whether active worktrees or shared servers need it.

For an unwanted **checkout-owned** stack, confirm with its owner, then run that checkout's documented `./bin/dev down` using its original project-name/configuration environment, **without `--volumes`**. WRAP and ELCC do not load their gateway overlay on every `down` path; inspect the resolved owner/config before relying on teardown. Do not substitute a raw `docker compose down` from the gateway checkout. Keep project-server and machine gateway lifecycles separate. If the wrapper cannot run, establish the exact original files/project name from labels and obtain owner approval for an equivalent targeted command; do not guess.

Only after the owner confirms that a particular leftover network is an orphan, and fresh inspection plus `docker ps -a --filter network=NETWORK_ID` establishes that **no containers, including stopped containers, reference it**, remove that exact owned network:

```sh
docker network rm NETWORK_ID
```

Do not remove the machine `local-gateway` network or a project's shared-database network as checkout cleanup. Never use blanket `docker network prune`, `docker system prune`, or delete unrelated containers to free address space. If ownership is uncertain or any container remains, stop and resolve it with the owner. Keep diagnosis and any later recovery commands/results in #41. Its recovery acceptance requires the previously blocked consumer lint command to succeed; successful gateway packaging or an empty-network removal alone does not prove that recovery.
