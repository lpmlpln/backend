# Import fixtures

These are the real inputs behind the `ImportValidationError.missingIngredients`
report for:

<https://verdegusto.it/en/ricette/spring-cutlets-with-arugula-and-tomatoes-spring-recipe>

- `recipes/verdegusto-spring-cutlets.html` — the page as fetched (kept verbatim,
  including its `schema.org/Recipe` JSON-LD `@graph`).
- `openrouter/verdegusto-spring-cutlets.json` — the completion shape that
  triggered the bug: every extracted array is `null`, so the import can only
  succeed if structured data on the page is used as a fallback.

`ImportFixtureTests` feeds both files through the real import pipeline
(`.parseCompletion` → `ImportService` → `POST /recipes/import/:id/run`) and
asserts the resulting recipe has all nine ingredients. Do not replace the HTML
with a hand-written snippet: synthetic markup is what let the original fix pass
while the reported import stayed broken.
