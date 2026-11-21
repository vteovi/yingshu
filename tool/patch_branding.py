#!/usr/bin/env python3
"""把「影枢 CineHub」的品牌信息写进各平台工程，可重复执行。

只处理已经存在的平台目录，缺失的跳过：
- android/app/build.gradle(.kts)：applicationId / namespace
- AndroidManifest.xml：INTERNET 权限、usesCleartextTraffic、应用名
- Kotlin/Java 的 MainActivity 包路径（applicationId 改了必须同步搬目录，否则启动崩溃）
- iOS Info.plist：CFBundleDisplayName、ATS
- macOS entitlements：network client
"""
from __future__ import annotations

import pathlib
import plistlib
import re
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_NAME = "影枢"
APP_NAME_EN = "CineHub"
PACKAGE_ID = "com.yingshu.player"


def patch_android() -> None:
    gradle = None
    for name in ("android/app/build.gradle.kts", "android/app/build.gradle"):
        candidate = ROOT / name
        if candidate.exists():
            gradle = candidate
            break
    if gradle is None:
        return

    text = gradle.read_text(encoding="utf-8")
    text = re.sub(r'applicationId\s*=?\s*"[^"]+"', f'applicationId = "{PACKAGE_ID}"', text)
    text = re.sub(r'namespace\s*=?\s*["\'][^"\']+["\']', f'namespace = "{PACKAGE_ID}"', text)
    gradle.write_text(text, encoding="utf-8")
    print(f"[android] {gradle.name}: applicationId = {PACKAGE_ID}")

    manifest = ROOT / "android/app/src/main/AndroidManifest.xml"
    if manifest.exists():
        text = manifest.read_text(encoding="utf-8")
        if "android.permission.INTERNET" not in text:
            text = text.replace(
                "<application",
                '    <uses-permission android:name="android.permission.INTERNET"/>\n    <application',
                1,
            )
        text = re.sub(r'android:label="[^"]*"', f'android:label="{APP_NAME}"', text)
        if "usesCleartextTraffic" not in text:
            text = re.sub(
                r"<application([^>]*?)>",
                r'<application\1 android:usesCleartextTraffic="true">',
                text,
                count=1,
            )
        manifest.write_text(text, encoding="utf-8")
        print("[android] AndroidManifest.xml: INTERNET / cleartext / label 已处理")

    patch_main_activity()


def patch_main_activity() -> None:
    """applicationId 改了以后 .MainActivity 会解析到新包名，必须同步移动源文件。"""
    for lang in ("kotlin", "java"):
        base = ROOT / "android/app/src/main" / lang
        if not base.exists():
            continue
        for activity in list(base.rglob("MainActivity.*")):
            text = activity.read_text(encoding="utf-8")
            text = re.sub(r"package\s+[\w.]+", f"package {PACKAGE_ID}", text, count=1)
            target = base.joinpath(*PACKAGE_ID.split(".")) / activity.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
            if target != activity:
                activity.unlink()
            print(f"[android] MainActivity -> {target.relative_to(ROOT)}")
            prune_empty_dirs(activity.parent, base)


def prune_empty_dirs(start: pathlib.Path, stop: pathlib.Path) -> None:
    current = start
    while current != stop and current.is_dir():
        if any(current.iterdir()):
            break
        current.rmdir()
        current = current.parent


def patch_ios() -> None:
    plist = ROOT / "ios/Runner/Info.plist"
    if not plist.exists():
        return
    with plist.open("rb") as file:
        data = plistlib.load(file)
    data["CFBundleDisplayName"] = APP_NAME
    data.setdefault("CFBundleName", APP_NAME_EN)
    data["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
    data.setdefault("UISupportedInterfaceOrientations", [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ])
    with plist.open("wb") as file:
        plistlib.dump(data, file)
    print("[ios] Info.plist: 显示名与 ATS 已写入")


def patch_macos() -> None:
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        path = ROOT / "macos/Runner" / name
        if not path.exists():
            continue
        with path.open("rb") as file:
            data = plistlib.load(file)
        data["com.apple.security.network.client"] = True
        with path.open("wb") as file:
            plistlib.dump(data, file)
        print(f"[macos] {name}: network.client 已开启")


def main() -> None:
    patch_android()
    patch_ios()
    patch_macos()


if __name__ == "__main__":
    main()
