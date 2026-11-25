BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    . (Join-Path $Arquivos 'multiplayer.ps1')
    function Read-Texto($p) { [IO.File]::ReadAllText($p) }

    function New-Emuladores {
        # Instalacao falsa com os cinco emuladores que tem multiplayer.
        $base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        $emu = Join-Path $base 'Emuladores'
        New-Item "$emu\PPSSPP", "$emu\RetroArch", "$emu\Eden\user", "$emu\Azahar\user", "$emu\RPCS3\config" -ItemType Directory -Force | Out-Null
        Set-Content "$emu\RetroArch\retroarch.exe" ''
        Set-Content "$emu\RPCS3\rpcs3.exe" ''
        $base
    }

    $L = [pscustomobject]@{ lan = 'http://192.168.0.10:1080'; jogos = [pscustomobject]@{ usuario = 'beto' } }
}

Describe 'Get-ApelidoMultiplayer' {
    It 'usa o login do convite com a primeira letra maiuscula' { Get-ApelidoMultiplayer 'beto' | Should -Be 'Beto' }
    It 'tira o que nao e letra, numero, - ou _' { Get-ApelidoMultiplayer 'jo.ao da silva!' | Should -Be 'Joaodasilva' }
    It 'sem login vira Jogador' { Get-ApelidoMultiplayer $null | Should -Be 'Jogador' }
    It 'corta em 20 caracteres' { (Get-ApelidoMultiplayer ('a' * 30)).Length | Should -Be 20 }
}

Describe 'Get-ServidorMultiplayer' {
    BeforeAll {
        $Escuta = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $Escuta.Start()
        $Porta = $Escuta.LocalEndpoint.Port
    }
    AfterAll { $Escuta.Stop() }

    It 'devolve o IP do primeiro caminho que responde na porta' {
        Get-ServidorMultiplayer ([pscustomobject]@{ lan = 'http://127.0.0.1:1080' }) $Porta | Should -Be '127.0.0.1'
    }

    It 'pula a rede local que nao responde e tenta o NetBird' {
        $l = [pscustomobject]@{ lan = 'http://192.0.2.1:1080'; netbird = 'http://localhost:1080' }
        Get-ServidorMultiplayer $l $Porta | Should -Be '127.0.0.1'
    }

    It 'sem nenhum caminho devolve nulo' {
        Get-ServidorMultiplayer ([pscustomobject]@{ lan = 'http://127.0.0.1:1080' }) (Get-PortaFechada) | Should -BeNullOrEmpty
    }
}

Describe 'Set-QtValue' {
    It 'cria [UI] com o par \default=false' {
        $qt = Join-Path $TestDrive 'qt\novo.ini'
        Set-QtValue $qt 'Multiplayer\ip' '10.0.0.1'
        Read-Texto $qt | Should -Be "[UI]`r`nMultiplayer\ip\default=false`r`nMultiplayer\ip=10.0.0.1`r`n"
    }

    It 'troca so dentro de [UI] e mantem as outras secoes' {
        $qt = Join-Path $TestDrive 'qt\b.ini'
        [IO.File]::WriteAllText($qt, "[Core]`r`nMultiplayer\ip=fica`r`n`r`n[UI]`r`nMultiplayer\ip\default=true`r`nMultiplayer\ip=`r`n[Web]`r`nx=1`r`n")
        Set-QtValue $qt 'Multiplayer\ip' '10.0.0.2'
        Set-QtValue $qt 'Multiplayer\port' 24873
        Read-Texto $qt | Should -Be ("[Core]`r`nMultiplayer\ip=fica`r`n`r`n[UI]`r`nMultiplayer\ip\default=false`r`nMultiplayer\ip=10.0.0.2`r`n" +
            "Multiplayer\port\default=false`r`nMultiplayer\port=24873`r`n[Web]`r`nx=1`r`n")
    }
}

Describe 'Set-Multiplayer' {
    It 'configura os cinco emuladores com o IP e o apelido' {
        $base = New-Emuladores
        $feito = Set-Multiplayer $base $L '100.64.0.10'
        $feito | Should -Be @('PSP', 'RetroArch', 'Switch', '3DS', 'PS3')
        $emu = Join-Path $base 'Emuladores'

        $psp = "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini"
        Get-IniValue $psp 'Network' 'proAdhocServer' | Should -Be '100.64.0.10'
        Get-IniValue $psp 'Network' 'AdhocServerRelayMode' | Should -Be '1'
        Get-IniValue $psp 'Network' 'EnableAdhocServer' | Should -Be 'False'
        Get-IniValue $psp 'Network' 'EnableWlan' | Should -Be 'True'
        Get-IniValue $psp 'SystemParam' 'NickName' | Should -Be 'Beto'

        $ra = "$emu\RetroArch\retroarch.cfg"
        Get-CfgValue $ra 'netplay_custom_mitm_server' | Should -Be '100.64.0.10'
        Get-CfgValue $ra 'netplay_mitm_server' | Should -Be 'custom'
        Get-CfgValue $ra 'netplay_use_mitm_server' | Should -Be 'true'
        Get-CfgValue $ra 'netplay_nickname' | Should -Be 'Beto'

        Get-QtValue "$emu\Eden\user\config\qt-config.ini" 'Multiplayer\port' | Should -Be '24872'
        Get-QtValue "$emu\Azahar\user\config\qt-config.ini" 'Multiplayer\port' | Should -Be '24873'
        Get-QtValue "$emu\Azahar\user\config\qt-config.ini" 'Multiplayer\ip' | Should -Be '100.64.0.10'
        Get-QtValue "$emu\Eden\user\config\qt-config.ini" 'Multiplayer\nickname' | Should -Be 'Beto'

        $rpcn = Read-Texto "$emu\RPCS3\config\rpcn.yml"
        $rpcn | Should -Match '(?m)^Host: 100\.64\.0\.10\r?$'
        $rpcn | Should -Match '(?m)^Hosts: Official RPCN Server\|np\.rpcs3\.net\|\|\|Servidor dos amigos\|100\.64\.0\.10\r?$'

        $ds = "$emu\RetroArch\config\melonDS DS\melonDS DS.opt"
        Get-CfgValue $ds 'melonds_firmware_wfc_dns' | Should -Be '95.217.77.181'
        Get-CfgValue $ds 'melonds_mac_address_mode' | Should -Be 'from-username'
        Get-CfgValue $ds 'melonds_network_mode' | Should -Be 'indirect'
    }

    It 'nao troca o apelido que a pessoa ja escolheu' {
        $base = New-Emuladores; $emu = Join-Path $base 'Emuladores'
        Set-IniValue "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini" 'SystemParam' 'NickName' 'Meu'
        Set-CfgValue "$emu\RetroArch\retroarch.cfg" 'netplay_nickname' 'Meu'
        Set-QtValue "$emu\Azahar\user\config\qt-config.ini" 'Multiplayer\nickname' 'Meu'
        Set-Multiplayer $base $L '100.64.0.10' | Out-Null
        Get-IniValue "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini" 'SystemParam' 'NickName' | Should -Be 'Meu'
        Get-CfgValue "$emu\RetroArch\retroarch.cfg" 'netplay_nickname' | Should -Be 'Meu'
        Get-QtValue "$emu\Azahar\user\config\qt-config.ini" 'Multiplayer\nickname' | Should -Be 'Meu'
    }

    It 'troca o apelido padrao do PPSSPP' {
        $base = New-Emuladores; $emu = Join-Path $base 'Emuladores'
        Set-IniValue "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini" 'SystemParam' 'NickName' 'PPSSPP'
        Set-Multiplayer $base $L '100.64.0.10' | Out-Null
        Get-IniValue "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini" 'SystemParam' 'NickName' | Should -Be 'Beto'
    }

    It 'RPCN com conta ja criada so ganha o servidor na lista' {
        $base = New-Emuladores; $cfg = Join-Path $base 'Emuladores\RPCS3\config'
        [IO.File]::WriteAllText("$cfg\rpcn.yml", "Version: 2`r`nHost: np.rpcs3.net`r`nNPID: beto123`r`nPassword: x`r`nToken: y`r`nHosts: Official RPCN Server|np.rpcs3.net`r`n")
        Set-Multiplayer $base $L '100.64.0.10' | Out-Null
        $rpcn = Read-Texto "$cfg\rpcn.yml"
        $rpcn | Should -Match '(?m)^Host: np\.rpcs3\.net\r?$'
        $rpcn | Should -Match '(?m)^NPID: beto123\r?$'
        $rpcn | Should -Match 'Servidor dos amigos\|100\.64\.0\.10'
    }

    It 'rodar de novo com outro IP nao duplica o servidor na lista do RPCN' {
        $base = New-Emuladores
        Set-Multiplayer $base $L '100.64.0.10' | Out-Null
        Set-Multiplayer $base $L '192.168.0.10' | Out-Null
        $hosts = (Get-Content "$base\Emuladores\RPCS3\config\rpcn.yml" | Where-Object { $_ -like 'Hosts:*' })
        $hosts | Should -Be 'Hosts: Official RPCN Server|np.rpcs3.net|||Servidor dos amigos|192.168.0.10'
    }

    It 'liga a rede e o PSN no config.yml do RPCS3 quando ele ja existe' {
        $base = New-Emuladores; $yml = Join-Path $base 'Emuladores\RPCS3\config\config.yml'
        [IO.File]::WriteAllText($yml, "Core:`n  PPU Decoder: Recompiler`nNet:`n  Internet enabled: Disconnected`n  IP address: 0.0.0.0`n  PSN status: Disconnected`n")
        Set-Multiplayer $base $L '100.64.0.10' | Out-Null
        Read-Texto $yml | Should -Be "Core:`n  PPU Decoder: Recompiler`nNet:`n  Internet enabled: Connected`n  IP address: 0.0.0.0`n  PSN status: RPCN`n"
    }

    It 'so mexe nos emuladores instalados' {
        $base = Join-Path $TestDrive 'so-psp'
        New-Item "$base\Emuladores\PPSSPP", "$base\Emuladores\RetroArch" -ItemType Directory -Force | Out-Null
        Set-Multiplayer $base $L '100.64.0.10' | Should -Be 'PSP'
        Test-Path "$base\Emuladores\RetroArch\retroarch.cfg" | Should -BeFalse -Because 'sem retroarch.exe o RetroArch nao esta instalado'
        Test-Path "$base\Emuladores\Eden" | Should -BeFalse
    }

    It 'sem servidor nao mexe em nada' {
        $base = New-Emuladores
        $l = [pscustomobject]@{ lan = "http://127.0.0.1:$(Get-PortaFechada)"; jogos = $L.jogos }
        Mock Get-ServidorMultiplayer { $null }
        Set-Multiplayer $base $l | Should -BeNullOrEmpty
        Test-Path "$base\Emuladores\PPSSPP\memstick" | Should -BeFalse
    }

    It 'grava sem BOM' {
        $base = New-Emuladores
        Set-Multiplayer $base $L '100.64.0.10' | Out-Null
        foreach ($f in 'PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini', 'RetroArch\retroarch.cfg', 'Eden\user\config\qt-config.ini', 'RPCS3\config\rpcn.yml') {
            [IO.File]::ReadAllBytes((Join-Path "$base\Emuladores" $f))[0] | Should -Not -Be 0xEF -Because $f
        }
    }
}

Describe 'Test-PokemonLink' {
    It 'aceita os Pokemon da 3a geracao pelo nome do jogo e da ROM' {
        Test-PokemonLink "Pok$([char]0xE9)mon FireRed Version" | Should -BeTrue
        Test-PokemonLink 'Pokemon - Emerald Version (USA, Europe)' | Should -BeTrue
        Test-PokemonLink 'Pokemon - Leaf Green Version (USA)' | Should -BeTrue
        Test-PokemonLink 'Pokemon - Ruby Version (USA)' | Should -BeTrue
        Test-PokemonLink 'Pokemon - Sapphire Version (Europe) (Rev 1)' | Should -BeTrue
    }
    It 'recusa os outros' {
        Test-PokemonLink 'Pokemon Pinball - Ruby & Sapphire (USA)' | Should -BeFalse
        Test-PokemonLink 'Pokemon Mystery Dungeon - Red Rescue Team (USA, Australia)' | Should -BeFalse
        Test-PokemonLink 'Golden Sun (USA, Europe)' | Should -BeFalse
        Test-PokemonLink $null | Should -BeFalse
    }
}

Describe 'Get-PastaSaves' {
    It 'resolve :\ como a pasta do RetroArch e usa saves quando nao ha a opcao' {
        $ra = Join-Path $TestDrive 'ra-saves'; New-Item $ra -ItemType Directory -Force | Out-Null
        Get-PastaSaves $ra | Should -Be (Join-Path $ra 'saves')
        Set-CfgValue "$ra\retroarch.cfg" 'savefile_directory' ':\meus-saves'
        Get-PastaSaves $ra | Should -Be (Join-Path $ra 'meus-saves')
        Set-CfgValue "$ra\retroarch.cfg" 'savefile_directory' 'default'
        Get-PastaSaves $ra | Should -BeNullOrEmpty
    }
}

Describe 'Set-PokemonGpsp (banco real do Playnite)' {
    BeforeAll {
        $Playnite = Find-Playnite
        if ($Playnite) {
            $Base = Join-Path $TestDrive 'gpsp'
            $Raiz = Join-Path $Base 'Playnite'
            $Ra = Join-Path $Base 'Emuladores\RetroArch'
            New-Item "$Raiz\library", "$Ra\cores", "$Ra\saves\mGBA" -ItemType Directory -Force | Out-Null
            Copy-Item (Join-Path $Playnite 'LiteDB.dll') $Raiz
            Set-Content "$Ra\retroarch.exe" ''
            Set-Content "$Ra\cores\gpsp_libretro.dll" 'core'  # core ja presente: sem download no teste
            Set-CfgValue "$Ra\retroarch.cfg" 'savefile_directory' ':\saves'
            [IO.File]::WriteAllText("$Ra\saves\mGBA\Pokemon - FireRed Version (USA).srm", 'save do mgba')

            # Banco montado num processo separado: a LiteDB.dll fica presa ao processo que a carrega.
            $script = @'
Add-Type -Path '{0}\LiteDB.dll'
function V($x) {{ New-Object LiteDB.BsonValue($x) }}
$e = New-Object LiteDB.LiteDatabase('Filename={0}\library\emulators.db')
$emu = New-Object LiteDB.BsonDocument
$emu['_id'] = V ([guid]'11111111-1111-1111-1111-111111111111'); $emu['BuiltInConfigId'] = V 'retroarch'
$p = New-Object LiteDB.BsonDocument; $p['_id'] = V '#builtin_mgba'; $p['BuiltInProfileName'] = V 'mGBA'; $p['Name'] = V 'mGBA'
$arr = New-Object LiteDB.BsonArray; $arr.Add($p); $emu['BuiltinProfiles'] = $arr
[void]$e.GetCollection('Emulator').Insert($emu); $e.Dispose()
$db = New-Object LiteDB.LiteDatabase('Filename={0}\library\games.db')
$col = $db.GetCollection('Game')
function Novo($nome, $arquivo) {{
    $d = New-Object LiteDB.BsonDocument
    $d['_id'] = V ([guid]::NewGuid()); $d['Name'] = V $nome; $d['PluginId'] = V ([guid]'9700aa21-447d-41b4-a989-acd38f407d9f')
    $rom = New-Object LiteDB.BsonDocument; $rom['Name'] = V ([IO.Path]::GetFileNameWithoutExtension($arquivo)); $rom['Path'] = V ('{{PlayniteDir}}\Jogos\' + $arquivo)
    $roms = New-Object LiteDB.BsonArray; $roms.Add($rom); $d['Roms'] = $roms
    $a = New-Object LiteDB.BsonDocument; $a['Type'] = V 'Emulator'; $a['EmulatorId'] = V ([guid]'11111111-1111-1111-1111-111111111111'); $a['EmulatorProfileId'] = V '#builtin_mgba'
    $u = New-Object LiteDB.BsonDocument; $u['Type'] = V 'URL'; $u['Path'] = V 'http://romm/rom/1'
    $acoes = New-Object LiteDB.BsonArray; $acoes.Add($a); $acoes.Add($u); $d['GameActions'] = $acoes
    [void]$col.Insert($d)
}}
Novo 'Pokemon FireRed Version' 'Pokemon - FireRed Version (USA).gba'
Novo 'Pokemon Pinball: Ruby & Sapphire' 'Pokemon Pinball - Ruby & Sapphire (USA).gba'
Novo 'Pokemon Omega Ruby' 'Pokemon Omega Ruby (USA).3ds'
Novo 'Golden Sun' 'Golden Sun (USA, Europe).gba'
$db.Dispose()
'@ -f $Raiz
            powershell.exe -NoProfile -Command $script

            function Invoke-Gpsp {
                powershell.exe -NoProfile -Command ". '$Arquivos\multiplayer.ps1'; Set-PokemonGpsp '$Base' ([pscustomobject]@{ playnite = '$Raiz' })"
            }
            function Get-Perfis {
                # "<jogo>=<perfil>" de cada jogo, e "emulador=<perfis>" do RetroArch.
                $ler = @'
Add-Type -Path '{0}\LiteDB.dll'
$e = New-Object LiteDB.LiteDatabase('Filename={0}\library\emulators.db;ReadOnly=true')
$emu = @($e.GetCollection('Emulator').FindAll())[0]
'emulador=' + ((@($emu['BuiltinProfiles'].AsArray) | ForEach-Object {{ $_['BuiltInProfileName'].AsString }}) -join ',')
$gpsp = @($emu['BuiltinProfiles'].AsArray) | Where-Object {{ $_['BuiltInProfileName'].AsString -eq 'gpSP' }} | ForEach-Object {{ $_['_id'].AsString }}
$e.Dispose()
$g = New-Object LiteDB.LiteDatabase('Filename={0}\library\games.db;ReadOnly=true')
foreach ($x in $g.GetCollection('Game').FindAll()) {{
    $p = $x['GameActions'].AsArray[0]['EmulatorProfileId'].AsString
    $x['Name'].AsString + '=' + $(if ($p -eq $gpsp) {{ 'gpSP' }} else {{ $p }})
}}
$g.Dispose()
'@ -f $Raiz
                powershell.exe -NoProfile -Command $ler
            }
        }
    }

    It 'troca so os Pokemon da 3a geracao de GBA para o gpSP e copia o save' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        Invoke-Gpsp | Should -Be 'Pokemon FireRed Version'
        $r = Get-Perfis
        $r | Should -Contain 'emulador=mGBA,gpSP'
        $r | Should -Contain 'Pokemon FireRed Version=gpSP'
        $r | Should -Contain 'Pokemon Pinball: Ruby & Sapphire=#builtin_mgba'
        $r | Should -Contain 'Pokemon Omega Ruby=#builtin_mgba'
        $r | Should -Contain 'Golden Sun=#builtin_mgba'
        Get-Content -LiteralPath "$Ra\saves\gpSP\Pokemon - FireRed Version (USA).srm" | Should -Be 'save do mgba'
        Test-Path -LiteralPath "$Ra\saves\mGBA\Pokemon - FireRed Version (USA).srm" | Should -BeTrue -Because 'o save do mGBA fica'
    }

    It 'rodar de novo nao muda nada nem cria outro perfil' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        [IO.File]::WriteAllText("$Ra\saves\gpSP\Pokemon - FireRed Version (USA).srm", 'jogado no gpsp')
        Invoke-Gpsp | Should -BeNullOrEmpty
        Get-Perfis | Should -Contain 'emulador=mGBA,gpSP'
        Get-Content -LiteralPath "$Ra\saves\gpSP\Pokemon - FireRed Version (USA).srm" | Should -Be 'jogado no gpsp'
    }
}

Describe 'launcher.ps1 com multiplayer' {
    BeforeAll {
        $Escuta = $null
        try { $Escuta = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 27312; $Escuta.Start() } catch { $Escuta = $null }
        $PlayniteAberto = [bool](Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue)
    }
    AfterAll { if ($Escuta) { $Escuta.Stop() } }

    It 'configura o PPSSPP ao abrir o atalho' {
        if (-not $Escuta) { Set-ItResult -Skipped -Because 'a porta 27312 esta ocupada neste PC' }
        if ($PlayniteAberto) { Set-ItResult -Skipped -Because 'feche o Playnite para rodar os testes do launcher' }
        $base = Join-Path $TestDrive 'launcher-mp'
        $pn = Join-Path $base 'Playnite'
        New-Item "$base\programa", $pn, "$base\Emuladores\PPSSPP" -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $Arquivos 'launcher.ps1') $base
        foreach ($f in 'atualizador.ps1', 'multiplayer.ps1', 'conquistas.ps1') { Copy-Item (Join-Path $Arquivos $f) "$base\programa" }
        $exe = Join-Path $TestDrive 'falso-mp.exe'; New-ExeFalso $exe
        Copy-Item $exe "$pn\Playnite.DesktopApp.exe"
        $l = [ordered]@{ lan = 'http://127.0.0.1:1'; rommConfig = "$base\nao-existe.json"; playnite = $pn; fullscreen = $false; mapas = @()
            jogos = @{ lan = "http://127.0.0.1:$(Get-PortaFechada)"; usuario = 'ana'; senha = 'b' } }
        Write-Utf8 "$base\launcher.json" ($l | ConvertTo-Json -Depth 5)

        $r = Invoke-Worker (Join-Path $base 'launcher.ps1') @{ EXE_FALSO_LOG = (Join-Path $base 'exe.log') }
        $r.Codigo | Should -Be 0 -Because $r.Erro
        for ($i = 0; $i -lt 300 -and -not (Test-Path "$base\exe.log"); $i++) { Start-Sleep -Milliseconds 100 }
        $ini = "$base\Emuladores\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini"
        Get-IniValue $ini 'Network' 'proAdhocServer' | Should -Be '127.0.0.1'
        Get-IniValue $ini 'SystemParam' 'NickName' | Should -Be 'Ana'
        Get-Content "$base\exe.log" | Should -Be 'Playnite.DesktopApp.exe|' -Because 'o Playnite abre depois do multiplayer'
    }
}
