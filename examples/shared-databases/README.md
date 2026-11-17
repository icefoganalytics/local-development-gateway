# Consumer-owned shared database example

This runnable **synthetic consumer**, not a migrated product, demonstrates one project-owned SQL Server 2022 server with independent application checkouts. PostgreSQL 17 is a selectable counterpart using the same application. The tiny Node application actually serves and persists notes; it has a Knex migration, restricted database connections, and a built-in Node test runner. No frontend, host database client, gateway, or gateway Ruby installation is needed.

## Prerequisites and ownership

- Docker Engine with Compose v2 (`up --wait` and `run --build` support), internet
  access for images/npm, and Ruby 2.7+ for this **consumer-side** `bin/dev`.
- SQL Server needs a supported host architecture and sufficient RAM. Starting
  it accepts Microsoft's EULA; Developer is not a production license.
- Run only against this disposable example's resources, never consumer data.
  Passwords are deliberately public development examples. Docker administrators
  can obtain server administrator access; this is checkout isolation, not a
  hostile-administrator security boundary.

The project owner runs `bin/dev servers up` and `bin/dev provision`. Provisioning creates databases/logins, not application tables. Application `up` applies the versioned `app/migrations/001_notes.cjs` using its **development login**, then starts a real HTTP service. Tests apply that same migration with the **test login**, delete only test notes before each test, and verify persistence and test-to-development denial. The application never falls back to `sa`, never creates databases, and never gets administrator environment variables.

`bin/dev` follows the consumer pattern of a Ruby Compose launcher, checkout-based Compose project naming, app initialization, and separate test initialization. It intentionally does not reproduce ELCC's product, framework, or legacy administrator-powered database-creation initializer. The gateway owns routing and its own lifecycle only; database sharing and application setup remain here.

## Two real checkout folders

From this example directory, create two disposable copies (or use two actual consumer Git worktrees after adapting the files):

```sh
example=$PWD
checkouts=$(mktemp -d)
cp -R "$example" "$checkouts/alpha"
cp -R "$example" "$checkouts/beta"
alpha="$checkouts/alpha/bin/dev"
beta="$checkouts/beta/bin/dev"

# Project-owner action, once per server group; SQL Server is the default.
"$alpha" servers up

# Explicit existing-style Compose names make the QA database names predictable.
COMPOSE_PROJECT_NAME=alpha "$alpha" provision
COMPOSE_PROJECT_NAME=beta "$beta" provision
# Reconcile explicit DENY entries now that both checkouts' logins exist.
COMPOSE_PROJECT_NAME=alpha "$alpha" provision

COMPOSE_PROJECT_NAME=alpha "$alpha" identity
COMPOSE_PROJECT_NAME=alpha "$alpha" up
COMPOSE_PROJECT_NAME=beta "$beta" up
COMPOSE_PROJECT_NAME=alpha "$alpha" note alpha-marker
COMPOSE_PROJECT_NAME=beta "$beta" note beta-marker
COMPOSE_PROJECT_NAME=alpha "$alpha" test
COMPOSE_PROJECT_NAME=beta "$beta" test
COMPOSE_PROJECT_NAME=alpha "$alpha" query development 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=beta "$beta" query development 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=alpha "$alpha" query test 'SELECT * FROM notes'
```

Expected: each development database contains only its own marker; test notes are empty after the suite. `note` POSTs through the live HTTP process, not directly to SQL. `query` uses the application's Knex driver and selected restricted credentials; SQL is trusted operator input, not a query API. No ports are published. App HTTP aliases are checkout-qualified on each checkout's own network, avoiding ambiguous `app` names on the shared network.

Without an explicit `COMPOSE_PROJECT_NAME`, identity is `checkout_<12 hexadecimal SHA256 characters of the canonical checkout path>`. Two same-named folders at different paths therefore do not collapse into one checkout. An explicit name must match `[a-z][a-z0-9_]{0,31}` exactly: no lossy normalization or SQL metacharacters. Names are project-scoped; never deliberately reuse an explicit name for independent checkouts. Moving a default-named checkout selects a new identity; retain an explicit name if persistence across moves matters.

Databases and logins are `app_<identity>_development` and `app_<identity>_test`, with passwords `Example-<database>-Only9!`. The fixed `app_` namespace separates example identities from server accounts. Provisioning is repeatable, retains data/passwords, rejects unexpected elevated PostgreSQL roles or SQL Server server-role/grant membership, and restores access restrictions. A changed password fails application authentication rather than silently resetting data.

## Executable isolation and lifecycle QA

Run the successful startup, HTTP writes, and tests above first. SQL Server cross-database commands below must fail specifically with database access denial (for example SQL Server 916), not syntax, login, network, or missing-server errors. Repeat after re-provisioning to cover idempotence.

```sh
COMPOSE_PROJECT_NAME=alpha "$alpha" query development 'USE [app_beta_development]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=beta "$beta" query development 'USE [app_alpha_development]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=alpha "$alpha" query development 'USE [app_alpha_test]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=alpha "$alpha" query test 'USE [app_alpha_development]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=beta "$beta" query development 'USE [app_beta_test]; SELECT DB_NAME();'
COMPOSE_PROJECT_NAME=beta "$beta" query test 'USE [app_beta_development]; SELECT DB_NAME();'

# Normal down stops only alpha's application and removes its private app network.
COMPOSE_PROJECT_NAME=alpha "$alpha" down
COMPOSE_PROJECT_NAME=beta "$beta" note beta-survives-alpha-down
COMPOSE_PROJECT_NAME=beta "$beta" query development 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=alpha "$alpha" query development 'SELECT * FROM notes'

# Explicit destructive opt-in: alpha only, both environments, logins retained.
COMPOSE_PROJECT_NAME=alpha "$alpha" remove-data --remove-data
COMPOSE_PROJECT_NAME=beta "$beta" query development 'SELECT * FROM notes'
COMPOSE_PROJECT_NAME=alpha "$alpha" provision
COMPOSE_PROJECT_NAME=alpha "$alpha" up
COMPOSE_PROJECT_NAME=alpha "$alpha" test
```

Cleanup does not force other sessions closed. An in-use database can fail to drop; disconnect the selected checkout first. Normal `down` never drops databases, stops project servers, or removes the neighbor's app.

SQL logins own no server roles. Database ownership stays with `sa`; each login has `db_owner` only inside its own database so app migrations can run. Guest CONNECT, TRUSTWORTHY, and cross-database ownership chaining are disabled. Other existing `app_` logins receive explicit CONNECT denials; subsequently created logins remain excluded by disabled guest access. PostgreSQL roles have no elevated attributes or inherited memberships; PUBLIC CONNECT/TEMPORARY is revoked and other `app_` grants are removed. System databases are not checkout databases; these settings are not production hardening.

## PostgreSQL counterpart

Stop both checkout apps before switching engines, then export `DB_ENGINE=postgres` and repeat the startup/provision/up/note/test lifecycle above. `servers up` starts only the selected engine, so PostgreSQL can be exercised independently. Its private alias is `example-shared-postgres`; SQL Server's remains `example-shared-sqlserver`. Both use `gateway-example-shared_default`.

PostgreSQL cannot `USE` another database. Test explicit alternate connections using the native client inside the server, with the otherwise-valid source login:

```sh
export DB_ENGINE=postgres
export DB_SERVER_GROUP=shared
for pair in \
  app_alpha_development:app_beta_development \
  app_beta_development:app_alpha_development \
  app_alpha_development:app_alpha_test \
  app_alpha_test:app_alpha_development \
  app_beta_development:app_beta_test \
  app_beta_test:app_beta_development
do
  source=${pair%:*}
  target=${pair#*:}
  docker compose -p gateway-example-shared -f "$example/compose.yml" exec -T \
    -e "PGPASSWORD=Example-$source-Only9!" postgres \
    psql -X -h example-shared-postgres -U "$source" -d "$target" \
    -v ON_ERROR_STOP=1 -c 'SELECT current_database(), current_user;'
done
```

Each must fail with `permission denied for database`; application tests also exercise development access denial using test credentials. Native clients are diagnostics/provisioning only; application migration, test setup, and HTTP work use Knex.

## Project lifecycle, baseline, and optional routing

After stopping **all** attached checkout apps, the project owner may stop servers while retaining volumes, or explicitly destroy all example data:

```sh
COMPOSE_PROJECT_NAME=alpha "$alpha" down
COMPOSE_PROJECT_NAME=beta "$beta" down
"$alpha" servers down
# Destructive for every checkout on BOTH engines:
"$alpha" servers destroy --remove-all-data
```

Do not invoke server shutdown from a checkout teardown hook. Resource exhaustion, server restarts, and project shutdown affect neighbors: sharing has a real contention/lifecycle tradeoff and does not fix Docker network exhaustion (#41). `COMPOSE_FILE` is supported as a colon-separated override of the normal file; for example use `COMPOSE_FILE=compose.yml:/absolute/private-network.yml` only on server commands. Do not prune unrelated networks.

For a separate-engine baseline, select `DB_SERVER_GROUP=alpha` for alpha's server startup/provision/app commands and `DB_SERVER_GROUP=beta` for beta's. Each group has its own project, volumes, network, and original qualified aliases `example-alpha-sqlserver` / `example-beta-sqlserver` (and PostgreSQL equivalents). Use the same schema, notes, test suites, images, warm-up, and sample intervals in both topologies. Stop checkout apps before changing topology. Measure only engine containers, summing repeated `docker stats --no-stream` steady-state samples for the selected projects; never combine baseline and shared totals. Record host/image IDs, workload, limits, timing, and contention. The earlier 48.2% synthetic RAM result is not evidence of consumer adoption or capacity.

Optional server routing retains `gateway.yml`. Only if a gateway and external `local-gateway` network **already exist**, the project owner can use:

```sh
DB_SERVER_GROUP=shared docker compose -p gateway-example-shared \
  -f compose.yml -f gateway.yml up -d --wait sqlserver
```

Use `postgres` instead for PostgreSQL. This never starts/restarts the gateway. Hostnames remain `sqlserver.example-shared.localhost` and `postgres.example-shared.localhost`: routing chooses a **server**, never a logical database or checkout. Private aliases stay qualified and no database ports are published.

To adapt a real consumer, retain its existing Ruby `bin/dev`, application, migration runner, and test suite. Replace checkout engine services with a project-owned server network, derive distinct development/test database and login configuration from its checkout identity, move only database/login creation into explicit project provisioning, and remove administrator fallback from app initialization. Keep normal app `down` independent of server lifecycle.
