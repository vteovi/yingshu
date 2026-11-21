# 影枢 CineHub

一个 Flutter 跨端流媒体播放器：用**苹果CMS v10 采集接口**当订阅源，支持聚合浏览、聚合搜索、点播播放、收藏、断点续播，形态类似 TVBox / ZYPlayer，但只做「源 + 播放器」，不内置任何影视源。

- 应用名：**影枢**（CineHub）
- 包名：`com.yingshu.player`
- 版本：`0.1.0+1`
- 目标平台：Android / iOS / Windows / macOS（同一套代码）
- 播放内核：`media_kit`（libmpv），支持 HLS(m3u8)、mp4 等直链
- 订阅格式：`https://域名/api.php/provide/vod/`

---

## 一、先补齐平台工程（必做）

本仓库只包含 `lib/` 业务代码、图标素材与配置，缺少 Android/iOS 等平台壳。因为不想让 `flutter create .` 覆盖 `lib/main.dart`，先生成到临时目录再把平台目录拷回来。

PowerShell（Windows）：

```powershell
cd C:\Users\Administrator\Doubao\chats\2026-11-21\new-chat\yingshu
flutter create --platforms=android,ios,windows,macos --org com.example --project-name yingshu "$env:TEMP\yingshu_shell"
Copy-Item -Recurse "$env:TEMP\yingshu_shell\android","$env:TEMP\yingshu_shell\ios","$env:TEMP\yingshu_shell\windows","$env:TEMP\yingshu_shell\macos" -Destination .
flutter pub get
dart run flutter_launcher_icons
powershell -ExecutionPolicy Bypass -File .\tool\apply_branding.ps1
flutter run -d windows
```

要求：Flutter ≥ 3.22（Dart ≥ 3.4）。打包 APK / IPA 由你自己执行。

> `tool/apply_branding.ps1` 会把 `applicationId` 改成 `com.yingshu.player`、应用名改成「影枢」、补 INTERNET 权限与明文流量开关、iOS 显示名与 ATS、macOS 网络权限与 AppIcon，并重跑图标生成。脚本可重复执行。

---

## 二、平台必改的几处配置

以下内容脚本已经覆盖，这里保留说明，方便你手动核对或改包名。

### 1. Android

`android/app/src/main/AndroidManifest.xml`：

```xml
<manifest ...>
    <uses-permission android:name="android.permission.INTERNET"/>
    <application
        ...
        android:usesCleartextTraffic="true">   <!-- 很多源站是 http 直链，不加会黑屏 -->
```

`android/app/build.gradle(.kts)` 里：

```gradle
applicationId = "com.yingshu.player"
namespace = "com.yingshu.player"
```

电视盒子需要的话，在 `<activity>` 内补 leanback 启动 intent。

### 2. iOS

`ios/Runner/Info.plist`：

```xml
<key>CFBundleDisplayName</key>
<string>影枢</string>
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```

`ios/Podfile` 第一行放开到 `platform :ios, '13.0'`（media_kit 要求）。

### 3. macOS

`macos/Runner/DebugProfile.entitlements` 与 `Release.entitlements`：

```xml
<key>com.apple.security.network.client</key>
<true/>
```

### 4. Windows

`media_kit_libs_video` 已自带 mpv 动态库；若播放无声，确认构建输出目录存在 `libmpv-2.dll`。

---

## 三、品牌材料

```
assets/branding/
├── app_icon.png       # 1024×1024 图标母图（深空紫 + 播放三角 + 三节点聚合网络）
└── app_icon_512.png   # 512 预览图
tool/apply_branding.ps1 # 平台品牌信息与图标落地脚本
```

- 图标来源：AI 生成后统一缩放，无任何文字/字母，小尺寸仍清晰。
- `pubspec.yaml` 中已配置 `flutter_launcher_icons`，改图标只需替换 `assets/branding/app_icon.png` 再执行一次 `dart run flutter_launcher_icons`。
- 应用内「欢迎页」直接复用该图标（`lib/widgets/brand_mark.dart`）。

---

## 四、已实现的功能

**订阅源管理**
- 添加 / 编辑 / 删除 / 启用停用，保存前可「测试连接」，直接显示分类数与最新数据条数
- 批量导入：粘贴多行 `名称,接口地址`、粘贴 JSON 数组、从订阅链接拉取（兼容 `{sites:[...]}` / `{list:[...]}`）
- 一键复制全部源配置为 JSON
- 删除源时连带清理该源的收藏与历史

**浏览与检索**
- 首页：分类 chips + 最近更新海报流，下拉刷新，右上角切换源
- 分类页：分页无限加载
- 聚合搜索：并发请求所有启用源，结果标注来源并可按来源筛选

**播放**
- 完整解析 `vod_play_from` / `vod_play_url`，支持多线路切换、上百集选集
- 手势：单击显隐控件、双击左/右半屏 ±10 秒、进度条拖动
- 倍速 0.5×–2×、上一集/下一集、全屏（横屏 + 沉浸式）、底部选集面板
- 每 5 秒记录进度，退出/切集落盘；历史页一键续播
- 自动连播下一集（设置可关）

**收藏 / 历史 / 设置**
- 收藏、历史独立页，长按或侧滑删除、可清空
- 自定义请求 UA、连播开关、记忆进度开关

---

## 五、代码结构

```
lib/
├── main.dart                 # 初始化 MediaKit + SharedPreferences + AppState
├── app.dart                  # MaterialApp（影枢 CineHub，深色主题）
├── core/constants.dart       # 应用名、包名、版本、默认 UA
├── models/                   # 源、影片、剧集、收藏/历史
├── data/                     # 苹果CMS 接口客户端、订阅解析、本地存储
├── state/app_state.dart      # 全局状态
├── theme/app_theme.dart
├── widgets/                  # 海报卡、状态视图、品牌 Logo
└── pages/                    # 首页/分类/搜索/详情/播放器/收藏/历史/设置/源管理
test/parsers_test.dart        # 播放串与订阅解析单测
tool/apply_branding.ps1       # 平台品牌落地脚本
```

---

## 六、接口约定

| 用途 | 参数 |
| --- | --- |
| 首页分类 + 最新 | `?ac=list`（读取 `class[]`、`list[]`） |
| 分类分页 | `?ac=detail&t=<type_id>&pg=<page>` |
| 关键词搜索 | `?ac=detail&wd=<关键字>&pg=<page>`，失败/空结果回退 `ac=videolist` |
| 详情（含播放地址） | `?ac=detail&ids=<vod_id>` |

剧集串规则：`线路A$$$线路B` 对应 `集1$url1#集2$url2$$$...`，解析逻辑在 `lib/models/episode.dart`，单测在 `test/parsers_test.dart`。

---

## 七、已知边界

1. **只播直链**。部分源的 `vod_play_url` 是网页地址，libmpv 播不了，播放失败页会提示，需要另做按域名的解析规则。
2. **没有直播**。要加 m3u/txt 直播源，可复用 `PlayerPage` 再挂一个页签。
3. 无下载、投屏、弹幕、DRM。
4. 源站多为 http，务必开启明文流量。
5. 图标、品牌名已落地，但应用商店所需的截图、隐私政策、软件著作权材料仍需自行准备。
