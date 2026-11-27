# Import fixtures

These are the real inputs behind the `ImportValidationError.missingIngredients`
report for:

<https://verdegusto.it/en/ricette/spring-cutlets-with-arugula-and-tomatoes-spring-recipe>

- `recipes/verdegusto-spring-cutlets.html` — the page as fetched (kept verbatim,
  including its `schema.org/Recipe` JSON-LD `@graph`).
- `openrouter/verdegusto-spring-cutlets.json` — every extracted array is `null`.
- `openrouter/verdegusto-blank-ingredients.json` — a non-empty array of blank
  objects, which bypassed the original "is the array empty?" check.
- `openrouter/verdegusto-partial-ingredients.json` — one usable ingredient and
  one blank one, which bypassed the same check.

`ImportFixtureTests` feeds each shape through the real import pipeline
(`.parseCompletion` → fallback → `ImportService` →
`POST /recipes/import/:id/run`) and asserts the resulting recipe has all nine
ingredients from the page. Do not replace the HTML with a hand-written snippet:
synthetic markup is what let the original fix pass while the reported import
stayed broken.
