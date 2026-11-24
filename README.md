# MealPlanner API

Vapor backend for MealPlanner: auth, recipes, plans, shopping lists, sync, imports and the admin UI.

## Requirements

- Swift 6.4+
- PostgreSQL 16+ (optional for local development; SQLite is supported)
- Access to the shared core package at `https://github.com/lpmlpln/swift-core`
  (`MealPlannerCore`, `main` branch). If the repository is private, configure
  Git credentials before building.

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

## Deploy to Vercel

The API is built with the official
[Swift Vercel runtime](https://github.com/vercel-labs/swift-vercel-runtime).
`vercel.json` installs the swift.org 6.4.3 toolchain plus the matching Static Linux SDK
and runs `swift package --disable-sandbox vercel`, which produces a static
binary served by Vercel's native `executable` runtime. No Docker or Node adapter
is involved.

1. Create a Vercel project with **Root Directory** = `mealplanner-api` and
   **Framework Preset** = `Other`.
2. Add environment variables in the Vercel dashboard:
   - `DATABASE_URL` — **required**, a PostgreSQL connection string. SQLite and
     an unset `DATABASE_URL` are rejected on Vercel because the filesystem is
     ephemeral.
   - `JWT_SECRET`, `APPLE_TEAM_ID`, `APPLE_BUNDLE_ID`, `APPLE_KEY_ID`,
     `APPLE_PRIVATE_KEY`, `SMTP2GO_API_KEY`, `EMAIL_FROM`, `OPENROUTER_API_KEY`,
     `SPACES_*`, `INITIAL_ADMIN_EMAIL`.
   - `VAPOR_ENV=production` (otherwise Vapor exposes error details).
   - `RUN_MIGRATIONS=false` after the initial deployment if you prefer to run
     migrations separately; leave it unset for the first deploy.
   - Private `swift-core` repository: set `CORE_REPO_TOKEN` in CI, or configure
     Git credentials on the build machine.
3. Deploy with Git or locally:

```bash
cd mealplanner-api
vercel link       # once
vercel --prod
```

Magic links use `VERCEL_URL` automatically unless `APP_BASE_URL` is set.

Recipe imports run synchronously on the `POST /recipes/import/:jobID/run`
endpoint. On Vercel this can exceed the default function duration on Hobby
plans; increase the function's maximum duration (or run imports through a
separate worker) for production imports.

The first build downloads about 1.4 GB of toolchain/SDK and takes several
minutes; later builds restore the toolchain and `.build` from Vercel's cache.
`.vercel/` is gitignored.

All outbound HTTP (SMTP2GO, Apple JWKS, page fetching and OpenRouter) uses
Vapor's `Client` (AsyncHTTPClient), not `URLSession`. Foundation's networking
types live in a separate `FoundationNetworking` module on Linux and are
problematic in fully static musl binaries.

Swift 6.4.0's SwiftPM crashed during build planning on Vercel's x86_64 Amazon
Linux 2023 image (`GlobalProductPlan.computeModuleInfo` / libdispatch
`Signal 11`). This project pins 6.4.3 in `.swift-version` to avoid that
toolchain bug. If the crash reappears, try a newer 6.4.x release by changing
only `.swift-version`; the cache is keyed by Swift version, so the next build
will be a cold one.

## Docker

```bash
docker compose up --build
```

DigitalOcean App Platform / Docker remains supported as an alternative to
Vercel.

## Environment

See `.env.example`. All secrets are environment variables; none are committed.

## Tests

`swift test` runs 48 integration tests against real databases with
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
