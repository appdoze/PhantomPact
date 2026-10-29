@echo off
title Phantom Pact - Host
echo Start the game and load your save first.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\pbz-coop.ps1" -Role host
pause
