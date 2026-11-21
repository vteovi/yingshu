# 影枢 CineHub —— 平台品牌信息一次性落地脚本
#
# 用法：先生成平台工程（见 README 第一节），然后在项目根目录执行：
#   powershell -ExecutionPolicy Bypass -File .\tool\apply_branding.ps1
#
# 做的事：
#   1. Android applicationId / namespace -> com.yingshu.player，应用名 -> 影枢
#   2. Android 补 INTERNET 权限与 usesCleartextTraffic（http 源必须）
#   3. iOS CFBundleDisplayName -> 影枢，补 ATS 允许 http
#   4. macOS 补 network client 权限，按 1024 母图生成 AppIcon 各尺寸
#   5. 调用 flutter_launcher_icons 生成 Android / iOS / Windows 图标
#
# 脚本可重复执行：已经改过的项不会重复写。

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$AppName = '影枢'
$AppNameEn = 'CineHub'
$PackageId = 'com.yingshu.player'
$MasterIcon = Join-Path $ProjectRoot 'assets\branding\app_icon.png'

function Write-Step($text) {
  Write-Host "==> $text" -ForegroundColor Cyan
}

function Add-NetworkClientEntitlement($path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $content = Get-Content -LiteralPath $path -Raw
  if ($content -match 'com\.apple\.security\.network\.client') { return }
  $last = $content.LastIndexOf('</dict>')
  if ($last -lt 0) { return }
  $inject = @'
	<key>com.apple.security.network.client</key>
	<true/>
'@
  $content = $content.Insert($last, "$inject`r`n")
  Set-Content -LiteralPath $path -Value $content -Encoding UTF8
  Write-Host "  patched $(Split-Path -Leaf $path)"
}

if (-not (Test-Path -LiteralPath $MasterIcon)) {
  throw "缺少图标母图：$MasterIcon"
}

if (-not (Test-Path -LiteralPath 'android')) {
  Write-Host '未找到 android/ 平台工程，请先按 README 第一节用 flutter create 生成平台壳。' -ForegroundColor Yellow
  exit 1
}

# ---------------------------------------------------------------- Android
Write-Step 'Android'
$gradle = @('android\app\build.gradle.kts', 'android\app\build.gradle') |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($gradle) {
  $content = Get-Content -LiteralPath $gradle -Raw
  $content = [regex]::Replace($content, 'applicationId\s*=?\s*"[^"]+"', "applicationId = `"$PackageId`"")
  $content = [regex]::Replace($content, 'namespace\s*=?\s*["''][^"'']+["'']', "namespace = `"$PackageId`"")
  Set-Content -LiteralPath $gradle -Value $content -Encoding UTF8
  Write-Host "  patched $gradle"
}

$manifest = 'android\app\src\main\AndroidManifest.xml'
if (Test-Path -LiteralPath $manifest) {
  $content = Get-Content -LiteralPath $manifest -Raw

  if ($content -notmatch 'android\.permission\.INTERNET') {
    $content = [regex]::Replace(
      $content,
      '<application',
      "    <uses-permission android:name=`"android.permission.INTERNET`"/>`r`n    <application",
      1
    )
  }

  if ($content -match 'android:label="([^"]*)"') {
    $content = [regex]::Replace($content, 'android:label="[^"]*"', "android:label=`"$AppName`"")
  }

  if ($content -notmatch 'usesCleartextTraffic') {
    $content = [regex]::Replace(
      $content,
      '<application([^>]*?)>',
      '<application$1 android:usesCleartextTraffic="true">',
      1
    )
  }

  Set-Content -LiteralPath $manifest -Value $content -Encoding UTF8
  Write-Host "  patched $manifest"
}

# ---------------------------------------------------------------- iOS
Write-Step 'iOS'
$plist = 'ios\Runner\Info.plist'
if (Test-Path -LiteralPath $plist) {
  $content = Get-Content -LiteralPath $plist -Raw

  if ($content -match '<key>CFBundleDisplayName</key>') {
    $content = [regex]::Replace(
      $content,
      '<key>CFBundleDisplayName</key>\s*<string>[^<]*</string>',
      "<key>CFBundleDisplayName</key>`r`n`t<string>$AppName</string>"
    )
  } else {
    $content = [regex]::Replace(
      $content,
      '<key>CFBundleName</key>\s*<string>[^<]*</string>',
      "<key>CFBundleName</key>`r`n`t<string>$AppNameEn</string>`r`n`t<key>CFBundleDisplayName</key>`r`n`t<string>$AppName</string>"
    )
  }

  if ($content -notmatch 'NSAppTransportSecurity') {
    $ats = @'
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
'@
    $last = $content.LastIndexOf('</dict>')
    if ($last -gt 0) {
      $content = $content.Insert($last, "$ats`r`n")
    }
  }

  Set-Content -LiteralPath $plist -Value $content -Encoding UTF8
  Write-Host "  patched $plist"
}

# ---------------------------------------------------------------- macOS
Write-Step 'macOS'
Add-NetworkClientEntitlement 'macos\Runner\DebugProfile.entitlements'
Add-NetworkClientEntitlement 'macos\Runner\Release.entitlements'

$appIconSet = 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
if (Test-Path -LiteralPath $appIconSet) {
  Add-Type -AssemblyName System.Drawing
  $source = [System.Drawing.Image]::FromFile($MasterIcon)
  try {
    Get-ChildItem -LiteralPath $appIconSet -Filter 'app_icon_*.png' | ForEach-Object {
      $size = [int]([regex]::Match($_.BaseName, '(\d+)$').Groups[1].Value)
      if ($size -le 0) { return }
      $bmp = New-Object System.Drawing.Bitmap($size, $size)
      $graphics = [System.Drawing.Graphics]::FromImage($bmp)
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.DrawImage($source, 0, 0, $size, $size)
      $graphics.Dispose()
      $bmp.Save($_.FullName, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
    }
    Write-Host '  macOS AppIcon 已按母图重绘'
  } finally {
    $source.Dispose()
  }
}

# ---------------------------------------------------------------- 图标生成
Write-Step '生成 Android / iOS / Windows 图标'
dart run flutter_launcher_icons

Write-Host ''
Write-Host "品牌信息已落地：$AppName / $AppNameEn / $PackageId" -ForegroundColor Green
