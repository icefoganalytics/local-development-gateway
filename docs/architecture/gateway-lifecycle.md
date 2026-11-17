# Gateway lifecycle ownership

The candidate lifecycle connects the developer's existing `bin/dev` command to one shared Docker Compose gateway. The routers remain self-contained containers; the existing consumer-side Ruby wrapper coordinates their use. Docker itself must already be running. This is not browser-triggered activation, a host service manager, or a database provisioning service.

## Three independent owners

| Owner | Starts and stops | Must preserve |
| --- | --- | --- |
| Machine gateway | HTTP and database routers | Shared gateway network and consumer data during ordinary idle-stop |
| Project database stack | That project's shared server processes | Databases/credentials belonging to every checkout |
| Checkout wrapper | Its app, worker, and one-off command containers | Neighboring apps, project servers, and stored data |

`with_running` protects a command from before gateway startup until that command returns. After a successful `up`, running app containers retain the gateway. After `down`, cleanup checks whether another consumer, pending command, or desktop hold remains. With none left, it uses Compose `stop`, not `down`: stopped router containers and the external gateway network remain available for the next startup. Database servers and their volumes are never part of that stop command.

## What retains the gateway

A running non-gateway container attached to `local-gateway` retains it unless the container explicitly has `local-gateway.lifecycle: passive`. Missing, misspelled, and unknown label values are not passive. This conservative default preserves legacy consumers.

A running container labeled `local-gateway.lifecycle: consumer` also retains it when attached only to its project's private network. Apply that label to app/job/test services whose ordinary lifecycle should count. Shared database servers may be passive; an active worker is not passive merely because it has no HTTP route. Stopped containers do not retain the gateway.

A named desktop hold retains the gateway without an app. `hold dbeaver` ensures readiness and creates a durable hold; `release dbeaver` removes it and performs guarded cleanup. Names are idempotent keys, not incrementing reference counts. Independent users of a hold need distinct names. A live database TCP connection is not automatically a hold, and a stopped router does not wake when a client connects.

## Concurrent operations and failure

The client uses private local state under `~/.local/state/local-development-gateway`, partitioned by a hash of the Docker daemon ID. A short exclusive coordinator lock protects startup, registration, hold changes, and shutdown decisions. Each pending operation keeps its own lock while the project command runs outside the coordinator lock, so long commands do not block unrelated checkout commands.

Under the coordinator lock, a later operation can reclaim an unlocked stale operation file. Process death releases the OS lock; no PID reuse heuristic, reference counter, background reaper, or timeout can accidentally expire a live operation. Named holds deliberately survive process exit and must be explicitly released. Surviving running consumers remain visible through Docker. If a wrapper is forcibly killed before its child creates a container, its parent-owned operation lock no longer protects that child: terminate/reconcile the interrupted command before relying on another teardown.

Failure to establish the daemon identity, acquire locks, or inspect active consumers does not authorize shutdown. Errors propagate rather than pretending cleanup succeeded. If the protected command already raised, cleanup does not replace its original exception. A teardown call with `ensure_running: false` does not start an absent gateway, but still requires a working daemon and coordination directory before running its block.

The block must wait for its project subprocess and propagate its failure. `exec` would replace Ruby and bypass block cleanup; asynchronous detached work must establish a running consumer before the block returns. The CLI `with-running [--no-start] -- COMMAND` supplies waiting execution and preserves command exit status. Direct `up`, guarded `down`, `hold`, and `release` use the same coordinator. Raw Docker Compose commands and old gem clients do not.

## Coordination boundary

Coordination covers cooperating processes for **one local OS user and one Docker daemon**. Multiple home directories, remote machines sharing a daemon, or unsupported filesystem locking do not share this safety guarantee. All consumers must update their lifecycle library during adoption. Do not delete live state files or use a different state directory to bypass a hold.

The target platforms are Linux Docker Engine and Windows/macOS Docker Desktop with Linux containers. Native Docker socket mapping, host name resolution, architecture support, and file locking need platform-specific verification. Linux evidence does not establish Windows/macOS support. SQL Server's supported host architecture is a separate constraint.

See the [core requirements](../requirements/effective-gateway.md), [four consumer examples](../guides/consumer-developer-examples.md), and [installation/rollback procedure](../guides/docker-installation.md). Release and consumer PRs own actual verification outcomes; this document defines the boundary, not a delivery claim.
