#!/usr/bin/env bash
# 跨平台品牌落地：Android 包名/应用名/权限 + iOS 显示名与 ATS + macOS 网络权限，最后生成图标。
# 用法：bash tool/apply_branding.sh（需先按 README 生成平台工程）
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -d android ]; then
  echo "未找到 android/ 平台工程，请先用 flutter create 生成平台壳（见 README 第一节）" >&2
  exit 1
fi

python3 tool/patch_branding.py

if command -v dart >/dev/null 2>&1; then
  dart run flutter_launcher_icons
else
  echo "未找到 dart，跳过图标生成" >&2
fi

echo "品牌信息已落地：影枢 CineHub / com.yingshu.player"
