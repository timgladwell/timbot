# 1. PostgreSQL as the primary datastore

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Tim Gladwell

## Context

timbot needs a stateful datastore. timbot is a single Rails monolith holding many
small automations. It is the only custom application planned for the homelab, and
it runs on a single-node k3s cluster (Raspberry Pi 4, 8GB RAM, 256GB NVMe over USB3),
managed by GitOps from [homelab](https://github.com/timgladwell/homelab).

Requirements:

- Multiple simultaneous connections from separate workloads (web and job
  workers in separate pods)
- Runs as a container in k3s with data on persistent storage
- First-class Ruby on Rails support
- Mature operational tooling, especially an online backup process supporting a
  daily offsite
- Point-in-time recovery for the "bad deploy corrupted data" case
- Consistent reliability over throughput; speed is explicitly not a factor

The node is shared between production work (DNS) and non-production work
(internal task automation), so resource contention is a first-class concern.

timbot's areas start in one database with namespaced tables (ADR 0002). Moving an
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
2. **Multi-tenancy flexibility.** Postgres separates database, schema and role,
   so an area can later move to its own schema or database without changing
   engines. MySQL conflates database and schema, making that migration harder.
3. **Stack fit.** Solid Queue on Postgres removes the Redis/Memcache dependency
   entirely. `pg_trgm` (trigram similarity) is a candidate for fuzzy dedup in a
   planned contact-sync feature — not adopted, but it ships with Postgres. Neither has
   a clean MySQL equivalent.

### Topology: single instance, single logical database

One Postgres instance, dedicated to timbot, with one logical database and one
application role. Solid Queue is required from the start and is installed into
that database using its single-database setup, not Rails 8's default of a separate
queue database. Solid Cache and Solid Cable are added only when a feature needs
them, into the same database the same way. Their tables are already prefixed
(`solid_queue_*` and so on), which fits the per-area table naming in ADR 0002.

Separate logical databases, per area or for the Solid components, are adopted
when their management overhead is worth it: `database.yml` entries, migration
paths, roles, connection pools and per-database restores. If another application
ever appears, it gets its own logical database on this instance.

### Deployment: CloudNativePG operator

Postgres runs in k3s via the CloudNativePG operator rather than a hand-rolled
StatefulSet. The operator manages PVCs directly, publishes arm64 operand images,
and — decisively — makes point-in-time recovery a declarative `Cluster` with a
`recoveryTarget`, rather than a hand-typed restore procedure executed under
pressure.

CNPG was accepted into the CNCF at Sandbox level on 2025-01-21, with an
Incubation application submitted at KubeCon NA in November 2025. The Sandbox
label reflects a late donation rather than immaturity: it originated at
EnterpriseDB, lists IBM, Google Cloud and Microsoft Azure among adopters, and
passed 132 million downloads in 2025.

Storage is a PVC on the NVMe via the k3s local-path provisioner.

### Backups and offsite

- Base backups plus continuous WAL archiving to a **new bucket on the existing
  AWS account**, via the CNPG Barman Cloud plugin. Barman Cloud speaks S3
  natively, so no adapter or self-hosted object store is required.
- **S3 Standard storage class.** Standard-IA carries a 30-day minimum storage
  duration and a 128KB minimum billable object size; at two-week retention it
  would cost more, not less. Glacier tiers are 90-day minimums.
- **WAL compression enabled.** WAL segments are a fixed 16MB regardless of
  content, so an idle database still emits padded full-size files. Compression
  is what keeps volume and cost proportional to actual change.
- **`archive_timeout` set to 15 minutes.** This is an RPO dial, not a schedule:
  each tick forces a segment switch and ships a padded 16MB file. 15 minutes
  caps worst-case loss on hardware failure at 15 minutes while cutting segment
  volume roughly two-thirds versus a 5-minute setting, and reduces write wear on
  the USB-attached NVMe.
- **Dedicated IAM user** scoped to the single bucket prefix, no wildcards, so a
  compromised node has a blast radius of one prefix.
- **Bucket versioning on**, so a bug or errant delete cannot irrecoverably erase
  backup history.

Cost at this scale is roughly $0.12–$1.50/month depending on compression
effectiveness. Backblaze B2 is ~70% cheaper per GB but was rejected: the saving
is under a dollar a month and does not justify a second vendor, credential set
and renewal surface.

### Retention

- **14 days, configured as the Barman `retentionPolicy`** — not as an S3
  lifecycle rule. Barman tracks which WAL segments the oldest base backup still
  requires. A lifecycle rule deleting by age has no such knowledge and can expire
  required WAL, producing a backup set that looks healthy in the console and
  fails at restore time.
- An S3 lifecycle rule may be set at ~60 days as a runaway-cost backstop only.

Beyond two weeks there is no value in point-in-time granularity; longer-horizon
GFS retention (dailies for a month, weeklies for three months, monthlies for a
year) remains the responsibility of the restic/borgbackup layer.

### Resource isolation

Because production DNS shares the node, Postgres carries explicit memory
requests and limits, and the DNS workload is given `requests == limits`
(Guaranteed QoS) plus a higher PriorityClass. Under memory pressure the kubelet
then evicts task automation rather than household DNS.

## Consequences

### Positive

- PITR for bad deploys and a bounded-loss offsite for hardware failure come from
  one mechanism and one configuration.
- No additional infrastructure components: no Redis, no self-hosted object store.
  MinIO would have pre-allocated 1Gi per node in single-node topologies (2Gi
  distributed), against a design centre its own guidance puts at 8+ cores and
  128GB RAM. Garage would have been the choice had local S3 been necessary.
- Restore is a declarative, rehearsable object rather than an undocumented
  runbook.

### Negative / risks

- **USB3-to-NVMe cache-flush integrity.** Some bridge chipsets ignore or
  misreport cache-flush/FUA commands, so Postgres may believe a commit is durable
  while it sits in the enclosure's volatile cache. A power loss then yields a
  corrupt cluster rather than a clean rollback. This is a larger threat to
  reliability than any engine-level difference and should be verified with a
  pull-the-plug test on this specific enclosure.
- **Shared failure domain.** Data and WAL live on the same disk. Anything not yet
  shipped to S3 is lost with the enclosure; `archive_timeout` bounds that window.
- **Archive failure fills the disk.** Postgres will not recycle WAL that has not
  been successfully archived. A silently failing `archive_command` therefore fills
  the NVMe and takes down DNS along with everything else. This requires an alert,
  not just a dashboard.
- **Untested backups are not backups.** Restore rehearsal must be periodic and
  deliberate.
- **Solid components share the application database.** Solid Queue's docs
  (and Solid Cable's, once it is added) recommend a separate database, so their
  polling and churn cannot contend with application queries. At timbot's load
  that isolation isn't worth a second database. If that contention shows up, move
  them out first.
- CNPG's Barman Cloud support is moving from in-core to a plugin, and older
  "system" images are deprecated; the plugin path should be adopted from the
  start to avoid a later migration.

## Alternatives considered

| Option | Rejected because |
| --- | --- |
| SQLite | No network protocol, single-writer, unsuited to multiple pods |
| MySQL / MariaDB | Backup story depends on XtraBackup/Mariabackup with weaker ARM64 packaging; database/schema conflation constrains future namespacing |
| CockroachDB / YugabyteDB | Wildly oversized for one 8GB node |
| Plain StatefulSet + own CronJobs | Fewest components, but hand-written WAL archiving and an untested manual restore path is the usual way homelab PITR turns out to be broken |
| Postgres on the host, outside k3s | Contradicts the containerised-platform goal |
| Local S3 (MinIO / Garage) + rclone to Drive | Unnecessary once an existing AWS account is available; adds RAM, a component, and a shared failure domain |
| Google Drive / iCloud as backup target | iCloud via rclone needs the real Apple ID password plus 2FA, produces a 30-day trust token requiring interactive reauth, and demands Advanced Data Protection off — a chain that silently dies monthly. Drive lacks object-store semantics and is the wrong shape for a continuous WAL stream |
