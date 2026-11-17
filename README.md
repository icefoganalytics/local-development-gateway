# Local Development Gateway

One shared loopback-only gateway for browser-facing Docker development services.

It lets several local projects use stable hostnames instead of competing for browser ports. It is intended to run once at the beginning of a development day and remain running while projects start and stop.

## What problem this solves

Without a gateway, two projects commonly both try to publish a web service on port `8080` and a backend service on port `3000`. Only one can start.

With this gateway running, a project routes its internal web service through a checkout-derived hostname instead:

```text
http://example.localhost
                         |
                         v
Local Development Gateway on 127.0.0.1:80
                         |
                         v
Example web container on internal port 8080
```

The checkout folder identifies the project. A separately named worktree such as `issue-123` uses `http://issue-123.example.localhost`; the browser reaches the web service through the gateway on port `80`, not a published application port.

These local `*.localhost` hostnames resolve to loopback and do not require a
public domain, external DNS provider, or internet-facing listener.

The [knowledge base](docs/README.md) connects the [core requirements](docs/requirements/effective-gateway.md), lifecycle ownership, and concrete developer examples for ELCC, WRAP, Travel Authorization, and Traditional Knowledge.

## Start once per day

For the published 0.3.x gem, use the small repository wrapper for the common lifecycle commands. For this branch's Docker-only candidate, follow [Docker-only installation](docs/guides/docker-installation.md), which covers building the unpublished image, installing from one Compose file, and coordinated upgrade/rollback.

```sh
bin/dev up
```

Check the gateway:

```sh
bin/dev status
```

Follow its logs:

```sh
bin/dev logs
```

Stop it only when no participating local project needs it:

```sh
bin/dev down
```

The wrapper also passes unrecognized arguments directly to `docker compose`, so
`bin/dev config` and `bin/dev up --force-recreate` remain available.

Port `80` on `127.0.0.1` must be free before starting. The gateway never binds to a non-loopback address.

## Install as a gem

Consuming projects do not need a gateway checkout. Add the released gem to
their bundle and pin the compatible minor version:

```ruby
gem "local-development-gateway", "~> 0.3.0"
```

Published gem: [`local-development-gateway`](https://rubygems.org/gems/local-development-gateway)

The published 0.3.x gem packages the gateway Compose file and pinned Traefik configuration. Its executable provides the same lifecycle commands:

```sh
bundle exec local-development-gateway up
bundle exec local-development-gateway status
bundle exec local-development-gateway logs
bundle exec local-development-gateway down
```

`local-development-gateway` uses the installed asset path, the
`local-gateway` Compose project and network labels, and the pinned minimum Ruby
version declared by the gem. Use `~> 0.3.0` for the private database alias API below.
The repository's `bin/dev` is only a thin wrapper around this executable API.

### Ruby API lifecycle

Wrap a command that needs the gateway with the block-oriented helper:

```ruby
require "local_development_gateway"

result = LocalDevelopmentGateway.with_running do
  run_development_command
end
```

The helper starts or reuses the gateway before yielding, returns the block's
result, and conditionally stops an unused gateway afterward. Cleanup also runs
when the block raises without replacing the original exception. For a shutdown
command that must not start a missing gateway, pass
`ensure_running: false`; the block still runs and unused-gateway cleanup is
attempted.

### Installed versus active versions

`bundle exec local-development-gateway status` reports the invoking gem's installed version separately from each running shared service's active version and provenance. Healthy CLI `up`/`ensure` reuse also prints these diagnostics without recreating containers. Ruby callers can inspect `LocalDevelopmentGateway.status`; `ensure_running` still returns `:reused` for healthy services, and `ready?` remains a health check, not an artifact-version check.

For the database router, the active version comes from a record written by the Ruby process after loading the library at startup. For the HTTP gateway, it is the gateway configuration artifact version recorded in a container-creation label, not the Traefik image version. Missing records or labels are `unknown`. A legacy mount path containing a gem version is useful diagnostic evidence but does not prove which Ruby code or configuration the running process loaded. Neither version record is a content hash or proof that bind-mounted files have remained unchanged.

Installing a newer gem does not update already-running services. A known difference is reported as `mismatch`; legacy `unknown` provenance cannot establish that an upgrade is active. Coordinate restart timing with all consumers before explicitly updating only the database router:

```sh
bundle exec local-development-gateway up --no-deps --force-recreate database-router
bundle exec local-development-gateway status
```

Recreating the shared database router interrupts existing database client sessions across every consuming project/worktree. This command leaves the HTTP gateway and consumer database containers/volumes alone. If the HTTP gateway itself needs an update, separately coordinate and explicitly select `gateway` instead. Do not use `down` for a router-only update. After updating, confirm the selected service's active version is current and exercise an encrypted connection to the intended database; readiness alone is insufficient release verification.

## Worktree database services

The gateway includes protocol drivers for encrypted SQL Server and PostgreSQL
connections. No host agent, DNS server, administrator privileges, or
`/etc/hosts` changes are required.

### Three connection paths

| Caller | Database hostname | Routing |
| --- | --- | --- |
| Application/API, background job, test container | `LocalDevelopmentGateway.database_alias(project_name:, service_name:)` | Qualified alias on that checkout's private `default` network; internal database port |
| Desktop client, such as DBeaver | `db.<worktree>.<project>.localhost` | Encrypted, hostname-labelled gateway endpoint on loopback |
| Database-local console, backup, clone command | `localhost` | Explicitly select the intended database container first |

Do not use bare database service names for application connections in the current gateway topology. An API attached to both `default` and `local-gateway` can see other projects' database service aliases on the shared network. Docker DNS or network ordering cannot reliably choose its own database. Separate database volumes do not prevent connecting to the wrong server.

The qualified alias belongs **only on the private `default` network**. Compose
project names must be distinct for concurrent checkouts. `.localhost` desktop
names resolve to loopback, not to an internal database container; they are not
substitutes for private aliases. Database cloning is independent of this
hostname correction: it selects source/destination containers explicitly and
connects locally.

### Private database alias length

The complete `<project-name>-<database-service>` alias is one DNS label. [DNS limits each label to 63 octets](https://www.rfc-editor.org/rfc/rfc1035.html#section-2.3.4). Starting in 0.3.0, consumers can opt into a deterministic private alias without renaming their Compose project or its volumes:

```ruby
require "local_development_gateway"

LocalDevelopmentGateway.database_alias(
  project_name: "issue-123-example",
  service_name: "db_reporting"
)
# => "issue-123-example-db_reporting"
```

The pure public function preserves the **entire** `<project-name>-<service-name>` string when it fits, including an exact 63-byte fit. A 60-character project plus `-db` fits; 61 characters needs shortening. For `-db_reporting`, the corresponding boundary is 50/51 characters. Longer aliases become the first 38 characters of the full alias, a hyphen, and the first 24 hexadecimal characters of SHA256 over `project_name + "\0" + service_name`. The NUL separator distinguishes identities whose hyphen-joined forms could otherwise be ambiguous. The 96-bit digest suffix provides collision resistance, not a mathematical guarantee that collisions are impossible. No persistent or random state is involved.

Inputs must be nonempty ASCII strings. Project names start with a lowercase letter or digit and otherwise contain lowercase letters, digits, hyphens, or underscores. Service names start with an ASCII letter or digit and otherwise contain ASCII letters, digits, hyphens, or underscores; case is preserved. Legacy underscores remain supported, even though they are not strict DNS hostname characters. Invalid inputs raise `ArgumentError`; the API does not normalize names.

Use the effective project name selected by [Compose's native precedence](https://docs.docker.com/compose/how-tos/project-name/): `-p`/`--project-name`, then `COMPOSE_PROJECT_NAME`, top-level `name:`, and directory defaults (including native file/project-directory selection). Compose remains the identity owner: ask its ordinary `config --format json` output for `name`, rather than implementing a separate resolver or parsing `.env`. Do not use `--no-interpolate` for identity discovery; it does not reliably resolve interpolated top-level names.

Derive each database alias from that name and its service name, then use the identical value for the private network alias and every matching application/job/test host setting. Preserve project names, volumes, images, credentials, database names, and desktop gateway hostnames. Upgrading the gem alone does not repair unchanged consumers: their wrappers and Compose configuration must adopt the API, then recreate only their affected database/client containers. This private-alias adoption does **not** require restarting the shared gateway or database router.

### Runnable disposable consumer example

[`examples/database-aliases`](examples/database-aliases) supplies a port-free base Compose file, an optional gateway overlay, and a Ruby wrapper. It models a PostgreSQL primary (`db`) plus two SQL Server external-source simulators (`db_reporting` and `db_archive`). A SQL-only project can select just a SQL Server service. The native `postgres_client`, `reporting_client`, and `archive_client` services are diagnostic stand-ins, not application APIs, jobs, or test runners. Real consumers map their own driver settings to the corresponding server aliases and choose a logical database for each context.

Development and tests use the **same server for each role**, not a different server or driver for tests: `app_development`/`app_test` on `db`, `reporting_development`/`reporting_test` on `db_reporting`, and `archive_development`/`archive_test` on `db_archive`. Separate logical test databases protect development data only when the application's test configuration actually selects them. These disposable clients do not demonstrate a consumer's migrations, permissions, or test isolation policy.

Run the following commands from `examples/database-aliases`. With a compatible gem in your bundle, use `bundle exec ruby compose.rb`; outside Bundler, use `ruby compose.rb`. To exercise this checkout's source, use `bundle exec ruby -I../../lib compose.rb`. The wrapper command shape is:

```text
ruby compose.rb [native Compose global options] -- COMMAND [args]
```

Only the `--` delimiter is interpreted by the wrapper. Put native global options such as `-p`, `--project-name`, `--project-directory`, `--env-file`, `--profile`, and `-f` before it; put the Compose command and its arguments after it. With no globals, Compose uses its normal environment and defaults. Keep the same globals/environment for every lifecycle command so they select the same resources.

#### SQL Server-only subset

A SQL-only API, job, and test runner can all use the alias for `db_reporting`, selecting `reporting_development` for development and `reporting_test` for tests. Start only that server; explicitly running its diagnostic client does not start PostgreSQL or the archive server:

```sh
bundle exec ruby compose.rb -- up -d --wait db_reporting
bundle exec ruby compose.rb -- run --rm reporting_client -Q 'CREATE DATABASE reporting_development; CREATE DATABASE reporting_test;'
bundle exec ruby compose.rb -- run --rm reporting_client -d reporting_development -Q 'SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name;'
bundle exec ruby compose.rb -- run --rm reporting_client -d reporting_test -Q 'SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name;'
bundle exec ruby compose.rb -- down
```

#### Full mixed-driver setup

The PostgreSQL image creates `app_development` on its first volume initialization. Create the remaining logical databases once on fresh disposable volumes, then query both development and test selections:

```sh
bundle exec ruby compose.rb -- config
bundle exec ruby compose.rb -- up -d --wait
bundle exec ruby compose.rb -- run --rm postgres_client -d postgres -c 'CREATE DATABASE app_test;'
bundle exec ruby compose.rb -- run --rm reporting_client -Q 'CREATE DATABASE reporting_development; CREATE DATABASE reporting_test;'
bundle exec ruby compose.rb -- run --rm archive_client -Q 'CREATE DATABASE archive_development; CREATE DATABASE archive_test;'

bundle exec ruby compose.rb -- run --rm postgres_client -c 'SELECT current_database(), current_user, inet_server_addr();'
bundle exec ruby compose.rb -- run --rm postgres_client -d app_test -c 'SELECT current_database(), current_user, inet_server_addr();'
bundle exec ruby compose.rb -- run --rm reporting_client -d reporting_development -Q 'SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name;'
bundle exec ruby compose.rb -- run --rm reporting_client -d reporting_test -Q 'SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name;'
bundle exec ruby compose.rb -- run --rm archive_client -d archive_development -Q 'SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name;'
bundle exec ruby compose.rb -- run --rm archive_client -d archive_test -Q 'SELECT @@SERVERNAME AS server_name, DB_NAME() AS database_name;'
bundle exec ruby compose.rb -- down
```

Creation commands intentionally fail if those databases already exist; skip creation when reusing initialized volumes, including after the SQL-only subset. PostgreSQL uses synthetic user `example` and password `development-only`. Both SQL Server instances use `sa` and synthetic password `Example-Only_Strong9!`. These credentials are only for this disposable stack and must not be reused elsewhere. Native clients use standard `PG*`/`SQLCMD*` environment variables; their entrypoints are `psql` and `sqlcmd`, so arguments above are passed directly without repeating the executable. SQL clients initially select `master` to permit database creation; subsequent `-d` arguments select the intended logical database.

Clients belong to the `clients` profile, so ordinary `up --wait` starts only databases. `run` explicitly selects a client without enabling unrelated services. The overlay adds shared ingress while preserving mapping-form private networks. Start the shared gateway first, then use a distinct checkout-derived desktop hostname:

```sh
export GATEWAY_HOSTNAME=issue-123.example.localhost
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- config
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- up -d --wait
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- run --rm postgres_client -d app_test -c 'SELECT current_database();'
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- run --rm reporting_client -d reporting_test -Q 'SELECT DB_NAME();'
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- run --rm archive_client -d archive_test -Q 'SELECT DB_NAME();'
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- down
```

Desktop routes are `db.${GATEWAY_HOSTNAME}:5432`, `reporting.${GATEWAY_HOSTNAME}:1433`, and `archive.${GATEWAY_HOSTNAME}:1433`; container clients continue using private aliases and internal ports. Base-only use needs no gateway.

The wrapper first renders `docker compose [exact globals] config --format json` with discovery-only `POSTGRES_HOST`, `REPORTING_HOST`, and `ARCHIVE_HOST` placeholders. It never starts that configuration. After reading the native `name`, it execs the requested command with derived aliases and exactly the same globals, files, and inherited environment. It does not force a project name, change `COMPOSE_PROJECT_NAME`, or read `.env` itself. Keep project identity independent of these reserved wrapper outputs. Configuration errors stop execution; direct Compose invocation without the required alias variables fails closed.

`down` stops this example's containers and removes its networks while retaining named database volumes. To erase **only disposable example data**, deliberately use `bundle exec ruby compose.rb -- down -v`, adding the exact same global options used to start it. Never remove a consumer's volumes as an alias-adoption step. The creation commands above require fresh volumes or logical databases that do not already exist.

### Canonical development and test Compose pattern

Apply the runnable example's network and alias patterns to the consumer's existing topology; do not replace its database architecture. Preserve its service names, images, credentials, volumes, migrations, and application commands. In this example, the wrapper derives aliases from the effective Compose project name and exports `POSTGRES_HOST` for `db`, `REPORTING_HOST` for `db_reporting`, and `ARCHIVE_HOST` for `db_archive`. These are example interpolation outputs, not prescribed application configuration names.

| Consumer architecture | Development contexts | Test contexts |
| --- | --- | --- |
| SQL Server only | API and jobs select `reporting_development` through `REPORTING_HOST` | Tests select `reporting_test` through the same `REPORTING_HOST` |
| PostgreSQL plus two external SQL Server sources | API and jobs select `app_development` through `POSTGRES_HOST`, `reporting_development` through `REPORTING_HOST`, and `archive_development` through `ARCHIVE_HOST` | Tests use those same three hosts with `app_test`, `reporting_test`, and `archive_test` respectively |

For an application using libpq's standard settings, the primary connection mapping can look like this. Its test service changes the logical database, not the server:

```yaml
services:
  api:
    environment:
      PGHOST: "${POSTGRES_HOST:?derive with database_alias}"
      PGDATABASE: app_development
  test_api:
    environment:
      PGHOST: "${POSTGRES_HOST:?derive with database_alias}"
      PGDATABASE: app_test
  db:
    networks:
      default:
        aliases:
          - "${POSTGRES_HOST:?derive with database_alias}"
```

Map SQL Server connections to the application's existing driver configuration in the same way: the reporting connection uses `REPORTING_HOST` and the archive connection uses `ARCHIVE_HOST`, with port `1433` and the context's intended logical database. Apply each connection to API, job, and test contexts that use it. `SQLCMD*` belongs to the diagnostic client, not a universal application interface. A SQL-only consumer does not need PostgreSQL settings.

The gateway overlay adds labels appropriate to each actual server. For example, this fragment exposes the reporting SQL Server, not the PostgreSQL primary:

```yaml
services:
  db_reporting:
    networks:
      default: {}
      local-gateway: {}
    labels:
      - "local-gateway.tcp.driver=sql_server"
      - "local-gateway.tcp.hostname=reporting.${GATEWAY_HOSTNAME}"
      - "local-gateway.tcp.port=1433"
```

The primary uses driver `postgresql`, hostname `db.${GATEWAY_HOSTNAME}`, and port `5432`; the second SQL Server uses driver `sql_server`, hostname `archive.${GATEWAY_HOSTNAME}`, and port `1433`. The runnable overlay declares the external `local-gateway` network. Each same-driver service needs its own desktop hostname.

Use **mapping-form** database networks in both files. Compose merges `default: {}` with the base's `default.aliases`; replacing that mapping with a network list can lose the private alias. Advertise qualified aliases only on `default`, never on `local-gateway`. Jobs/tests need only `default` unless they themselves expose a routed service; qualified database names remain safe if an existing overlay also attaches them to shared ingress.

The shared router owns `127.0.0.1:1433` and `127.0.0.1:5432`. No participating database publishes either port, so multiple development/test stacks can start concurrently. Internal connections use each server's internal port and existing encryption policy; they do not pass through the router or require a published port.

### Explicit non-gateway fallback

Container-only development/tests work with the base alone. If desktop access without the gateway is required, select a separate, project-local publishing overlay **instead of** the gateway overlay:

```yaml
# docker-compose.development.ports.yml: opt-in, non-gateway mode only.
services:
  db:
    ports:
      - "127.0.0.1:5432:5432"
  db_reporting:
    ports:
      - "127.0.0.1:1433:1433"
```

These fallback ports must be free; this mode does not promise parallel desktop access. The archive SQL Server is intentionally not published in this fragment because the reporting server already occupies port `1433`. Do not combine fallback publications with the gateway or leave them in base/test files. When migrating a project that retains base publications, its gateway overlay must explicitly clear each database's ports with `ports: !reset []` (Docker Compose 2.24.4 or newer); simply omitting `ports` or setting `ports: []` does not remove inherited publications. Prefer the port-free base plus an explicit fallback.

Use the project's documented development wrapper to select Compose modes and start/test/stop services. Inspect its rendered `config`: gateway mode must have no database host publications and must retain the private aliases. A base-only test wrapper must use the same qualified hosts.

### Desktop database clients

For `GATEWAY_HOSTNAME=issue-123.example.localhost`, the runnable mixed-driver example exposes these desktop endpoints:

| Desktop hostname | Driver label | Host port | Client requirement |
| --- | --- | ---: | --- |
| `db.issue-123.example.localhost` | `postgresql` | `5432` | SSL mode `require`, SNI enabled, development certificate accepted |
| `reporting.issue-123.example.localhost` | `sql_server` | `1433` | Encryption enabled and **Trust server certificate** selected |
| `archive.issue-123.example.localhost` | `sql_server` | `1433` | Encryption enabled and **Trust server certificate** selected |

Use the database container's actual internal port in `local-gateway.tcp.port`; it need not match the host listener. Different drivers can share a hostname because their listeners differ. Two databases using the same driver need distinct hostname labels, such as `reporting.${GATEWAY_HOSTNAME}` and `archive.${GATEWAY_HOSTNAME}`.

All `.localhost` names resolve to loopback. The gateway publishes loopback-only
listeners, discovers labelled containers through Docker, and uses the database
protocol's encrypted handshake to select the hostname-labelled container.
Container replacements and stopped routes require no consumer lifecycle code
or cleanup.

SQL Server encryption remains end to end through the router. PostgreSQL TLS
terminates at the gateway; the backend stream is plaintext on the private Docker
network. New PostgreSQL sessions require TLS and SNI, but query cancellation
does not: the gateway substitutes a session-specific cancellation identity and
routes ordinary `psql` and JDBC cancellation packets to that session's backend.
Closed sessions lose their cancellation mapping. See
[`docs/architecture/local-tcp-routing.md`](docs/architecture/local-tcp-routing.md)
for the complete contract and security boundary, including the reason for
retaining cancellation-aware PostgreSQL routing despite Traefik's STARTTLS support.

### Downstream adoption checklist

1. Give each concurrent checkout a distinct Compose project name and desktop route hostname. Derive each private alias from the native effective project name and database service with [`database_alias`](#private-database-alias-length), then set every matching API/job/test driver host. Do not rename an existing project or volumes to fit a DNS budget.
2. Advertise each qualified alias only on its private `default` network;
   preserve it through mapping-form network merges in base-only and gateway modes.
3. Remove fixed database publications from development/test stacks; retain
   desktop fallback publications only in an explicitly selected non-gateway file.
4. Recreate database and consumer services so changed aliases and environment
   settings take effect. Inspect both rendered Compose configurations.
5. Query real, read-only server/database identity from API, job, and test
   contexts and compare it with the explicitly selected local database
   container. Stop that checkout's database while another is available: its
   consumers must fail, not select the other checkout. Record the actual DNS or
   connection error; there is no universal platform error code.
6. Verify both encrypted desktop routes, and restore normal gateway attachments
   after test wrappers recreate services using base-only Compose.

Shared development networks are not a hostile-container security boundary.
Qualified private aliases prevent accidental cross-stack selection; they do not
prevent an attached, malicious container from connecting to another database.

## Development checks

Install the locked development tools with `bundle install`. Ruby lint uses RuboCop's non-fixing `Lint` checks; Syntax Tree owns formatting. These checks run on the host, like the existing Ruby tests: `bin/dev` controls the shared gateway, not a test or lint container. `.omp-verifier.json` declares that native lint command explicitly.

```sh
bundle exec rubocop --lint
bundle exec ruby "$(bundle show syntax_tree)/exe/stree" check \
  Gemfile \
  Rakefile \
  lib/local_development_gateway.rb \
  lib/local_development_gateway/database_alias.rb \
  lib/local_development_gateway/database_router.rb \
  lib/local_development_gateway/database_router/*.rb \
  lib/local_development_gateway/database_router/drivers/*.rb \
  lib/local_development_gateway/database_router/postgre_sql/*.rb \
  lib/local_development_gateway/database_router/tds/*.rb \
  lib/local_development_gateway/version.rb \
  bin/dev \
  bin/database-router \
  bin/local-development-gateway \
  examples/database-aliases/compose.rb \
  examples/shared-databases/bin/dev \
  test/*.rb \
  test/database_router/*.rb \
  test/database_router/drivers/*.rb \
  test/database_router/postgre_sql/*.rb \
  test/database_router/tds/*.rb
rake test
```

## Use case: concurrent application checkouts

Each participating project installs the published gem through its existing dependency and development-wrapper workflow. Its wrapper can start or reuse the shared gateway before starting application services. A primary checkout can use `http://example.localhost`, while a separate worktree uses `http://issue-123.example.localhost`. Routed API or mail services can use corresponding `api.` or `mail.` prefixes when the consumer supplies those labels.

Application shutdown stops that checkout's services. A wrapper using the published 0.3.x gateway lifecycle helper removes the shared gateway only when no other running consumer needs it. Hostname derivation and application lifecycle commands remain consumer responsibilities; the gem does not prescribe a particular application wrapper or rewrite its settings.

The gateway owns the single browser port on `127.0.0.1:80`. Participating projects keep service ports internal to Docker and route browser traffic with explicit Traefik labels.

## Contract for participating projects

The gateway:

- listens only on `127.0.0.1:80`, `127.0.0.1:1433`, and `127.0.0.1:5432`;
- creates the external Docker network `local-gateway` for HTTP and labelled database ingress;
- discovers only services explicitly labelled for routing;
- has the Docker label `local-gateway=true` so a project can detect it.

A participating project joins routed services to `local-gateway` and supplies a checkout-derived hostname plus explicit service labels:

```yaml
services:
  web:
    networks:
      - default
      - local-gateway
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=local-gateway"
      - "traefik.http.routers.<compose-project>-web.rule=Host(`<web-hostname>`)"
      - "traefik.http.routers.<compose-project>-web.entrypoints=web"
      - "traefik.http.services.<compose-project>-web.loadbalancer.server.port=8080"

networks:
  local-gateway:
    external: true
    name: local-gateway
```

Use a project- and service-prefixed router/service identifier. Never derive a destination port from the hostname; each routed service must name one explicit internal destination port.

Without the gateway, a participating project may use its own loopback port-publishing fallback. That fallback is project-specific and is not part of the shared gateway contract.

Application/job/test database connections follow the
[private-alias contract](#three-connection-paths), not desktop gateway hostnames
or bare database service names. Database services retain their private network
and add gateway labels without publishing host ports. The
[architecture decision](docs/architecture/local-tcp-routing.md#internal-database-isolation-decision)
explains why a future HTTP/database ingress split requires coordinated consumer
migration rather than a transparent gem update.

## Application-owned integrations

Consumers configure their own public application URLs, browser origins, and identity-provider registrations to match their selected local hostnames. The gateway routes labelled services; it does not register callbacks, configure authentication, or guarantee an identity provider's wildcard policy. Keep production and staging registrations independent of local development settings.

## Security boundary

The gateway publishes port `80` only to the local machine. It does not create a public endpoint.

It mounts the Docker socket so it can discover labelled containers. A read-only socket mount still exposes broad Docker metadata and control-plane access. Treat anyone who can modify this repository or its running gateway container as having significant access to local Docker. Do not run untrusted gateway images or route untrusted containers through it.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Gateway will not start | Confirm `127.0.0.1:80` is free. |
| Generated hostname returns `404` | Confirm the web container has the route labels and is attached to `local-gateway`. |
| A project uses normal ports unexpectedly | Confirm the gateway container is running and has `local-gateway=true`. |
| Authentication rejects a local URL | Check the consumer's configured application URL and identity-provider registration for the selected hostname. |

## Release 0.3.3

- Describe historical verification with generic server roles and checkout hostnames, preserving the tested versions and outcomes without consumer-specific identifiers. Runtime and runnable examples are unchanged.

## Release 0.3.2

- Replace consumer-specific examples with a generic PostgreSQL primary and two SQL Server external-source simulators, plus a SQL-only subset and native diagnostic clients.
- Document same-server development/test database selection, real initialization/query commands, and safe disposable-data cleanup. The library runtime, routing, alias API, and consumer configurations are unchanged; no shared gateway restart is required.

## Release 0.3.1

- Resolve the existing Ruby lint diagnostics without suppressions or reduced coverage. Clarify range and assertion boundaries, retain EOF handling through `IOError`, and use supported OpenSSL digest construction and socket-readiness APIs.
- Database routing, cancellation, lifecycle, and consumer alias contracts are unchanged; no shared gateway restart or consumer configuration change is required.

## Release 0.3.0

- Add the opt-in `LocalDevelopmentGateway.database_alias(project_name:, service_name:)` API: preserve short/exact-fit identities and deterministically shorten long private aliases with a 96-bit SHA256 suffix.
- Document native Compose identity discovery and provide a disposable multi-database consumer example for base-only and gateway modes. Existing consumer configuration is not rewritten; no shared gateway restart or project/volume rename is required.

## Release 0.2.4

- Document suffix-specific DNS length budgets for private database aliases and data-safe project-name handling. No alias validation, shortening, routing, or lifecycle behavior changes.

## Release 0.2.3

- Status and healthy CLI reuse distinguish the installed gem version from each active shared service, reporting mismatches and unknown legacy provenance without restarting services.
- Scoped router update instructions explain shared database session interruption and keep restart timing under caller control. Health readiness and Ruby lifecycle return values remain unchanged.

## Release 0.2.2

- Canonical SQL Server/PostgreSQL Compose integration supports concurrent
  development/test stacks without per-stack database host publications.
- Application, job, and test connections use checkout-qualified private aliases
  instead of ambiguous shared-network service names. Base-only mode, explicit
  non-gateway fallback, multiple databases, and adoption checks are documented.
- The packaged architecture reference records the current private-alias
  decision, real-container Linux validation, and coordinated migration required
  for a future HTTP/database ingress split.
- Gateway routing and the public Ruby API are unchanged. Consumers must adopt
  the Compose contract; upgrading the gem does not rewrite their configuration.

## Release 0.2.1

- PostgreSQL query cancellation works across concurrent worktrees, including
  plaintext cancellation from `psql` and JDBC and encrypted cancellation.
  Session-specific identities prevent backend key collisions and expire when
  their session closes.
- Invalid database labels and duplicate hostname identities reject only the
  affected routes, leaving unrelated worktrees and database drivers available.
- SQL Server negotiation can fall back from a stalled backend within the
  shared handshake deadline.
- PostgreSQL STARTTLS support in Traefik is documented accurately. The gateway
  retains cancellation-aware session routing without changing consumer labels.
