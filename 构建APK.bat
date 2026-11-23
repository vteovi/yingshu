@echo off
rem 本机系统代码页是 UTF-8(65001)，所以本文件按 UTF-8 无 BOM 保存
%SystemRoot%\System32\chcp.com 65001 >nul 2>nul
setlocal
title 影枢 CineHub 构建

rem ============================================================
rem 影枢 CineHub 一键构建（BAT 入口）
rem 真正的构建逻辑在同目录的 构建APK.ps1，本文件只负责调用它，
rem 双击即可运行，不用改系统的 PowerShell 执行策略。
rem
rem 用法：
rem   直接双击                  分架构构建 + 签名 + 复制到 D:\DouBao\CineHub
rem   构建APK.bat -Universal    只出一个通用包
rem   构建APK.bat -NoSign       只构建不签名
rem ============================================================

rem 用通配符找同目录的 ps1，避免在 bat 里写死中文文件名
set "SCRIPT="
for %%F in ("%~dp0*.ps1") do if not defined SCRIPT set "SCRIPT=%%~fF"

if not defined SCRIPT (
    echo [错误] 同目录下没有找到 .ps1 构建脚本。
    echo         当前目录：%~dp0
    pause
    exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell"

echo ==^> 构建脚本：%SCRIPT%
echo ==^> 开始构建，请稍候……
echo.

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"

echo.
if "%CODE%"=="0" (
    echo [完成] 构建成功，APK 已复制到 D:\DouBao\CineHub
) else (
    echo [失败] 构建失败，错误码 %CODE%，原因见上方日志。
)
echo.
pause
exit /b %CODE%