# 1. PostgreSQL as the primary datastore

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Tim Gladwell

## Context

timbot needs a stateful datastore. timbot is a single Rails monolith holding many
small automations. It is the only custom application planned for the homelab, and
it runs on a single-node k3s cluster (Raspberry Pi 4, 8GB RAM, 256GB NVMe over USB3),
managed by GitOps from [homelab](https://github.com/timgladwell/homelab).

The database is operated by homelab as a service, and timbot consumes a
connection string ([ADR 0003](0003-database-as-a-service-from-homelab.md)). This ADR therefore chooses the engine and the
logical shape timbot builds against. It does not choose how the database is
deployed, backed up, sized or upgraded — those are homelab's, and its reasoning
lives there.

Requirements timbot places on the datastore:

- Multiple simultaneous connections from separate workloads (web and job
  workers in separate pods)
- First-class Ruby on Rails support
- Mature operational tooling, so a platform can cheaply offer bounded loss on
  hardware failure and point-in-time recovery for the "bad deploy corrupted
  data" case. homelab's
  [tenant contract](https://github.com/timgladwell/homelab/blob/main/docs/adr/0001-postgresql-platform-service.md#the-tenant-contract)
  states what timbot actually gets: point-in-time recovery to any moment in the
  last 14 days, with a recovery-point target homelab tunes against cost
- Consistent reliability over throughput. Speed is not a factor at this time:
  nothing timbot does yet is demanding enough for it to matter

timbot's areas start in one database with namespaced tables ([ADR 0002](0002-area-boundaries-in-the-monolith.md)). Moving an
area to its own database later must remain possible.

## Decision

### Engine: PostgreSQL

SQLite is excluded: no network protocol, single-writer, unsuited to multiple
independent workloads connecting from separate pods.

PostgreSQL is chosen over MySQL/MariaDB on three grounds:

1. **Backup.** Continuous WAL archiving and `pg_basebackup` are in core, giving
   real point-in-time recovery with no third-party dependency. The MySQL
   equivalent (physical hot backup with incrementals) requires Percona
   XtraBackup, a separate project whose ARM64 packages only appeared in
   8.0.35-31 and targeted RHEL/OL rather than Debian-family. The fallback,
   `mysqldump --single-transaction`, is a nightly full logical dump with no PITR.
   timbot does not perform these backups, but the requirement is timbot's, and
   the engine decides whether the operator can meet it cheaply.
2. **Multi-tenancy flexibility.** Postgres separates database, schema and role,
   so an area can later move to its own schema or database without changing
   engines. MySQL conflates database and schema, making that migration harder.
3. **Stack fit.** Solid Queue on Postgres removes the Redis/Memcache dependency
   entirely. `pg_trgm` (trigram similarity) is a candidate for fuzzy dedup in a
   planned contact-sync feature — not adopted, but it ships with Postgres. Neither has
   a clean MySQL equivalent.

### Topology: single logical database, read-write and read-only roles

One logical database, timbot's tenancy on homelab's shared PostgreSQL service,
reached through two roles: a read-write role that owns the schema and runs
migrations, and a read-only role. `config/database.yml` declares both from the
start, the read-only one as a `replica: true` configuration, using Rails'
multiple-database support.

Nothing routes reads to the read-only role yet. Its real use is fanning read
volume out to replicas, and the platform has none. It is supported now so the
application is built in the shape that scales: adding it later means auditing
every read path, while having it from the start costs one configuration entry
and one Secret key.

Solid Queue is required from the start and is installed into that
database using its single-database setup, not Rails 8's default of a separate
queue database. Solid Cache and Solid Cable are added only when a feature needs
them, into the same database the same way. Their tables are already prefixed
(`solid_queue_*` and so on), which fits the per-area table naming in ADR 0002.

Separate logical databases, per area or for the Solid components, are adopted
when their management overhead is worth it: `database.yml` entries, migration
paths, roles, connection pools and per-database restores. A second database for
timbot is a request to homelab, like any other change to the service. If another
application ever appears, it is a separate tenant of the same service, with its
own role and database.

## Consequences

### Positive

- No additional infrastructure components: Solid Queue on Postgres means no
  Redis and no second datastore to operate or back up.
- Postgres's separation of database, schema and role keeps ADR 0002's "an area
  could move out later" open without an engine change.
- The backup and PITR requirements are met by mechanisms in core, so they cost
  the operator configuration rather than a third-party dependency.

### Negative / risks

- **Solid components share the application database.** Solid Queue's docs
  (and Solid Cable's, once it is added) recommend a separate database, so their
  polling and churn cannot contend with application queries. At timbot's load
  that isolation isn't worth a second database. If that contention shows up, move
  them out first.
- **Server parameters and extensions are requests, not commits.** A feature that
  needs `pg_trgm`, or a non-default server parameter, needs homelab to enable it
  before the feature can ship ([ADR 0003](0003-database-as-a-service-from-homelab.md)). That is a lead time, not a blocker, but
  it is real and it is new.

## Alternatives considered

| Option | Rejected because |
| --- | --- |
| SQLite | No network protocol, single-writer, unsuited to multiple pods |
| MySQL / MariaDB | Backup story depends on XtraBackup/Mariabackup with weaker ARM64 packaging; database/schema conflation constrains future namespacing |
| CockroachDB / YugabyteDB | Wildly oversized for one 8GB node |
| Separate database for the Solid components from day one | A second database to configure, migrate and restore, to solve contention that does not exist at this load |

## Changelog

| Date | By | Description |
| --- | --- | --- |
| 2026-09-16 | Tim and Claude | Accepted (#5) |
| 2026-10-02 | Tim and Claude | Narrowed to the engine and logical shape; how the database is operated moved to homelab with ADR 0003. timbot is a tenant of homelab's shared service, its requirements are the tenant contract's service levels, and it has read-write and read-only roles (#22) |
