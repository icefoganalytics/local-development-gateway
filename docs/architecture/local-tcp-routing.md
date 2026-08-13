# Local TCP Routing Architecture

Status: implemented in PR #22; pending privileged host-agent and DBeaver verification before merge.

## Request

Extend Local Development Gateway so a participating Docker Compose project can expose raw TCP services, initially SQL Server, with the same simple declarative integration it already uses for HTTP services.

For WRAP, adding database routing should require only a small change to `docker-compose.development.gateway.yml`. WRAP must not implement address allocation, routing, DNS, host-file management, startup orchestration, or cleanup.

The desired endpoint is:

```text
db.<worktree>.wrap.localhost:1433
```

It must connect from DBeaver to that worktree's `db` container on internal port `1433`.

## Consumer Contract

A participating project declares the service in Compose using the existing `local-gateway` network and gateway-owned labels. The final labels may differ, but the integration must remain approximately this simple:

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

## Chosen Routing Shape

Raw SQL Server connections do not carry an HTTP `Host` header, and their first
packet is TDS PRELOGIN rather than a TLS ClientHello that Traefik can match with
`HostSNI`. Traefik therefore remains responsible for HTTP only.

The gateway installs one root-owned host agent:

```text
DBeaver
  -> /etc/hosts maps db.<worktree>.wrap.localhost to 127.77.0.x
  -> host agent listens on 127.77.0.x:1433
  -> host agent forwards raw TCP
  -> labelled <worktree> db container:1433
```

The agent watches Docker for `local-gateway.tcp.hostname` and
`local-gateway.tcp.port` labels. It assigns a distinct loopback address to each
active hostname, owns a marked block in `/etc/hosts`, and forwards to the
container's current `local-gateway` address. Container recreation and removal
are reconciled without consumer lifecycle code.

This host process is required because `.localhost` is synthesized by local
resolvers and cannot be assigned distinct addresses through ordinary DNS.
Exact `/etc/hosts` records precede that fallback on supported Linux systems.
The agent runs outside Docker so no long-running container receives write
access to the host's `/etc/hosts`.

## Hostname Contract

- Keep the established WRAP hostname family.
- HTTP remains:
  - `<worktree>.wrap.localhost`
  - `api.<worktree>.wrap.localhost`
  - `mail.<worktree>.wrap.localhost`
- SQL Server is:
  - `db.<worktree>.wrap.localhost`
- Do not migrate consumers to `.test`, `.alt`, `.local`, `home.arpa`, or an externally registered domain as part of this issue.
- If exact `.localhost` routing needs host integration, that integration must be installed and managed by this gateway project, not each consumer.

## Security Boundary

- No routed service may be reachable from another machine.
- Bind host listeners only to loopback addresses.
- Do not publish generated names through public DNS.
- Do not expose SQL Server on `0.0.0.0` or a LAN interface.
- Any privileged host integration must be narrowly scoped, deterministic, reversible, and owned by this project.
- Do not grant a long-running container unrestricted write access to arbitrary host files.
- Existing Docker-socket risk must not be expanded without a documented reason.

## Lifecycle

- Starting a labelled container creates or refreshes its route automatically.
- Restarting or recreating a container updates the target without changing the user-facing hostname.
- Stopping the final labelled service for a worktree removes its route automatically.
- Stale routes must not forward to a different worktree.
- Concurrent gateway reconciliation must not allocate the same route identity to two active worktrees.
- Gateway restart must reconstruct active routes from Docker metadata and owned state.

## Compatibility

- DBeaver connects using host `db.<worktree>.wrap.localhost` and port `1433`.
- SQL Server TDS is treated as raw TCP; the consumer must not need an HTTP shim.
- Existing browser routes through Traefik on `127.0.0.1:80` remain unchanged.
- Multiple active WRAP worktrees can all use internal port `1433` simultaneously.
- The design should generalize to another labelled raw TCP service without adding consumer orchestration, but no speculative protocol framework is required.

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
- Building a generic service mesh or protocol-aware SQL proxy.

## Verification Gate

Do not mark PR #22 ready until runnable checks prove all three facts:

1. Two exact `db.<worktree>.wrap.localhost` entries select different loopback
   routes on the same TCP port from a DBeaver-equivalent Java client.
2. The gateway discovers, updates, and removes routes from Docker labels
   without consumer lifecycle code.
3. Installation and removal reconcile the root-owned systemd service,
   loopback-only listeners, state, and marked `/etc/hosts` block.
