# 影枢 CineHub 本地构建脚本
#
# 用法（在 PowerShell 里）：
#   .\构建APK.ps1                 # 分架构构建 + 正式签名 + 拷贝到项目根目录
#   .\构建APK.ps1 -Universal      # 出一个通用包（体积大，但一个包通吃）
#   .\构建APK.ps1 -NoSign         # 只构建不签名（调试用）
#   .\构建APK.ps1 -Toolchain "D:\DouBao\CineHub\.toolchain"   # 指定工具链位置
#
# 前置：工具链（Flutter SDK / Android SDK / pub & gradle 缓存）放在 .toolchain 目录，
# 或在环境变量 CINEHUB_TOOLCHAIN 里指定路径。

param(
    [string]$Toolchain = "",
    [switch]$Universal,
    [switch]$NoSign,
    [switch]$KeepJava
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "构建失败：$msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- 1. 定位工具链
Write-Step '定位工具链'

$candidates = @()
if ($Toolchain) { $candidates += $Toolchain }
if ($env:CINEHUB_TOOLCHAIN) { $candidates += $env:CINEHUB_TOOLCHAIN }
$candidates += @(
    (Join-Path $Root '.toolchain'),
    (Join-Path 'D:\DouBao\CineHub' '.toolchain'),
    (Join-Path $env:USERPROFILE 'CineHub\.toolchain'),
    'C:\Users\Administrator\Doubao\chats\2026-11-21\new-chat\.toolchain'
)

$Tc = ''
foreach ($path in $candidates) {
    if (-not $path) { continue }
    if (Test-Path (Join-Path $path 'flutter\bin\flutter.bat')) { $Tc = (Resolve-Path $path).Path; break }
}
if (-not $Tc) {
    Fail '没找到工具链目录。请用 -Toolchain 指定，或把 .toolchain 放到项目根目录。'
}
Write-Ok "工具链：$Tc"

$FlutterBat = Join-Path $Tc 'flutter\bin\flutter.bat'
$DartBat = Join-Path $Tc 'flutter\bin\dart.bat'
$Sdk = Join-Path $Tc 'android-sdk'
if (-not (Test-Path $Sdk)) { Fail "工具链里缺少 Android SDK：$Sdk" }

# ---------------------------------------------------------------- 2. 准备环境变量
Write-Step '准备构建环境'

$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:PUB_CACHE = Join-Path $Tc 'pub-cache'
$env:GRADLE_USER_HOME = Join-Path $Tc 'gradle-home'
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_USER_HOME = Join-Path $Tc 'android-home'

# JDK：优先环境变量，其次工具链里的 jdk-17，最后常见安装位置
$JdkHome = $env:JAVA_HOME
if (-not $JdkHome -or -not (Test-Path (Join-Path $JdkHome 'bin\java.exe'))) {
    foreach ($guess in @((Join-Path $Tc 'jdk-17'), 'C:\Java\jdk-17', 'C:\Program Files\Java\jdk-17')) {
        if (Test-Path (Join-Path $guess 'bin\java.exe')) { $JdkHome = $guess; break }
    }
}
if (-not $JdkHome) { Fail '没找到 JDK 17。请设置 JAVA_HOME 或把 jdk-17 放进工具链目录。' }
$env:JAVA_HOME = $JdkHome
Write-Ok "JDK：$JdkHome"

$GitDir = ''
foreach ($g in @('C:\Users\Administrator\Tools\MinGit\cmd', 'C:\Program Files\Git\cmd')) {
    if (Test-Path (Join-Path $g 'git.exe')) { $GitDir = $g; break }
}
if (-not $GitDir) { $GitDir = (Split-Path (Get-Command git -ErrorAction SilentlyContinue).Source -Parent) }
if (-not $GitDir) { Fail '没找到 git.exe（Flutter 需要 git），请安装 Git for Windows。' }

$env:PATH = @(
    (Join-Path $Tc 'flutter\bin'),
    (Join-Path $JdkHome 'bin'),
    $GitDir,
    (Join-Path $Sdk 'platform-tools'),
    'C:\Windows\System32',
    'C:\Windows',
    $env:PATH
) -join ';'

# local.properties：指向当前工具链，避免工程搬家后路径失效
$LocalProps = Join-Path $Root 'android\local.properties'
$sdkEscaped = $Sdk -replace '\\', '\\'
$flutterEscaped = (Join-Path $Tc 'flutter') -replace '\\', '\\'
$props = "sdk.dir=$sdkEscaped`nflutter.sdk=$flutterEscaped`n"
$needWrite = $true
if (Test-Path $LocalProps) {
    $needWrite = ((Get-Content $LocalProps -Raw) -notmatch [regex]::Escape("sdk.dir=$sdkEscaped"))
}
if ($needWrite) {
    [IO.File]::WriteAllText($LocalProps, $props, [System.Text.UTF8Encoding]::new($false))
    Write-Ok 'local.properties 已按当前工具链重写'
}

# ---------------------------------------------------------------- 3. 预置 libmpv jar
# media_kit 插件会去 GitHub Release 拉 libmpv 的 jar，国内直连经常卡死。
# 工具链里存着这几个 jar 时直接塞进 build 目录，插件检测到就不再联网下载。
Write-Step '预置 libmpv 运行库'

$JarSrc = Join-Path $Tc 'libmpv-jars'
$JarDir = Join-Path $Root 'build\media_kit_libs_android_video\v1.1.7'
if (Test-Path $JarSrc) {
    New-Item -ItemType Directory -Force -Path $JarDir | Out-Null
    Copy-Item (Join-Path $JarSrc '*.jar') $JarDir -Force
    Write-Ok "已复制 $((Get-ChildItem $JarSrc -Filter *.jar).Count) 个 jar 到 build 目录"
} else {
    Write-Warn2 '工具链里没有 libmpv-jars，构建时会尝试联网下载（国内可能超时）'
}

# ---------------------------------------------------------------- 4. 版本号与参数
# pubspec.yaml 的 `version: X.Y.Z+B`：X.Y.Z 给用户看（versionName），B 给系统（versionCode）
$VersionLine = (Select-String -Path (Join-Path $Root 'pubspec.yaml') -Pattern '^version:' |
        Select-Object -First 1).Line -replace '^version:\s*', ''
$Version = ($VersionLine -replace '\+.*$', '').Trim()
$VersionCode = ($VersionLine -replace '^[^+]*\+?', '').Trim()
if (-not $VersionCode) {
    # 没写 +B 时按 主×10000 + 次×100 + 补丁 算一个单调递增的整数
    $parts = @($Version.Split('.') | ForEach-Object { [int]($_ -replace '[^0-9]', '0') })
    while ($parts.Count -lt 3) { $parts += 0 }
    $VersionCode = $parts[0] * 10000 + $parts[1] * 100 + $parts[2]
}
if (-not $VersionCode) { Fail "pubspec.yaml 里的版本号格式不对：$VersionLine" }
Write-Ok "版本：$Version（versionCode $VersionCode）"

# Gradle 的 flutter.versionName / flutter.versionCode 来自 local.properties。
# 直接调 gradlew 时 Flutter 工具不会来刷新这两个字段，旧值会让安装界面一直显示老版本，
# 所以这里每次构建都按 pubspec 覆盖一遍。
$LocalProps = Join-Path $Root 'android\local.properties'
$lines = @()
if (Test-Path $LocalProps) {
    $lines = Get-Content $LocalProps | Where-Object { $_ -notmatch '^\s*flutter\.version(Name|Code)\s*=' }
} else {
    $lines = @("sdk.dir=$sdkEscaped", "flutter.sdk=$flutterEscaped")
}
$lines += "flutter.versionName=$Version"
$lines += "flutter.versionCode=$VersionCode"
[IO.File]::WriteAllLines($LocalProps, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Ok "local.properties 已写入 versionName=$Version / versionCode=$VersionCode"

# ---------------------------------------------------------------- 5. pub get + 构建
Write-Step '拉取依赖'
& $FlutterBat pub get
if ($LASTEXITCODE -ne 0) { Fail 'flutter pub get 失败' }

Write-Step '开始构建 release APK'

# 上一次构建/搬盘后残留的 Gradle、Kotlin 守护进程会锁住增量缓存，先清干净再编
$staleJava = Get-Process java, javaw -ErrorAction SilentlyContinue
if ($staleJava) {
    $staleJava | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "已结束 $($staleJava.Count) 个残留 Java 进程"
    Start-Sleep -Seconds 2
}

# 用 Gradle 直接组装，比 `flutter build apk` 稳（后者在这台机器上会随机倒在 Kotlin 缓存锁上）
$OutDir = Join-Path $Root 'build\app\outputs\flutter-apk'
$Gradlew = Join-Path $Root 'android\gradlew.bat'
if (-not (Test-Path $Gradlew)) { Fail "没找到 gradlew：$Gradlew" }

function Invoke-Build {
    # 清掉上一次产物，避免把旧的通用包当成这次的产物
    if (Test-Path $OutDir) { Get-ChildItem $OutDir -Filter '*.apk' | Remove-Item -Force -ErrorAction SilentlyContinue }
    $buildArgs = @('assembleRelease')
    if (-not $Universal) {
        $buildArgs += '-Psplit-per-abi=true'
        $buildArgs += '-Ptarget-platform=android-arm,android-arm64,android-x64'
    }
    # sdkReleaseDependencyData 会把结果写进 build\app\outputs\sdk-dependencies，
    # 上一次构建/杀 Java 进程后常留下被占用的死文件，直接让 BUILD FAILED。
    # 这任务只是给 Google Play 记录依赖、对 APK 没影响，这里先删目录再跳过任务。
    $SdkDepDir = Join-Path $Root 'build\app\outputs\sdk-dependencies'
    if (Test-Path $SdkDepDir) { Remove-Item $SdkDepDir -Recurse -Force -ErrorAction SilentlyContinue }
    $buildArgs += @('-x', 'sdkReleaseDependencyData')
    Push-Location (Join-Path $Root 'android')
    # gradlew 会把进度/提示写到 stderr（例如 “Flutter assets will be downloaded from ...”），
    # 在 ErrorActionPreference=Stop 下会被当成终止性错误、把构建中途掐断，所以这里临时放宽。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Out-Host 让日志直接打到屏幕，不混进函数返回值
        & $Gradlew @buildArgs 2>&1 | Out-Host
        $script:BuildExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Build
if ($script:BuildExitCode -ne 0) {
    Write-Warn2 '首次构建失败，清理 build 缓存后重试一次（常见于工程搬家后 Kotlin 增量缓存损坏）'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FlutterBat clean | Out-Host
        & $FlutterBat pub get | Out-Host
    } finally {
        $ErrorActionPreference = $prevEap
    }
    # clean 会删掉预置的 libmpv jar，这里补回去
    if (Test-Path $JarSrc) {
        New-Item -ItemType Directory -Force -Path $JarDir | Out-Null
        Copy-Item (Join-Path $JarSrc '*.jar') $JarDir -Force
    }
    Invoke-Build
}
$sw.Stop()
if ($script:BuildExitCode -ne 0) { Fail 'Gradle 构建失败（日志见上方）' }
Write-Ok "构建耗时 $([math]::Round($sw.Elapsed.TotalMinutes,1)) 分钟"

$Built = Get-ChildItem $OutDir -Filter 'app-*-release.apk' -ErrorAction SilentlyContinue
if (-not $Built) { $Built = Get-ChildItem $OutDir -Filter 'app-release.apk' -ErrorAction SilentlyContinue }
if (-not $Built) { Fail "没找到构建产物：$OutDir" }

# ---------------------------------------------------------------- 6. 正式签名
$Signed = @()
$Keystore = Join-Path 'D:\DouBao\CineHub' '.signing\yingshu-release.p12'
if (-not (Test-Path $Keystore)) { $Keystore = Join-Path (Split-Path $Root -Parent) '.signing\yingshu-release.p12' }

if (-not $NoSign) {
    Write-Step '正式签名'
    $Apksigner = Join-Path $Sdk 'build-tools\37.0.0\apksigner.bat'
    if (-not (Test-Path $Apksigner)) {
        $bt = Get-ChildItem (Join-Path $Sdk 'build-tools') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($bt) { $Apksigner = Join-Path $bt.FullName 'apksigner.bat' }
    }
    if (-not (Test-Path $Apksigner)) { Fail '没找到 apksigner，检查 Android SDK build-tools。' }
    if (-not (Test-Path $Keystore)) { Fail "没找到签名密钥：$Keystore" }

    # 密码从 keystore-info.txt 读取，脚本里不写死
    $InfoFile = Join-Path (Split-Path $Keystore -Parent) 'keystore-info.txt'
    $StorePass = ''
    $Alias = 'yingshu'
    if (Test-Path $InfoFile) {
        $info = Get-Content $InfoFile -Raw
        if ($info -match 'storePassword[)）:：\s]*([^\s]+)') { $StorePass = $Matches[1].Trim() }
        if ($info -match '别名[^:：]*[:：]\s*([^\s]+)') { $Alias = $Matches[1].Trim() }
    }
    if (-not $StorePass) { Fail "没能从 keystore-info.txt 读取密码，请检查 $InfoFile" }

    $DistDir = Join-Path $Root 'dist'
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
    Get-ChildItem $DistDir -Filter '*.apk' -ErrorAction SilentlyContinue | Remove-Item -Force

    foreach ($apk in $Built) {
        $abi = 'universal'
        if ($apk.Name -match 'app-(.+)-release\.apk') { $abi = $Matches[1] }
        $target = Join-Path $DistDir "yingshu-$Version-$abi.apk"
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $Apksigner sign --ks $Keystore --ks-type PKCS12 `
                --ks-pass "pass:$StorePass" --key-pass "pass:$StorePass" `
                --ks-key-alias $Alias --out $target $apk.FullName 2>&1 | Out-Null
            $signExit = $LASTEXITCODE
            & $Apksigner verify --print-certs $target 2>&1 | Select-String 'certificate DN' | ForEach-Object {
                Write-Ok "已签名 $abi · $($_.Line.Trim())"
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($signExit -ne 0) { Fail "签名失败：$($apk.Name)" }
        $Signed += [pscustomobject]@{ Abi = $abi; Path = $target }
    }
}

# ---------------------------------------------------------------- 7. 拷贝到项目上层目录
Write-Step '拷贝到 D:\DouBao\CineHub'

# 产物直接放到工程外层的 CineHub 目录（和 .signing / 安装包 同级），
# 不要清理这个目录里已有的 APK：老版本要留着，新版本按「影枢_版本_架构.apk」名字并入。
$DestDir = Split-Path -Parent $Root
if (-not (Test-Path $DestDir)) { $DestDir = $Root }
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

$results = @()
if ($Signed.Count -gt 0) {
    foreach ($item in $Signed) {
        $name = "影枢_${Version}_$($item.Abi).apk"
        $target = Join-Path $DestDir $name
        Copy-Item $item.Path $target -Force
        $results += Get-Item $target
    }
} else {
    foreach ($apk in $Built) {
        $abi = 'universal'
        if ($apk.Name -match 'app-(.+)-release\.apk') { $abi = $Matches[1] }
        $name = "影枢_${Version}_$abi.apk"
        $target = Join-Path $DestDir $name
        Copy-Item $apk.FullName $target -Force
        $results += Get-Item $target
    }
}

Write-Step '完成'
foreach ($f in $results) {
    Write-Host ("    {0}  {1} MB" -f $f.FullName, [math]::Round($f.Length / 1MB, 2)) -ForegroundColor White
}
Write-Warn2 'arm64-v8a 是绝大多数手机要装的那个，armeabi-v7a 给老机型，x86_64 给模拟器。'
Write-Warn2 "同目录下的老版本 APK 都保留着，不会被这次构建删掉。"

# ---------------------------------------------------------------- 8. 收尾：清理 Java 进程
if (-not $KeepJava) {
    $javaProcs = Get-Process java, javaw -ErrorAction SilentlyContinue
    if ($javaProcs) {
        $javaProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "已清理 $($javaProcs.Count) 个残留 Java 进程（-KeepJava 可保留）"
    }
}
