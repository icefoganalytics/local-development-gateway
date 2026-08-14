# Local TCP Routing Architecture

Status: SQL Server and PostgreSQL protocol routing implemented in PR #22; user review pending.

## Request

Extend Local Development Gateway so a participating Docker Compose project can
expose hostname-routed database services with the same simple declarative
integration it already uses for HTTP services.

For WRAP, database routing should require only a small change to
`docker-compose.development.gateway.yml`. WRAP must not implement address
allocation, routing, DNS, host-file management, startup orchestration, or
cleanup.

The initial endpoints are:

```text
db.<worktree>.wrap.localhost:1433 # SQL Server
db.<worktree>.wrap.localhost:5432 # PostgreSQL
```

Each must connect from DBeaver to that worktree's labelled database container.

## Consumer Contract

A participating project declares the service in Compose using the existing `local-gateway` network and these gateway-owned labels:

```yaml
services:
  db:
    networks:
      - default
      - local-gateway
    labels:
      - "local-gateway.tcp.driver=sql_server"
      - "local-gateway.tcp.hostname=db.${GATEWAY_HOSTNAME}"
      - "local-gateway.tcp.port=1433"

networks:
  local-gateway:
    external: true
    name: local-gateway
```

Requirements:

- No consumer Ruby API calls.
- No consumer-side address allocator.
- No per-worktree host-port selection.
- No bind-address environment variable passed from application code.
- No consumer startup or shutdown hook solely for gateway routing.
- No consumer cleanup call.
- No manually maintained DBeaver port per worktree.
- The consumer supplies only declarative service identity and internal-port metadata.

- No administrator or root installation.
- No host `/etc/hosts`, DNS, resolver, systemd, or Windows-service changes.
- The same gateway Compose stack must run through Docker on Linux and Windows.

## Gateway Responsibilities

All implementation belongs in this repository. The gateway must:

1. Discover participating containers and their routing metadata through Docker.
2. Derive or read the requested hostname and target internal port.
3. Distinguish concurrent worktrees even when they expose the same internal TCP port.
4. Make `db.<worktree>.wrap.localhost` resolve or connect to the correct worktree route on the local machine.
5. Forward the raw TCP stream to the labelled container.
6. Add, update, and remove routes automatically as containers start, restart, and stop.
7. Preserve stable routing for a worktree while it remains active.
8. Keep all listeners and generated routes local to the developer machine.
9. Preserve the existing HTTP routing behavior.

## Implemented Routing Shape

Every `.localhost` name intentionally resolves to loopback on both Linux and
Windows. A shared port therefore requires a protocol-level hostname. The
gateway uses one Docker-label discovery path and a small driver for each
supported database handshake:

```text
DBeaver
  -> db.<worktree>.wrap.localhost:<driver port>
  -> Docker publishes the database router on loopback
  -> driver reads the encrypted handshake hostname
  -> router selects the matching Docker label
  -> router forwards the database stream to the labelled container
```

The `sql_server` driver mediates Tabular Data Stream (TDS) PRELOGIN, reads SNI
from the wrapped TLS ClientHello, then preserves the encrypted client/backend
stream. The
`postgresql` driver accepts PostgreSQL's SSLRequest, terminates the client TLS
session to obtain SNI, and forwards the plaintext PostgreSQL stream on the
private Docker network.

Traefik remains responsible for HTTP. It cannot inspect TLS SNI wrapped inside
TDS PRELOGIN or the TLS handshake that follows a PostgreSQL SSLRequest.

Encrypted connections are required so the requested hostname is present as
TLS SNI. The router supports only the handshake framing required to select a
backend; it is not a database protocol implementation.

## Code Organization

`DatabaseRouter` owns listener concurrency, backend connection lifecycle, and
bidirectional stream forwarding. `DockerApi` and `DockerRoutes` form the
external Docker boundary and produce validated `Route` values. Behavior-bearing
classes each have one file, and directories map to Ruby namespaces: database
drivers live under `DatabaseRouter::Drivers`, while TDS framing and wrapped TLS
parsing live under `DatabaseRouter::Tds`. Tiny immutable `Route` and TDS
`Packet` records stay with the classes that own them rather than creating empty
standalone subclasses.

Source and test imports resolve from the gem's `lib` load path and start at
`local_development_gateway`; domain files never traverse sibling paths with
`require_relative`.

The focused tests mirror those boundaries under `test/database_router/`.
Protocol scenarios keep their literal setup beside the behavior they verify
instead of sharing a generic fixture layer.

## Hostname Contract

- Keep the established WRAP hostname family.
- HTTP remains:
  - `<worktree>.wrap.localhost`
  - `api.<worktree>.wrap.localhost`
  - `mail.<worktree>.wrap.localhost`
- SQL Server is:
  - `db.<worktree>.wrap.localhost`
- PostgreSQL uses the same hostname on port `5432`.
- Do not migrate consumers to `.test`, `.alt`, `.local`, `home.arpa`, or an externally registered domain as part of this issue.
- Do not require host resolver configuration; `.localhost` must retain its native loopback behavior.

## Security Boundary

- No routed service may be reachable from another machine.
- Bind host listeners only to loopback addresses.
- Do not publish generated names through public DNS.
- Do not expose SQL Server on `0.0.0.0` or a LAN interface.
- Do not require privileged host integration.
- Do not grant a long-running container unrestricted write access to arbitrary host files.
- The database router receives the same read-only Docker socket already required by Traefik so it can resolve labels to current container addresses.
- SQL Server remains encrypted end to end. PostgreSQL is plaintext only inside the private Docker network after the gateway terminates client TLS.

## Lifecycle

- The router reads current Docker metadata for every new connection; starting, restarting, or stopping a labelled container therefore requires no stored route state or cleanup.
- Duplicate active hostname labels are rejected instead of selecting an arbitrary container.
- A connection snapshot never changes backend after selection.
- Gateway restart requires no route reconstruction because Docker metadata is the source of truth.

## Compatibility

- DBeaver connects to `db.<worktree>.wrap.localhost` on `1433` for SQL Server
  or `5432` for PostgreSQL.
- SQL Server clients must enable encryption and trust the development server
  certificate.
- PostgreSQL clients must use SSL mode `require`, send SNI, and permit the
  gateway's generated development certificate.
- Concurrent SQL Server routes must use compatible PRELOGIN encryption
  settings because the client receives a provisional backend's negotiation
  response before SNI identifies the final backend.
- PostgreSQL backends must accept a plaintext connection from the private
  `local-gateway` Docker network.
- Existing browser routes through Traefik on `127.0.0.1:80` remain unchanged.
- Multiple active worktrees can use each database driver's standard port
  simultaneously.
- Adding another protocol requires another explicit driver; ports are never
  inferred from labels.

## Acceptance Scenarios

1. Start worktree A and worktree B with the same database driver and internal
   port.
2. Connect a DBeaver-equivalent client to
   `db.<A>.wrap.localhost:<driver port>`; observe bytes reaching only A.
3. Connect to `db.<B>.wrap.localhost:<driver port>`; observe bytes reaching
   only B.
4. Repeat the routing check for both `sql_server` and `postgresql`.
5. Keep both connections possible concurrently without alternate host ports.
6. Recreate A's database container; the same hostname routes to its replacement.
7. Stop A; A's route disappears while B remains available.
8. Verify existing HTTP hostnames still use Traefik.
9. Verify every host listener is loopback-only.
10. Demonstrate consumer integration as a Compose-only diff.

## Non-Goals

- Changing consumer application code or development wrappers.
- Requiring consumers to run DNS, a proxy, or host installation.
- Assigning a different database port to each worktree.
- Publishing development routes outside the machine.
- Replacing existing HTTP routing.
- Building a generic service mesh or full database proxy.
- Supporting plaintext clients, PostgreSQL direct TLS negotiation, or database
  protocols without an implemented driver.

## Verification Gate

Do not merge PR #22 until runnable checks prove:

1. Two exact `db.<worktree>.wrap.localhost` names select different labelled
   containers for SQL Server and PostgreSQL.
2. The gateway discovers, updates, and removes routes from Docker labels
   without consumer lifecycle code.
3. Fragmented and oversized handshakes, stalled clients, duplicate routes,
   unsupported drivers, and unreachable provisional backends fail safely.
4. No host resolver, administrator/root, or operating-system service setup is
   required on Linux or Windows.
5. Existing HTTP routes remain unchanged and every published listener is
   loopback-only.
