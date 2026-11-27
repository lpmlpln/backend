# Admin UI end-to-end tests

Playwright drives a real backend and Mailpit. Screenshots, traces and videos
are kept **on failure only** and written to `test-results/` and
`playwright-report/`; both are gitignored.

## Prerequisites

```bash
docker compose up -d db mailpit          # PostgreSQL + Mailpit (:8025)
INITIAL_ADMIN_EMAIL=admin@example.com \
SMTP_HOST=localhost SMTP_PORT=1025 \
APP_BASE_URL=http://localhost:8080 \
swift run App serve
```

Then, from this directory:

```bash
npm install
npx playwright install chromium
npm run test:e2e
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `E2E_BASE_URL` | `http://127.0.0.1:8080` | backend under test |
| `MAILPIT_URL` | `http://127.0.0.1:8025` | Mailpit API used to read the magic link |
| `E2E_ADMIN_EMAIL` | `admin@example.com` | account created from `INITIAL_ADMIN_EMAIL` |

The tests log in through the real magic-link flow, create a user (audited),
create and run a queued import, verify the audit trail, check the CSRF guard,
and verify that unauthenticated admin pages redirect to login.

Never point these tests at production: they create users and import jobs.
