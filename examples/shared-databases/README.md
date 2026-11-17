# Consumer-owned shared database example

This synthetic consumer uses a small Ruby Compose launcher, a real Node HTTP application, Knex migrations, and separate development/test connections. SQL Server 2022 is the default; PostgreSQL 17 exercises the same application. It is not a migrated ELCC, WRAP, or Travel application.

## What a consumer maintains

`bin/dev` follows the existing consumer pattern: short `up`, `down`, `run`, `test`, `lint`, and `migrate` methods delegate to Compose; other arguments pass through unchanged. Compose owns service connections and test overrides. The wrapper does not choose SQL clients, stream SQL, provision databases, delete data, manage shared servers, or implement benchmark groups.

| Responsibility | Owner |
| --- | --- |
| Checkout name and ordinary application commands | Existing consumer `bin/dev` |
| Development/test connections and private server network | Consumer Compose configuration |
| Application tables and test reset | Existing application migrations and tests |
| Shared server startup, backup, provisioning, and retirement | Project owner, using the server Compose project |
| Browser/desktop routing | Machine-wide gateway, independently managed |

Sharing removes repeated engine containers and per-checkout server lifecycle, but adds a project-level provisioning and backup responsibility. The two explicit provisioning services below are that remaining responsibility, not code to copy into every wrapper. They run existing engine-specific SQL with native clients; they never run during normal application startup. Moving this responsibility out of the wrapper does not make it disappear.

## Prerequisites

- Docker Engine with Compose v2 (`up --wait` and `run --build` support), Ruby 2.7+ for the consumer wrapper, and internet access for images/npm.
- SQL Server requires a supported host architecture and sufficient RAM. Starting it accepts Microsoft's EULA; Developer is not a production license.
- Use disposable resources only. The checked-in passwords are public examples, not secrets. Docker administrators can obtain server administrator access; this is checkout isolation, not a hostile-administrator security boundary.

No gateway, gateway gem, host database client, or host npm installation is required.

## Project-owner setup

From `examples/shared-databases`, create two disposable checkouts and start the project-owned server once:

```sh
example=$PWD
servers="$example/compose.yml"
checkouts=$(mktemp -d)
cp -R "$example" "$checkouts/alpha"
cp -R "$example" "$checkouts/beta"
alpha="$checkouts/alpha/bin/dev"
beta="$checkouts/beta/bin/dev"

docker compose -p gateway-example-shared -f "$servers" up -d --wait sqlserver
CHECKOUT_NAME=alpha docker compose -p gateway-example-shared -f "$servers" run --rm --no-deps provision-sqlserver
CHECKOUT_NAME=beta docker compose -p gateway-example-shared -f "$servers" run --rm --no-deps provision-sqlserver
# Reconcile explicit denials after both logins exist.
CHECKOUT_NAME=alpha docker compose -p gateway-example-shared -f "$servers" run --rm --no-deps provision-sqlserver
```

Provisioning creates databases/logins, not application tables. It retains existing data/passwords, rejects elevated identities, and restores restrictions. The provisioning services validate `CHECKOUT_NAME` before executing any SQL. Only these explicitly selected setup services receive administrator credentials.

## Normal checkout work

```sh
COMPOSE_PROJECT_NAME=alpha "$alpha" up
COMPOSE_PROJECT_NAME=beta "$beta" up
COMPOSE_PROJECT_NAME=alpha "$alpha" run app node app.mjs note alpha-marker
COMPOSE_PROJECT_NAME=beta "$beta" run app node app.mjs note beta-marker
COMPOSE_PROJECT_NAME=alpha "$alpha" test
COMPOSE_PROJECT_NAME=beta "$beta" test
COMPOSE_PROJECT_NAME=alpha "$alpha" run app node app.mjs query 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=beta "$beta" run app node app.mjs query 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=alpha "$alpha" run test_app node app.mjs query 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=alpha "$alpha" config
COMPOSE_PROJECT_NAME=alpha "$alpha" ps
COMPOSE_PROJECT_NAME=alpha "$alpha" lint
```

Each development database must contain only its own marker; test notes are empty after the tests. `note` POSTs through the live HTTP process. Startup and tests apply the same versioned migration using their respective restricted logins. Neither can create databases or fall back to administrator credentials. `lint` runs pinned, non-fixing Oxlint in a networkless container without starting databases; warnings fail the command.

The explicit Compose name is also the checkout identity. Without one, the wrapper uses `checkout_<12 hexadecimal SHA256 characters of the canonical checkout path>` so same-named folders at different paths remain distinct. Inspect `bin/dev config` and provision that name. Explicit names must match `[a-z][a-z0-9_]{0,31}`; moving a default-named checkout changes its identity. Retain an explicit name when persistence across moves matters.

Databases/logins are `app_<checkout>_development` and `app_<checkout>_test`; passwords are `Example-<database>-Only9!`. `consumer.yml` shows the test connection override directly. App HTTP aliases are checkout-qualified, database aliases are server-project-qualified, and no ports are published.

## Isolation and checkout shutdown

After the successful queries above, these SQL Server commands must fail with database access denial, not syntax, login, network, or missing-server errors:

```sh
COMPOSE_PROJECT_NAME=alpha "$alpha" run app node app.mjs query 'USE [app_beta_development]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=beta "$beta" run app node app.mjs query 'USE [app_alpha_development]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=alpha "$alpha" run app node app.mjs query 'USE [app_alpha_test]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=alpha "$alpha" run test_app node app.mjs query 'USE [app_alpha_development]; SELECT DB_NAME();'

COMPOSE_PROJECT_NAME=alpha "$alpha" down
COMPOSE_PROJECT_NAME=beta "$beta" run app node app.mjs note beta-survives-alpha-down
COMPOSE_PROJECT_NAME=alpha "$alpha" run app node app.mjs query 'SELECT * FROM notes'
```

Normal `down` stops only alpha's application and removes its private app network. Alpha's data, the shared server, and beta's live application remain available. Repeat provisioning and confirm both development markers remain.

SQL Server logins have no server roles. Database ownership remains with `sa`; each login has `db_owner` only in its own database for migrations. Guest CONNECT, TRUSTWORTHY, and cross-database ownership chaining are disabled. Other existing `app_` logins receive explicit CONNECT denials; new logins remain excluded by disabled guest access. PostgreSQL roles have no elevated attributes or inherited memberships; PUBLIC CONNECT/TEMPORARY is revoked and other `app_` grants are removed.

## PostgreSQL counterpart

Stop both checkout apps, then export `DB_ENGINE=postgres`. Start `postgres` instead of `sqlserver`, and run `provision-postgres` instead of `provision-sqlserver` in the project-owner commands. Repeat the same normal checkout commands and marker checks. Both server services use `gateway-example-shared_default`; only the selected engine needs to run.

PostgreSQL cannot `USE` another database. Verify alternate connections with otherwise-valid source credentials:

```sh
for pair in \
  app_alpha_development:app_beta_development \
  app_beta_development:app_alpha_development \
  app_alpha_development:app_alpha_test \
  app_alpha_test:app_alpha_development
do
  source=${pair%:*}
  target=${pair#*:}
  docker compose -p gateway-example-shared -f "$servers" exec -T \
    -e "PGPASSWORD=Example-$source-Only9!" postgres \
    psql -X -h gateway-example-shared-postgres -U "$source" -d "$target" \
    -v ON_ERROR_STOP=1 -c 'SELECT current_database(), current_user;'
done
```

Each must fail with `permission denied for database`. Application tests also exercise test-to-development denial through Knex.

## Explicit data retirement and project shutdown

Deleting databases is not an application `down` operation. After stopping alpha's app and disconnecting its clients, the project owner can delete **only these disposable alpha databases**:

```sh
# SQL Server:
docker compose -p gateway-example-shared -f "$servers" exec -T \
  -e SQLCMDPASSWORD=Example-Sql-Admin9! sqlserver \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -d master -C -b \
  -Q 'DROP DATABASE [app_alpha_development]; DROP DATABASE [app_alpha_test];'

# PostgreSQL alternative:
docker compose -p gateway-example-shared -f "$servers" exec -T \
  -e PGPASSWORD=Example-Postgres-Admin9! postgres \
  psql -X -h localhost -U example_admin -d postgres -v ON_ERROR_STOP=1 \
  -c 'DROP DATABASE app_alpha_development;' -c 'DROP DATABASE app_alpha_test;'
```

Connected clients can cause deletion to fail; do not force other sessions closed. Confirm beta's markers survive, then reprovision alpha and run its normal `up` and `test` commands to prove fresh app-owned migrations.

After stopping **all** checkout apps, `docker compose -p gateway-example-shared -f "$servers" down` stops project servers while preserving volumes. Adding `--volumes` destroys **every checkout's data on both engines** and is appropriate only when retiring this disposable project. Never invoke it from checkout teardown or prune unrelated networks.

## Optional routing and measurement

If the gateway and external `local-gateway` network already exist, the project owner may add `-f gateway.yml` to server startup. Desktop hostnames are `sqlserver.gateway-example-shared.localhost` and `postgres.gateway-example-shared.localhost`. Routing selects a server, not a logical database; this never starts or restarts the gateway.

For a separate-server comparison, use ordinary Compose `-p` to create an independent server project per checkout and set `DB_SERVER_PROJECT` on the corresponding application's commands. No benchmark mode exists in `bin/dev`. Compare identical images, databases, data, workload, and sampling intervals, running only one topology during measurement. The historical 48.2% synthetic idle RAM saving is not evidence of application adoption, capacity, or lower maintenance burden. Server restarts and contention now affect all project checkouts; sharing does not fix network exhaustion (#41).

For a real consumer, retain its existing wrapper, application, migration runner, and tests. Change its Compose connections and network, remove checkout-owned engine lifecycle and application administrator fallback, and establish project-owned provisioning/backup. Preserve its editor bridge and other unrelated hooks. Do not copy this synthetic application or replace an existing wrapper with this example.
