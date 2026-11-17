# Consumer developer examples

These are **adoption designs**, not changes applied to ELCC, WRAP, Travel Authorization, or Traditional Knowledge (TK). They answer: “What would my existing `bin/dev` and development Compose configuration change, and what would I type every day?” Snippets are focused edits to the named owners, not complete replacement files. No consumer tests, restore, registry publication, or installed-gateway replacement is established here.

Use the [migration guide](/docs/guides/docker-first-migration.md) for backup, restore, restricted-login provisioning, rollback, and acceptance gates, and [Docker installation](/docs/guides/docker-installation.md) for the coordinated gateway installation. Preserve native engine versions below; the generic example's engines are not substitutes. Never edit production Compose, copy production secrets/data into examples, upgrade an engine implicitly, or remove old volumes during adoption.

## Source identity

The snippets adapt these actual, clean local HEADs inspected on 2026-11-17. The migration guide's older ELCC baseline remains historical; the ELCC examples below use its newer actual revision.

| Consumer | Actual inspected revision | Main source owners |
| --- | --- | --- |
| ELCC | `d2e2a46e3a3e73e2680a4342343a4a28306401b6` | [bin/dev](https://github.com/icefoganalytics/elcc-data-management/blob/d2e2a46e3a3e73e2680a4342343a4a28306401b6/bin/dev), [development Compose](https://github.com/icefoganalytics/elcc-data-management/blob/d2e2a46e3a3e73e2680a4342343a4a28306401b6/docker-compose.development.yaml) |
| WRAP | `67883eb5612162b8bd67541dfd522148f70e24b1` | [bin/dev](https://github.com/icefoganalytics/wrap/blob/67883eb5612162b8bd67541dfd522148f70e24b1/bin/dev), [development Compose](https://github.com/icefoganalytics/wrap/blob/67883eb5612162b8bd67541dfd522148f70e24b1/docker-compose.development.yml) |
| Travel | `5966448cb387227fa9d7c51b42da4906d0ccc85d` | [bin/dev](https://github.com/icefoganalytics/travel-authorization/blob/5966448cb387227fa9d7c51b42da4906d0ccc85d/bin/dev), [development Compose](https://github.com/icefoganalytics/travel-authorization/blob/5966448cb387227fa9d7c51b42da4906d0ccc85d/docker-compose.development.yml) |
| TK | `9699f8ac89d5fc7935c40f95f44c64bfeaf0931f` | [bin/dev](https://github.com/icefoganalytics/traditional-knowledge/blob/9699f8ac89d5fc7935c40f95f44c64bfeaf0931f/bin/dev), [development Compose](https://github.com/icefoganalytics/traditional-knowledge/blob/9699f8ac89d5fc7935c40f95f44c64bfeaf0931f/docker-compose.development.yml) |

For additional files named below, use the same repository and pinned revision, not a moving default branch. ELCC, WRAP, and Travel currently lock gateway gem 0.2.2; TK locks 0.1.2. Each adoption must update its existing Gemfile/lock to the coordinated candidate/release before using this lifecycle contract. Do not commit a personal source path or assume the candidate image is published.

## Shared contract: ordinary app commands, automatic gateway

The intended daily behavior is: project `up` makes the shared gateway ready before starting the project; project `down` does not start an absent gateway; the last active consumer's teardown stops gateway **services**, preserving `local-gateway`. Idle shared DB servers remain running but do not retain the gateway. An explicit desktop-client hold does retain it.

The existing Ruby integration owns that coordination:

```ruby
LocalDevelopmentGateway.with_running do
  # Existing project up/run operation; wait for it to finish.
end

LocalDevelopmentGateway.with_running(ensure_running: false) do
  # Existing project down/stop operation; wait for it to finish.
end
```

Keep this inside development paths only; preserve each wrapper's existing nondevelopment delegation. Retain the existing module-level `LocalDevelopmentGateway.with_running` calls: updating the bundle selects the candidate client contract without changing their receivers. Do not wrap it in a second management CLI. In particular, a wrapped `compose` call must use `execution_mode: WAIT_FOR_PROCESS`, not `exec`: replacing Ruby would skip block cleanup. Propagate failed Compose operations; do not report a successful test or teardown from an unchecked `system` result.

The client, not downstream Ruby wrappers, owns per-user/per-Docker-daemon coordination: short coordinator file locks serialize lifecycle decisions; pending operations retain their own file locks while project commands execute. A simultaneous `up` must not lose the gateway to another checkout's `down` between readiness and container attachment. Locks are scoped to Docker daemon identity, not merely a checkout directory. Consumer wrappers must not invent lock files, counters, stale PID cleanup, or private gateway ownership.

### Label and network ownership

Only an explicit `local-gateway.lifecycle: passive` label exempts a running container from retention. Do not infer passivity from a service name, database image, missing HTTP label, or idle connections. Unknown/legacy attachments conservatively keep the gateway alive. Use `consumer` for active app/job/test containers that need to retain it, including private-network-only consumers; do not mark workers passive just because they have no browser route.

A proposed project-owner server file, distinct from every checkout app stack, has this shape (ELCC shown):

```yaml
name: elcc-shared-db
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2019-CU28-ubuntu-20.04
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "${ELCC_DB_ADMIN_PASSWORD:?local provisioning secret required}"
    volumes:
      - sqlserver-data:/var/opt/mssql/data
    networks:
      project-db:
        aliases: [elcc-sqlserver]
      local-gateway: {}
    labels:
      local-gateway.tcp.hostname: "db.elcc.localhost"
      local-gateway.tcp.driver: "sql_server"
      local-gateway.tcp.port: "1433"
      local-gateway.lifecycle: passive
networks:
  project-db:
    name: elcc-shared-db
  local-gateway:
    external: true
    name: local-gateway
volumes:
  sqlserver-data: {}
```

The project server stack owns its new volume and private `elcc-shared-db` network; the gateway owns `local-gateway`. No database host ports are published. Apps connect directly through private DNS, not through the desktop router. The shared-server labels supply one unique project endpoint per server; they do not grant database permissions. Reuse this ownership shape with WRAP/TK/Travel's exact engines and distinct names, never one cross-project engine. Gateway listeners remain host-loopback only.

Checkout Compose declares the private network **external**, retaining its normal checkout `default` network. Put database fields, lifecycle labels, and private network attachments in the base development file, not only `docker-compose.development.gateway.yml`: tests and `run` do not all load that overlay. On services already declaring networks in the gateway overlay, preserve `default` and `local-gateway` and explicitly retain `project-db` in the merged configuration. Keep existing HTTP routes. The database route moves to the project server; remove obsolete checkout DB route stanzas rather than allowing an overlay to recreate a deleted DB service.

### Setup is not the daily loop

A project-owner adoption PR first creates its own shared-server Compose/provisioning owners and preserves/backs up old volumes. After the coordinated candidate installation, run `local-development-gateway hold setup` before the first server startup: it ensures gateway readiness and creates the external `local-gateway` network that server Compose requires. Start servers with native Compose and provision restricted development/test databases while that hold remains active. For example, **after creating the proposed file above**, `docker compose -f compose.shared-db.yml up -d sqlserver` starts ELCC's server. Equivalent proposed owners start WRAP's `sqlserver`, TK's `sqlserver`, or Travel's `postgres travcom travelport`. These are design names, not files or commands that already exist in the consumers. When provisioning is finished, run `local-development-gateway release setup`; the passive servers remain running, and idle-stop preserves the network. This initial setup hold is not another step in the daily loop.

Per checkout, allocate a stable collision-resistant key (examples use `a7c91`), provision the named databases and distinct dev/test logins administratively, restore development data explicitly, and record connection inputs in ignored local root `.env`/approved local configuration. Do not print credentials or put admin credentials in apps. Compose `${NAME:?message}` inputs below require those local values; no secret values are included. Extend the existing configuration owner rather than adding another shell command for developers to remember. Normal migrations/seeds/test resets remain application-owned, but automatic server-level database creation must become validation of the provisioned target.

Server maintenance is separate: checkout `down` neither stops shared databases nor removes their networks/volumes. Gateway idle-stop is also not shared-server teardown. Preserve all old data until native restore and rollback are accepted; new databases do not authorize deleting previous ones.

## 1. ELCC: one SQL Server, two databases per checkout

**One-time setup:** retain SQL Server `2019-CU28-ubuntu-20.04`. Provision `elcc_a7c91_dev` and `elcc_a7c91_test` on `elcc-sqlserver`, with different restricted logins/passwords. Use the project-server shape above. ELCC has no observed `bin/dev db --export` implementation: establish the canonical native SQL Server backup/restore procedure before moving data, rather than inventing an export command.

**Small existing-wrapper change:** retain `bin/dev#up` and `#down`'s module-level gateway calls, `OpenInEditorBridge.compose` bodies and UID/GID/environment assembly; update the bundle to select the candidate implementation. In `down`, select the same development files as `up` (`compose_file_options(gateway: true, **kwargs)`). Adjust the existing `run` method, which is also used by `test_api`, to wait:

```ruby
def run(*args, **kwargs)
  LocalDevelopmentGateway.with_running do
    compose(*%w[run --rm], *args, gateway: true,
      execution_mode: WAIT_FOR_PROCESS, **kwargs)
  end
end
```

This excerpt is the development branch of `run`; keep nondevelopment delegation outside it. No DB-engine switch, provisioning dispatcher, or new daily CLI belongs in this method.

**Base `docker-compose.development.yaml` edits** (merge into existing services; retain unrelated environment keys):

```yaml
x-checkout-db: &checkout-db
  DB_HOST: elcc-sqlserver
  DB_PORT: "1433"
  DB_NAME: "${ELCC_DEV_DATABASE:?provision checkout database}"
  DB_USER: "${ELCC_DEV_USER:?provision scoped login}"
  DB_PASS: "${ELCC_DEV_PASSWORD:?local secret required}"
  DB_TRUST_SERVER_CERTIFICATE: "true"
services:
  api:
    environment:
      <<: [*checkout-db, *default-environment]
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
  test_api:
    environment:
      <<: [*checkout-db, *default-environment]
      NODE_ENV: test
      DB_NAME: "${ELCC_TEST_DATABASE:?provision test database}"
      DB_USER: "${ELCC_TEST_USER:?provision test login}"
      DB_PASS: "${ELCC_TEST_PASSWORD:?local secret required}"
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
networks:
  project-db:
    external: true
    name: elcc-shared-db
```

Remove `db` and the API/test dependency edges to it from this file and its obsolete gateway-overlay DB stanza; retain old `db_data`. Keep the optional Linux override, host user behavior, frontend route and editor bridge. Retarget existing `db`/`sqlcmd` helpers away from `exec db`; SQL Server server selection is `-S host,port`, not the current helper's `-H` workstation flag.

**Daily, from the adopted ELCC checkout:**

```sh
./bin/dev up -d
./bin/dev test api --run
./bin/dev down
```

`test api` is the real wrapper route to `test_api npm run test`; `--run` makes the Vitest invocation finite. Acceptance must retain normal `api/tests/global-setup.ts` initializers and test seed policy, replace `10-ensure-database.ts`'s server-creation fallback, and prove `api/tests/support/clean-database.ts` only resets the private test database while another checkout retains data. Do not use `--skip-setup` for adoption acceptance.

## 2. WRAP: SQL Server full-text, jobs, and checkout search

**One-time setup:** project-owned `wrap-sqlserver` must use the existing `wrap-db:full-text` build from [db.Dockerfile](https://github.com/icefoganalytics/wrap/blob/67883eb5612162b8bd67541dfd522148f70e24b1/db.Dockerfile): SQL Server **2025 CU7 / Ubuntu 24.04** plus `mssql-server-fts`. Provision `wrap_a7c91_dev` / `wrap_a7c91_test` and separate logins. Give the server `local-gateway.tcp.hostname: db.wrap.localhost`, `local-gateway.tcp.driver: sql_server`, `local-gateway.tcp.port: "1433"`, and lifecycle `passive`, attached to project-owned `wrap-shared-db` plus external `local-gateway`.

**Small existing-wrapper change:** keep `up`'s `check_development_environment`, Compose flags, `WAIT_FOR_PROCESS`, and existing module-level gateway calls in `up`/`down`; update the bundle to the candidate. Add `gateway: true` to development teardown to match the startup files. In the existing `run`, preserve the web `--no-deps` special case and wrap the final Compose operation:

```ruby
LocalDevelopmentGateway.with_running do
  compose(*compose_arguments, *args, execution_mode: WAIT_FOR_PROCESS, **kwargs)
end
```

This is the development branch only. The existing guard must still run; do not bypass it to pass connection inputs.

**Base `docker-compose.development.yml` edits:** introduce a connection anchor and apply it to **both `api` and `jobs`**. Keep `jobs`' `RUN_SCHEDULER`, `APPLICATION_NAME`, and existing resource settings.

```yaml
x-checkout-db: &checkout-db
  AZURE_SQL_HOST: wrap-sqlserver
  AZURE_SQL_PORT: "1433"
  AZURE_SQL_DATABASE: "${WRAP_DEV_DATABASE:?provision checkout database}"
  AZURE_SQL_USERNAME: "${WRAP_DEV_USER:?provision scoped login}"
  AZURE_SQL_PASSWORD: "${WRAP_DEV_PASSWORD:?local secret required}"
  DB_TRUST_SERVER_CERTIFICATE: "true"
services:
  api:
    environment:
      <<: [*checkout-db, *default-environment]
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
  jobs:
    environment:
      <<: [*checkout-db, *default-environment]
      RUN_SCHEDULER: "true"
      APPLICATION_NAME: Jobs
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
  test_api:
    environment:
      <<: [*checkout-db, *default-environment]
      NODE_ENV: test
      AZURE_SQL_DATABASE: "${WRAP_TEST_DATABASE:?provision test database}"
      AZURE_SQL_USERNAME: "${WRAP_TEST_USER:?provision test login}"
      AZURE_SQL_PASSWORD: "${WRAP_TEST_PASSWORD:?local secret required}"
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
networks:
  project-db:
    external: true
    name: wrap-shared-db
```

Remove checkout `db`, all three DB dependency edges, and its gateway-overlay route; preserve old `db_data`. Keep Redis, mail, Elasticsearch 9.5.2, their dependencies, test profiles and test Redis database unchanged. The environment snippets do not replace the services' other explicit keys.

WRAP's [environment guard](https://github.com/icefoganalytics/wrap/blob/67883eb5612162b8bd67541dfd522148f70e24b1/bin/lib/development_environment/command.rb) discovers Compose-owned names and interpolation inputs. Keep the new `WRAP_*` inputs in the root/host configuration, not `api/.env.development`; reconcile its existing policy with private secrets without weakening the guard. Separately reconcile ignored `api/.env.test`: `api/src/config.ts` uses dotenv `override: true`. Assert actual database/principal before setup/reset, not just intended Compose values.

**Daily, from the adopted WRAP checkout:**

```sh
./bin/dev up -d
./bin/dev test api --run
./bin/dev down
```

**Adoption-only checks:** run `./bin/dev check-environment`; retain normal initializers; retarget `bin/lib/database/command.rb` export/import and `sqlcmd` to explicit shared destinations. Correct the hard-coded `wrap_development.dbo.workflow_histories` rollback in migration `20250414162002_increase-size-of-workflow-histories-subtitle-field-to-better-support-commenting.ts` before allowing scoped rollback. Full-text remains necessary for historical migration replay/rollback even though current search uses Elasticsearch. `ELASTICSEARCH_INDEX_PREFIX` defaults to the lowercased SQL database name: restore does not migrate search documents, so rebuild/verify each checkout's intended search namespace. See the pinned consumer's `docs/architecture/workflow-search.md` and the migration guide's WRAP gates.

## 3. Travel Authorization: three engine families, six databases

**One-time setup:** retain three project-owned servers, not one generalized SQL server:

| Proposed service / private DNS / desktop route | Native engine | Provisioned checkout dev / test databases |
| --- | --- | --- |
| `postgres` / `travel-postgres` / `db.travel.localhost` | `postgres:14.4` | `travel_a7c91_dev` / `travel_a7c91_test` |
| `travcom` / `travel-travcom` / `db-trav-com.travel.localhost` | SQL Server `2022-CU14-ubuntu-22.04` | `travcom_a7c91_dev` / `travcom_a7c91_test` |
| `travelport` / `travel-travelport` / `db-travelport.travel.localhost` | SQL Server `2019-CU28-ubuntu-20.04`, `SQL_Latin1_General_CP1_CI_AS` | `travelport_a7c91_dev` / `travelport_a7c91_test` |

All three attach to project-owned `travel-shared-db` and external `local-gateway`, with `passive` lifecycle labels. Set `local-gateway.tcp.hostname` to the table's desktop route and `local-gateway.tcp.driver` / `local-gateway.tcp.port` to `postgresql` / `"5432"` on PostgreSQL and `sql_server` / `"1433"` on each SQL Server endpoint. Use distinct restricted roles for all six databases. The current PostgreSQL `app` bootstrap role and SQL Server `sa` are not the desired app identities. Do not point these local simulators or tests at real production Travelport.

**Small existing-wrapper change:** Travel already waits in `run` and `stop` and uses `OpenInEditorBridge.compose` for `up`/`down`. Retain its existing module-level gateway calls and update the bundle to the candidate, preserving `ensure_running: false` in `down`/`stop`, nondevelopment guards, the one-off `traefik.enable=false` label, editor-bridge environment and checkout-name hashing. No receiver changes or additional command dispatch are needed.

**Base development Compose edits:** use all five fields of each family, with explicit test overrides. This development anchor shows the complete connection surface:

```yaml
x-checkout-db: &checkout-db
  DB_HOST: travel-postgres
  DB_PORT: "5432"
  DB_NAME: "${TRAVEL_DEV_DATABASE:?provision checkout database}"
  DB_USER: "${TRAVEL_DEV_USER:?provision scoped role}"
  DB_PASS: "${TRAVEL_DEV_PASSWORD:?local secret required}"
  TRAVCOM_DB_HOST: travel-travcom
  TRAVCOM_DB_PORT: "1433"
  TRAVCOM_DB_NAME: "${TRAVCOM_DEV_DATABASE:?provision checkout database}"
  TRAVCOM_DB_USER: "${TRAVCOM_DEV_USER:?provision scoped login}"
  TRAVCOM_DB_PASS: "${TRAVCOM_DEV_PASSWORD:?local secret required}"
  TRAVCOM_DB_TRUST_SERVER_CERTIFICATE_ENABLED: "true"
  TRAVELPORT_DB_HOST: travel-travelport
  TRAVELPORT_DB_PORT: "1433"
  TRAVELPORT_DB_NAME: "${TRAVELPORT_DEV_DATABASE:?provision checkout database}"
  TRAVELPORT_DB_USER: "${TRAVELPORT_DEV_USER:?provision scoped login}"
  TRAVELPORT_DB_PASS: "${TRAVELPORT_DEV_PASSWORD:?local secret required}"
  TRAVELPORT_DB_TRUST_SERVER_CERTIFICATE_ENABLED: "true"
```

Merge `<<: [*checkout-db, *default-environment]` into both `api` and `test_api`, attach each to `[default, project-db]`, label each `local-gateway.lifecycle: consumer`, and declare external `project-db` named `travel-shared-db`. In `test_api`, replace all nine database/name/user/password fields explicitly:

```yaml
NODE_ENV: test
DB_NAME: "${TRAVEL_TEST_DATABASE:?provision test database}"
DB_USER: "${TRAVEL_TEST_USER:?provision test role}"
DB_PASS: "${TRAVEL_TEST_PASSWORD:?local secret required}"
TRAVCOM_DB_NAME: "${TRAVCOM_TEST_DATABASE:?provision test database}"
TRAVCOM_DB_USER: "${TRAVCOM_TEST_USER:?provision test login}"
TRAVCOM_DB_PASS: "${TRAVCOM_TEST_PASSWORD:?local secret required}"
TRAVELPORT_DB_NAME: "${TRAVELPORT_TEST_DATABASE:?provision test database}"
TRAVELPORT_DB_USER: "${TRAVELPORT_TEST_USER:?provision test login}"
TRAVELPORT_DB_PASS: "${TRAVELPORT_TEST_PASSWORD:?local secret required}"
```

Retain each family's host, port, and local trust settings from the anchor. Remove `db`, `db_trav_com`, `db_travelport`, their app/test dependency edges, and all three gateway-overlay route stanzas. Preserve `db_data`, `db_trav_com_data`, `db_travelport_data`. Private database reachability must not depend on loading the gateway overlay even though Travel's wrapper currently loads it by default.

**Daily, from the adopted Travel checkout:**

```sh
./bin/dev up -d
./bin/dev test api --run
./bin/dev down
```

Before this becomes a supported loop, change the PostgreSQL initializer's maintenance-database creation path and both integrations' ensure-database paths to provisioned-target validation. Retarget existing `psql` and PostgreSQL export/import owners; that export does **not** back up either SQL source simulator. Establish native SQL backups separately. Reconcile the development-env-as-test-env mount. Prove actual identities and reset/seed results for all three test databases and untouched neighboring checkout sentinels. The migration guide records swallowed initializer/TravCom cleanup failures: fix those existing owners, not merely the wrapper's exit handling, before treating command success as acceptance.

## 4. Traditional Knowledge: SQL Server plus the archiver writer

TK is not just another API/web pair. At the pinned revision its development stack contains `api`, `web`, `api_wait`, `test_api`, `test_web`, Redis `bitnamilegacy/redis:8.0.2`, MailDev `2.2.1`, optional PlantUML, and an **archiver** service. Both API and archiver connect to SQL Server `2022-CU14-ubuntu-22.04`; archiver also depends on Redis. Its DB configuration is consumed by `archiver/src/config.ts` and `archiver/src/db/db-client.ts`. Keep its local certificate mounts and other private configuration outside examples.

**One-time setup:** provision `tk_a7c91_dev` / `tk_a7c91_test` with separate logins on project-owned `tk-sqlserver`, preserving the 2022 CU14 engine. The server owns `tk-shared-db`, a new SQL volume and route `db.tk.localhost` (`sql_server`, `1433`, lifecycle `passive`), and joins external `local-gateway`. Stop **API and archiver writers** before native backup/restore; retain old `db_data`. No DB backup/export implementation was observed in TK's `bin/dev`; adopt a canonical native procedure rather than advertise an imaginary wrapper command.

**Small existing-wrapper change:** retain the module-level gateway calls, `OpenInEditorBridge.with_running` nesting in `up` and `down`, and both existing `WAIT_FOR_PROCESS` calls; update the bundle to the candidate. Make development `down` use `gateway: true` to match `up`. TK's current `run` has no gateway wrapper; replace its development branch with:

```ruby
LocalDevelopmentGateway.with_running do
  compose(*%w[run --rm], *args, gateway: true,
    execution_mode: WAIT_FOR_PROCESS, **kwargs)
end
```

Keep the nondevelopment branch separate and preserve the existing Linux override and host IDs. Do not replace the local editor bridge implementation while adopting the gateway.

**Base development Compose edits** use TK's real variable names, which differ from ELCC's:

```yaml
x-checkout-db: &checkout-db
  DB_HOST: tk-sqlserver
  DB_PORT: "1433"
  DB_DATABASE: "${TK_DEV_DATABASE:?provision checkout database}"
  DB_USERNAME: "${TK_DEV_USER:?provision scoped login}"
  DB_PASSWORD: "${TK_DEV_PASSWORD:?local secret required}"
  DB_TRUST_SERVER_CERTIFICATE: "true"
services:
  api:
    environment:
      <<: [*checkout-db, *default-environment]
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
  archiver:
    environment:
      <<: [*checkout-db, *default-environment]
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
  test_api:
    environment:
      <<: [*checkout-db, *default-environment]
      NODE_ENV: test
      DB_DATABASE: "${TK_TEST_DATABASE:?provision test database}"
      DB_USERNAME: "${TK_TEST_USER:?provision test login}"
      DB_PASSWORD: "${TK_TEST_PASSWORD:?local secret required}"
    networks: [default, project-db]
    labels:
      local-gateway.lifecycle: consumer
networks:
  project-db:
    external: true
    name: tk-shared-db
```

Remove checkout `db` and the `api`, `archiver`, and `test_api` dependency edges to it, preserving mail/cache dependencies. TK's existing gateway overlay routes **API, web, and mail only**; there is no DB route stanza to remove. Keep those HTTP labels and external `local-gateway`, and add the new project-server DB route only once. Archiver/test lifecycle labels belong in the base file even though neither needs an HTTP route.

**Daily, from the adopted TK checkout:**

```sh
./bin/dev up -d
./bin/dev test api --run
./bin/dev down
```

The real `test_api` owner runs `test_api npm run test`; `api/tests/global-setup.ts` invokes normal initializers. Replace `api/src/initializers/10-ensure-database.ts`'s server-level fallback/`CREATE DATABASE` with provisioned-target validation. `api/src/config.ts` uses dotenv `override: true`, and Compose mounts `.env.development` as `.env.test`: reconcile ignored local DB declarations so they cannot override test isolation. `api/tests/support/clean-database.ts` disables constraints, deletes rows and reseeds identities; assert test database/principal before cleanup and prove a second checkout survives. Retarget existing `sqlcmd` from `exec db` and its `-H` workstation assumption to explicit `-S host,port` and database selection. Validate archiver behavior against the new restricted development login independently; API test success cannot establish that writer's compatibility.

## DBeaver without keeping an app checkout alive

After the coordinated candidate is installed and project servers/routes are configured:

```sh
local-development-gateway hold dbeaver
# Open DBeaver; select the project route and explicit checkout database.
# Close/disconnect DBeaver when finished.
local-development-gateway release dbeaver
```

`hold dbeaver` ensures the gateway is ready and records a durable named hold for this user/daemon. Closing DBeaver does not release it automatically. `release dbeaver` removes that hold and stops gateway services only if no active consumers, other holds, or pending lifecycle operations require them. It must not delete `local-gateway` or stop project servers. Do not replace this with “leave an unused project up.”

Use each project's shared-server hostname, loopback port 1433 (SQL Server) or 5432 (PostgreSQL), explicit checkout database, and its restricted credentials. Travel has three separate endpoints. A route chooses a server, not an authorization boundary. Preserve existing protocol/TLS behavior; raw TCP readiness is not SQL login/query evidence.

## What remains to establish in each consumer PR

The source facts above establish owners, field names, versions, commands and topology—not adoption success. Each consumer PR must demonstrate a cold `bin/dev up` to a ready gateway; ordinary tests with correct effective identities; overlapping up/down without a stop race; last-consumer down stopping services despite passive servers; legacy/unknown attachment keepalive; DBeaver hold/release; preserved shared networks/data; native backup/restore and neighbor isolation. WRAP also needs jobs/full-text-history/search evidence; Travel needs six-database/three-engine evidence; TK needs archiver evidence. Project-specific RAM reduction requires equivalent measured workloads, not engine upgrades or a smaller configuration file.

No consumer rollout, image publication, gateway deployment, restore compatibility, or passing consumer test suite is claimed by these examples.
