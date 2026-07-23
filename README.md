# Local Development Gateway

A shared Docker gateway for browser-facing local development stacks.

## Start once per day

```sh
docker compose up -d
```

Stop it only when no local stack needs it:

```sh
docker compose down
```

## Contract for participating projects

The gateway:

- listens only on `127.0.0.1:80`;
- creates the external Docker network `local-gateway`;
- discovers only services explicitly labelled for Traefik routing;
- has the Docker label `local-gateway=true` so projects can detect it.

A participating web service joins `local-gateway` and supplies route labels like:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.docker.network=local-gateway"
  - "traefik.http.routers.<stack-identifier>.rule=Host(`<generated-hostname>.localhost`)"
  - "traefik.http.routers.<stack-identifier>.entrypoints=web"
  - "traefik.http.routers.<stack-identifier>.service=<stack-identifier>"
  - "traefik.http.services.<stack-identifier>.loadbalancer.server.port=8080"
```

Use `*.localhost` hostnames. They resolve to loopback and need no public domain or DNS provider.
