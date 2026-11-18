# Effective local development gateway

## Purpose and authority

Developers should run the commands they already know in ELCC, WRAP, Travel Authorization, and Traditional Knowledge without managing a second application lifecycle or exposing development services to the LAN. These requirements describe the intended product contract. Source code defines current behavior; release and consumer PR evidence establish what has actually been exercised. A generic example is not proof that a consumer has migrated.

## Required outcomes

| Requirement | Acceptance scenario |
| --- | --- |
| Familiar automatic lifecycle | With Docker running and the gateway stopped, a participating project's `bin/dev up` starts the gateway, waits for readiness, then starts the project. Another checkout reuses it without interrupting existing routes. |
| Last-user shutdown | `bin/dev down` removes only that checkout's app resources. The gateway stops after the last active consumer and in-flight lifecycle operation finishes, unless an explicit desktop hold exists. Shared database containers and data remain. |
| Conservative ownership | Only explicitly marked passive infrastructure is ignored for retention. Unknown legacy consumers keep the gateway alive. Inspection or synchronization failure must not cause speculative shutdown. |
| Concurrent operations | Overlapping project startup, shutdown, and failed startup cannot cause a competing shutdown to interrupt a live protected wrapper. A dead wrapper must not leave a permanent phantom user. Coordination scope, crash recovery, and surviving-child limitations must be documented. |
| Desktop access | DBeaver connects using a server hostname, explicit checkout database, and restricted credentials. A named hold supports desktop-only use until deliberately released. |
| Local-only networking | Host listeners bind only to loopback. Container listeners remain reachable through Docker networking. HTTP, PostgreSQL, and SQL Server routes remain independent and fail closed when their target disappears. |
| Self-contained installation | One Compose stack runs HTTP and database routers from images, without host source/configuration mounts or host Ruby for the routers. Optional Ruby integration may use the consumer's existing Ruby environment. Docker itself must already be running. |
| Isolated checkout data | Shared engines belong to one project, never multiple projects. Each checkout has independent development/test databases and restricted identities. Tests, reset, shutdown, and retirement must preserve neighboring data. |
| Engine-neutral application integration | Application commands and provisioning callers do not contain native permission SQL or choose SQL clients. PostgreSQL and SQL Server adapters own those differences; application migrations remain application-owned. |
| Four concrete adoption examples | Each of ELCC, WRAP, Travel Authorization, and Traditional Knowledge has a source-backed example covering setup, normal commands, shutdown, database ownership, and remaining compatibility checks. Preserve existing editor hooks and consumer-specific behavior. |
| Useful resource savings | Measure equivalent real consumer workloads before/after sharing database servers, including total RAM and contention. Packaging changes and synthetic idle savings alone do not prove this requirement. |
| Recoverable installation and upgrades | Show requested/active version and image identity; coordinate upgrades, preserve old configuration and data, and prove rollback. Publishing, installation, and running behavior are separate gates. |
| Cross-platform intent | Linux Docker Engine and Windows/macOS Docker Desktop using Linux containers are target environments. Claim support only for exercised OS/architecture combinations; SQL Server engine limitations are independent of gateway compatibility. |

## Safety boundaries and non-goals

Docker socket access is privileged, even through a read-only mount. This is trusted local development tooling, not a hostile-container or production security boundary. Do not start Docker Desktop, elevate privileges, migrate consumer data, upgrade database engines, stop unrelated stacks, or prune networks implicitly. Production deployment is outside this contract.

Normal lifecycle commands do not upgrade a healthy gateway. All cooperating lifecycle clients on a workstation must use the same coordination contract; old gem clients and raw Compose commands do not gain concurrency protection automatically. Support for independently coordinated users or remote workstations sharing one Docker daemon requires separate proof.

## Knowledge and delivery owners

- [Lifecycle ownership and concurrency](../architecture/gateway-lifecycle.md) defines the runtime boundaries.
- [Consumer developer examples](../guides/consumer-developer-examples.md) explains the four adoption paths.
- [Migration guide](../guides/docker-first-migration.md) owns data transfer, restricted identities, and rollback.
- [Installation guide](../guides/docker-installation.md) owns image distribution and installed-version checks.
- [Issue #42](https://github.com/icefoganalytics/local-development-gateway/issues/42) and its linked PRs own current implementation, verification, release state, and unresolved gates. This document is not a duplicate progress ledger.
