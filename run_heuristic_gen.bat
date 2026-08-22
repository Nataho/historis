@echo off
setlocal

:: Default to 1 instance if no argument is supplied
set INSTANCES=%1
if "%INSTANCES%"=="" set INSTANCES=1

python "%~dp0run_heuristic_gen.py" %INSTANCES%

pause
