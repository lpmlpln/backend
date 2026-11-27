# Bug-fix evidence

One directory per report, e.g. `docs/evidence/verdegusto-missing-ingredients/`:

- `before.txt` — the exact failing input and response, captured from the layer
  where the user saw the bug (status, body, request URL).
- `after.txt` — the same request against the same input after the fix.
- `test.txt` — name and output of the regression test that keeps it fixed.

For backend bugs the before/after artifact is an HTTP response, not a
screenshot. For iOS bugs, put before/after PNGs in
`mealplanner-ios/docs/evidence/<issue>/` and keep the assertion in
`ScreenInventoryTests` or a view-model test. Record the git revision and
environment in each capture.

Never replace a real captured input with a hand-written approximation: doing
that is what allowed the `missingIngredients` fix to pass its tests while the
reported import remained broken.
