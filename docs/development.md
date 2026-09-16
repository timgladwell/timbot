# Local development

## Postgres version pin

timbot runs **PostgreSQL 18** everywhere: locally, in CI and on the `akron`
cluster (ADR 0001). The major version is pinned in three places, and they move
together:

| Where | What |
| --- | --- |
| `.github/workflows/ci.yml` | `postgres:18` service image (both test jobs) |
| `test/database_version_test.rb` | fails if the connected server isn't 18 |
| homelab, `sites/akron` | the CNPG `Cluster` image ([#1](https://github.com/timgladwell/timbot/issues/1)) |

Because the version test runs locally and in CI, a mismatched local server
fails `bin/rails test` rather than drifting unnoticed.

## Setup

Ruby is pinned in `.ruby-version`. Postgres comes from
[Postgres.app](https://postgresapp.com/): start a PostgreSQL 18 server on the
default port. `pg_trgm` ships with it. The app's default trust auth for the
current user is what `config/database.yml` expects, so there's nothing to
configure.

```sh
bin/setup              # bundle, db:prepare, then starts bin/dev
bin/setup --skip-server
bin/rails test
```

## Solid Queue

Solid Queue's tables live in the application database as an ordinary migration
(`db/migrate/*_create_solid_queue_tables.rb`), not in Rails 8's separate queue
database (ADR 0001). Development uses the default async adapter. To run the
worker locally against Postgres, run `bin/jobs`.
