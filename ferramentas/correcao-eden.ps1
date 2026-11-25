# Monta a entrada do instalador\arquivos\correcoes.json a partir do Eden do dono: le o
# config\custom\<TitleID>.ini e pega so o que foi trocado na configuracao do jogo
# ("chave\use_global=false"). Cole a saida na lista e publique uma atualizacao.
# Uso: pwsh -File correcao-eden.ps1 0100606026F12000 -Id ff-resonance-nvdec -Jogo "Nome" -Motivo "Tela preta"

param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{16}$')][string]$TitleId,
    [Parameter(Mandatory = $true)][string]$Id,
    [string]$Jogo = '',
    [string]$Motivo = '',
    [string]$Eden = 'E:\Emuladores\Eden'
)

$ErrorActionPreference = 'Stop'
$ini = Join-Path $Eden "user\config\custom\$($TitleId.ToUpper()).ini"
if (-not (Test-Path -LiteralPath $ini)) { throw "Nao achei $ini (abra Propriedades do jogo no Eden e mude algo primeiro)." }

$linhas = [IO.File]::ReadAllLines($ini)
$secao = ''; $proprios = @(); $valores = @{}
foreach ($l in $linhas) {
    if ($l -match '^\[(.+)\]$') { $secao = $Matches[1]; continue }
    if ($l -match '^(.+)\\use_global=false$') { $proprios += "$secao|$($Matches[1])" }
}
foreach ($l in $linhas) {
    if ($l -match '^\[(.+)\]$') { $secao = $Matches[1]; continue }
    if ($l -match '^([^\\=]+)=(.*)$' -and "$secao|$($Matches[1])" -in $proprios) {
        if (-not $valores[$secao]) { $valores[$secao] = [ordered]@{} }
        $valores[$secao][$Matches[1]] = $Matches[2]
    }
}
if (-not $valores.Count) { throw 'Esse jogo nao tem nada diferente da configuracao geral.' }

[ordered]@{ id = $Id; jogo = $Jogo; emulador = 'Eden'; titleId = $TitleId.ToUpper(); motivo = $Motivo; valores = $valores } | ConvertTo-Json -Depth 4
