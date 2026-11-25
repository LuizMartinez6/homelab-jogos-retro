# Gera os dois instaladores em saida (fora do git):
#   Instalador-Jogos-NetBird.zip   - amigos novos (conecta pelo NetBird)
#   Instalador-Jogos-Tailscale.zip - amigos que ja estao no Tailscale
# Nenhum leva login: cada pessoa entra com o codigo de convite do painel Amigos.
# Uso: pwsh -File gerar-zips.ps1

$ErrorActionPreference = 'Stop'
$Pasta = $PSScriptRoot
$Raiz = Split-Path $Pasta -Parent
$Origem = Join-Path $Raiz 'instalador'
$Saida = Join-Path $Raiz 'saida'
New-Item $Saida -ItemType Directory -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

$cfgOrigem = Get-Content (Join-Path $Origem 'arquivos\config.json') -Raw -Encoding UTF8
if (($cfgOrigem | ConvertFrom-Json).jogos.usuario) { throw 'config.json do instalador tem login de pessoa; tire antes de gerar.' }
# CRLF sempre: os trechos abaixo usam `r`n, e a copia local pode ter vindo do git com LF.
$leiaOrigem = (Get-Content (Join-Path $Origem 'LEIA-ME.txt') -Raw -Encoding UTF8) -replace '\r?\n', "`r`n"

# Trechos do LEIA-ME (escrito para o NetBird) trocados na edicao Tailscale.
$TrocasTailscale = [ordered]@{
    "   Cada codigo e de uma pessoa so e vale por 7 dias. Fora da casa do`r`n   servidor, o instalador instala o NetBird e conecta sozinho. Se o`r`n   Windows perguntar se pode fazer alteracoes, clique em Sim." =
    "   Fora da casa do servidor, a conexao e pelo Tailscale: se ele ainda`r`n   nao estiver no PC, o instalador instala e espera voce entrar com a sua`r`n   conta (icone perto do relogio > Log in)."
    "- Fora da casa do servidor, o NetBird precisa estar ligado (ele liga`r`n  sozinho com o Windows)." =
    "- Fora da casa do servidor, o Tailscale precisa estar ligado."
    "- Abra no navegador (fora de casa, com o NetBird ligado):`r`n  http://100.64.0.10:8090" =
    "- Abra no navegador, com o Tailscale ligado:`r`n  https://meu-servidor.tailnet-exemplo.ts.net:8443"
}

foreach ($edicao in 'NetBird', 'Tailscale') {
    $temp = Join-Path $env:TEMP "zip-jogos-$PID-$edicao"
    Copy-Item $Origem $temp -Recurse
    try {
        # Cada edicao so conhece o proprio caminho (alem da rede local).
        $cfg = $cfgOrigem | ConvertFrom-Json
        $tirar = if ($edicao -eq 'NetBird') { 'tailscale' } else { 'netbird' }
        $cfg.servidor.PSObject.Properties.Remove($tirar); $cfg.jogos.PSObject.Properties.Remove($tirar)
        [IO.File]::WriteAllText((Join-Path $temp 'arquivos\config.json'), ($cfg | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))

        $leia = $leiaOrigem
        if ($edicao -eq 'Tailscale') {
            foreach ($t in $TrocasTailscale.Keys) {
                if (-not $leia.Contains($t)) { throw "LEIA-ME mudou; trecho nao encontrado: $($t.Substring(0, 40))..." }
                $leia = $leia.Replace($t, $TrocasTailscale[$t])
            }
        }
        [IO.File]::WriteAllText((Join-Path $temp 'LEIA-ME.txt'), $leia, (New-Object Text.UTF8Encoding $false))

        $zip = Join-Path $Saida "Instalador-Jogos-$edicao.zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($temp, $zip)
        Write-Host "$edicao -> $zip"

        # Mesmo pacote dentro de um .exe (sem .bat para o amigo abrir).
        $exe = Join-Path $Saida "Instalar Jogos Retro ($edicao).exe"
        $fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
        $saidaCsc = & "$fw\csc.exe" /nologo /target:winexe /optimize+ /codepage:65001 "/out:$exe" "/win32icon:$Pasta\exe\jogos.ico" "/resource:$zip,pacote.zip" `
            /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Windows.Forms.dll "$Pasta\exe\Instalador.cs" 2>&1
        if ($LASTEXITCODE) { throw "Falha ao compilar o .exe:`n$($saidaCsc -join "`n")" }
        Write-Host "$edicao -> $exe"
    } finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Os .exe tambem ficam no painel "Amigos" do ZimaOS (botao "Baixar instalador").
$scp = "$env:WINDIR\System32\OpenSSH\scp.exe"
$exes = @(Get-ChildItem $Saida -Filter 'Instalar Jogos Retro (*).exe' | ForEach-Object FullName)
& $scp -i "$env:USERPROFILE\.ssh\id_servidor" -o IdentitiesOnly=yes -o BatchMode=yes @exes 'usuario@192.168.0.10:/DATA/AppData/amigos/instaladores/'
if ($LASTEXITCODE) { Write-Warning 'Nao deu para enviar os .exe para o painel Amigos.' } else { Write-Host 'Instaladores enviados para o painel Amigos.' }
