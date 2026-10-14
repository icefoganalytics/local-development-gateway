# Local TCP Routing Architecture

Status: SQL Server and PostgreSQL protocol routing implemented in PR #22 and
validated on Linux. Windows Docker Desktop validation remains outstanding.

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

A participating project keeps its databases on its private `default` network
and adds the existing `local-gateway` network plus three gateway-owned labels:
driver, desktop hostname, and internal port. The copyable SQL Server and
PostgreSQL base/overlay examples live in the README's
[canonical Compose pattern](../../README.md#canonical-development-and-test-compose-pattern).

| Connection path | Destination selection |
| --- | --- |
| API, background job, test | `${COMPOSE_PROJECT_NAME}-<database-service>` on private Docker DNS, using the driver's existing host setting and internal port |
| Desktop database client | Encrypted `db.<worktree>.<project>.localhost` endpoint; driver/hostname labels select the backend |
| Database-local console, backup, clone | Explicitly selected container, then `localhost`; not gateway routing |

Each concurrent checkout has a distinct Compose project name. Each database
advertises its qualified alias only on that project's `default` network.
Use mapping-form database networks in the base and gateway overlay so Compose
preserves `default.aliases`. Configure all application/job/test contexts with
their appropriate aliases, existing credentials, and intended database names;
test contexts still select their own test database.

Gateway-mode development and test stacks publish no database host ports.
Container consumers work with the base alone. Desktop access without the
gateway is an explicit project-local port-publishing overlay, not an inherited
base default and not a parallel-stack guarantee. The README covers migration
of inherited port publications, fallback selection, and adoption checks.

Internal database hostnames and desktop `.localhost` hostnames are separate
contracts. Internal connections need neither a published host port nor the
gateway's encrypted-handshake protocol. Database cloning does not depend on
the internal hostname correction.

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

## Internal Database Isolation Decision

**Decision:** retain the current shared ingress topology and standardize
checkout-qualified private aliases. This resolves
[#23](https://github.com/icefoganalytics/local-development-gateway/issues/23)'s
parallel-stack contract and
[#26](https://github.com/icefoganalytics/local-development-gateway/issues/26)'s
internal database selection contract without new runtime machinery or public
Ruby lifecycle changes.

Bare `db` is not safe for an API attached to both its private bridge and
`local-gateway`: other attached databases advertise the same Compose service
alias on shared ingress. Docker DNS/network ordering, container IDs, separate
volumes, and gateway TLS/SNI cannot disambiguate an ordinary internal connection.
The qualified alias identifies only its own private endpoint. If that endpoint
is absent, its consumers must fail rather than connect to another checkout.
Do not advertise the qualified alias on shared ingress.

An HTTP/database ingress split is a possible future centralization, not a
transparent gem-only patch:

- HTTP services/APIs: private checkout network plus existing HTTP ingress.
- Databases: private checkout network plus a distinct gateway-owned database
  ingress network. APIs/jobs/tests must not join database ingress.
- Traefik: HTTP ingress only. Database router: database ingress only.
- Route discovery must read backend addresses on database ingress instead of
  `DockerRoutes::NETWORK_NAME`'s current `local-gateway`.
- Gateway readiness/discovery must check the appropriate networks and services.
  Unused-gateway shutdown must retain running consumers on either ingress,
  including database-only stacks, without counting exited containers.
- Consumer network membership, installed gem versions, and already-running
  shared gateways require coordinated migration. Old consumers still
  advertising database aliases on HTTP ingress remain ambiguous after a
  gateway-only update.

That alternative requires packaged install/readiness, database-only lifecycle,
multi-project startup/stop/replacement, SQL Server routing, PostgreSQL routing
and cancellation, mixed-version migration, and unchanged HTTP-routing evidence
before adoption. No structural split is implemented in this release; downstream
qualified-alias mitigations must remain until a verified replacement is adopted.

These development networks are not hostile-container security boundaries.
Private qualified aliases prevent accidental selection, not deliberate
connections by another attached container.

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
TDS PRELOGIN. It **does** support PostgreSQL SSLRequest/STARTTLS and subsequent
TLS-SNI routing, as documented in its
[TCP TLS reference](https://doc.traefik.io/traefik/reference/routing-configuration/tcp/tls/).

STARTTLS alone is therefore not a reason to implement PostgreSQL routing here.
The gateway also owns PostgreSQL query cancellation: `psql` and JDBC can open
a separate plaintext CancelRequest connection containing only a backend PID and
secret, with no hostname. A stateless SNI router cannot select that backend.
Keeping negotiation and cancellation-aware session forwarding together preserves
the existing three-label consumer contract without per-route internal listeners,
generated Traefik configuration, or another discovery/control plane.

Normal database sessions require encrypted handshakes so the requested hostname
is present as TLS SNI. PostgreSQL cancellation is a bounded control-message
exception, not support for plaintext database sessions. The router parses
PostgreSQL backend messages only until BackendKeyData, replaces that key, then
forwards the remainder without interpreting query results.

## Code Organization

`DatabaseRouter` owns listener concurrency and backend connection lifecycle.
`Wire` owns bounded handshake I/O and bidirectional forwarding, including
shutdown that wakes both relay directions. `DockerApi` and `DockerRoutes` form
the external Docker boundary and produce validated `Route` values.
Behavior-bearing classes each have one file, and directories map to Ruby
namespaces: drivers live under `DatabaseRouter::Drivers`, TDS framing and TLS
parsing under `DatabaseRouter::Tds`, and PostgreSQL session-key forwarding and
cancellation lookup under `DatabaseRouter::PostgreSql`. Tiny immutable `Route`,
`Connection`, cancellation destination, and TDS `Packet` records stay with
their owners.

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

- Normal session selection reads current Docker metadata; starting, restarting,
  or stopping a labelled container requires no stored route configuration or
  consumer cleanup.
- Containers outside `local-gateway` are excluded before label validation.
  Invalid participating routes are warned about and quarantined individually.
- Duplicate active driver/hostname identities reject every route for that
  identity, not unrelated identities or database drivers.
- A connection snapshot never changes backend after selection.
- PostgreSQL rewrites BackendKeyData with a random, collision-checked virtual
  identity whose PID is positive for older client compatibility. The active
  mapping retains the exact backend address, port, and original cancellation key.
- Cancellation uses that mapping without Docker discovery or hostname
  negotiation. Unknown and closed-session identities fail closed, and malformed
  cancellation lengths never fall through to normal backend forwarding.
- Backend EOF, client disconnect, or relay failure removes the session mapping.
  Gateway restart closes sessions and clears their cancellation identities;
  normal route configuration is reconstructed from Docker metadata.
- Handshakes and active sessions have separate bounded admission pools.
  Cancellation and closed health probes do not consume an active-session slot,
  so cancellation remains available when the normal session limit is reached.
- SQL Server provisional attempts have a bounded sub-deadline within the shared
  handshake deadline. Connection establishment uses only the remaining budget;
  stalled provisional sockets are closed before a healthy alternative is tried.

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
- PostgreSQL cancellation PIDs reported by client APIs are virtual. Use
  `SELECT pg_backend_pid()` when inspecting the physical backend in server views.
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

- Changing consumer application code, adding new development wrapper runtimes,
  or automatically mutating consumer networks. Existing Compose connection
  settings and file selection must adopt the documented contract.
- Requiring consumers to run DNS, a proxy, or host installation.
- Assigning a different database port to each worktree.
- Publishing development routes outside the machine.
- Replacing existing HTTP routing.
- Building a generic service mesh or full database proxy.
- Supporting plaintext database sessions, PostgreSQL direct TLS negotiation, or
  database protocols without an implemented driver. Plaintext PostgreSQL
  cancellation control packets are supported.

## Verification Evidence

PR #22 demonstrated:

1. Two exact `db.<worktree>.wrap.localhost` names selected different labelled
   containers for SQL Server and PostgreSQL.
2. Docker-label discovery updated routes without consumer lifecycle code;
   stopped routes were rejected while surviving routes remained reachable.
3. Fragmented and oversized handshakes, stalled clients, duplicate routes,
   unsupported drivers, and unreachable provisional backends failed safely.
4. Linux validation required no host resolver, administrator/root, or
   operating-system service setup. Windows Docker Desktop was unavailable for
   equivalent validation.
5. Existing HTTP routes remained unchanged and every published listener was
   loopback-only.

Issue #24's corrective release additionally demonstrated:

1. PostgreSQL 14.4 `psql` cancellation stopped A's query while B stayed active.
2. DBeaver's Java runtime with PostgreSQL JDBC 42.7.13 and 42.2.27 returned
   SQLSTATE `57014` for A while B completed its query normally.
3. Two SQL Server 2022 backends remained reachable with encrypted `sqlcmd`
   connections despite a first labelled backend that accepted TCP but never
   answered PRELOGIN.
4. Focused regressions cover invalid-route isolation, cancellation identity
   collisions after PID normalization, variable backend keys, session cleanup,
   malformed cancellation packets, and cancellation at full session capacity.

Issues #23 and #26's documentation release demonstrated on Linux with Docker
Compose 5.6.0:

1. Two isolated Compose projects, each with SQL Server 2022 `db` and PostgreSQL
   17 `db_trav_com`, started concurrently without database host publications.
   The repository's `bin/dev` Compose passthrough selected the temporary
   consumer fixtures; the existing shared gateway was reused.
2. Real SQL/PG client containers representing API, job, and test contexts joined
   both private and shared networks. `getent hosts` selected only their private
   qualified aliases. Read-only SQL Server `@@SERVERNAME` / `DB_NAME()` and
   PostgreSQL `cluster_name` / `current_database()` / `inet_server_addr()`
   identified their own servers. Test contexts selected `qa_test`; explicit
   database-container `localhost` queries matched the consumer identities.
3. Stopping A's two databases made every A context fail while B remained
   usable. `getent hosts` returned exit 1; SQL Server reported login timeout,
   TCP Provider `0x2AFA`, and server-not-found/not-accessible; PostgreSQL reported
   `could not translate host name ... to address: Try again`. These are observed
   platform errors, not required portable error codes.
4. Both projects were recreated using base-only Compose. All consumer identity
   checks passed with private-only attachments. Recreating with the gateway
   overlay restored shared attachments and preserved private aliases and test
   database selection.
5. Desktop-equivalent host-network clients selected both labelled worktrees:
   `sqlcmd` 18.6 with `-Nm -C` (mandatory encryption, trusted development
   certificate), and PostgreSQL 17 `psql` with `sslmode=require`, SNI, hostname,
   and explicit loopback `hostaddr`. SQL Server strict/direct TLS is outside the
   supported TDS PRELOGIN contract.
6. Docker inspection confirmed the shared gateway publishes only
   `127.0.0.1:80`, `127.0.0.1:1433`, and `127.0.0.1:5432`.

This validates real database client contexts, not an automatic downstream
application migration. Consumers still need to adopt the README checklist.
Windows Docker Desktop validation remains outstanding.
