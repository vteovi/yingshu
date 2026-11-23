#!/usr/bin/env bash
# 把 split-per-abi 产物整理成带版本号的 APK；配置了签名密钥就用正式 keystore 重签。
# 需要环境变量：ANDROID_KEYSTORE_BASE64 / KEYSTORE_PASSWORD / KEY_PASSWORD（未配置则跳过重签）
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rm -rf dist
mkdir -p dist

VERSION=$(grep -m1 '^version:' pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)
SRC=build/app/outputs/flutter-apk

mapfile -t APKS < <(ls "$SRC"/app-*-release.apk 2>/dev/null || true)
if [ "${#APKS[@]}" -eq 0 ]; then
  APKS=("$SRC/app-release.apk")
fi

suffix_of() {
  local base
  base=$(basename "$1")
  base=${base#app-}
  base=${base%-release.apk}
  if [ "$base" = "$(basename "$1")" ]; then
    echo "universal"
  else
    echo "$base"
  fi
}

if [ -z "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  for f in "${APKS[@]}"; do
    suffix=$(suffix_of "$f")
    cp "$f" "dist/yingshu-${VERSION}-${suffix}.apk"
  done
  echo "未配置签名密钥：输出调试签名的分架构 APK"
  ls -l dist
  exit 0
fi

KS="$RUNNER_TEMP/yingshu-release.p12"
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$KS"

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
BT_DIR=$(ls -d "$SDK_ROOT"/build-tools/* 2>/dev/null | sort -V | tail -n 1)
APKSIGNER="$BT_DIR/apksigner"
echo "使用 apksigner: $APKSIGNER"

for f in "${APKS[@]}"; do
  suffix=$(suffix_of "$f")
  out="dist/yingshu-${VERSION}-${suffix}.apk"
  "$APKSIGNER" sign \
    --ks "$KS" --ks-type PKCS12 \
    --ks-pass "pass:${KEYSTORE_PASSWORD:-}" \
    --key-pass "pass:${KEY_PASSWORD:-}" \
    --out "$out" "$f"
  "$APKSIGNER" verify --print-certs "$out" | head -n 5
done

ls -l dist
