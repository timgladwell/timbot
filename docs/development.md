# Local development

Development happens in the Rails dev container (`.devcontainer/`). It runs the
app and PostgreSQL as containers, so the Mac needs only a container runtime and
an editor.

## Prerequisites

- A Docker-compatible runtime. This Mac uses [Colima](https://colima.run/):
  `brew install colima docker docker-compose`, then `colima start`.
- VS Code with the Dev Containers extension, or the
  [devcontainer CLI](https://github.com/devcontainers/cli).

## Working in the container

In VS Code, **Dev Containers: Reopen in Container**. The first build runs
`bin/setup --skip-server`, which installs gems and creates the development and
test databases. Ruby LSP is installed in the container and provides the test
explorer and debugger.

From a terminal instead:

```sh
npx @devcontainers/cli up --workspace-folder .
npx @devcontainers/cli exec --workspace-folder . bin/rails test
```

Inside the container, `bin/dev` serves on port 3000, which is forwarded to the
host. `bin/jobs` runs the Solid Queue worker.

To wipe the database and start over, remove the containers and their volume, then
bring the dev container up again:

```sh
docker compose -p timbot down -v
```

## Postgres version pin

timbot runs **PostgreSQL 18** everywhere: in the dev container, in CI and on the
`akron` cluster (ADR 0001). The version is pinned in these places, which move
together:

| Where | What |
| --- | --- |
| `.devcontainer/compose.yaml` | `postgres` service image |
| `.devcontainer/devcontainer.json` | `postgres-client` feature version (`psql`, `pg_dump`) |
| `.github/workflows/ci.yml` | `postgres` service image |
| `test/database_version_test.rb` | fails if the connected server isn't major 18 |
| homelab, `sites/akron` | the CNPG `Cluster` image ([#1](https://github.com/timgladwell/timbot/issues/1)) |

The dev container and CI use the same image tag. The version test runs in both,
so a mismatched server fails `bin/rails test` rather than drifting unnoticed.

## Database connection

In the dev container, `DB_HOST` is set and `config/database.yml` connects to the
`postgres` service with the container's credentials. CI and production supply
`DATABASE_URL` instead.

## Solid Queue

Solid Queue's tables live in the application database as an ordinary migration
(`db/migrate/*_create_solid_queue_tables.rb`), not in Rails 8's separate queue
database (ADR 0001). Development uses the default async adapter.
