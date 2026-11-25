# Abre o build mais novo do Weeping of the Empire (a pasta muda de nome a cada atualizacao) e espera o jogo fechar,
# para o Playnite contar o tempo. O plugin Recomps passa a pasta do Recomp (-Pasta).
param([Parameter(Mandatory = $true)][string]$Pasta)
$build = Get-ChildItem -LiteralPath (Join-Path $Pasta 'game') -Directory -Filter 'TotK-PC-*' |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'TotK Launcher.exe') } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $build) { exit 1 }
Start-Process (Join-Path $build.FullName 'TotK Launcher.exe') -WorkingDirectory $build.FullName -Wait
# O launcher pode sair antes do jogo: espera o totk.exe tambem.
do {
    Start-Sleep -Seconds 3
    $jogo = Get-Process totk -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Pasta\*" }
} while ($jogo)
