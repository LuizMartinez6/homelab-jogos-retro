#Requires -Version 5.1
# Instalador de Jogos Retro: emuladores + Playnite ligado ao RoMM do Neto.
# Roda no Windows PowerShell 5.1 (padrao do Windows 10/11).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression.FileSystem

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg = Get-Content (Join-Path $Here 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Out-Utf8 {
    # Grava texto em UTF-8 sem BOM (o Windows PowerShell 5.1 poe BOM com -Encoding UTF8, e o Playnite nao aceita).
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [Parameter(Position = 0)][string]$Path)
    begin { $sb = New-Object System.Text.StringBuilder }
    process { [void]$sb.AppendLine([string]$InputObject) }
    end { [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false)) }
}

function Say($msg, $color = 'White') { Write-Host ''; Write-Host ">> $msg" -ForegroundColor $color }
function Info($msg) { Write-Host "   $msg" -ForegroundColor Gray }
function Fail($msg) {
    # A interface (instalador-ui.ps1) le esta linha e mostra o erro na tela.
    Write-Host ''; Write-Host "ERRO: $msg" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Catalogo: consoles, emuladores e downloads (sites oficiais; hash quando o
# projeto publica um).
# ---------------------------------------------------------------------------
. (Join-Path $Here 'catalogo.ps1')
. (Join-Path $Here 'conquistas.ps1')
. (Join-Path $Here 'convite.ps1')

# Perfil do Playnite usado por plataforma do RoMM (fs_slug -> emulador/perfil).
$PerfilPorSlug = @{
    psp = @('ppsspp', '64bit'); nds = @('retroarch', 'melonDS DS'); gb = @('retroarch', 'Gambatte'); gba = @('retroarch', 'mGBA')
    psx = @('retroarch', 'PCSX-ReARMed'); ps2 = @('pcsx2', 'Default QT'); ngc = @('dolphin', 'Nintendo GameCube')
    wii = @('dolphin', 'Nintendo Wii'); switch = @('eden', 'Default'); ps3 = @('rpcs3', 'Default QT6')
    snes = @('retroarch', 'Snes9x'); n64 = @('retroarch', 'Mupen64Plus-Next'); genesis = @('retroarch', 'Genesis Plus GX'); sms = @('retroarch', 'Genesis Plus GX')
    gamegear = @('retroarch', 'Genesis Plus GX'); segacd = @('retroarch', 'Genesis Plus GX'); saturn = @('retroarch', 'Beetle Saturn'); dc = @('retroarch', 'Flycast')
    '3ds' = @('azahar', 'Default')
}

$Downloads = @{
    '7zr'       = @{ Url = 'https://www.7-zip.org/a/7zr.exe' }
    playnite    = @{ Url = 'https://github.com/JosefNemec/Playnite/releases/download/10.63/10.63.7z'; Sha = '9af9a0db330c97879697beac9f819c16f9f544e712261a83fa4e62a8f9a2c787' }
    rommplugin  = @{ Url = 'https://github.com/rommapp/playnite-plugin/releases/download/0.9.0/RomM_9700aa21-447d-41b4-a989-acd38f407d9f_0_9_0.pext'; Sha = '77a427a6ca4c15611363794472d1d52ddc0d6cb713adb0464af32604077e7c64' }
    tema        = @{ Url = 'https://github.com/mattxslv/Selene/releases/download/v1.5.6/Selene.pthm'; Sha = '3fd46e5eed1cf3ab966daaaec44425af7a649f7bfcbd59c201fcaf449e0f7908' }
    # Extensao exigida pelo tema (sem ela o Playnite abre numa tela pedindo para instalar).
    temahelper  = @{ Url = 'https://github.com/mattxslv/Selene/releases/download/v1.5.6/SeleneCore.pext'; Sha = 'c130918a0e73da1f0c4dac3cdec9b285331a7a5a0fdbdc9f46d4b6ade9621fa6' }
    # Musica por jogo no modo tela cheia.
    musica      = @{ Url = 'https://github.com/aHuddini/UniPlaySong/releases/download/1.9.0/UniPlaySong-1_9_0.pext'; Sha = '6669a38477af090a004520bec7bfd00bf8b9270b02f0d920e283805335524897' }
    # Integracoes oficiais: trazem para o Playnite os jogos que a pessoa ja tem no PC.
    SteamLibrary_Builtin     = @{ Url = 'https://github.com/JosefNemec/PlayniteExtensions/releases/download/2.2/SteamLibrary_Builtin_2_44.pext'; Sha = 'b95b745f4da624462dbf1fbde358bb35bb8350dfda22580cc727e62452048c1f' }
    EpicGamesLibrary_Builtin = @{ Url = 'https://github.com/JosefNemec/PlayniteExtensions/releases/download/2.2/EpicGamesLibrary_Builtin_2_30.pext'; Sha = '05e4a3cf7af3d7582116445680f0e2848997f894e5ec9a1e5588ca979215956a' }
    GogLibrary_Builtin       = @{ Url = 'https://github.com/JosefNemec/PlayniteExtensions/releases/download/2.2/GogLibrary_Builtin_2_23.pext'; Sha = '712e0d1cca698200bb9cdf10165b4cd1f745ed5297e5ae77418fdc1bacabb05a' }
    XboxLibrary_Builtin      = @{ Url = 'https://github.com/JosefNemec/PlayniteExtensions/releases/download/2.2/XboxLibrary_Builtin_2_17.pext'; Sha = '2dd701d6bf478363704f75c42b61603635efa37b7041ed29b1e083c2c34670e8' }
    IGDBMetadata_Builtin     = @{ Url = 'https://github.com/JosefNemec/PlayniteExtensions/releases/download/2.2/IGDBMetadata_Builtin_2_13.pext'; Sha = '29c29469b845118a7589127d40f1a6dbcbc17f31e4d8ca9e493fb03a3ab471ff' }
    ppsspp      = @{ Url = 'https://github.com/hrydgard/ppsspp/releases/download/v1.20.4/PPSSPP-v1.20.4-Windows-x64.zip'; Sha = 'fbc9cd2f5131b159a92424e5c458c35ce43ba603cdded64dfc98e4bd4f17ff93' }
    retroarch   = @{ Url = 'https://buildbot.libretro.com/stable/1.22.2/windows/x86_64/RetroArch.7z' }
    pcsx2       = @{ Url = 'https://github.com/PCSX2/pcsx2/releases/download/v2.8.2/pcsx2-v2.8.2-windows-x64-Qt.7z'; Sha = '7dfc829ca1994cc1045ac49f05e39b6cf968b72e6a374c40e05c2a2b4ac200b4' }
    dolphin     = @{ Url = 'https://dl.dolphin-emu.org/releases/2609/dolphin-2609-x64.7z' }
    eden        = @{ Url = 'https://stable.eden-emu.dev/v0.2.1/Eden-Windows-v0.2.1-amd64-clang-pgo.zip' }
    rpcs3       = @{ Url = 'https://github.com/RPCS3/rpcs3-binaries-win/releases/download/build-13a3cd4266158911a8c555dda59005bc20fd2a66/rpcs3-v0.0.43-20570-13a3cd42_win64_msvc.7z'; Sha = '7149d494756f083917dae78bbfd4b94b246a67154419dbd366e5abf159f09d74' }
    azahar      = @{ Url = 'https://github.com/azahar-emu/azahar/releases/download/2126.2/azahar-windows-msvc-2126.2.zip' }
    netbird     = @{ Url = 'https://github.com/netbirdio/netbird/releases/download/v0.82.0/netbird_installer_0.82.0_windows_amd64.msi'; Sha = '8155544c557676069c49d43ccf2c62a5ccb2fefec9d92ec58fa6920db8bc43e9' }
    tailscale   = @{ Url = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' }
    vcredist    = @{ Url = 'https://aka.ms/vs/17/release/vc_redist.x64.exe' }
}
$CoreUrl = 'https://buildbot.libretro.com/nightly/windows/x86_64/latest/{0}_libretro.dll.zip'
# Lista oficial da Sony com o endereco do firmware mais recente do PS3.
$Ps3FirmwareList = 'http://fus01.ps3.update.playstation.net/update/ps3/list/us/ps3-updatelist.txt'
$RommPluginGuid = '9700aa21-447d-41b4-a989-acd38f407d9f'
$TemaId = 'Selene_a98e0027-fa6a-4f5e-a087-bad8d69f2443'
$TemaHelperId = 'SeleneCore_cd424c29-97f4-4dd0-aa66-4d8e01cc8724'
$MusicaId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
$ExtensoesLojas = 'SteamLibrary_Builtin', 'EpicGamesLibrary_Builtin', 'GogLibrary_Builtin', 'XboxLibrary_Builtin', 'IGDBMetadata_Builtin'

# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------
function Get-File($key, $name) {
    $d = $Downloads[$key]; $out = Join-Path $Dl $name
    if (Test-Path $out) { Remove-Item $out -Force }
    Info "Baixando $name ..."
    for ($try = 1; $try -le 3; $try++) {
        try { Invoke-WebRequest -Uri $d.Url -OutFile $out -UseBasicParsing; break }
        catch { if ($try -eq 3) { Fail "Nao consegui baixar $name.`n$($_.Exception.Message)" }; Start-Sleep 3 }
    }
    if ($d.Sha) {
        $fs = [IO.File]::OpenRead($out); try { $h = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Close() }
        if ($h -ne $d.Sha) { Fail "O arquivo $name veio diferente do oficial (hash nao confere). Tente de novo mais tarde." }
        Info 'conferido (hash oficial OK)'
    }
    $out
}

function Expand-Any($archive, $dest) {
    $tmp = Join-Path $Dl ('_x_' + [IO.Path]::GetFileNameWithoutExtension($archive))
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory $tmp | Out-Null
    if ($archive -like '*.7z') { & $SevenZip x $archive "-o$tmp" -y | Out-Null; if ($LASTEXITCODE -ne 0) { Fail "Falha ao extrair $archive" } }
    else { [IO.Compression.ZipFile]::ExtractToDirectory($archive, $tmp) }
    $items = @(Get-ChildItem $tmp -Force)
    $src = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $tmp }
    New-Item -ItemType Directory $dest -Force | Out-Null
    # Copia mesclando, para funcionar tambem ao rodar o instalador de novo na mesma pasta.
    Copy-Item (Join-Path $src '*') -Destination $dest -Recurse -Force
    Remove-Item $tmp -Recurse -Force
}

function Expand-Zip($zip, $dest) {
    # Extrai sobrescrevendo (o ExtractToDirectory do .NET falha se o arquivo ja existe).
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($e in $z.Entries) {
            $out = Join-Path $dest $e.FullName
            if ($e.FullName -match '[\\/]$') { New-Item $out -ItemType Directory -Force | Out-Null; continue }
            New-Item (Split-Path $out -Parent) -ItemType Directory -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
        }
    } finally { $z.Dispose() }
}

function Test-Lan {
    $u = [Uri]$Cfg.servidor.lan
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($u.Host, $u.Port).Wait(1500); $c.Close(); return $ok } catch { return $false }
}
function Test-Url($url) {
    try { $r = Invoke-WebRequest -Uri ($url.TrimEnd('/') + '/api/heartbeat') -UseBasicParsing -TimeoutSec 8; return ($r.StatusCode -eq 200) } catch { return $false }
}
function Get-RommHost {
    if (Test-Lan) { return $Cfg.servidor.lan }
    if ($Cfg.servidor.netbird -and (Test-Url $Cfg.servidor.netbird)) { return $Cfg.servidor.netbird }
    if ($Cfg.servidor.tailscale -and (Test-Url $Cfg.servidor.tailscale)) { return $Cfg.servidor.tailscale }
    return $null
}

function Connect-Tailscale {
    # Instala o Tailscale (se preciso) e da um tempo para a pessoa entrar; se nao entrar,
    # a instalacao segue e a biblioteca se liga depois, pelo atalho.
    $tsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale-ipn.exe'
    if (-not (Test-Path $tsExe)) {
        Info 'Instalando o Tailscale (rede segura para acessar os jogos de qualquer lugar)...'
        $msi = Get-File 'tailscale' 'tailscale.msi'
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /passive /norestart" -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { Fail "A instalacao do Tailscale falhou (codigo $($p.ExitCode))." }
    } else { Info 'Tailscale ja instalado.' }
    Start-Process $tsExe
    $h = $null
    for ($i = 0; $i -lt 18 -and -not $h; $i++) {
        Info 'Aguardando voce entrar no Tailscale (icone perto do relogio > Log in)...'
        Start-Sleep 5
        $h = Get-RommHost
    }
    $h
}

function Connect-NetBird($Chave, $Nome) {
    # Instala o NetBird (se preciso) e entra na rede do Neto com a chave do convite.
    $nb = Join-Path $env:ProgramFiles 'Netbird\netbird.exe'
    if (-not (Test-Path $nb)) {
        Info 'Instalando o NetBird (rede segura para acessar os jogos de qualquer lugar)...'
        Info 'Se o Windows perguntar se pode fazer alteracoes, clique em Sim.'
        $msi = Get-File 'netbird' 'netbird.msi'
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /passive /norestart" -Wait -PassThru
        if ($p.ExitCode -eq 1602) { Fail 'A instalacao do NetBird foi cancelada. Abra o instalador de novo e clique em Sim quando o Windows perguntar.' }
        if ($p.ExitCode -notin 0, 3010) { Fail "A instalacao do NetBird falhou (codigo $($p.ExitCode))." }
    } else { Info 'NetBird ja instalado.' }
    # O servico demora uns segundos para responder depois de instalado.
    $st = ''
    for ($i = 0; $i -lt 15; $i++) { $st = (& $nb status 2>&1 | Out-String); if ($st -match 'Daemon status|Management:') { break }; Start-Sleep 2 }
    if ($st -match 'Management: Connected') { Info 'NetBird ja conectado.'; return }
    if (-not $Chave) { Fail "O NetBird deste PC nao esta conectado e o convite nao tem a chave. Peca um convite novo ao $($Cfg.dono)." }
    Info 'Entrando na rede do servidor...'
    $apelido = (($Nome + '-' + $env:COMPUTERNAME) -replace '[^A-Za-z0-9-]', '-').ToLower()
    $saida = (& $nb up --setup-key $Chave --hostname $apelido 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        if ($saida -match 'setup key|invalid|expired|revoked|exhausted') { Fail "O convite ja foi usado ou venceu. Peca um convite novo ao $($Cfg.dono)." }
        Fail "Nao consegui conectar o NetBird.`n$($saida.Trim())"
    }
}

# ---------------------------------------------------------------------------
# Instalacao
# ---------------------------------------------------------------------------
Clear-Host
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '        INSTALADOR DE JOGOS RETRO' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'Este instalador precisa de Windows 64 bits.' }

# Opcoes escolhidas na interface (instalador-ui.ps1), em JSON na variavel de ambiente.
if (-not $env:JOGOSRETRO_OPCOES) { Fail 'Abra o instalador pelo arquivo Instalar.bat.' }
$Opt = $env:JOGOSRETRO_OPCOES | ConvertFrom-Json
$Base = $Opt.Base; $Emu = Join-Path $Base 'Emuladores'; $Dl = Join-Path $Base '_downloads'; $PlayniteDir = Join-Path $Base 'Playnite'
New-Item -ItemType Directory $Base, $Emu, $Dl -Force | Out-Null
$drive = (Get-Item $Base).PSDrive; if ($drive.Free -lt 5GB) { Fail "Pouco espaco livre em $($drive.Name): (precisa de pelo menos 5 GB, mais o espaco dos jogos)." }
$emus = @($Opt.Consoles | ForEach-Object { $Consoles[$_].Emu } | Select-Object -Unique)
$cores = @($Opt.Consoles | ForEach-Object { $Consoles[$_].Cores } | Where-Object { $_ } | Select-Object -Unique)
Say "Consoles escolhidos: $(($Opt.Consoles | ForEach-Object { $Consoles[$_].Nome }) -join ', ')" Cyan

# 1) Conexao com o servidor: rede local, ou o caminho desta edicao do instalador
# (NetBird para os amigos novos, Tailscale para os que ja estavam nele).
Say 'Passo 1/6 - Conexao com a biblioteca de jogos'
# Login do servidor de jogos: vem do convite (zips antigos traziam no config.json).
$Jogos = [ordered]@{ lan = $Cfg.jogos.lan; netbird = $Cfg.jogos.netbird; tailscale = $Cfg.jogos.tailscale; usuario = $Cfg.jogos.usuario; senha = $Cfg.jogos.senha }
if ($Opt.Convite) { $Jogos.usuario = $Opt.Convite.u; $Jogos.senha = $Opt.Convite.s }
if (-not $Jogos.usuario) { Fail "Falta o codigo de convite. Peca um ao $($Cfg.dono)." }
$RommHost = Get-RommHost
if (-not $RommHost -and $Cfg.servidor.netbird) {
    Connect-NetBird $Opt.Convite.k $Jogos.usuario
    for ($i = 0; $i -lt 20 -and -not $RommHost; $i++) {
        Info 'Aguardando a conexao com o servidor...'
        Start-Sleep 3
        $RommHost = Get-RommHost
    }
    if (-not $RommHost) { Fail "O NetBird conectou, mas o servidor nao respondeu. Ele pode estar desligado; tente de novo mais tarde ou chame o $($Cfg.dono)." }
} elseif (-not $RommHost) {
    $RommHost = Connect-Tailscale
}
if ($RommHost) { Info "Conectado: $RommHost" } else { Info 'Sem conexao agora; a biblioteca aparece sozinha depois que voce entrar no Tailscale.' }
foreach ($u in @($Jogos.lan, $Jogos.netbird, $Jogos.tailscale) | Where-Object { $_ }) {
    $login = Test-LoginJogos $u $Jogos.usuario $Jogos.senha
    if ($login -eq $false) { Fail "O codigo de convite nao confere. Peca um novo ao $($Cfg.dono)." }
    if ($login) { break }
}

# 2) Downloads
Say 'Passo 2/6 - Baixando os programas (pode demorar alguns minutos)'
$SevenZip = Get-File '7zr' '7zr.exe'
$arq = @{ playnite = Get-File 'playnite' 'playnite.7z'; rommplugin = Get-File 'rommplugin' 'romm.pext' }
if ($Opt.Tema) {
    $arq.tema = Get-File 'tema' 'tema.pthm'; $arq.temahelper = Get-File 'temahelper' 'temahelper.pext'; $arq.musica = Get-File 'musica' 'musica.pext'
}
foreach ($l in $ExtensoesLojas) { $arq[$l] = Get-File $l "$l.pext" }
foreach ($e in $emus) { $ext = if ($Downloads[$e].Url -like '*.7z') { '7z' } else { 'zip' }; $arq[$e] = Get-File $e "$e.$ext" }
foreach ($c in $cores) { $Downloads["core_$c"] = @{ Url = ($CoreUrl -f $c) }; $arq["core_$c"] = Get-File "core_$c" "$c.zip" }
if ('rpcs3' -in $emus) {
    try { $lista = (Invoke-WebRequest -Uri $Ps3FirmwareList -UseBasicParsing).Content } catch { Fail "Nao consegui ver a versao do firmware do PS3.`n$($_.Exception.Message)" }
    $fw = [regex]::Match($lista, 'CDN=(http[^;]*PS3UPDAT\.PUP)').Groups[1].Value
    if (-not $fw) { Fail 'Nao achei o firmware do PS3 na lista da Sony.' }
    $Downloads.ps3fw = @{ Url = $fw }; $arq.ps3fw = Get-File 'ps3fw' 'PS3UPDAT.PUP'
}
if ($emus | Where-Object { $_ -in 'pcsx2', 'dolphin', 'eden', 'rpcs3', 'azahar' }) { $arq.vcredist = Get-File 'vcredist' 'vc_redist.x64.exe' }

# 3) Emuladores
Say 'Passo 3/6 - Instalando os emuladores'
$dirs = @{ ppsspp = 'PPSSPP'; retroarch = 'RetroArch'; pcsx2 = 'PCSX2'; dolphin = 'Dolphin'; eden = 'Eden'; rpcs3 = 'RPCS3'; azahar = 'Azahar' }
foreach ($e in $emus) {
    $d = Join-Path $Emu $dirs[$e]; Info $dirs[$e]
    Expand-Any $arq[$e] $d
    switch ($e) {
        # Com a pasta "user" ao lado do programa, o Azahar guarda tudo ali dentro.
        'azahar' { New-Item (Join-Path $d 'user') -ItemType Directory -Force | Out-Null }
        'pcsx2' {
            New-Item (Join-Path $d 'portable.ini') -ItemType File -Force | Out-Null
            New-Item (Join-Path $d 'bios') -ItemType Directory -Force | Out-Null
            if ($Opt.Bios -and (Test-Path $Opt.Bios)) {
                Copy-Item $Opt.Bios (Join-Path $d 'bios') -Force
                New-Item (Join-Path $d 'inis') -ItemType Directory -Force | Out-Null
                Set-Content (Join-Path $d 'inis\PCSX2.ini') "[UI]`r`nSetupWizardIncomplete = false`r`n[Filenames]`r`nBIOS = $(Split-Path $Opt.Bios -Leaf)`r`n" -Encoding ASCII
            }
        }
        'dolphin' {
            New-Item (Join-Path $d 'portable.txt') -ItemType File -Force | Out-Null
            New-Item (Join-Path $d 'User\Config') -ItemType Directory -Force | Out-Null
            Set-Content (Join-Path $d 'User\Config\Dolphin.ini') "[Analytics]`r`nPermissionAsked = True`r`nEnabled = False`r`n" -Encoding ASCII
        }
        'eden' {
            $u = Join-Path $d 'user'; New-Item (Join-Path $u 'keys') -ItemType Directory -Force | Out-Null
            if ($Opt.Keys -and (Test-Path $Opt.Keys)) { Copy-Item $Opt.Keys (Join-Path $u 'keys\prod.keys') -Force }
            if ($Opt.Firm -and (Test-Path $Opt.Firm)) {
                $reg = Join-Path $u 'nand\system\Contents\registered'; New-Item $reg -ItemType Directory -Force | Out-Null
                $tmp = Join-Path $Dl '_firm'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
                [IO.Compression.ZipFile]::ExtractToDirectory($Opt.Firm, $tmp)
                Get-ChildItem $tmp -Recurse -Filter *.nca | ForEach-Object { Copy-Item $_.FullName $reg -Force }
                Info "firmware: $((Get-ChildItem $reg).Count) arquivos"
                Remove-Item $tmp -Recurse -Force
            }
        }
        'retroarch' {
            $cd = Join-Path $d 'cores'; New-Item $cd -ItemType Directory -Force | Out-Null
            foreach ($c in $cores) { Expand-Zip $arq["core_$c"] $cd }
            # Ajusta so estas opcoes: rodar de novo preserva o resto (inclusive o login das conquistas).
            $arqRetroarch = Join-Path $d 'retroarch.cfg'
            foreach ($o in @(@('sort_savefiles_enable', 'true'), @('sort_savestates_enable', 'true'), @('input_joypad_driver', 'sdl2'), @('menu_driver', 'ozone'), @('config_save_on_exit', 'true'))) {
                Set-CfgValue $arqRetroarch $o[0] $o[1]
            }
        }
    }
}
$RaAviso = $null
if ($Opt.RaUser -and $Opt.RaPass) {
    # Um login so para todos os emuladores; falha aqui nunca derruba a instalacao.
    try {
        $login = Get-RaToken $Opt.RaUser $Opt.RaPass
        $con = Set-RaLogin $Emu $login.Usuario $login.Token
        Info "Conquistas conectadas como $($login.Usuario): $($con -join ', ')"
    } catch { $RaAviso = "- Conquistas: o login falhou ($($_.Exception.Message)). Use 'Conectar Conquistas' depois." }
}
if ($arq.vcredist) {
    Info 'Componentes do Windows (Visual C++)...'
    Start-Process $arq.vcredist -ArgumentList '/install /passive /norestart' -Wait | Out-Null
}
if ('rpcs3' -in $emus) {
    # Instala o firmware depois do Visual C++, que o RPCS3 precisa para abrir.
    Info 'Firmware do PS3 (leva 1-2 minutos)...'
    $d = Join-Path $Emu 'RPCS3'
    $p = Start-Process (Join-Path $d 'rpcs3.exe') -ArgumentList '--headless', '--installfw', "`"$($arq.ps3fw)`"" -WorkingDirectory $d -PassThru
    if (-not $p.WaitForExit(600000)) { $p.Kill() }
    if (-not (Test-Path (Join-Path $d 'dev_flash\vsh\etc\version.txt'))) { Fail 'O firmware do PS3 nao foi instalado.' }
    New-Item (Join-Path $d 'dev_hdd0\home\00000001\savedata') -ItemType Directory -Force | Out-Null
    # Sem a janela "Welcome to RPCS3" na frente do primeiro jogo. Em alguns PCs o
    # RPCS3 ainda nao criou este arquivo; e so conforto, entao nunca derruba a instalacao.
    try {
        $guiDir = Join-Path $d 'GuiConfigs'; New-Item $guiDir -ItemType Directory -Force | Out-Null
        $gui = Join-Path $guiDir 'CurrentSettings.ini'
        if (-not ((Test-Path $gui) -and (Select-String -Path $gui -Pattern 'infoBoxEnabledWelcome' -Quiet))) {
            Add-Content $gui "`r`n[main_window]`r`ninfoBoxEnabledWelcome=false`r`n" -Encoding ASCII
        }
    } catch { Info 'Aviso: nao consegui desligar a tela de boas-vindas do RPCS3 (nao atrapalha).' }
}

# 4) Playnite
Say 'Passo 4/6 - Instalando a biblioteca (Playnite)'
Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue | ForEach-Object {
    [Windows.Forms.MessageBox]::Show('O Playnite esta aberto. Feche-o (clique com o botao direito no icone perto do relogio > Sair) e clique OK.', 'Playnite') | Out-Null
}
Expand-Any $arq.playnite $PlayniteDir
$ext = Join-Path $PlayniteDir "Extensions\RomM_$RommPluginGuid"; Expand-Zip $arq.rommplugin $ext
if ($arq.tema) {
    Expand-Zip $arq.tema (Join-Path $PlayniteDir "Themes\Fullscreen\$TemaId")
    Expand-Zip $arq.temahelper (Join-Path $PlayniteDir "Extensions\$TemaHelperId")
    Expand-Zip $arq.musica (Join-Path $PlayniteDir "Extensions\UniPlaySong.$MusicaId")
}
foreach ($l in $ExtensoesLojas) { Expand-Zip $arq[$l] (Join-Path $PlayniteDir "Extensions\$l") }
[ordered]@{ Version = 7; DatabasePath = '{PlayniteDir}\library'; FirstTimeWizardComplete = $true; InstallInstanceId = [guid]::NewGuid().ToString(); Language = 'pt_BR'; CloseToTray = $false; EnableTray = $false; StartInFullscreen = $false; AfterGameClose = 2 } |
    ConvertTo-Json | Out-Utf8 (Join-Path $PlayniteDir 'config.json')
if ($arq.tema) { @{ Theme = $TemaId } | ConvertTo-Json | Out-Utf8 (Join-Path $PlayniteDir 'fullscreenConfig.json') }

# 5) Cadastrar emuladores no Playnite (extensao temporaria) e ligar ao RoMM
Say 'Passo 5/6 - Configurando a biblioteca'
$want = [ordered]@{}
foreach ($k in $Opt.Consoles) { foreach ($s in $Consoles[$k].Slugs) { $p = $PerfilPorSlug[$s]; if (-not $want.Contains($p[0])) { $want[$p[0]] = @{ dir = (Join-Path $Emu $dirs[$p[0]]); profiles = @() } }; if ($p[1] -notin $want[$p[0]].profiles) { $want[$p[0]].profiles += $p[1] } } }
$helper = Join-Path $PlayniteDir 'Extensions\JogosRetroSetup'; New-Item $helper -ItemType Directory -Force | Out-Null
$want | ConvertTo-Json -Depth 5 | Out-Utf8 (Join-Path $helper 'wanted.json')
Set-Content (Join-Path $helper 'extension.yaml') "Id: JogosRetroSetup`r`nName: Setup (temporario)`r`nAuthor: JogosRetro`r`nVersion: 1.0`r`nModule: Setup.psm1`r`nType: Script`r`n" -Encoding ASCII
Copy-Item (Join-Path $Here 'playnite-helper.psm1') (Join-Path $helper 'Setup.psm1') -Force
$out = Join-Path $helper 'result.txt'
$pn = Join-Path $PlayniteDir 'Playnite.DesktopApp.exe'
Remove-Item (Join-Path $PlayniteDir 'safestart.flag') -Force -ErrorAction SilentlyContinue
Start-Process $pn -WorkingDirectory $PlayniteDir
$t = 0; while (-not (Test-Path $out) -and $t -lt 180) { Start-Sleep 2; $t += 2 }
Start-Process $pn -ArgumentList '--shutdown' -WorkingDirectory $PlayniteDir; Start-Sleep 6
Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue | Stop-Process -Force
if (-not (Test-Path $out)) { Fail 'O Playnite nao respondeu ao cadastrar os emuladores.' }
$res = Get-Content $out -Encoding UTF8
if ($res[0] -like 'ERRO*') { Fail ($res -join "`n") }
$ids = @{}; foreach ($l in $res) { $p = $l -split '\|'; if ($p[0] -eq 'EMU') { $ids["$($p[1])/$($p[4])"] = @($p[2], $p[3]) } }
Remove-Item $helper -Recurse -Force
if ($arq.musica) {
    $mcfgDir = Join-Path $PlayniteDir "ExtensionsData\$MusicaId"; New-Item $mcfgDir -ItemType Directory -Force | Out-Null
    # MusicState 2 = musica so na tela cheia.
    [ordered]@{ EnableMusic = $true; MusicState = 2; MusicVolume = 50; EnableDefaultMusic = $false; SuppressPlayniteBackgroundMusic = $true; MusicOnlyForInstalledGames = $true
        AutoDownloadOnLibraryUpdate = $false; AutoDownloadOnGameInstall = $false; AutoDeleteMusicOnGameRemoval = $true } |
        ConvertTo-Json | Out-Utf8 (Join-Path $mcfgDir 'config.json')
}
if ($arq.tema) {
    # Sem "taskcards", o Selene nao mostra o card de progresso dos downloads.
    $scfgDir = Join-Path $PlayniteDir 'ExtensionsData\cd424c29-97f4-4dd0-aa66-4d8e01cc8724'; New-Item $scfgDir -ItemType Directory -Force | Out-Null
    $scfgArq = Join-Path $scfgDir 'config.json'
    $scfg = if (Test-Path -LiteralPath $scfgArq) { Get-Content -LiteralPath $scfgArq -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object psobject }
    $scfg | Add-Member -NotePropertyName TurnedOn -NotePropertyValue @(@($scfg.TurnedOn | Where-Object { $_ }) + 'taskcards' | Select-Object -Unique) -Force
    $scfg | ConvertTo-Json -Depth 10 | Out-Utf8 $scfgArq
}
# O plugin Jogos de PC so esconde os repetidos da loja e reduz as imagens quando este arquivo existe.
Set-Content (Join-Path $Base 'instalacao-amigo.txt') 'ok' -Encoding ASCII
if ($Opt.Fullscreen) { $pc = Get-Content (Join-Path $PlayniteDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json; $pc.StartInFullscreen = $true; $pc | ConvertTo-Json -Depth 20 | Out-Utf8 (Join-Path $PlayniteDir 'config.json') }

$platforms = @()
if ($RommHost) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Cfg.romm.usuario):$($Cfg.romm.senha)"))
    try { $platforms = @(Invoke-RestMethod -Uri ($RommHost.TrimEnd('/') + '/api/platforms') -Headers @{ Authorization = "Basic $b64" } -UseBasicParsing) }
    catch { Info "Nao consegui ler as plataformas agora: $($_.Exception.Message)" }
}
$keep = 'id', 'slug', 'fs_slug', 'name', 'display_name', 'rom_count', 'igdb_id', 'sgdb_id', 'moby_id', 'logo_path', 'firmware', 'created_at', 'updated_at'
$platforms = @($platforms | ForEach-Object { $_ | Select-Object $keep })
$mappings = @()
# Receita de cada console escolhido: o atalho usa para ligar ao RoMM as
# plataformas que ainda nao existiam/nao estavam acessiveis na instalacao.
$mapas = @()
foreach ($k in $Opt.Consoles) {
    foreach ($s in $Consoles[$k].Slugs) {
        $p = $PerfilPorSlug[$s]; $id = $ids["$($p[0])/$($p[1])"]; $plat = $platforms | Where-Object { $_.fs_slug -eq $s } | Select-Object -First 1
        if (-not $id) { continue }
        $dest = Join-Path $Base "Jogos\$s"; New-Item $dest -ItemType Directory -Force | Out-Null
        $mapas += [ordered]@{ slug = $s; emuladorId = $id[0]; perfilId = $id[1]; perfil = $p[1]; destino = $dest }
        if (-not $plat) { continue }
        $mappings += [ordered]@{ MappingId = [guid]::NewGuid().ToString(); Enabled = $true; AutoExtract = $false; EmulatorId = $id[0]; EmulatorProfileId = $id[1]
            RomMPlatformId = $plat.id; RomMPlatform = $plat; MappingName = "$($plat.name) -> $($p[1])"; DestinationPath = $dest; InstallFlat = $false }
    }
}
$rcfgDir = Join-Path $PlayniteDir "ExtensionsData\$RommPluginGuid"; New-Item $rcfgDir -ItemType Directory -Force | Out-Null
[ordered]@{ RomMHost = $(if ($RommHost) { $RommHost } else { $Cfg.servidor.tailscale }); UseBasicAuth = $true; RomMUsername = $Cfg.romm.usuario; RomMPassword = $Cfg.romm.senha
    NotifyOnInstallComplete = $true; ScanGamesInFullScreen = $true; EnableSaveSync = $false; KeepRomMSynced = $false; Mappings = $mappings; RomMPlatforms = $platforms } |
    ConvertTo-Json -Depth 10 | Out-Utf8 (Join-Path $rcfgDir 'config.json')
Info "$($mappings.Count) plataformas ligadas ao RoMM"

# 6) Atalho inteligente (rede local x Tailscale) e limpeza
Say 'Passo 6/6 - Criando o atalho "Jogos Retro"'
Copy-Item (Join-Path $Here 'launcher.ps1') (Join-Path $Base 'launcher.ps1') -Force
# Copia atualizavel dos scripts; a versao 0 faz o launcher buscar a ultima publicada.
$programa = Join-Path $Base 'programa'
if (Test-Path $programa) { Remove-Item $programa -Recurse -Force }
New-Item $programa -ItemType Directory -Force | Out-Null
Get-ChildItem -LiteralPath $Here -File | Where-Object { $_.Name -ne 'config.json' } | Copy-Item -Destination $programa
Set-Content (Join-Path $programa 'versao.txt') '0' -Encoding ASCII
[ordered]@{ lan = $Cfg.servidor.lan; netbird = $Cfg.servidor.netbird; tailscale = $Cfg.servidor.tailscale; fullscreen = [bool]$Opt.Fullscreen; rommConfig = (Join-Path $rcfgDir 'config.json'); playnite = $PlayniteDir; mapas = $mapas; jogos = $Jogos } |
    ConvertTo-Json -Depth 5 | Out-Utf8 (Join-Path $Base 'launcher.json')
$ws = New-Object -ComObject WScript.Shell
foreach ($lnkPath in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Jogos Retro.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Jogos Retro.lnk'))) {
    $l = $ws.CreateShortcut($lnkPath); $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Base 'launcher.ps1')`""
    $l.WorkingDirectory = $Base; $l.IconLocation = "$(Join-Path $PlayniteDir 'Playnite.FullscreenApp.exe'),0"; $l.WindowStyle = 7; $l.Save()
}
# Ferramentas no menu Iniciar (o instalador .exe nao deixa os .bat a mao).
foreach ($a in @(@('Baixar Jogo', 'baixar-jogo.ps1'), @('Conectar Conquistas', 'conectar-conquistas.ps1'))) {
    $l = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) "$($a[0]).lnk")); $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $l.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $programa $a[1])`""
    $l.WorkingDirectory = $programa; $l.IconLocation = "$(Join-Path $PlayniteDir 'Playnite.FullscreenApp.exe'),0"; $l.WindowStyle = 7; $l.Save()
}
if ($Jogos.usuario) {
    $l = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Jogos de PC.lnk')); $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $l.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $programa 'jogos-pc.ps1')`""
    $l.WorkingDirectory = $Base; $l.IconLocation = "$(Join-Path $PlayniteDir 'Playnite.FullscreenApp.exe'),0"; $l.WindowStyle = 7; $l.Save()
}
Remove-Item $Dl -Recurse -Force -ErrorAction SilentlyContinue

Say 'Tudo pronto!' Green
$extra = @()
if ('ps2' -in $Opt.Consoles -and -not $Opt.Bios) { $extra += '- PS2: coloque a BIOS na pasta Emuladores\PCSX2\bios' }
if ('switch' -in $Opt.Consoles -and -not $Opt.Keys) { $extra += '- Switch: coloque o prod.keys em Emuladores\Eden\user\keys' }
if ($RaAviso) { $extra += $RaAviso }
# A interface monta a tela final a partir deste arquivo.
if ($env:JOGOSRETRO_RESULTADO) {
    [ordered]@{ conectado = [bool]$RommHost; rede = $(if ($Cfg.servidor.netbird) { 'netbird' } else { 'tailscale' }); plataformas = $mappings.Count; falta = $extra; launcher = (Join-Path $Base 'launcher.ps1') } |
        ConvertTo-Json | Out-Utf8 $env:JOGOSRETRO_RESULTADO
}
Write-Host "Conectado: $([bool]$RommHost)"
if ($extra) { Write-Host ("Falta:`n" + ($extra -join "`n")) }
exit 0
