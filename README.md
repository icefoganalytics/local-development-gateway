# Local Development Gateway

One shared loopback-only gateway for browser-facing Docker development services.

It lets several local projects use stable hostnames instead of competing for browser ports. It is intended to run once at the beginning of a development day and remain running while projects start and stop.

## What problem this solves

Without a gateway, two projects commonly both try to publish a web service on port `8080` and a backend service on port `3000`. Only one can start.

With this gateway running, a project can publish its internal web service through a generated hostname instead:

```text
http://port-35053.traditional-knowledge.localhost
                         |
                         v
Local Development Gateway on 127.0.0.1:80
                         |
                         v
Traditional Knowledge web container on internal port 8080
```

`port-35053` is derived from Traditional Knowledge's generated `WEB_PORT` value. It identifies the project instance; the browser reaches the web service through the gateway on port `80`, not directly on port `35053`.

The generated hostname is a local `*.localhost` name. It resolves to loopback and does not require a public domain, external DNS provider, or internet-facing listener.

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
gem "local-development-gateway", "~> 0.1.0"
```

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
version declared by the gem. Upgrade the version constraint when a new
compatible release is published. The repository's `bin/dev` is only a thin
wrapper around this executable API.

## Use case: Traditional Knowledge beside WRAP

1. Start this gateway once.
2. Run `dev up` in Traditional Knowledge. It writes role-based generated values to `.env.development.local`, including `WEB_PORT`, `BACKEND_PORT`, and `WEB_HOSTNAME=port-<WEB_PORT>.traditional-knowledge.localhost`.
3. With the gateway running, Traditional Knowledge's web container joins `local-gateway`, its direct web publishing is removed, and the generated hostname routes through the gateway on `127.0.0.1:80`.
4. Open `WEB_HOSTNAME` from `.env.development.local`.
5. When WRAP adopts the same contract, start it normally. It can then use its own generated route labels and hostname through this same gateway.

Each project receives an independent hostname, while the gateway owns the single browser port. The generated `WEB_PORT` is an identity seed in gateway mode, not the browser-facing port.

Without the gateway, Traditional Knowledge publishes the same generated values directly, including `localhost:<WEB_PORT>` for the web service and `localhost:<BACKEND_PORT>` for the backend. `dev up` regenerates unavailable assignments; deleting `.env.development.local` forces a fresh assignment.

## Contract for participating projects

The gateway:

- listens only on `127.0.0.1:80`;
- creates the external Docker network `local-gateway`;
- discovers only services explicitly labelled for routing;
- has the Docker label `local-gateway=true` so a project can detect it.

A participating project writes role-based generated values to its local `.env.development.local`:

```dotenv
WEB_PORT=35053
BACKEND_PORT=38261
WEB_HOSTNAME=port-35053.traditional-knowledge.localhost
```

With the gateway available, its web service joins `local-gateway` and supplies explicit route labels. Use a project-prefixed identifier containing the published `BACKEND_PORT` for the internal router/service name; do not generate a separate `STACK_IDENTIFIER`:

```yaml
services:
  web:
    networks:
      - default
      - local-gateway
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=local-gateway"
      - "traefik.http.routers.<project>-<backend-port>.rule=Host(`<web-hostname>`)"
      - "traefik.http.routers.<project>-<backend-port>.entrypoints=web"
      - "traefik.http.routers.<project>-<backend-port>.service=<project>-<backend-port>"
      - "traefik.http.services.<project>-<backend-port>.loadbalancer.server.port=8080"

networks:
  local-gateway:
    external: true
    name: local-gateway
```

Without the gateway, publish the same generated values directly:

```yaml
services:
  web:
    ports:
      - "127.0.0.1:${WEB_PORT}:8080"
  backend:
    ports:
      - "127.0.0.1:${BACKEND_PORT}:3000"
```

Use a unique generated `WEB_PORT` and `BACKEND_PORT` for every running project instance. Never derive a destination port from the hostname; each route must name one explicit Docker service and internal port.

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
