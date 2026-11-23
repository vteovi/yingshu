@echo off
chcp 936 >nul
setlocal
title 影枢 CineHub 构建

rem ============================================================
rem 影枢 CineHub 一键构建（BAT 入口）
rem 实际构建逻辑在同目录的 构建APK.ps1，本文件只负责调用它，
rem 好处是双击即可运行，不用改系统的执行策略。
rem
rem 用法：
rem   直接双击            分架构构建 + 签名 + 复制到 D:\DouBao\CineHub
rem   构建APK.bat -Universal   出一个通用包
rem   构建APK.bat -NoSign      只构建不签名
rem ============================================================

set "SCRIPT=%~dp0构建APK.ps1"
if not exist "%SCRIPT%" (
    echo [错误] 找不到 构建APK.ps1，请确认它和本文件在同一目录。
    echo         当前目录：%~dp0
    pause
    exit /b 1
)

where powershell >nul 2>nul
if errorlevel 1 (
    echo [错误] 系统里找不到 powershell，无法继续。
    pause
    exit /b 1
)

echo ==^> 开始构建：%SCRIPT%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
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