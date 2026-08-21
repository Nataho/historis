@echo off
setlocal enabledelayedexpansion

:: Resolve project root directory
set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "SCENE_PATH=%~1"
if "%SCENE_PATH%"=="" set "SCENE_PATH=res://scenes/test.tscn"

:: Shift first argument so %* contains remaining args
shift

:: Auto-detect Godot binary location
if defined GODOT_BIN (
    if exist "%GODOT_BIN%" set "GODOT_EXEC=%GODOT_BIN%"
)

if not defined GODOT_EXEC (
    if exist "A:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" (
        set "GODOT_EXEC=A:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
    ) else if exist "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" (
        set "GODOT_EXEC=C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
    ) else if exist "C:\Program Files\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" (
        set "GODOT_EXEC=C:\Program Files\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
    ) else (
        for %%X in (godot.exe godot4.exe) do (
            if not defined GODOT_EXEC (
                for /f "tokens=*" %%A in ('where %%X 2^>nul') do set "GODOT_EXEC=%%A"
            )
        )
    )
)

if not defined GODOT_EXEC (
    echo [ERROR] Could not find Godot executable!
    echo Please set GODOT_BIN environment variable, e.g.:
    echo   set GODOT_BIN=C:\path\to\Godot.exe
    pause
    exit /b 1
)

echo =========================================================
echo  Launching Godot Headless Test Arena
echo    Binary:  %GODOT_EXEC%
echo    Project: %PROJECT_DIR%
echo    Scene:   %SCENE_PATH%
echo =========================================================
echo Press Ctrl+C to stop the headless instance.
echo.

"%GODOT_EXEC%" --path "%PROJECT_DIR%" --headless "%SCENE_PATH%" %1 %2 %3 %4 %5 %6 %7 %8 %9
