# Hermes Android app

See [the repository README](../README.md) for setup, configuration,
architecture, contract mapping, and reconnect limitations.

```bash
source ../scripts/env.sh
flutter pub get
flutter analyze
flutter test   # full per-file sweep: bash ../scripts/run-tests-detached.sh
```

正式建置走 repo root 的 wrapper（`--profile` 必填；personal 需要 env 檔內的
`HERMES_APP_DEFAULT_URL`，public 完全不含任何伺服器位址）：

```bash
bash ../scripts/build_app.sh --target apk --mode debug --profile personal
bash ../scripts/build_app.sh --target apk --mode release --profile public
```
