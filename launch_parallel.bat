@echo off
setlocal enabledelayedexpansion

:: Resolve project root directory
set "PROJECT_PATH=%~dp0"
if "%PROJECT_PATH:~-1%"=="\" set "PROJECT_PATH=%PROJECT_PATH:~0,-1%"

set "SCENE_PATH=res://classes/boards/bots/TrainingBotBoard/TrainingBotBoard.tscn"

set "NUM_ENVS=%~1"
if "%NUM_ENVS%"=="" set "NUM_ENVS=14"

set "PORT=%~2"
if "%PORT%"=="" set "PORT=11000"

set "RULESET=%~3"
if "%RULESET%"=="" set "RULESET=survival"

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
    echo Please set GODOT_BIN environment variable or edit this script.
    echo Example: set GODOT_BIN=C:\path\to\Godot.exe
    pause
    exit /b 1
)

echo =========================================================
echo  Launching %NUM_ENVS% headless Godot training instance(s)
echo    Binary:  %GODOT_EXEC%
echo    Project: %PROJECT_PATH%
echo    Scene:   %SCENE_PATH%
echo    Port:    %PORT%
echo    Ruleset: %RULESET%
echo =========================================================

for /L %%i in (1,1,%NUM_ENVS%) do (
    start "" /B "%GODOT_EXEC%" --path "%PROJECT_PATH%" --headless --quiet "%SCENE_PATH%" -- --port=%PORT% --ruleset=%RULESET% >nul 2>&1
)

echo.
echo All %NUM_ENVS% instances started in background.
echo Now run: python train.py
echo.
echo Press any key to stop all training instances...
pause >nul

echo Stopping headless Godot instances...
for %%F in ("%GODOT_EXEC%") do set "GODOT_NAME=%%~nxF"
taskkill /F /IM "%GODOT_NAME%" >nul 2>&1
echo Done.
