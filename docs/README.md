# Gateway knowledge base

For developers integrating a checkout, start with [consumer developer examples](guides/consumer-developer-examples.md). For a machine owner installing or upgrading the gateway, start with [Docker installation](guides/docker-installation.md).

| Reader question | Canonical owner |
| --- | --- |
| What must this project accomplish? | [Core requirements](requirements/effective-gateway.md) |
| When does the shared gateway start and stop? | [Lifecycle ownership](architecture/gateway-lifecycle.md) |
| How are HTTP and encrypted database connections routed? | [Local TCP routing](architecture/local-tcp-routing.md) |
| What changes in ELCC, WRAP, Travel Authorization, and Traditional Knowledge? | [Consumer developer examples](guides/consumer-developer-examples.md) |
| How do we preserve data and roll back a shared-server migration? | [Migration guide](guides/docker-first-migration.md) |
| How can the database-isolation contract be exercised without consumer data? | [Runnable shared-database example](../examples/shared-databases/README.md) |

Requirements and architecture describe intended meaning and ownership; implementation defines current behavior. Tests, PRs, and release records establish observed compatibility and delivery status. Instructions for a candidate artifact do not establish that it is published or installed, and source-backed consumer examples do not establish completed adoption.

This is a public repository. Include only public guidance and sanitized contracts, never consumer secrets, backups, or copied private source. Linked private repositories retain their own access controls. No documentation site is configured; a future site must explicitly select public input rather than publish every local file.
