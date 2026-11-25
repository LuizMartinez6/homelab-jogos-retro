@echo off
title Instalador de Jogos Retro
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0arquivos' | Unblock-File"
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0arquivos\instalador-ui.ps1"
