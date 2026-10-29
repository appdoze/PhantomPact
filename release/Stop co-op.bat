@echo off
title Phantom Pact - Stop
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\pbz-coop.ps1" -Stop
pause
