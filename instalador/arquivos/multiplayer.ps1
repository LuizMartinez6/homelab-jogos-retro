# Liga o multiplayer online dos emuladores aos servidores do homelab: ad hoc do PSP,
# salas do Switch (Eden) e do 3DS (Azahar), RPCN do PS3 e relay de netplay do RetroArch.
# Roda a cada abertura do atalho (launcher.ps1). So mexe nas opcoes de rede e no
# apelido quando ainda esta vazio; emulador aberto fica para a proxima vez.

. (Join-Path $PSScriptRoot 'conquistas.ps1')

$MultiplayerPortas = @{ psp = 27312; switch = 24872; n3ds = 24873 }
$MultiplayerNomeRpcn = 'Servidor dos amigos'
# Wi-Fi do DS: todo mundo no mesmo servidor (o padrao do melonDS DS e o Kaeru WFC).
$DsWfcDns = '95.217.77.181'  # Wiimmfi
$GpspCoreUrl = 'https://buildbot.libretro.com/nightly/windows/x86_64/latest/gpsp_libretro.dll.zip'
$RommPluginId = [guid]'9700aa21-447d-41b4-a989-acd38f407d9f'

function Get-ServidorMultiplayer($L, [int]$Porta = 27312) {
    # Mesmo caminho do RomM (rede local, NetBird, Tailscale), mas devolve o IP do
    # servidor que respondeu na porta do ad hoc do PSP. $null se nenhum responder.
    foreach ($t in @(@($L.lan, 800), @($L.netbird, 2500), @($L.tailscale, 2500))) {
        if (-not $t[0]) { continue }
        try { $ips = @([Net.Dns]::GetHostAddresses(([Uri]$t[0]).Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }) } catch { continue }
        foreach ($ip in $ips) {
            try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($ip, $Porta).Wait($t[1]); $c.Close() } catch { $ok = $false }
            if ($ok) { return $ip.ToString() }
        }
    }
    $null
}

function Get-ApelidoMultiplayer($usuario) {
    # O login do convite vira o apelido nas salas: so letras, numeros, - e _.
    $a = ([string]$usuario) -replace '[^A-Za-z0-9_-]', ''
    if (-not $a) { return 'Jogador' }
    if ($a.Length -gt 20) { $a = $a.Substring(0, 20) }
    $a.Substring(0, 1).ToUpper() + $a.Substring(1)
}

function Get-QtValue($path, $key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($l in [IO.File]::ReadAllLines($path)) { if ($l.StartsWith("$key=")) { return $l.Substring($key.Length + 1) } }
    $null
}

function Set-QtValue($path, $key, $value) {
    # qt-config.ini do Eden e do Azahar: "chave=valor" em [UI], com o par "chave\default=false"
    # (sem ele o emulador volta para o padrao).
    Set-QtPares $path 'UI' @(@("$key\default", 'false'), @($key, $value))
}

function Set-QtPares($path, $secao, $pares) {
    # Grava cada par "chave=valor" (sem espacos, formato Qt) dentro de [secao], criando o que faltar.
    $linhas = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $path) { foreach ($l in [IO.File]::ReadAllLines($path)) { $linhas.Add($l) } }
    $ini = -1
    for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i].Trim() -eq "[$secao]") { $ini = $i; break } }
    if ($ini -lt 0) {
        if ($linhas.Count -and $linhas[$linhas.Count - 1].Trim()) { $linhas.Add('') }
        $linhas.Add("[$secao]"); $ini = $linhas.Count - 1
    }
    foreach ($par in $pares) {
        $fim = $linhas.Count
        for ($i = $ini + 1; $i -lt $linhas.Count; $i++) { if ($linhas[$i].StartsWith('[')) { $fim = $i; break } }
        $achou = $false
        for ($i = $ini + 1; $i -lt $fim; $i++) { if ($linhas[$i].StartsWith("$($par[0])=")) { $linhas[$i] = "$($par[0])=$($par[1])"; $achou = $true; break } }
        if (-not $achou) { $linhas.Insert($fim, "$($par[0])=$($par[1])") }
    }
    New-Item (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllLines($path, $linhas, (New-Object Text.UTF8Encoding $false))
}

function Get-CfgValue($path, $key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($l in [IO.File]::ReadAllLines($path)) { if ($l -match "^\s*$([regex]::Escape($key))\s*=\s*`"(.*)`"") { return $Matches[1] } }
    $null
}

function Get-IniValue($path, $section, $key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $dentro = $false
    foreach ($l in [IO.File]::ReadAllLines($path)) {
        if ($l.Trim().StartsWith('[')) { $dentro = $l.Trim() -ieq "[$section]"; continue }
        if ($dentro -and $l -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    $null
}

function Set-RpcnServidor($dir, $ip) {
    # Poe o servidor do homelab na lista do RPCN. So vira o servidor padrao quando a
    # pessoa ainda nao tem conta (NPID vazio), para nao derrubar uma conta do RPCN oficial.
    $cfgDir = Join-Path $dir 'config'; New-Item $cfgDir -ItemType Directory -Force | Out-Null
    $arq = Join-Path $cfgDir 'rpcn.yml'
    $entrada = "$MultiplayerNomeRpcn|$ip"
    $linhas = if (Test-Path -LiteralPath $arq) { [IO.File]::ReadAllLines($arq) } else { @('Version: 2', "Host: $ip", 'NPID: ""', 'Password: ""', 'Token: ""', 'Hosts: Official RPCN Server|np.rpcs3.net') }
    $semConta = [bool]($linhas | Where-Object { $_ -match '^NPID:\s*("")?\s*$' })
    for ($i = 0; $i -lt $linhas.Count; $i++) {
        if ($linhas[$i] -match '^Hosts:\s*(.*)$') {
            $hosts = @($Matches[1] -split '\|\|\|' | Where-Object { $_ -and -not $_.StartsWith("$MultiplayerNomeRpcn|") })
            $linhas[$i] = 'Hosts: ' + ((@($hosts) + $entrada) -join '|||')
        } elseif ($semConta -and $linhas[$i] -match '^Host:\s') { $linhas[$i] = "Host: $ip" }
    }
    if (-not ($linhas | Where-Object { $_ -match '^Hosts:' })) { $linhas += "Hosts: Official RPCN Server|np.rpcs3.net|||$entrada" }
    [IO.File]::WriteAllLines($arq, $linhas, (New-Object Text.UTF8Encoding $false))

    # Rede ligada e PSN pelo RPCN. O config.yml so existe depois da primeira abertura do RPCS3.
    $yml = Join-Path $cfgDir 'config.yml'
    if (Test-Path -LiteralPath $yml) {
        $t = [IO.File]::ReadAllText($yml)
        $n = $t -replace '(?m)^(\s+Internet enabled:)\s*\S+', '$1 Connected' -replace '(?m)^(\s+PSN status:)\s*\S+', '$1 RPCN'
        if ($n -ne $t) { [IO.File]::WriteAllText($yml, $n, (New-Object Text.UTF8Encoding $false)) }
    }
}

function Test-EmuladorAberto($dir) {
    [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($dir + '\', 'OrdinalIgnoreCase') })
}

function Set-Multiplayer($Base, $L, $Ip = $null) {
    # Devolve a lista do que foi configurado (vazia se o servidor nao respondeu).
    if (-not $Ip) { $Ip = Get-ServidorMultiplayer $L }
    if (-not $Ip) { return @() }
    $emu = Join-Path $Base 'Emuladores'
    $apelido = Get-ApelidoMultiplayer $L.jogos.usuario
    $feito = @()

    $d = Join-Path $emu 'PPSSPP'
    if ((Test-Path $d) -and -not (Test-EmuladorAberto $d)) {
        $ini = Join-Path $d 'memstick\PSP\SYSTEM\ppsspp.ini'
        Set-IniValue $ini 'Network' 'EnableWlan' 'True'
        Set-IniValue $ini 'Network' 'proAdhocServer' $Ip
        Set-IniValue $ini 'Network' 'AdhocServerRelayMode' '1'
        Set-IniValue $ini 'Network' 'EnableAdhocServer' 'False'
        if ((Get-IniValue $ini 'SystemParam' 'NickName') -in @($null, '', 'PPSSPP')) { Set-IniValue $ini 'SystemParam' 'NickName' $apelido }
        $feito += 'PSP'
    }

    $d = Join-Path $emu 'RetroArch'
    if ((Test-Path (Join-Path $d 'retroarch.exe')) -and -not (Test-EmuladorAberto $d)) {
        # Quem hospeda passa pelo relay do homelab; a sala aparece na lista do RetroArch,
        # mas so quem esta na VPN alcanca o relay.
        $cfg = Join-Path $d 'retroarch.cfg'
        Set-CfgValue $cfg 'netplay_use_mitm_server' 'true'
        Set-CfgValue $cfg 'netplay_mitm_server' 'custom'
        Set-CfgValue $cfg 'netplay_custom_mitm_server' $Ip
        Set-CfgValue $cfg 'netplay_public_announce' 'true'
        Set-CfgValue $cfg 'netplay_start_as_spectator' 'false'
        if ((Get-CfgValue $cfg 'netplay_nickname') -in @($null, '')) { Set-CfgValue $cfg 'netplay_nickname' $apelido }
        # DS: online dos jogos com Wi-Fi da Nintendo pelo Wiimmfi. O MAC sai do apelido; com o
        # do firmware embutido todos teriam o mesmo console e o Wiimmfi barra.
        $opt = Join-Path $d 'config\melonDS DS\melonDS DS.opt'
        New-Item (Split-Path $opt -Parent) -ItemType Directory -Force | Out-Null
        Set-CfgValue $opt 'melonds_network_mode' 'indirect'
        Set-CfgValue $opt 'melonds_firmware_wfc_dns' $DsWfcDns
        Set-CfgValue $opt 'melonds_mac_address_mode' 'from-username'
        $feito += 'RetroArch'
    }

    foreach ($s in @(@('Eden', 'switch', 'Switch'), @('Azahar', 'n3ds', '3DS'))) {
        $d = Join-Path $emu $s[0]
        if (-not (Test-Path $d) -or (Test-EmuladorAberto $d)) { continue }
        $qt = Join-Path $d 'user\config\qt-config.ini'
        Set-QtValue $qt 'Multiplayer\ip' $Ip
        Set-QtValue $qt 'Multiplayer\port' $MultiplayerPortas[$s[1]]
        if (-not (Get-QtValue $qt 'Multiplayer\nickname')) { Set-QtValue $qt 'Multiplayer\nickname' $apelido }
        $feito += $s[2]
    }

    $d = Join-Path $emu 'RPCS3'
    if ((Test-Path (Join-Path $d 'rpcs3.exe')) -and -not (Test-EmuladorAberto $d)) {
        Set-RpcnServidor $d $Ip
        $feito += 'PS3'
    }
    $feito
}

function Test-PokemonLink($nome) {
    # Pokemon de GBA da 3a geracao: trocam e batalham pelo cabo link ou pelo adaptador sem fio.
    ([string]$nome -match '(?i)^pok.mon\b.*\b(fire ?red|leaf ?green|emerald|ruby|sapphire)\b') -and ([string]$nome -notmatch '(?i)pinball')
}

function Get-PastaSaves($ra) {
    # Pasta de saves do RetroArch, ou $null quando ele salva ao lado do jogo (ai nao ha o que copiar).
    $v = Get-CfgValue (Join-Path $ra 'retroarch.cfg') 'savefile_directory'
    if ($v -eq 'default') { return $null }
    if (-not $v) { return Join-Path $ra 'saves' }
    if ($v.StartsWith(':\')) { return Join-Path $ra $v.Substring(2) }
    $v
}

function Get-CoreGpsp($ra) {
    $core = Join-Path $ra 'cores\gpsp_libretro.dll'
    if (Test-Path $core) { return $true }
    $zip = Join-Path $env:TEMP "gpsp-$PID.zip"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $GpspCoreUrl -OutFile $zip -UseBasicParsing -TimeoutSec 60
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $e = $z.Entries | Where-Object { $_.Name -eq 'gpsp_libretro.dll' } | Select-Object -First 1
            if (-not $e) { return $false }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $core, $true)
        } finally { $z.Dispose() }
        $true
    } catch { $false } finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}

function Set-PokemonGpsp($Base, $L) {
    # Os Pokemon da 3a geracao passam a abrir no gpSP, o unico core do RetroArch que leva o
    # cabo link / adaptador sem fio pelo netplay. O resto do GBA continua no mGBA, e o save
    # do mGBA e copiado (nunca movido) para a pasta do gpSP. Exige o Playnite fechado.
    $ra = Join-Path $Base 'Emuladores\RetroArch'
    $raiz = $L.playnite
    if (-not (Test-Path (Join-Path $ra 'retroarch.exe')) -or -not $raiz) { return @() }
    $lite = Join-Path $raiz 'LiteDB.dll'
    $lib = Join-Path $raiz 'library'
    if (-not (Test-Path $lite) -or -not (Test-Path (Join-Path $lib 'games.db')) -or -not (Test-Path (Join-Path $lib 'emulators.db'))) { return @() }
    Add-Type -Path $lite

    $edb = New-Object LiteDB.LiteDatabase("Filename=$(Join-Path $lib 'emulators.db')")
    $gdb = New-Object LiteDB.LiteDatabase("Filename=$(Join-Path $lib 'games.db')")
    $trocados = @()
    try {
        $emus = $edb.GetCollection('Emulator')
        $emu = @($emus.FindAll()) | Where-Object { $_['BuiltInConfigId'].AsString -eq 'retroarch' } | Select-Object -First 1
        if (-not $emu) { return @() }
        $emuId = $emu['_id'].AsGuid
        $perfis = $emu['BuiltinProfiles'].AsArray
        $gpsp = @($perfis) | Where-Object { $_['BuiltInProfileName'].AsString -eq 'gpSP' } | Select-Object -First 1
        $gpspId = if ($gpsp) { $gpsp['_id'].AsString } else { $null }

        $jogos = $gdb.GetCollection('Game')
        $mudar = @()
        foreach ($g in @($jogos.FindAll())) {
            if ($g['PluginId'].AsGuid -ne $RommPluginId -or $g['Roms'].IsNull -or $g['Roms'].AsArray.Count -eq 0) { continue }
            $rom = $g['Roms'].AsArray[0]
            if ($rom['Path'].AsString -notlike '*.gba') { continue }
            if (-not ((Test-PokemonLink $g['Name'].AsString) -or (Test-PokemonLink $rom['Name'].AsString))) { continue }
            if ($g['GameActions'].IsNull) { continue }
            $acao = @($g['GameActions'].AsArray) | Where-Object { $_['Type'].AsString -eq 'Emulator' -and $_['EmulatorId'].AsGuid -eq $emuId } | Select-Object -First 1
            if ($acao -and $acao['EmulatorProfileId'].AsString -ne $gpspId) { $mudar += , @($g, $acao) }
        }
        if ($mudar.Count -eq 0) { return @() }
        if (-not (Get-CoreGpsp $ra)) { return @() }

        if (-not $gpspId) {
            $gpspId = "#builtin_$([guid]::NewGuid())"
            $p = New-Object LiteDB.BsonDocument
            $p['_id'] = New-Object LiteDB.BsonValue($gpspId)
            $p['BuiltInProfileName'] = New-Object LiteDB.BsonValue('gpSP')
            $p['OverrideDefaultArgs'] = New-Object LiteDB.BsonValue($false)
            $p['Name'] = New-Object LiteDB.BsonValue('gpSP')
            $perfis.Add($p)
            [void]$emus.Update($emu)
        }

        $saves = Get-PastaSaves $ra
        foreach ($m in $mudar) {
            $m[1]['EmulatorProfileId'] = New-Object LiteDB.BsonValue($gpspId)
            [void]$jogos.Update($m[0])
            $trocados += $m[0]['Name'].AsString
            if ($saves) {
                $nome = [IO.Path]::GetFileNameWithoutExtension($m[0]['Roms'].AsArray[0]['Path'].AsString)
                $de = Join-Path $saves "mGBA\$nome.srm"; $para = Join-Path $saves "gpSP\$nome.srm"
                if ((Test-Path -LiteralPath $de) -and -not (Test-Path -LiteralPath $para)) {
                    New-Item (Split-Path $para -Parent) -ItemType Directory -Force | Out-Null
                    Copy-Item -LiteralPath $de -Destination $para
                }
            }
        }
    } finally { $gdb.Dispose(); $edb.Dispose() }
    $trocados
}
