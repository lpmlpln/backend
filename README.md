# MealPlanner API

Vapor backend for MealPlanner: auth, recipes, plans, shopping lists, sync, imports and the admin UI.

## Requirements

- Swift 6.4+
- PostgreSQL 16+
- `mealplanner-core` as a sibling directory

## Local development

SQLite is the default for local development, so no database server is required:

```bash
swift build
swift run App serve --hostname 0.0.0.0 --port 8080
```

The database file is `mealplanner.sqlite` in the working directory. Select a
different database with:

```bash
# SQLite file
DB_DRIVER=sqlite SQLITE_PATH=/tmp/mealplanner.sqlite swift run App serve

# In-memory SQLite (fresh database on each launch)
DB_DRIVER=sqlite SQLITE_PATH=:memory: swift run App serve
DATABASE_URL=sqlite::memory: swift run App serve

# PostgreSQL
DATABASE_URL=postgres://mealplanner:mealplanner@localhost:5432/mealplanner \
  swift run App serve
```

Resolution order: `DB_DRIVER=sqlite` first (so it overrides a `DATABASE_URL`
from Vapor's automatically loaded `.env`), then `DATABASE_URL` (`sqlite:` →
SQLite, otherwise PostgreSQL), then the test PostgreSQL defaults, then the
local SQLite file. Migrations run automatically outside the `testing`
environment.

`swift test` uses PostgreSQL (`POSTGRES_*`), but also includes SQLite migration
and request-flow tests. Without `SMTP2GO_API_KEY`, magic links are logged to the
console instead of being sent.

## Initial admin

Set `INITIAL_ADMIN_EMAIL` (see `.env.example`). On startup, after migrations,
the API creates or promotes that user to admin **only when no active admin
exists**. If an admin already exists, the variable is ignored. This makes a
fresh local database immediately usable with `/admin`; sign in there with an
admin magic link.

## Docker

```bash
docker compose up --build
```

## Environment

See `.env.example`. All secrets are environment variables; none are committed.

## Tests

`swift test` runs 45 integration tests against real databases with
fake email, Apple, page-fetch, extraction and image-storage adapters. The admin
UI is covered by the same suite; Playwright is added in the deployment phase.

## Routes

- `/health`, `/health/ready`
- `/auth/*`, `/me`, `/devices`
- `/recipes`, `/recipes/import`, `/recipes/:id/*`
- `/plans`, `/plans/:id/*`, `/plans/:id/shopping/*`
- `/friends`, `/sync/pull`, `/sync/push`
- `/admin/*` — dashboard, users (create, enable/disable, grant/revoke admin),
  recipes (list, create, edit, delete), imports (create, retry), audit log
