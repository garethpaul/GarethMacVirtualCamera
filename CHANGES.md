# Changes

## 2026-06-08

- Added `make check` as the conventional local validation entry point.
- Documented the Makefile baseline and recorded the completed plan under `docs/plans/`.
- Extended project validation so the Makefile, plan, README, VISION, and change log stay aligned.
- Routed CI pre-build validation through `make check` so local and CI baselines stay aligned.
- Added unsigned build script fixture tests for the `xcodebuild` invocation contract.
- Strengthened build-product verification for missing app/extension products, declared executables, bundled diagnostics self-tests, and product-specific privacy usage strings.
- Added the expected runtime evidence copy action to the Build details actions so it matches the Runtime Evidence panel and Camera menu.
- Covered missing extension usage strings, wrong app camera usage strings, and unsigned build failure propagation in fixture tests.
- Covered bundled-video metadata fallback behavior in runtime diagnostics self-tests.
- Covered executable declaration, executable permission, extension display metadata, direct app-group, and missing build-log edge cases in validation fixtures.
- Limited CI workflow token permissions to read-only repository contents.
- Added activity feedback for automatic foreground refreshes when visible readiness state changes after returning to the app.
- Covered non-executable host app binaries and missing extension executable declarations in build-product verifier fixtures.
- Covered empty and multi-value application-group formatting in runtime diagnostics self-tests.
