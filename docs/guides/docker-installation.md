# Docker-Only Gateway Installation

Version **0.4.0** runs the gateway from one Compose file and registry images. Do not replace a running shared gateway until all participating developers/checkouts have agreed to the interruption.

The runtime requires Docker Engine with Linux containers and Docker Compose **2.20.2 or newer** (`start_interval` support). It does not require host Ruby, Bundler, a gem installation, or a gateway source checkout. Consumer `bin/dev` wrappers can still have their own Ruby requirements. The router image targets Linux amd64; Windows/macOS and other architectures have not been verified. SQL Server examples also require an engine-supported platform.

## Download the Compose File

Download [`docker-compose.yml` from release 0.4.0](https://github.com/icefoganalytics/local-development-gateway/releases/download/v0.4.0/docker-compose.yml) into a stable, user-owned installation directory outside any disposable worktree. For example:

```sh
mkdir -p ~/.local/share/local-development-gateway
cd ~/.local/share/local-development-gateway
curl --fail --location --output docker-compose.yml \
  https://github.com/icefoganalytics/local-development-gateway/releases/download/v0.4.0/docker-compose.yml
```

The Compose file pins the router and Traefik to immutable registry digests. Docker downloads the images during installation; no local build or source transfer is needed. Docker socket access is privileged daemon access even when the socket bind mount says `:ro`; use this only on a trusted development machine.

Keep a copy of the previous Compose file and the exact previous image references before upgrades.

## Install from One Compose File

Run the following from the installation directory, with ports 80, 1433, and 5432 on loopback available:

```sh
docker compose -p local-gateway -f docker-compose.yml up -d --wait
docker compose -p local-gateway -f docker-compose.yml ps
docker compose -p local-gateway -f docker-compose.yml exec -T database-router \
  cat /tmp/local-development-gateway-version
docker compose -p local-gateway -f docker-compose.yml images
```

The process record must report `0.4.0`. Inspect the containers' `.Image` IDs and `.Mounts` to confirm the selected images are running and the only host mount is the Docker socket. The HTTP router configuration is carried by Compose command arguments; the database router code is inside its image. Deleting a build checkout therefore cannot break the running service.

`up` is an explicit reconciliation operation and can recreate changed services. For routine inspection use `ps`, `images`, and `logs`; do not run `up` as a read-only health check. Existing Ruby `ensure_running` keeps its healthy-reuse behavior and does not silently upgrade active services.

```sh
docker compose -p local-gateway -f docker-compose.yml logs --follow
```

Each service checks health every second during its initial ten-second startup period and every thirty seconds afterward. Three consecutive failing steady-state checks mark it unhealthy. This reduces probe frequency, not a guarantee of lower total CPU or RAM under every workload.

## Stop and Upgrade Deliberately

The native `docker compose stop` and `down` commands have **no unused-gateway guard**. Do not invoke them from consumer checkout shutdown hooks. Integrate the coordinated [Ruby lifecycle API](#optional-ruby-integration) in the existing wrapper: the first `bin/dev up` starts the gateway, another reuses it, and the last `bin/dev down` stops the routers. Automatic shutdown preserves the gateway network and containers so passive shared databases remain attached. It never stops those databases or removes their volumes.

Before a machine-wide shutdown, inspect running **and stopped** attached containers and identify their owners:

```sh
docker ps -a --filter network=local-gateway \
  --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}} {{.Status}}'
docker network inspect local-gateway
```

For ordinary shutdown, use `local-development-gateway down` from gem 0.4.0 or newer, which refuses to stop while a consumer, pending operation, or named hold remains. Unknown legacy containers remain blockers. A shared database may be explicitly labeled `local-gateway.lifecycle: passive`; pair that with active consumer labels on app/job/test services, even when they only use a project's private network. The four [consumer examples](consumer-developer-examples.md) show this boundary.

For explicit machine-wide **uninstallation**, first coordinate with all owners and detach their containers from the gateway network. Only then run `docker compose -p local-gateway -f docker-compose.yml down`. Normal project teardown is not uninstallation.

Do not delete consumer database volumes or prune Docker networks to upgrade the gateway. For a router-only update, agree on downtime, obtain/build the selected image, and explicitly recreate only that service:

```sh
docker compose -p local-gateway -f docker-compose.yml up -d --no-deps --force-recreate --wait database-router
```

Existing database sessions will disconnect. Verify the process version/image identity, then connect through both database protocols. To roll back, restore the previous Compose file and image selection and explicitly recreate only the affected service. The gateway does not migrate application data.

## Optional Ruby Integration

Gem 0.4.0 provides `with_running`, `ensure_running`, `ready?`, `status`, `logs`, `stop_if_unused`, named `hold`/`release` operations, and deterministic private alias generation. It carries an image-based Compose file, not a runtime source/config mount. `status` reports the active version, requested image, immutable running image ID, and legacy mounted assets when present.

Add `gem "local-development-gateway", "~> 0.4.0"` to the consumer's existing bundle. Update every cooperating consumer's old gem and retain its existing lifecycle hooks using the coordinated contract. An old client can still recreate the legacy installation and bypass coordination. Do not commit personal checkout paths. See [lifecycle ownership](../architecture/gateway-lifecycle.md) and [the four consumer examples](consumer-developer-examples.md).

The routers remain Docker-only. Automatic project lifecycle uses the existing host Ruby wrapper, not a new native service. A machine with only Docker can run the stack explicitly with Compose, but raw Compose commands do not participate in the unused-gateway guard. Docker Engine/Desktop must already be running; Windows/macOS behavior and filesystem locking still require native verification.

For DBeaver without an app checkout, run `local-development-gateway hold dbeaver`, then release it with `local-development-gateway release dbeaver`. Holds are durable names, not reference counts: use a distinct name for independently managed sessions. Release triggers guarded cleanup. A stopped gateway does not wake on a browser or database connection.

A custom image can be selected with `LOCAL_DEVELOPMENT_GATEWAY_IMAGE`, including a registry digest reference. This does not change the gateway's Compose project, loopback ports, network name, or protocol labels. The router process record reports its actual library version even if an operator supplies an older image.

## Release Gate

For each release, build/push the router image for the supported platforms, resolve its registry digest, and select that immutable digest in the released Compose artifact. Publish the matching Compose file and optional gem together; verify a fresh remote pull and installation in a clean Docker environment. Those publication/install checks are not established by a local image build. Do not publish the gem while its default image is unavailable.

The shared-database example is a separate opt-in consumer architecture change. Image packaging removes installation coupling; reducing repeated database server processes is the source of the expected material RAM savings.
