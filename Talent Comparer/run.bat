@echo off
REM Quick launcher for compare_talents.py
REM Just double-click this. It'll ask you to paste List A, then List B.
REM (You can still drag-and-drop two JSON files onto this .bat instead.)

setlocal

if "%~2"=="" (
    python "%~dp0compare_talents.py" --out shared.json
) else (
    python "%~dp0compare_talents.py" "%~1" "%~2" --out shared.json
)

echo.
pause
