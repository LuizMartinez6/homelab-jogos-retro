# Compila o plugin, publica a nova versao, refaz os zips e confere o seu Playnite.
# Uso, com o Playnite fechado: powershell -ExecutionPolicy Bypass -File publicar-plugin.ps1
# Com -Teste a versao vai so para o canal de teste (libere com publicar-atualizacao.ps1 -Liberar
# e gere os zips depois): os instaladores novos nao levam codigo que ainda nao foi conferido.
param([switch]$Teste)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Pasta = $PSScriptRoot
$Arq = Join-Path (Split-Path $Pasta -Parent) 'instalador\arquivos'
$Base = 'C:\Jogos PC'   # pasta da sua propria instalacao (a escolhida no instalador)
$Pn = 'C:\Playnite'       # seu Playnite

if (Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue) { 'PLAYNITE ABERTO'; exit 2 }
if (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'jogos-pc-worker|baixar-worker' }) { 'DOWNLOAD EM ANDAMENTO'; exit 3 }
# Sem ele o plugin Recomps novo nao conhece as pastas dos seus Recomps, e o Desinstalar do RomM poderia apaga-los.
if (-not (Test-Path -LiteralPath (Join-Path $Base 'recomps-local.json'))) { "SEM $Base\recomps-local.json (ex.: { `"usar`": `"D:\\Recomps\\recomps.json`" })"; exit 4 }
'AVISO: nao use o Playnite durante a conferencia (no fim a tela cheia abre por 60 s e fecha sozinha).'

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$wpf = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\WPF"
foreach ($nome in 'JogosPc', 'Recomps') {
    $saida = & $csc /nologo /target:library /optimize+ /codepage:65001 "/out:$Arq\$nome.dll" "/reference:$Pn\Playnite.SDK.dll" "/reference:$wpf\PresentationFramework.dll" "/reference:$wpf\PresentationCore.dll" "/reference:$wpf\WindowsBase.dll" /reference:System.Xaml.dll "$Pasta\plugin\$nome.cs" 2>&1
    if ($LASTEXITCODE) { $saida | Select-Object -First 20; exit 1 }
    "compilou ${nome}: $((Get-Item "$Arq\$nome.dll").Length) bytes"
}

& pwsh -NoProfile -File "$Pasta\publicar-atualizacao.ps1" @(if ($Teste) { '-Teste' })
if ($LASTEXITCODE) { 'FALHA AO PUBLICAR'; exit 1 }
. "$Arq\atualizador.ps1"
"atualizou: $(Update-JogosRetro $Base) versao=$(Get-Content "$Base\programa\versao.txt" -TotalCount 1)"

$ext = Join-Path $Pn 'Extensions\JogosPc_c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3'
Copy-Item "$Base\programa\JogosPc.dll" "$ext\JogosPc.dll" -Force
$hash = (Get-FileHash "$Arq\JogosPc.dll").Hash
"plugin igual ao compilado: $((Get-FileHash "$ext\JogosPc.dll").Hash -eq $hash)"
$extR = Join-Path $Pn 'Extensions\Recomps_7d1f4c2a-9b3e-4a6d-8c5f-2e1a0b9d3f71'
New-Item $extR -ItemType Directory -Force | Out-Null
Copy-Item "$Base\programa\Recomps.dll" "$extR\Recomps.dll" -Force
Set-Content "$extR\extension.yaml" "Id: Recomps_7d1f4c2a-9b3e-4a6d-8c5f-2e1a0b9d3f71`r`nName: Recomps`r`nAuthor: JogosRetro`r`nVersion: 1.0`r`nModule: Recomps.dll`r`nType: GenericPlugin`r`n" -Encoding ASCII
[IO.File]::WriteAllText("$extR\instalacao.txt", $Base, (New-Object Text.UTF8Encoding $false))
$hashR = (Get-FileHash "$Arq\Recomps.dll").Hash
"plugin Recomps igual ao compilado: $((Get-FileHash "$extR\Recomps.dll").Hash -eq $hashR)"

if (-not $Teste) {
    & pwsh -NoProfile -File "$Pasta\gerar-zips.ps1" 2>&1 | ForEach-Object { "$_" }
    "zips exit: $LASTEXITCODE"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Get-ChildItem (Join-Path (Split-Path $Pasta -Parent) 'saida') -Filter 'Instalador-Jogos-*.zip' | Where-Object Name -in 'Instalador-Jogos-NetBird.zip', 'Instalador-Jogos-Tailscale.zip' | ForEach-Object {
        $z = [IO.Compression.ZipFile]::OpenRead($_.FullName)
        try {
            foreach ($par in @(@('JogosPc.dll', $hash), @('Recomps.dll', $hashR))) {
                $e = $z.Entries | Where-Object Name -eq $par[0] | Select-Object -First 1
                if (-not $e) { "$($_.Name): sem $($par[0])"; continue }
                $m = New-Object IO.MemoryStream; $s = $e.Open(); $s.CopyTo($m); $s.Dispose(); $m.Position = 0
                "$($_.Name): $($par[0]) novo = $((Get-FileHash -InputStream $m).Hash -eq $par[1])"
            }
        } finally { $z.Dispose() }
    }
}

$inicio = Get-Date
[IO.File]::Delete("$Pn\safestart.flag")
'CONFERENCIA: abrindo a tela cheia do Playnite por 60 s. Nao use o Playnite ate o fim (ele fecha sozinho).'
Start-Process "$Pn\Playnite.FullscreenApp.exe" -WorkingDirectory $Pn
Start-Sleep 60
# Antes de fechar: uma instalacao ou remocao que comecou nesse meio tempo (recomp.ps1, que espera o Setup do
# Recomp, ou os workers do Jogos de PC) termina primeiro, ate 2 h; fechar no meio deixaria o jogo pela metade.
$ocupado = { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' or Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'recomp\.ps1|jogos-pc-worker|baixar-worker' }).Count -gt 0 }
$limite = (Get-Date).AddHours(2)
if (& $ocupado) { 'instalacao ou remocao em andamento: esperando terminar para fechar o Playnite (ate 2 h)...' }
while ((& $ocupado) -and (Get-Date) -lt $limite) { Start-Sleep 30 }
if (& $ocupado) { 'AINDA EM ANDAMENTO DEPOIS DE 2 H: o Playnite fica aberto; feche voce quando terminar' }
else {
    Start-Process "$Pn\Playnite.FullscreenApp.exe" -ArgumentList '--shutdown' -WorkingDirectory $Pn
    Start-Sleep 12
    Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue | Stop-Process -Force
}
Get-Content "$Pn\playnite.log" -Tail 3000 | Where-Object { $_ -match 'Loaded plugin: (Jogos de PC|Selene Core|RomM|Recomps)' } | Select-Object -Last 4 | ForEach-Object { $_.Substring(0, [math]::Min(120, $_.Length)) }
'ERROS DESTA ABERTURA:'
foreach ($l in 'playnite.log', 'extensions.log') {
    Get-Content "$Pn\$l" -Tail 3000 | Where-Object { $_ -match '\|ERROR\|' -and $_ -notmatch 'AnikiHelper' -and ([datetime]::ParseExact(($_.Substring(0, 14)), 'dd-MM HH:mm:ss', $null) -ge $inicio.AddSeconds(-2)) } | Select-Object -Last 6 | ForEach-Object { $_.Substring(0, [math]::Min(210, $_.Length)) }
}
"versao publicada: $(Get-Content "$Pasta\versao-publicada.txt" -TotalCount 1)"
