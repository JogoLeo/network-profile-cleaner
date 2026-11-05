@echo off
title Network Profile Restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-NetworkProfiles.ps1"
