@echo off
title Conectar Conquistas
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0arquivos' | Unblock-File"
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0arquivos\conectar-conquistas.ps1"
