@echo off
title Network Profile Cleaner
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clear-NetworkProfiles.ps1"
