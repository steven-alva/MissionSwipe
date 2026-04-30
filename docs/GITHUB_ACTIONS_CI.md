# Optional GitHub Actions CI

The current GitHub token used for the first publish does not include the `workflow` scope, so CI is documented here instead of being committed under `.github/workflows/`.

To enable CI later, create `.github/workflows/ci.yml` with:

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  build:
    runs-on: macos-latest

    steps:
      - uses: actions/checkout@v4

      - name: Typecheck
        run: |
          swiftc -typecheck MissionSwipe/*.swift \
            -target "$(uname -m)-apple-macosx13.0" \
            -sdk "$(xcrun --sdk macosx --show-sdk-path)"

      - name: Build app bundle
        run: BUILD_UNIVERSAL=0 scripts/build_app.sh
```
