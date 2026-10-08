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
gem "local-development-gateway", "~> 0.2"
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
version declared by the gem. The `~> 0.2` constraint follows the consuming
project's published Gemfile.
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

## Worktree database services

The gateway includes protocol drivers for encrypted SQL Server and PostgreSQL
connections. No host agent, DNS server, administrator privileges, or
`/etc/hosts` changes are required.

A participating project only joins its existing database service to
`local-gateway` and adds three labels:

```yaml
services:
  db:
    networks:
      - default
      - local-gateway
    labels:
      - "local-gateway.tcp.driver=sql_server"
      - "local-gateway.tcp.hostname=db.${GATEWAY_HOSTNAME:-wrap.localhost}"
      - "local-gateway.tcp.port=1433"

networks:
  local-gateway:
    external: true
    name: local-gateway
```

For a worktree whose `GATEWAY_HOSTNAME` is `issue-567.wrap.localhost`, DBeaver
connects to `db.issue-567.wrap.localhost` on the driver's standard port:

| Driver label | Host port | Client requirement |
| --- | ---: | --- |
| `sql_server` | `1433` | Encryption enabled and **Trust server certificate** selected |
| `postgresql` | `5432` | SSL mode `require` |

Use the database container's actual internal port in
`local-gateway.tcp.port`; it does not need to match the host listener.

Remove the database's host `ports` publication when using the gateway; the shared
router owns `127.0.0.1:1433` and `127.0.0.1:5432`. Keep the `default` network so
application and test containers still connect directly to `db` on its internal
port, without TLS or a host-published port. A project not using the gateway must
select its own explicit port-publishing fallback.

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

## Development checks

Install the locked development tools with `bundle install`. Run the Ruby
formatter check and tests with:

```sh
bundle exec ruby "$(bundle show syntax_tree)/exe/stree" check \
  Gemfile \
  Rakefile \
  lib/local_development_gateway.rb \
  lib/local_development_gateway/database_router.rb \
  lib/local_development_gateway/database_router/*.rb \
  lib/local_development_gateway/database_router/drivers/*.rb \
  lib/local_development_gateway/database_router/postgre_sql/*.rb \
  lib/local_development_gateway/database_router/tds/*.rb \
  lib/local_development_gateway/version.rb \
  bin/dev \
  bin/local-development-gateway \
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

- listens only on `127.0.0.1:80`;
- creates the external Docker network `local-gateway`;
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
