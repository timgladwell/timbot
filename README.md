# timbot
Automating bits of my life

See [docs/development.md](docs/development.md) for local setup.

## Quick reference

Development runs in the Rails dev container ([ADR 0004](docs/adr/0004-local-development-in-the-rails-dev-container.md)).
`devcontainer` is the [devcontainer CLI](https://github.com/devcontainers/cli);
VS Code's **Dev Containers** commands do the same things from the editor.

| Task | Command |
| --- | --- |
| Start the container runtime | `colima start` (or `brew services start colima` to start it at login) |
| Stop the container runtime | `colima stop` |
| Open the dev container | VS Code: **Dev Containers: Reopen in Container**, or `devcontainer up --workspace-folder .` |
| Rebuild the dev container | VS Code: **Dev Containers: Rebuild Container**, or `devcontainer up --remove-existing-container --workspace-folder .` |
| Run a command in it | `devcontainer exec --workspace-folder . <command>` |
| Run the checks | `bin/ci` |
| Run the tests | `bin/rails test` |
| Start the dev server | `bin/dev` |
| Start the job worker | `bin/jobs` |
| Reset the database | `bin/rails db:reset` |
| Delete the database and its volume | `docker compose -p timbot down -v` |

Commands from `bin/ci` down run inside the container.
