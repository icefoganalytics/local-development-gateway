# Project-local shared database servers

This **disposable, synthetic development example** runs one PostgreSQL 17 server
and one SQL Server 2022 Developer server for one project. Two checkout identities,
`alpha` and `beta`, each get separate `development` and `test` databases **and
credentials** on each server. There are no checkout-specific engine containers,
no published host ports, and no requirement for Ruby, host database clients, or a
running gateway. Docker with the Compose plugin and a POSIX shell are required.
SQL Server requires a supported Docker host architecture and enough available RAM.
Starting it accepts Microsoft's container EULA; Developer is not a production license.

The network, engine containers, and named volumes belong to this example project,
not a checkout. Real projects must each own their own server pair, network, volume
names, and aliases; never use this example as a cross-project database service.
The checked-in passwords are deliberately public dev-only examples, not secrets or
consumer configuration. Anyone with Docker access can obtain administrator access.
This protects normal checkout connections, not hostile Docker administrators.

## Initialize and connect

From this directory:

```sh
./database shared up
./database shared init alpha
./database shared init beta

./database shared psql alpha development -c 'SELECT current_database(), current_user;'
./database shared psql alpha test -c 'SELECT current_database(), current_user;'
./database shared psql beta development -c 'SELECT current_database(), current_user;'
./database shared psql beta test -c 'SELECT current_database(), current_user;'
./database shared sqlcmd alpha development -Q 'SELECT DB_NAME(), ORIGINAL_LOGIN();'
./database shared sqlcmd alpha test -Q 'SELECT DB_NAME(), ORIGINAL_LOGIN();'
./database shared sqlcmd beta development -Q 'SELECT DB_NAME(), ORIGINAL_LOGIN();'
./database shared sqlcmd beta test -Q 'SELECT DB_NAME(), ORIGINAL_LOGIN();'
```

`up` waits for authenticated SQL Server readiness and PostgreSQL connection
readiness; provisioning and authenticated client calls must also succeed.
The small `database` shell script invokes native `psql` and `sqlcmd` in the
existing server containers, using their qualified private-network aliases.
Arguments after the checkout/environment are passed directly to those clients;
these are trusted operator commands, not a sandboxed query API.

| Engine | Private hostname | Port |
| --- | --- | --- |
| PostgreSQL | `example-shared-postgres` | 5432 |
| SQL Server | `example-shared-sqlserver` | 1433 |

For both engines, the database and login names are `alpha_development`,
`alpha_test`, `beta_development`, and `beta_test`. Each password is
`Example-<database>-Only9!`, for example `Example-alpha_test-Only9!`.
Apps on this private network use these hosts, explicit database names, and the
corresponding **non-admin** login, never `sa` or `example_admin`.
The Compose project is `gateway-example-shared`; its default network is
`gateway-example-shared_default`. Attach app services to that existing network
rather than launching a database engine in each checkout.

Provisioning is repeatable: it creates missing databases/logins, does not drop
existing data, and never changes an existing password. A manually changed
password causes the final authenticated client check to fail; resolve it
explicitly rather than resetting a volume. Unexpected PostgreSQL ownership or
privileged role attributes/memberships, and SQL Server server-role memberships,
are rejected. The scripts restore the documented database access restrictions.
Use only the allowlisted `alpha`/`beta` identities and `development`/`test`
environments. Do not point these scripts at existing consumer databases.

PostgreSQL roles have no superuser, CREATEDB, CREATEROLE, replication, bypass-RLS,
or inherited role membership. Database ownership is per environment; `PUBLIC`
CONNECT/TEMPORARY is revoked and other example identities' grants removed.
SQL logins have no server-role membership. Database owners are `sa`, never app
logins; checkout users get `db_owner` only in their own environment database.
Guest CONNECT, TRUSTWORTHY, and cross-database ownership chaining are disabled;
other example logins have explicit CONNECT denials in each checkout database.
System databases are not checkout databases; do not treat these disposable
settings as production hardening. Server-level configuration or administrator
permission changes outside the example require a new security review.

## Prove cross-checkout and development/test denial

First run the successful commands above. Each following command must exit
nonzero with a **database access denial**, not a missing container, login failure,
syntax error, or network failure. The PostgreSQL `-d` explicitly selects the
other database; the SQL command attempts a cross-database `USE` from a valid
initial connection. Repeat for the other environment/direction if adapting this
example.

```sh
./database shared psql alpha development -d beta_development -c 'SELECT current_database();'
./database shared psql beta development -d alpha_development -c 'SELECT current_database();'
./database shared psql alpha test -d alpha_development -c 'SELECT current_database();'
./database shared psql beta test -d beta_development -c 'SELECT current_database();'
./database shared sqlcmd alpha development -Q 'USE [beta_development]; SELECT DB_NAME();'
./database shared sqlcmd beta development -Q 'USE [alpha_development]; SELECT DB_NAME();'
./database shared sqlcmd alpha test -Q 'USE [alpha_development]; SELECT DB_NAME();'
./database shared sqlcmd beta test -Q 'USE [beta_development]; SELECT DB_NAME();'
```

## Checkout cleanup versus project shutdown

There is no checkout engine to stop. Normal checkout `down` should stop only its
application services and leave this project-owned server Compose project alone.
Removing a checkout's data is an explicit, destructive opt-in:

```sh
# Optional: create beta markers before removing alpha.
./database shared psql beta development -c 'CREATE TABLE IF NOT EXISTS cleanup_marker (id integer PRIMARY KEY); INSERT INTO cleanup_marker VALUES (42) ON CONFLICT DO NOTHING;'
./database shared sqlcmd beta development -Q "IF OBJECT_ID(N'dbo.cleanup_marker', N'U') IS NULL CREATE TABLE dbo.cleanup_marker (id int PRIMARY KEY); IF NOT EXISTS (SELECT 1 FROM dbo.cleanup_marker WHERE id = 42) INSERT INTO dbo.cleanup_marker VALUES (42);"

# Drops only alpha_development and alpha_test on both engines; retains logins.
./database shared remove-checkout alpha --remove-data
./database shared psql beta development -c 'SELECT * FROM cleanup_marker;'
./database shared sqlcmd beta development -Q 'SELECT * FROM dbo.cleanup_marker;'
# Alpha can be reprovisioned explicitly later.
./database shared init alpha
```

Disconnect the removed checkout's clients first. Cleanup does not force sessions
closed; an in-use database can fail to drop. It does not stop shared servers or
delete beta databases. Retained empty roles/logins preserve passwords on later
reprovisioning. The **project owner only** can stop shared engines, preserving
volumes, or opt into destroying all example data:

```sh
./database shared down
# OR, destructive for BOTH checkouts:
./database shared destroy --remove-all-data
```

Do not run these project-owner commands from checkout teardown hooks. A server
restart, resource exhaustion, or project-owner shutdown affects both checkouts.
This sharing tradeoff does not fix private Docker network lifecycle/exhaustion
(#41); do not prune other projects' networks to make this example start.

## Equivalent separate-engine baseline and RAM measurement

For a comparison, use exactly the same image versions, settings, four logical
databases, credentials, schema/data, queries, and warm-up on each topology. The
baseline uses one pair of servers **per checkout** (four engines total), while
the shared topology uses one pair (two engines total). Groups `alpha` and `beta`
have separate Compose projects, volumes, networks, and aliases such as
`example-alpha-postgres`; they are not extra logical databases on the shared pair.
Never include both topologies in one RAM total.

```sh
./database shared down
./database alpha up
./database alpha init alpha
./database beta up
./database beta init beta
# Run the same workload against each baseline group; for example:
./database alpha psql alpha development -c 'SELECT current_database(), current_user;'
./database beta psql beta development -c 'SELECT current_database(), current_user;'
./database alpha sqlcmd alpha development -Q 'SELECT DB_NAME(), ORIGINAL_LOGIN();'
./database beta sqlcmd beta development -Q 'SELECT DB_NAME(), ORIGINAL_LOGIN();'
# Also exercise both test databases with the same commands/environment=test.
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $(docker ps -q --filter label=com.docker.compose.project=gateway-example-alpha) $(docker ps -q --filter label=com.docker.compose.project=gateway-example-beta)

./database alpha down
./database beta down
./database shared up
# Re-run the identical workload using group=shared, then measure both engines:
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $(docker ps -q --filter label=com.docker.compose.project=gateway-example-shared)
```

Record the host/architecture, image IDs, memory limits, dataset/workload, warm-up,
sampling interval, per-container measurements, and **sum of engine RAM** for each
mode. Use repeated steady-state samples, not just image size or one startup
sample. Report measured absolute/percentage change and any latency/contention
tradeoff; packaging alone is not evidence of RAM reduction. Empty-database
results only support a disposable idle-workload claim, not consumer capacity.
After collecting evidence, destroy only these explicitly owned baseline projects
if their data is no longer wanted:

```sh
./database alpha destroy --remove-all-data
./database beta destroy --remove-all-data
```

## Optional gateway attachment

Not needed for any command above. If an existing gateway and external
`local-gateway` network are already available, the project owner can apply:

```sh
DB_SERVER_GROUP=shared docker compose -p gateway-example-shared -f compose.yml -f gateway.yml up -d --wait
```

This attaches the **servers**, not per-checkout engines, and never starts or
restarts the gateway. It advertises `postgres.example-shared.localhost` and
`sqlserver.example-shared.localhost`, one hostname per engine. Connect using the
gateway's PostgreSQL/SQL Server listener and the desired database/login. The
router selects a server from the hostname; **it does not route logical database
names or checkout identities**. `alpha` and `beta` use the same server hostname
but different databases and credentials. Private aliases remain only on the
project network. Do not add a hostname per logical database or publish server
ports; coordinate hostname ownership before using a shared gateway.
