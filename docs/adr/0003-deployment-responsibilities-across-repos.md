# 3. Deployment responsibilities across timbot and homelab

- **Status:** Proposed
- **Date:** 2026-09-16
- **Deciders:** Tim Gladwell

## Context

timbot runs on the `akron` k3s cluster, which is managed by Flux from
[homelab](https://github.com/timgladwell/homelab). Its database is PostgreSQL
through the CloudNativePG operator, with backups to S3 through the Barman Cloud
plugin (ADR 0001).

The plan in #1 and #3 put everything except the application code in homelab:
the CNPG `Cluster`, the Deployment, Service and ingress, and the Secrets. That
splits every change that touches both the app and its runtime shape across two
repos and two PRs. Examples include a new worker process, a Postgres parameter
a feature depends on, or a memory limit that a change in the app requires.

homelab already separates what a component *is* from what a site *supplies*:

| homelab layer | Directory | Contains |
| --- | --- | --- |
| Component | `base/<component>/` | Site-agnostic definitions, with `${VAR}` placeholders for site values |
| Site | `sites/<site>/<layer>/` | That site's Secrets, patches and choice of components |
| Entry point | `clusters/<site>/` | Flux `Kustomization` objects and `cluster-vars` |

timbot's deployment definition is a component in that sense. The question is
which repo it lives in.

## Decision

### timbot owns what timbot is

timbot holds its deployment definition as a plain Kustomize base in `deploy/`.
The base has no site values and no secrets. It plays the role of a homelab
`base/` component that happens to live with its application.

| Owned by timbot (`deploy/`, CI) | Why here |
| --- | --- |
| Application image, built and pushed to GHCR by timbot's CI (#3) | Built from this repo's code |
| Deployments for the web and job processes, and their Service | Process shape changes with the code: a new worker, a new port, a health check path |
| Probes on `/up` | The app defines what healthy means |
| CNPG `Cluster`: Postgres image and version pin, `postgresql` parameters, `archive_timeout`, WAL compression, `retentionPolicy`, base backup schedule | The version pin already spans the dev container and CI in this repo (`docs/development.md`). Parameters and retention are properties of how this app uses its data |
| Barman Cloud `ObjectStore`, minus bucket and credentials | Its shape belongs with the `Cluster`, and the site supplies the destination |
| Alert rules describing timbot's failure modes: WAL archive failure, backup age, PVC free space | Rules describe this app's database. Routing them is a site concern |
| Default resource requests and limits | A starting point that the site overrides |

### homelab owns where and how timbot runs

| Owned by homelab | Why there |
| --- | --- |
| CNPG operator and Barman Cloud plugin | Cluster-wide, with CRDs. The same kind of shared infrastructure as cert-manager or MetalLB |
| Flux wiring: source, `Kustomization`, `dependsOn` the operator layer | Flux lives there |
| Namespace and `ResourceQuota` | Site policy, as for every homelab component |
| Resource limits, storage size and storage class for akron | Sized against the node, which is shared with DNS (ADR 0001) |
| PriorityClasses and DNS protection (#1, section 6) | Protects other workloads *from* timbot |
| SOPS Secrets: `RAILS_MASTER_KEY`, S3 credentials | Encrypted to the site's age key, which only homelab holds |
| Bucket name, ingress hostname and Traefik `IngressRoute` | Site values |
| Alert routing | Monitoring is stored only at akron |
| Restore runbook and recovery manifests | Performed against a site |
| AWS bucket and IAM user, and the plug-pull test | Not reconciled by anything. Inventoried in homelab's `docs/host-state.md` |

`DATABASE_URL` is not a hand-managed Secret. CNPG generates an application user
Secret for each `Cluster`, including a connection URI, and the Deployment
references it.

### One version for code, image and manifests

A timbot release is one git tag. The image is tagged with it, and homelab
selects the `deploy/` base at the same tag. Code and manifests therefore
cannot drift apart.

Which Flux source carries the base is decided in #3, alongside how a new tag
reaches homelab:

- a `GitRepository` on timbot at the tag (public repo, no credentials), or
- an OCI artifact of `deploy/` pushed by timbot's CI next to the image, read
  through an `OCIRepository`.

## Consequences

### Positive

- A change to the app and to its runtime shape is one PR in one repo, reviewed
  together and released under one tag.
- The Postgres version pin lives entirely in timbot: dev container, CI and
  cluster.
- homelab's layering holds. timbot is a component with site values supplied by
  the site, and nothing site-specific leaks into timbot.
- Secrets stay under homelab's existing SOPS enforcement. timbot is a public repo
  and holds no secrets.

### Negative / risks

- **homelab's validation does not see timbot's base.** homelab runs
  `kustomize build`, kubeconform, kube-score, trivy and conftest over what it
  holds locally. A base pulled from another repo at reconcile time bypasses all
  of it. One of the following has to close that gap before the first deploy:
  homelab's pipeline fetches the base at the pinned tag, or timbot's CI runs the
  same checks on `deploy/`. Without either, the first place a bad manifest fails
  is akron.
- **Two repos still change for site-level work.** A new Secret, a hostname or a
  resized limit needs a homelab PR, and a release that depends on it has to land
  after it.
- **Ordering across repos.** A release that needs a new site value can
  reconcile before homelab supplies it. Flux reports the failure, but nothing
  prevents it.
- **Database topology is public.** Parameters, retention and alert thresholds
  are visible in a public repo. None are secrets, and timbot is intended as a
  public portfolio.

## Alternatives considered

| Option | Rejected because |
| --- | --- |
| Everything in homelab (the plan in #1 and #3) | Every change to the app's runtime shape is two PRs, and nothing ties a manifest version to an image version. homelab's validation coverage is the one real advantage, and the consequence above addresses it directly |
| Everything in timbot, including site values and Secrets | Secrets would need a second SOPS setup and age key outside homelab's enforcement, in a public repo. Site sizing against DNS would move away from the node it protects |
| Helm chart published from timbot | Templating, a values schema and chart versioning, for a single consumer. Kustomize bases and patches already match how homelab composes components |
| CNPG `Cluster` in homelab, app workloads in timbot | Splits the Postgres version pin and database parameters away from the dev container and CI that must match them |
