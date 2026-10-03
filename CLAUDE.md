# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

timbot is one Rails 8 monolith with two jobs: automating household things that
should be automated, and being the place to develop an application idea quickly,
without standing up infrastructure first. Ideas that outgrow it split out. It runs on the
single-node `akron` K3s cluster, which is managed by Flux from
[timgladwell/homelab](https://github.com/timgladwell/homelab).

**It is currently a Rails skeleton.** No area has been built yet — `app/` holds
generated defaults and `test/` holds two guard tests. Most of what is decided
lives in `docs/adr/`, not in code. Read the ADR before assuming an absence is an
oversight; several are deliberate deferrals.

This is a public repository, and doubles as a portfolio, though that comes
second. Design detail is welcome in it; secrets never are, and there are none
here to find.

## Development

Everything runs in the Rails dev container — the Mac has a container runtime, an
editor, and no Postgres. Host Ruby and the bundle exist only so Claude Code's
Ruby LSP plugin can run (ADR 0004, #11); never run the app, tests or `bin/ci`
with them. Commands below are run
inside it (VS Code **Reopen in Container**, or prefix with the CLI form):

```sh
npx @devcontainers/cli up --workspace-folder .
npx @devcontainers/cli exec --workspace-folder . <command>
```

| Task | Command |
| --- | --- |
| Full CI locally | `bin/ci` — setup, rubocop, bundler-audit, importmap audit, brakeman, tests, seeds |
| All tests | `bin/rails test` |
| One test file | `bin/rails test test/database_version_test.rb` |
| One test by name | `bin/rails test test/foo_test.rb -n test_the_thing` |
| Style | `bin/rubocop` (rails-omakase, unmodified) |
| Server | `bin/dev` — port 3000, forwarded to the host |
| Solid Queue worker | `bin/jobs` |
| Wipe the database | `docker compose -p timbot down -v`, then bring the container up again |

`bin/ci` is Rails' own runner; its steps are `config/ci.rb`, which is where a new
check goes. **Prefer the `ci-runner` subagent over running `bin/ci` inline** — it
runs on a cheaper model and keeps several thousand lines of tool output out of
the conversation.

Colima is the runtime here. If `docker ps` fails, say so rather than starting it.

## Architecture

### Areas are module namespaces, and their tables carry a prefix

Each area is a top-level Ruby module in the standard Rails directories —
`app/models/water_levels/station.rb`, `WaterLevels::Station`. Every table **must**
carry its area's prefix via the module's `table_name_prefix`
(`water_levels_stations`, never `stations`). `rails generate model
water_levels/station` produces the whole shape.

Nothing enforces this yet; packwerk is a deliberate deferral until a second area
exists to test a boundary against. The prefix is what keeps a later split cheap,
so it is the one rule to be strict about now (ADR 0002).

### The database is not this repo's

timbot does not own, configure or deploy its database. It is a tenant of
homelab's shared PostgreSQL service, with its own role and database. homelab owns
the service in full:
engine version, server parameters, storage, backups, recovery, alerting and
upgrades. timbot receives `DATABASE_URL` and `DATABASE_READONLY_URL` from a
`timbot-database` Secret that
homelab writes into its namespace, and knows nothing else (ADR 0003).

Consequences that change what to do here:

- **Never add cluster or database configuration to this repo.** No CloudNativePG
  `Cluster`, no Postgres parameters, no backup or retention config. If a change
  seems to need one, it is a homelab issue.
- **A feature needing an extension (`pg_trgm`) or a non-default server parameter
  is blocked on a homelab PR**, and the timbot release assuming it must land
  after. Raise it early; it is a lead time, not a blocker.
- **Nothing here names the `Cluster`, the operator or a CNPG Service.** That
  indirection is what lets homelab move the database without touching timbot.
- **Point-in-time recovery is not something timbot can perform.** From this side
  the rollback story is forward-fix, plus asking homelab to restore.

Solid Queue's tables live in the application database as an ordinary migration,
not Rails 8's separate queue database. Solid Cache and Solid Cable follow the
same path if they are ever added (ADR 0001).

Who owns timbot's *deployment* manifests — Deployment, Service, probes, ingress —
is still open (#10). Do not create a `deploy/` directory on the assumption it is
settled.

## Developing alongside homelab

timbot and its platform, homelab, are being built side by side, and both are
immature. **Expect timbot work to keep exposing problems that belong to the
platform**: a missing service, a gap in the database contract, a deploy path that
does not exist yet.

**Platform-scope problems live in homelab only.** File the issue in
[timgladwell/homelab](https://github.com/timgladwell/homelab/issues), and record
the decision in homelab's `docs/adr/`. From timbot, link to it and record only
what timbot itself must do. Do not keep a parallel copy here, even when the
problem was found here. timbot's ADR 0001 was narrowed exactly that way when the
database's operation moved to homelab.

The test: would a second application on the platform hit the same problem? If
so, it is homelab's.

## ADR conventions

`docs/adr/` holds the decisions. **Each ADR addresses a problem inherent in the
system's design**, so revising one is expected, not a failure. If Postgres turns
out to be the wrong datastore, ADR 0001 is revised. It is still the same
discussion about stateful storage, so it is not superseded by a new ADR. An ADR is
`Deprecated` only when its problem has gone out of the system's scope.

Status is `Proposed`, `Accepted` or `Deprecated`. Each ADR ends with a changelog,
one row per change, newest last:

```markdown
## Changelog

| Date | By | Description |
| --- | --- | --- |
| 2026-09-16 | Tim and Claude | Accepted (#5) |
```

Keep descriptions to one line. If one has to break, GitHub renders `<br>` inside
a table cell.

Refer to this repo's ADRs by relative link and homelab's by full URL. homelab
numbers its ADRs independently, so a bare "ADR 0001" is ambiguous.

---

## When to read what

Open these only when the trigger applies. The fact each one is most often needed
for is inlined, so the common case needs no read at all.

| File | Open it when | Fact you usually want |
| --- | --- | --- |
| [`docs/development.md`](docs/development.md) | Setting up, changing the dev container or CI, or touching the Postgres version | Postgres 18, pinned in four places that move together |
| [`docs/adr/0001-postgresql-as-primary-datastore.md`](docs/adr/0001-postgresql-as-primary-datastore.md) | Proposing a second database, a different engine, or moving Solid Queue out | One logical database, read-write and read-only roles; Solid Queue shares it |
| [`docs/adr/0002-area-boundaries-in-the-monolith.md`](docs/adr/0002-area-boundaries-in-the-monolith.md) | Creating an area, a model, or any migration | Tables carry the area's `table_name_prefix` |
| [`docs/adr/0003-database-as-a-service-from-homelab.md`](docs/adr/0003-database-as-a-service-from-homelab.md) | Anything touching deployment, the database's config, or the boundary with homelab | The interface is one Secret; the rest is homelab's |
| [`docs/adr/0004-local-development-in-the-rails-dev-container.md`](docs/adr/0004-local-development-in-the-rails-dev-container.md) | Changing `.devcontainer/`, or wondering why something isn't installed on the host | Local parity covers the toolchain, not production behaviour |
| [`.claude/agents/ci-runner.md`](.claude/agents/ci-runner.md) | Its report is confusing, or CI gains a step | It reports a pass/fail table and does not fix anything |

Cross-repo: homelab's `CLAUDE.md` governs anything in that repo, and its
`docs/adr/0001-postgresql-platform-service.md` holds how the database is run and
the tenant contract — recovery point, PITR window, served major — that timbot
can rely on. Claude does not touch a running cluster from either repo — commands get
written out for a person to run.
