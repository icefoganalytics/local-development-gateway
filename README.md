# Local Development Gateway

One shared loopback-only gateway for browser-facing Docker development services.

It lets several local projects use stable hostnames instead of competing for browser ports. It is intended to run once at the beginning of a development day and remain running while projects start and stop.

## What problem this solves

Without a gateway, two projects commonly both try to publish a web service on port `8080` and a backend service on port `3000`. Only one can start.

With this gateway running, a project routes its internal web service through a
checkout-derived hostname instead:

```text
http://traditional-knowledge.localhost
                         |
                         v
Local Development Gateway on 127.0.0.1:80
                         |
                         v
Traditional Knowledge web container on internal port 8080
```

The checkout folder identifies the project. A separately named worktree such as
`issue-123` uses `http://issue-123.traditional-knowledge.localhost`; the browser
reaches the web service through the gateway on port `80`, not a published
application port.

These local `*.localhost` hostnames resolve to loopback and do not require a
public domain, external DNS provider, or internet-facing listener.

## Start once per day

Use the small repository wrapper for the common lifecycle commands:

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

The gem packages the gateway Compose file and pinned Traefik configuration.
Its executable provides the same lifecycle commands:

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

`bundle exec local-development-gateway status` reports the invoking gem's installed version separately from each running shared service's active version, provenance, and mounted asset path. Healthy CLI `up`/`ensure` reuse also prints these diagnostics without recreating containers. Ruby callers can inspect `LocalDevelopmentGateway.status`; `ensure_running` still returns `:reused` for healthy services, and `ready?` remains a health check, not an artifact-version check.

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

Do not use bare `db` or `db_trav_com` for application connections in the current
gateway topology. An API attached to both `default` and `local-gateway` can see
other projects' database service aliases on the shared network. Docker DNS or
network ordering cannot reliably choose its own database. Separate database
volumes do not prevent connecting to the wrong server.

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
  service_name: "db_trav_com"
)
# => "issue-123-example-db_trav_com"
```

The pure public function preserves the **entire** `<project-name>-<service-name>` string when it fits, including an exact 63-byte fit. A 60-character project plus `-db` fits; 61 characters needs shortening. For `-db_trav_com`, the corresponding boundary is 51/52 characters. Longer aliases become the first 38 characters of the full alias, a hyphen, and the first 24 hexadecimal characters of SHA256 over `project_name + "\0" + service_name`. The NUL separator distinguishes identities whose hyphen-joined forms could otherwise be ambiguous. The 96-bit digest suffix provides collision resistance, not a mathematical guarantee that collisions are impossible. No persistent or random state is involved.

Inputs must be nonempty ASCII strings. Project names start with a lowercase letter or digit and otherwise contain lowercase letters, digits, hyphens, or underscores. Service names start with an ASCII letter or digit and otherwise contain ASCII letters, digits, hyphens, or underscores; case is preserved. Legacy underscores remain supported, even though they are not strict DNS hostname characters. Invalid inputs raise `ArgumentError`; the API does not normalize names.

Use the effective project name selected by [Compose's native precedence](https://docs.docker.com/compose/how-tos/project-name/): `-p`/`--project-name`, then `COMPOSE_PROJECT_NAME`, top-level `name:`, and directory defaults (including native file/project-directory selection). Compose remains the identity owner: ask its ordinary `config --format json` output for `name`, rather than implementing a separate resolver or parsing `.env`. Do not use `--no-interpolate` for identity discovery; it does not reliably resolve interpolated top-level names.

Derive each database alias from that name and its service name, then use the identical value for the private network alias and every matching application/job/test host setting. Preserve project names, volumes, images, credentials, database names, and desktop gateway hostnames. Upgrading the gem alone does not repair unchanged consumers: their wrappers and Compose configuration must adopt the API, then recreate only their affected database/client containers. This private-alias adoption does **not** require restarting the shared gateway or database router.

### Runnable disposable consumer example

[`examples/database-aliases`](examples/database-aliases) supplies real base and gateway-overlay Compose files and a small Ruby wrapper. This is an adoption example, not a downstream rollout or a replacement for a consumer's existing driver configuration, images, data, or lifecycle wrapper. Both databases use PostgreSQL to demonstrate distinct services with the same driver; `api`/`jobs` select `app_data` on `db`, while `test_api` selects `test_data` with separate credentials on `db_trav_com`. The development-only credentials must not be reused outside this disposable stack. No database publishes host ports.

Run from `examples/database-aliases`. With the 0.3.0 gem available in your bundle, use `bundle exec ruby compose.rb`; with a compatible gem installed outside Bundler, use `ruby compose.rb`. To exercise this repository's source instead, use `bundle exec ruby -I../../lib compose.rb`. The command shape is:

```text
ruby compose.rb [native Compose global options] -- COMMAND [args]
```

Only the `--` delimiter is interpreted by the wrapper. Put native global options such as `-p`, `--project-name`, `--project-directory`, `--env-file`, `--profile`, and `-f` before it; put the Compose command and its arguments after it. With no globals, Compose uses its normal environment and defaults. Keep the same globals/environment for subsequent lifecycle commands so they select the same resources.

```sh
# Base-only: Compose chooses the project identity; only the databases start.
bundle exec ruby compose.rb -- config
bundle exec ruby compose.rb -- up -d --wait
bundle exec ruby compose.rb -- run --rm api psql -c 'SELECT current_database(), current_user, inet_server_addr()'
bundle exec ruby compose.rb -- run --rm jobs psql -c 'SELECT current_database(), current_user, inet_server_addr()'
bundle exec ruby compose.rb -- run --rm test_api psql -c 'SELECT current_database(), current_user, inet_server_addr()'
bundle exec ruby compose.rb -- down

# Optional overlay: the shared gateway/network must already be available.
# Choose a unique checkout-derived desktop hostname; do not change an existing
# stack's project identity just to shorten its aliases.
export GATEWAY_HOSTNAME=issue-123.database-aliases.localhost
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- config
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- up -d --wait
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- run --rm api psql -c 'SELECT current_database()'
bundle exec ruby compose.rb -f compose.yml -f gateway.yml -- down
```

Clients are in the `clients` profile so ordinary `up --wait` remains database-only; `run` explicitly selects each client. To keep clients running for `exec` checks, add `--profile clients` before `--`. The overlay attaches databases and all clients to shared ingress while preserving their mapping-form private networks. Desktop routes are `db.${GATEWAY_HOSTNAME}` and `secondary-db.${GATEWAY_HOSTNAME}` on port 5432 with SSL mode `require` and SNI; container clients still use private aliases and internal port 5432.

The wrapper first renders `docker compose [exact globals] config --format json` with discovery-only `DB_HOST`/`DB_TRAV_COM_HOST` placeholders. It never starts that configuration. After reading the native `name`, it execs the requested command with derived aliases and the exact same globals, files, and inherited environment. It does not force a project name, change `COMPOSE_PROJECT_NAME`, or read `.env` itself. Keep project identity independent of these two host variables; they are reserved wrapper outputs. Configuration errors stop execution. Direct Compose invocation without those variables fails closed through `${DB_HOST:?run compose.rb}` and `${DB_TRAV_COM_HOST:?run compose.rb}`. Named volumes survive `down`; use `down -v` through the same wrapper/options only when deliberately discarding this example's disposable data. None of these commands mutates or restarts the shared gateway.

### Canonical development and test Compose pattern

Merge these entries into the project's existing development base and gateway
overlay. Keep its database images, credentials, volumes, and application
commands. The base must not publish database host ports. Use the driver's
existing configuration keys: `AZURE_SQL_HOST` is a SQL Server application
example; `PGHOST` is the PostgreSQL/libpq equivalent. An application with a
different PostgreSQL configuration key must set that key instead.

For example, an effective Compose project name `issue-123-example` gives private hosts `issue-123-example-db` and `issue-123-example-db_trav_com`. Have the consumer wrapper export the API results as `DB_HOST` and `DB_TRAV_COM_HOST` for interpolation below. These are wrapper variables, not new application driver settings. `GATEWAY_HOSTNAME=issue-123.example.localhost` separately identifies desktop routes.

```yaml
# docker-compose.development.yml: also safe without the gateway overlay.
services:
  api:
    environment:
      AZURE_SQL_HOST: "${DB_HOST:?derive with database_alias}"
      PGHOST: "${DB_TRAV_COM_HOST:?derive with database_alias}"
  jobs:
    environment:
      AZURE_SQL_HOST: "${DB_HOST:?derive with database_alias}"
      PGHOST: "${DB_TRAV_COM_HOST:?derive with database_alias}"
  test_api:
    environment:
      AZURE_SQL_HOST: "${DB_HOST:?derive with database_alias}"
      PGHOST: "${DB_TRAV_COM_HOST:?derive with database_alias}"
  db:
    networks:
      default:
        aliases:
          - "${DB_HOST:?derive with database_alias}"
  db_trav_com:
    networks:
      default:
        aliases:
          - "${DB_TRAV_COM_HOST:?derive with database_alias}"
```

The example's driver assignments are illustrative. In
[Travel Authorization's overlay](https://github.com/icefoganalytics/travel-authorization/blob/main/docker-compose.development.gateway.yml),
`db` is PostgreSQL and `db_trav_com` is SQL Server: its PostgreSQL host setting
must use the alias derived for `db`, and its SQL Server host setting must use the alias derived for `db_trav_com`, with labels/ports matching those drivers.
Apply the rule separately to **every** database service, even when two services
use the same driver. Preserve each context's existing credentials, internal
port, and database name; tests must still select the test database rather than
development data.

```yaml
# docker-compose.development.gateway.yml
services:
  api:
    networks:
      - default
      - local-gateway
  db:
    networks:
      default: {}
      local-gateway: {}
    labels:
      - "local-gateway.tcp.driver=sql_server"
      - "local-gateway.tcp.hostname=db.${GATEWAY_HOSTNAME}"
      - "local-gateway.tcp.port=1433"
  db_trav_com:
    networks:
      default: {}
      local-gateway: {}
    labels:
      - "local-gateway.tcp.driver=postgresql"
      - "local-gateway.tcp.hostname=db.${GATEWAY_HOSTNAME}"
      - "local-gateway.tcp.port=5432"

networks:
  local-gateway:
    external: true
    name: local-gateway
```

Use **mapping-form** database networks in both files. Compose merges
`default: {}` with the base's `default.aliases`; replacing that mapping with a
network list can lose the private alias. Do not add qualified aliases to
`local-gateway`. Jobs/tests need only `default` unless they themselves expose a
routed service; qualified database names remain safe if an existing overlay
also attaches them to the shared network.

The shared router owns `127.0.0.1:1433` and `127.0.0.1:5432`. No participating
database publishes either port, so multiple development/test stacks can start
concurrently. Internal connections use each server's internal port and existing
encryption policy; they do not pass through the router or require a published
port.

### Explicit non-gateway fallback

Container-only development/tests work with the base alone. If desktop access
without the gateway is required, select a separate, project-local publishing
overlay **instead of** the gateway overlay:

```yaml
# docker-compose.development.ports.yml: opt-in, non-gateway mode only.
services:
  db:
    ports:
      - "127.0.0.1:1433:1433"
  db_trav_com:
    ports:
      - "127.0.0.1:5432:5432"
```

These fallback ports must be free; this mode does not promise parallel desktop
access. Do not combine it with the gateway or leave these publications in the
base/test files. When migrating a project that retains base publications, its
gateway overlay must explicitly clear each database's ports with
`ports: !reset []` (Docker Compose 2.24.4 or newer); simply omitting `ports` or
setting `ports: []` does not remove inherited publications. Prefer the
port-free base plus explicit fallback above.

Use the project's documented development wrapper to select Compose modes and
start/test/stop services. Inspect its rendered `config`: gateway mode must have
no database host publications and must retain the private aliases. A base-only
test wrapper must use the same qualified hosts.

### Desktop database clients

For `GATEWAY_HOSTNAME=issue-123.example.localhost`, connect to
`db.issue-123.example.localhost` on the driver's standard port:

| Driver label | Host port | Client requirement |
| --- | ---: | --- |
| `sql_server` | `1433` | Encryption enabled and **Trust server certificate** selected |
| `postgresql` | `5432` | SSL mode `require`, SNI enabled, development certificate accepted |

Use the database container's actual internal port in
`local-gateway.tcp.port`; it need not match the host listener. Different drivers
can share a hostname because their listeners differ. Two databases using the
same driver need distinct labels, for example `db.${GATEWAY_HOSTNAME}` and
`db_trav_com.${GATEWAY_HOSTNAME}`.

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
  bin/local-development-gateway \
  examples/database-aliases/compose.rb \
  test/*.rb \
  test/database_router/*.rb \
  test/database_router/drivers/*.rb \
  test/database_router/postgre_sql/*.rb \
  test/database_router/tds/*.rb
rake test
```

## Use case: Traditional Knowledge beside WRAP

1. Use the published gateway gem; it starts or reuses the shared gateway when Traditional Knowledge starts.
2. Run `bundle install` in Traditional Knowledge so the published gateway gem is available.
3. Run `dev up --watch` in Traditional Knowledge. The gateway is the browser entrypoint; the base checkout uses `http://traditional-knowledge.localhost`, with the API at `http://api.traditional-knowledge.localhost` and MailDev at `http://mail.traditional-knowledge.localhost`.
4. A separately named checkout or worktree derives its own hostname, such as `http://issue-123.traditional-knowledge.localhost`. The API and MailDev hosts use the corresponding `api.` and `mail.` prefixes.
5. Run `dev down` to stop the application services. It stops the shared gateway only when no other project is attached.
6. When WRAP adopts the same contract, it can use its own checkout-derived hostnames through this shared gateway.

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

## Authentication callbacks

A wildcard hostname lets an identity provider allow one local callback pattern instead of every generated port. For Traditional Knowledge, configure:

```text
Allowed Callback URLs: http://*.traditional-knowledge.localhost/callback
Allowed Logout URLs:   http://*.traditional-knowledge.localhost
Allowed Web Origins:   http://*.traditional-knowledge.localhost
```

Keep existing production and staging entries. Verify that the identity provider accepts wildcard hostnames in each field before relying on this pattern.

## Security boundary

The gateway publishes port `80` only to the local machine. It does not create a public endpoint.

It mounts the Docker socket so it can discover labelled containers. A read-only socket mount still exposes broad Docker metadata and control-plane access. Treat anyone who can modify this repository or its running gateway container as having significant access to local Docker. Do not run untrusted gateway images or route untrusted containers through it.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Gateway will not start | Confirm `127.0.0.1:80` is free. |
| Generated hostname returns `404` | Confirm the web container has the route labels and is attached to `local-gateway`. |
| A project uses normal ports unexpectedly | Confirm the gateway container is running and has `local-gateway=true`. |
| Authentication rejects the callback | Confirm the generated hostname matches the allowed wildcard callback pattern. |

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
