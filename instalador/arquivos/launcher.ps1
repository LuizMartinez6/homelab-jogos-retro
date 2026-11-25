# Abre o Playnite apontando para o servidor de jogos pelo caminho que estiver
# disponivel: rede local primeiro, depois NetBird e por ultimo Tailscale.

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$L = Get-Content (Join-Path $Here 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$atualizou = $false
$erroAtualizacao = $null
try { . (Join-Path $Here 'programa\atualizador.ps1'); $atualizou = Update-JogosRetro $Here } catch { $erroAtualizacao = $_ }

# Falhas vao para a aba Erros do painel do dono (relato.ps1); avisar nunca derruba o launcher.
try { . (Join-Path $Here 'programa\relato.ps1') } catch { }
function Send-Falha($etapa, $erro) { try { [void](Send-Erro $Here $etapa $erro) } catch { } }
if ($erroAtualizacao) { Send-Falha 'atualizacao' $erroAtualizacao }

function Out-Utf8 {
    # Grava texto em UTF-8 sem BOM (o Windows PowerShell 5.1 poe BOM com -Encoding UTF8, e o Playnite nao aceita).
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [Parameter(Position = 0)][string]$Path)
    begin { $sb = New-Object System.Text.StringBuilder }
    process { [void]$sb.AppendLine([string]$InputObject) }
    end { [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false)) }
}

function Test-Porta($url, $ms) {
    if (-not $url) { return $false }
    $u = [Uri]$url
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($u.Host, $u.Port).Wait($ms); $c.Close(); return $ok } catch { return $false }
}

# Quem usa o Tailscale nao tem NetBird: tira o endereco que a versao 21 acrescentou,
# para nao perder tempo tentando um caminho que este PC nao tem.
if ($L.netbird -and $L.tailscale -and -not (Test-Path (Join-Path $env:ProgramFiles 'Netbird\netbird.exe'))) {
    $L.PSObject.Properties.Remove('netbird')
    if ($L.jogos) { $L.jogos.PSObject.Properties.Remove('netbird') }
    try { $L | ConvertTo-Json -Depth 5 | Out-Utf8 (Join-Path $Here 'launcher.json') } catch { }
}

function Get-Plataformas($url, $cfg) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cfg.RomMUsername):$($cfg.RomMPassword)"))
    try { return @(Invoke-RestMethod -Uri ($url.TrimEnd('/') + '/api/platforms') -Headers @{ Authorization = "Basic $b64" } -UseBasicParsing -TimeoutSec 8) } catch { return $null }
}

$running = Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue
if (-not $running -and (Test-Path $L.rommConfig)) {
    $raw = Get-Content $L.rommConfig -Raw -Encoding UTF8
    $cfg = $raw | ConvertFrom-Json
    # Sem nenhum caminho agora, fica o ultimo que funcionou.
    $target = if (Test-Porta $L.lan 1200) { $L.lan } elseif (Test-Porta $L.netbird 3000) { $L.netbird } elseif (Test-Porta $L.tailscale 3000) { $L.tailscale } else { $cfg.RomMHost }
    $mudou = $false
    if ($cfg.RomMHost -ne $target) { $cfg.RomMHost = $target; $mudou = $true }

    # Liga ao RoMM os consoles que ficaram sem plataforma na instalacao
    # (sem conexao ainda, ou plataforma criada depois no servidor).
    $tem = @($cfg.Mappings | ForEach-Object { $_.RomMPlatform.fs_slug })
    $faltam = @($L.mapas | Where-Object { $_.slug -notin $tem })
    if ($faltam.Count -gt 0) {
        $plats = Get-Plataformas $target $cfg
        if ($plats) {
            $keep = 'id', 'slug', 'fs_slug', 'name', 'display_name', 'rom_count', 'igdb_id', 'sgdb_id', 'moby_id', 'logo_path', 'firmware', 'created_at', 'updated_at'
            $plats = @($plats | ForEach-Object { $_ | Select-Object $keep })
            $novos = @($cfg.Mappings | Where-Object { $_ })
            foreach ($m in $faltam) {
                $plat = $plats | Where-Object { $_.fs_slug -eq $m.slug } | Select-Object -First 1
                if (-not $plat) { continue }
                $novos += [pscustomobject][ordered]@{ MappingId = [guid]::NewGuid().ToString(); Enabled = $true; AutoExtract = $false; EmulatorId = $m.emuladorId; EmulatorProfileId = $m.perfilId
                    RomMPlatformId = $plat.id; RomMPlatform = $plat; MappingName = "$($plat.name) -> $($m.perfil)"; DestinationPath = $m.destino; InstallFlat = $false }
            }
            $cfg.Mappings = $novos; $cfg.RomMPlatforms = $plats; $mudou = $true
        }
    }
    if ($mudou) { $cfg | ConvertTo-Json -Depth 10 | Out-Utf8 $L.rommConfig }
}

# Plugin que coloca os jogos de PC na biblioteca do Playnite.
$modulo = Join-Path $Here 'programa\JogosPc.dll'
if (-not $running -and (Test-Path $modulo)) {
    $antiga = Join-Path $L.playnite 'Extensions\JogosRetroJogosPC'
    if (Test-Path $antiga) { Remove-Item $antiga -Recurse -Force }
    $ext = Join-Path $L.playnite 'Extensions\JogosPc_c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3'
    New-Item $ext -ItemType Directory -Force | Out-Null
    Copy-Item $modulo (Join-Path $ext 'JogosPc.dll') -Force
    Set-Content (Join-Path $ext 'extension.yaml') "Id: JogosPc_c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3`r`nName: Jogos de PC`r`nAuthor: JogosRetro`r`nVersion: 1.0`r`nModule: JogosPc.dll`r`nType: GameLibrary`r`n" -Encoding ASCII
    $Here | Out-Utf8 (Join-Path $ext 'instalacao.txt')

    # Deixa so o "Baixar para o emulador" nos jogos do RomM. Outra versao do plugin fica como esta.
    $romm = Join-Path $L.playnite 'Extensions\RomM_9700aa21-447d-41b4-a989-acd38f407d9f\RomM.dll'
    $semInstalador = Join-Path $Here 'programa\RomMSemInstalador.dll'
    if ((Test-Path $romm) -and (Test-Path $semInstalador) -and (Get-FileHash $romm -Algorithm SHA256).Hash -eq '5D7ECCE8E5CBC962074F62AAAE21B64F52CB5DCB713A34E21EC2CAC247342ACE') {
        Copy-Item $romm "$romm.original" -Force
        Copy-Item $semInstalador $romm -Force
    }
}

# Plugin dos Recomps (versao nativa para PC de alguns jogos do RomM): le programa\recomps.json.
$modulo = Join-Path $Here 'programa\Recomps.dll'
if (-not $running -and (Test-Path $modulo)) {
    $ext = Join-Path $L.playnite 'Extensions\Recomps_7d1f4c2a-9b3e-4a6d-8c5f-2e1a0b9d3f71'
    New-Item $ext -ItemType Directory -Force | Out-Null
    Copy-Item $modulo (Join-Path $ext 'Recomps.dll') -Force
    Set-Content (Join-Path $ext 'extension.yaml') "Id: Recomps_7d1f4c2a-9b3e-4a6d-8c5f-2e1a0b9d3f71`r`nName: Recomps`r`nAuthor: JogosRetro`r`nVersion: 1.0`r`nModule: Recomps.dll`r`nType: GenericPlugin`r`n" -Encoding ASCII
    $Here | Out-Utf8 (Join-Path $ext 'instalacao.txt')
}

# Multiplayer online pelos servidores do homelab (PSP, Switch, 3DS, PS3 e RetroArch).
try { . (Join-Path $Here 'programa\multiplayer.ps1'); [void](Set-Multiplayer $Here $L) } catch { Send-Falha 'multiplayer' $_ }
# Pokemon de GBA no gpSP (link pelo netplay); mexe no banco do Playnite, entao so com ele fechado.
if (-not $running) { try { [void](Set-PokemonGpsp $Here $L) } catch { Send-Falha 'gpsp' $_ } }
# Ajustes de emulador por jogo (correcoes.json, dentro do pacote assinado).
try { . (Join-Path $Here 'programa\correcoes.ps1'); [void](Invoke-Correcoes $Here) } catch { Send-Falha 'correcoes' $_ }

$exe = if ($L.fullscreen) { 'Playnite.FullscreenApp.exe' } else { 'Playnite.DesktopApp.exe' }
# Avisa o ao-abrir.ps1 (que o plugin roda quando o Playnite abre) que o launcher ja cuidou de tudo.
try { [IO.File]::WriteAllText((Join-Path $Here 'launcher-abriu.txt'), (Get-Date).ToString('s')) } catch { }
Start-Process (Join-Path $L.playnite $exe) -WorkingDirectory $L.playnite

if ($atualizou) {
    # Aviso discreto; a janela invisivel do launcher precisa ficar aberta enquanto ele aparece.
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $aviso = New-Object Windows.Forms.NotifyIcon
    $aviso.Icon = [Drawing.SystemIcons]::Information; $aviso.Visible = $true
    $aviso.ShowBalloonTip(5000, 'Jogos Retro', 'Atualizado', [Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep 6
    $aviso.Dispose()
}
