#!/usr/bin/env bash
# Source from any directory in bash/zsh; keep SDKs and caches inside this repo.
if [ -n "${BASH_VERSION:-}" ]; then
  HERMES_APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  HERMES_APP_ROOT="${0:A:h:h}"
fi
export HERMES_APP_ROOT
export ANDROID_HOME="$HERMES_APP_ROOT/toolchain/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="$HERMES_APP_ROOT/toolchain/jdk/usr/lib/jvm/java-21-openjdk-amd64"
export GRADLE_USER_HOME="$HERMES_APP_ROOT/toolchain/gradle"
export PUB_CACHE="$HERMES_APP_ROOT/toolchain/pub-cache"
export PATH="$HERMES_APP_ROOT/toolchain/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin:$PATH"
