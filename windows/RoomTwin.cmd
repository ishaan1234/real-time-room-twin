@echo off
rem Starts RoomTwin Desktop and opens it in Chrome (or Edge, if there's no Chrome).
rem For VR, start SteamVR with the headset connected before this.
cd /d "%~dp0"
if not exist node_modules (
  echo Installing packages, once...
  call pnpm install || goto :eof
)
set BROWSER=chrome
if not exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set BROWSER=msedge
call pnpm dev --open
