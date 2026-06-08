# Changes

## 2026-06-08

- Added `make check` as the conventional local validation entry point.
- Documented the Makefile baseline and recorded the completed plan under `docs/plans/`.
- Extended project validation so the Makefile, plan, README, VISION, and change log stay aligned.
- Routed CI pre-build validation through `make check` so local and CI baselines stay aligned.
- Added unsigned build script fixture tests for the `xcodebuild` invocation contract.
- Strengthened build-product verification for missing app/extension products, declared executables, bundled diagnostics self-tests, and product-specific privacy usage strings.
