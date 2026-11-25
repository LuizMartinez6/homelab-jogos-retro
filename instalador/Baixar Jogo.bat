@echo off
title Baixar Jogo
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0arquivos' | Unblock-File"
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0arquivos\baixar-jogo.ps1"
