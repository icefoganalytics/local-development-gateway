# Docker-Only Gateway Installation

This branch prepares the **unreleased 0.4.0 candidate**. The image tag below is a build target, not a claim that it exists in GHCR. Build it locally for draft evaluation. Do not replace a running shared gateway until all participating developers/checkouts have agreed to the interruption.

The runtime requires Docker Engine with Linux containers and Docker Compose **2.20.2 or newer** (`start_interval` support). It does not require host Ruby, Bundler, a gem installation, or a gateway source checkout after the image is built. Consumer `bin/dev` wrappers can still have their own Ruby requirements. SQL Server examples require an engine-supported platform; the local reference scenario is Linux amd64.

## Build or Transfer the Candidate

From this branch's repository root:

```sh
docker build --build-arg REVISION="$(git rev-parse HEAD)" \
  -t ghcr.io/icefoganalytics/local-development-gateway/database-router:0.4.0 .
docker image inspect ghcr.io/icefoganalytics/local-development-gateway/database-router:0.4.0 \
  --format '{{.Id}} {{json .Config.Labels}}'
```

Only the router library and its entrypoint enter the build context. There is no package installation during build or startup. The Ruby base and Traefik image are digest-pinned. Docker socket access is privileged daemon access even when the socket bind mount says `:ro`; use this only on a trusted development machine.

For another machine, transfer the image archive and this branch's `docker-compose.yml` through your normal trusted file-transfer mechanism:

```sh
docker save ghcr.io/icefoganalytics/local-development-gateway/database-router:0.4.0 \
  -o database-router-0.4.0.tar
# On the destination:
docker load -i database-router-0.4.0.tar
```

Keep a copy of the previous Compose file and the exact previous image references before upgrades. A local image ID identifies the candidate you tested; it is not evidence of registry publication.

## Install from One Compose File

Copy `docker-compose.yml` into a stable, user-owned installation directory outside any disposable worktree. Run the following from that directory, with ports 80, 1433, and 5432 on loopback available:

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

The native `docker compose down` command has **no unused-gateway guard**. Unlike the optional Ruby lifecycle API, it must not be invoked by consumer checkout shutdown hooks. Leave this small shared pair running while any participating project needs it.

Before a machine-wide shutdown, inspect running **and stopped** attached containers and identify their owners:

```sh
docker ps -a --filter network=local-gateway \
  --format '{{.ID}} {{.Names}} {{.Label "com.docker.compose.project"}} {{.Status}}'
docker network inspect local-gateway
```

Stop/tear down participating application and shared-database projects through their own documented commands first. Only after confirming no consumer needs the gateway:

```sh
docker compose -p local-gateway -f docker-compose.yml down
```

Do not delete consumer database volumes or prune Docker networks to upgrade the gateway. For a router-only update, agree on downtime, obtain/build the selected image, and explicitly recreate only that service:

```sh
docker compose -p local-gateway -f docker-compose.yml up -d --no-deps --force-recreate --wait database-router
```

Existing database sessions will disconnect. Verify the process version/image identity, then connect through both database protocols. To roll back, restore the previous Compose file and image selection and explicitly recreate only the affected service. The candidate does not migrate application data.

## Optional Ruby Integration

The candidate gem still provides `with_running`, `ensure_running`, `ready?`, `status`, `logs`, `stop_if_unused`, and deterministic private alias generation. It now carries an image-based Compose file, not a runtime source/config mount. `status` reports the active version, requested image, immutable running image ID, and legacy mounted assets when present.

For candidate evaluation, consumers may point their local bundle at this branch; do not commit personal checkout paths. For normal adoption, wait for the coordinated image/gem release. Existing bundles pinned to 0.2.2 must not remain responsible for recreating the shared gateway after cutover: update their gem or remove those gateway lifecycle hooks in favor of the explicit Docker-only installation. See [the three consumer migration instructions](docker-first-migration.md).

A custom image can be selected with `LOCAL_DEVELOPMENT_GATEWAY_IMAGE`, including a registry digest reference. This does not change the gateway's Compose project, loopback ports, network name, or protocol labels. The router process record reports its actual library version even if an operator supplies an older image.

## Release Gate

Before publishing this candidate, build/push the router image for the supported platforms, resolve its registry digest, and select that immutable digest in the released Compose artifact. Publish the matching Compose file and optional gem together; verify a fresh remote pull and installation on a clean machine. Those publication/install checks are not established by a local draft image build. Do not publish the gem while its default image is unavailable.

The shared-database example is a separate opt-in consumer architecture change. Image packaging removes installation coupling; reducing repeated database server processes is the source of the expected material RAM savings.
