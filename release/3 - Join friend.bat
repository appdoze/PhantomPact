@echo off
title Phantom Pact - Join
echo Start the game and load your save first.
set /p PEER=Host's Tailscale IP (starts with 100.): 
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\pbz-coop.ps1" -Role client -Peer "%PEER%"
pause
