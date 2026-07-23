# Local Development Gateway

One shared loopback-only gateway for browser-facing Docker development services.

It lets several local projects use stable hostnames instead of competing for browser ports. It is intended to run once at the beginning of a development day and remain running while projects start and stop.

## What problem this solves

Without a gateway, two projects commonly both try to publish a web service on port `8080` and a backend service on port `3000`. Only one can start.

With this gateway running, a project can publish its internal web service through a generated hostname instead:

```text
http://stack-35053.traditional-knowledge.localhost
                 |
                 v
Local Development Gateway on 127.0.0.1:80
                 |
                 v
Traditional Knowledge web container on port 8080
```

The generated hostname is a local `*.localhost` name. It resolves to loopback and does not require a public domain, external DNS provider, or internet-facing listener.

## Start once per day

```sh
docker compose up -d
```

Check the gateway:

```sh
docker compose ps
```

Stop it only when no participating local project needs it:

```sh
docker compose down
```
Port `80` on `127.0.0.1` must be free before starting. The gateway never binds to a non-loopback address.

## Use case: Traditional Knowledge beside WRAP

1. Start this gateway once.
2. Run `dev up` in Traditional Knowledge. It detects the running gateway, generates descriptive ports and a `TRADITIONAL_KNOWLEDGE_WEB_HOSTNAME`, and adds route labels to its web container.
3. Open the generated hostname from `.dev-ports.env`.
4. When WRAP adopts the same contract, start it normally. It can then use its own generated route labels and hostname through this same gateway.

Each project receives an independent hostname, while the gateway owns the single browser port.

If this gateway is unavailable, Traditional Knowledge deliberately falls back to its original localhost ports, including web port `8080` and backend port `3000`. That fallback may conflict with another project; start the gateway when concurrent development is needed.

## Contract for participating projects

The gateway:

- listens only on `127.0.0.1:80`;
- creates the external Docker network `local-gateway`;
- discovers only services explicitly labelled for routing;
- has the Docker label `local-gateway=true` so a project can detect it.

A participating web service joins `local-gateway` and supplies explicit route labels:

```yaml
services:
  web:
    networks:
      - default
      - local-gateway
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=local-gateway"
      - "traefik.http.routers.<stack-identifier>.rule=Host(`<generated-hostname>.localhost`)"
      - "traefik.http.routers.<stack-identifier>.entrypoints=web"
      - "traefik.http.routers.<stack-identifier>.service=<stack-identifier>"
      - "traefik.http.services.<stack-identifier>.loadbalancer.server.port=8080"

networks:
  local-gateway:
    external: true
    name: local-gateway
```

Use a unique stack identifier for every running project instance. Never derive a destination port from the hostname; each route must name one explicit Docker service and internal port.

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
