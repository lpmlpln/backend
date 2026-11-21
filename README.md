# MealPlanner API

Vapor backend for MealPlanner: auth, recipes, plans, shopping lists, sync, imports and the admin UI.

## Requirements

- Swift 6.4+
- PostgreSQL 16+
- `mealplanner-core` as a sibling directory

## Local development

```bash
brew services start postgresql@14
createdb mealplanner_test
swift build
swift test
swift run App serve --hostname 0.0.0.0 --port 8080
```

Set `DATABASE_URL` to override the test database connection. Without
`SMTP2GO_API_KEY`, magic links are logged to the console instead of being sent.

## Docker

```bash
docker compose up --build
```

## Environment

See `.env.example`. All secrets are environment variables; none are committed.

## Tests

`swift test` runs 30 integration tests against a real PostgreSQL database with
fake email, Apple, page-fetch, extraction and image-storage adapters. The admin
UI is covered by the same suite; Playwright is added in the deployment phase.

## Routes

- `/health`, `/health/ready`
- `/auth/*`, `/me`, `/devices`
- `/recipes`, `/recipes/import`, `/recipes/:id/*`
- `/plans`, `/plans/:id/*`, `/plans/:id/shopping/*`
- `/friends`, `/sync/pull`, `/sync/push`
- `/admin/*`
