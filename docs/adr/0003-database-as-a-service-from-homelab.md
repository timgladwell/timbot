# 3. The database is a service homelab provides

- **Status:** Accepted
- **Date:** 2026-09-16
- **Revised:** 2026-09-18 — replaces the previous proposal, which put the
  database's definition in timbot alongside its deployment manifests.
- **Deciders:** Tim Gladwell

## Context

timbot runs on the `akron` k3s cluster, which is managed by Flux from
[homelab](https://github.com/timgladwell/homelab). Its datastore is PostgreSQL
(ADR 0001).

The first version of this ADR proposed that timbot hold the CloudNativePG
`Cluster`, its server parameters, its backup configuration and its retention
policy, on the grounds that the Postgres version pin already spanned timbot's
dev container and CI, and that a change to the app and to its runtime shape
should be one PR. That coupling is the thing being rejected here.

On any third-party platform — Cloud SQL, RDS — the database's configuration is
not in the application's repository. The platform owns the engine version,
the parameters, the backups, the storage and the upgrade path. The application
owns a compatible client library, and the only thing passing between them is a
connection string. Nothing about that arrangement depends on the platform being
a third party. It is available here.

## Decision

### homelab owns the database; timbot consumes a connection string

homelab has 100% of the responsibility for the database being up, available,
backed up, recoverable and upgraded. timbot has 100% of the responsibility for
using a client library that works against what homelab provides.

| Owned by homelab | Owned by timbot |
| --- | --- |
| CloudNativePG operator, and the `Cluster` for timbot | The `pg` gem and Rails' Postgres adapter |
| Postgres major version, minor upgrades, server parameters, extensions | The dev container and CI Postgres pin, following homelab's server version |
| Storage, PVC sizing, storage class | Schema and migrations (#2) |
| Backups, WAL archiving, retention, offsite bucket and IAM | Solid Queue's tables, as ordinary migrations in this database (ADR 0001) |
| Restore and point-in-time recovery, and the runbook for it | Nothing about how any of the left column is achieved |
| Alerting on the database: WAL archive failure, backup age, PVC free space | Alerting on timbot's own failure modes |
| Resource requests, limits, quota and PriorityClass, including protecting DNS | |
| Major-version upgrades, and the connection string that follows one | |

The database's alerts are on the left because they are the platform's health,
not the tenant's: an unarchived-WAL pile-up fills the NVMe and takes household
DNS down with it, whether or not timbot is running.

homelab's reasoning for the items in the left column — engine deployment, backup
design, retention, resource isolation, the hardware integrity risk — lives in
homelab's own ADR. It is not repeated here.

### The interface is one Secret, in timbot's namespace, owned by homelab

The `Cluster` and timbot run in **separate namespaces**. A Kubernetes Secret is
namespaced and a Pod can only reference Secrets in its own namespace; there is no
cross-namespace Secret reference in core Kubernetes. So the Secret CloudNativePG
generates for the application role is, by construction, unreachable from timbot.

That constraint is why the interface is explicit rather than incidental:

- homelab holds the application role's password in a SOPS-encrypted file, as it
  does every other secret.
- It supplies that password to CloudNativePG, and writes a Secret named
  `timbot-database` into timbot's namespace containing a `DATABASE_URL` for the
  same role. What that URL contains — host, port, database, TLS mode — is
  homelab's to compose.
- timbot's Deployment names `timbot-database` and knows nothing else about the
  database. It does not name the `Cluster`, the operator, or a CloudNativePG
  Service.

Namespaces are not a network boundary here — without NetworkPolicies, a Service
in one namespace is reachable from any pod in the cluster. The separation buys
RBAC scope, separate quota, and blast radius; the contract is what the Secret
buys.

This reverses a detail recorded in #10: CloudNativePG generates an application
Secret, so `DATABASE_URL` did not have to be hand-managed. Under this ADR it is
hand-managed, in one SOPS file, deliberately. The generated Secret ties timbot's
configuration to the identity of a particular `Cluster` object, and that is
exactly the coupling that has to be absent for a major-version cutover — or a
move to a database outside the cluster entirely — to leave timbot unchanged.

### Version compatibility is verified at upgrade time, not continuously

timbot's dev container and CI pin a Postgres image, and `test/database_version_test.rb`
fails if the connected server is a different major (`docs/development.md`). Those
pin the version timbot is *developed and tested* against. homelab publishes the
version it *serves*.

Nothing checks continuously that the two agree, because the test does not run
against akron. The check is the upgrade drill instead: homelab stands up the new
major and a throwaway timbot is deployed against it before anything in production
moves. timbot's pin follows homelab's server version, and it follows during that
drill.

### Major upgrades are a migration, not an upgrade in place

The database is not upgraded under timbot. homelab makes a new instance available
and timbot moves to it, accepting a downtime window:

1. homelab stands up a test instance on the new major, restored from a backup of
   the current one, and a throwaway timbot is deployed against it.
2. Both are torn down.
3. homelab stands up the production instance on the new major, disconnects
   clients from the old one, takes a final backup and restores it.
4. timbot is redeployed against the new connection string.

timbot's obligation in all of this is to be pointable at a new host without a
code change — which the Secret interface gives it — and to tolerate the outage.
Minutes of downtime on internal task automation costs nothing.

Logical replication would cut the window to seconds and is rejected: it requires
`wal_level=logical` permanently, which inflates WAL volume on a USB-attached NVMe
that also ships every segment offsite; it runs on replication slots, where a
stalled subscriber retains WAL indefinitely and fills the disk — the highest-
severity failure mode in the stack, given a second trigger; and it replicates
neither DDL nor sequence positions, so a cutover that looks clean collides on the
first insert unless every sequence is advanced by hand.

### Out of scope

Who owns timbot's *application* manifests — Deployment, Service, probes, ingress
— is not decided here. The previous version of this ADR bundled that question
with the database; separating them is the point. It remains open in #10.

## Consequences

### Positive

- The database's manifests are ordinary homelab components, and get homelab's
  full validation: `flux build`, `kustomize build`, kubeconform, kube-score,
  trivy, conftest, and dependabot's image-pin coverage. The open question in #10
  about a base from another repo bypassing all of it never arises for the
  database — the workload it would have been most dangerous for.
- Secrets stay entirely under homelab's existing SOPS enforcement. timbot is a
  public repo and holds no secrets.
- A major-version cutover is a change to a file homelab already owns. timbot is
  not modified, reviewed or released for it.
- If the database ever moves off the cluster — a managed service, another host —
  nothing in timbot changes. The interface is already the one such a service
  would offer.
- Database topology stays out of a public repo, not because it is secret, but
  because it is not timbot's to publish.

### Negative / risks

- **Server parameters and extensions have a lead time.** A feature needing
  `pg_trgm` or a non-default parameter needs a homelab change first, and a timbot
  release that assumes it must land after. This is the manual work the model
  trades for; it is the same friction as filing against a platform team.
- **One hand-managed Secret.** A password in SOPS, referenced twice by homelab,
  where CloudNativePG would have generated one. If the two uses drift, timbot
  fails to authenticate.
- **Version drift is caught late.** Between upgrade drills, nothing verifies that
  akron's server major matches what timbot tested against. The failure surfaces
  at deploy, not in CI.
- **Two repos for one concern.** Diagnosing a database problem means reading
  homelab. That is the correct place for it to be, and it is still a second repo.

## Alternatives considered

| Option | Rejected because |
| --- | --- |
| timbot owns the `Cluster`, parameters, backups and retention (this ADR's first version) | Couples the app's release cycle to the database's configuration for no benefit the connection string doesn't already provide. Its manifests bypass homelab's validation, which is worst for exactly this workload. And it makes a major-version cutover a timbot change |
| Split: `Cluster` in homelab, server parameters and retention in timbot | The worst of both. Two repos must agree on one object, with no mechanism enforcing it, and the parameters are meaningless without the sizing that stays in homelab |
| timbot in the same namespace as the `Cluster`, reading the generated Secret | Needs no machinery at all, and is genuinely simpler. But the generated Secret's name identifies a particular `Cluster`, so timbot's configuration names the database instance — and the cutover in step 4 above becomes a timbot change. The one property being bought is the one it gives up |
| A controller replicating the generated Secret across namespaces | A component to install, run and upgrade, to deliver a value that a SOPS file already holds. Still leaves timbot depending on the `Cluster`'s identity, just indirectly |
| Postgres on the host, outside k3s | Contradicts the containerised-platform goal, and puts the database outside GitOps and outside homelab's validation |
