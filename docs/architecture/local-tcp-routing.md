# Local TCP Routing Architecture

Status: implementation and Linux/Docker verification complete in PR #22; user review pending.

## Request

Extend Local Development Gateway so a participating Docker Compose project can expose raw TCP services, initially SQL Server, with the same simple declarative integration it already uses for HTTP services.

For WRAP, adding database routing should require only a small change to `docker-compose.development.gateway.yml`. WRAP must not implement address allocation, routing, DNS, host-file management, startup orchestration, or cleanup.

The desired endpoint is:

```text
db.<worktree>.wrap.localhost:1433
```

It must connect from DBeaver to that worktree's `db` container on internal port `1433`.

## Consumer Contract

A participating project declares the service in Compose using the existing `local-gateway` network and these gateway-owned labels:

```yaml
services:
  db:
    networks:
      - default
      - local-gateway
    labels:
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
Windows. That means a cross-platform solution cannot distinguish worktrees by
destination IP, and SQL Server TDS has no HTTP `Host` header for Traefik.

The remaining gateway-owned discriminator is the TLS Server Name Indication
sent by encrypted SQL Server clients. With TDS 7.x, the TLS ClientHello is
wrapped inside TDS PRELOGIN packets, so a small TDS-aware router must expose
the SNI before selecting the labelled backend:

```text
DBeaver
  -> db.<worktree>.wrap.localhost:1433
  -> Docker publishes gateway TDS router on 127.0.0.1:1433
  -> router mediates TDS PRELOGIN and reads wrapped TLS SNI
  -> router selects the matching Docker label
  -> router forwards the encrypted stream to <worktree> db:1433
```

Traefik remains responsible for HTTP. The dedicated TDS router forwards the
selected stream directly because Traefik cannot expose TLS SNI wrapped inside
TDS PRELOGIN.

Encrypted DBeaver connections are required so the requested hostname is
present as TLS SNI. A smoke test with DBeaver's bundled Microsoft JDBC driver
proved that the driver sends `db.<worktree>.wrap.localhost`, the router can
select a second running SQL Server container, and the encrypted login exchange
continues to that selected container.

## Hostname Contract

- Keep the established WRAP hostname family.
- HTTP remains:
  - `<worktree>.wrap.localhost`
  - `api.<worktree>.wrap.localhost`
  - `mail.<worktree>.wrap.localhost`
- SQL Server is:
  - `db.<worktree>.wrap.localhost`
- Do not migrate consumers to `.test`, `.alt`, `.local`, `home.arpa`, or an externally registered domain as part of this issue.
- Do not require host resolver configuration; `.localhost` must retain its native loopback behavior.

## Security Boundary

- No routed service may be reachable from another machine.
- Bind host listeners only to loopback addresses.
- Do not publish generated names through public DNS.
- Do not expose SQL Server on `0.0.0.0` or a LAN interface.
- Do not require privileged host integration.
- Do not grant a long-running container unrestricted write access to arbitrary host files.
- The TDS router receives the same read-only Docker socket already required by Traefik so it can resolve labels to current container addresses.

## Lifecycle

- The router reads current Docker metadata for every new connection; starting, restarting, or stopping a labelled container therefore requires no stored route state or cleanup.
- Duplicate active hostname labels are rejected instead of selecting an arbitrary container.
- A connection snapshot never changes backend after selection.
- Gateway restart requires no route reconstruction because Docker metadata is the source of truth.

## Compatibility

- DBeaver connects using host `db.<worktree>.wrap.localhost` and port `1433`.
- SQL Server TDS is treated as raw TCP; the consumer must not need an HTTP shim.
- Concurrent routed databases must use compatible PRELOGIN encryption settings because the client receives that negotiation response before its TLS hostname identifies the backend.
- Existing browser routes through Traefik on `127.0.0.1:80` remain unchanged.
- Multiple active WRAP worktrees can all use internal port `1433` simultaneously.
- Other hostname-routed protocols may use Traefik TLS SNI or their own protocol-aware router; this change intentionally implements only SQL Server TDS.

## Acceptance Scenarios

1. Start WRAP worktree A and worktree B with identical `db` labels and internal port `1433`.
2. Connect a DBeaver-equivalent raw TCP client to `db.<A>.wrap.localhost:1433`; observe bytes reaching only A's database service.
3. Connect to `db.<B>.wrap.localhost:1433`; observe bytes reaching only B's database service.
4. Keep both connections possible concurrently without choosing alternate host ports.
5. Recreate A's database container; the same hostname routes to the replacement container.
6. Stop A; A's route disappears while B remains available.
7. Verify `<A>.wrap.localhost`, `api.<A>.wrap.localhost`, and `mail.<A>.wrap.localhost` still use their existing HTTP routes.
8. Verify listeners are loopback-only and unavailable from a non-loopback interface.
9. Demonstrate the WRAP integration as a Compose-only diff in `docker-compose.development.gateway.yml`.

## Non-Goals

- Changing WRAP application code or its development wrapper.
- Requiring every consumer to run its own DNS or proxy service.
- Assigning a different database port to each worktree.
- Publishing development routes outside the machine.
- Replacing existing HTTP routing when it already works.
- Building a generic service mesh or a general-purpose SQL proxy beyond the
  minimum PRELOGIN and TLS-SNI routing needed here.

## Verification Gate

Do not mark PR #22 ready until runnable checks prove all four facts:

1. Two exact `db.<worktree>.wrap.localhost` names select different labelled
   containers on port `1433` from the DBeaver Microsoft JDBC driver.
2. The gateway discovers, updates, and removes routes from Docker labels
   without consumer lifecycle code.
3. No host resolver, administrator/root, or operating-system service setup is
   required on Linux or Windows.
4. Existing HTTP routes remain unchanged and every published listener is
   loopback-only.
