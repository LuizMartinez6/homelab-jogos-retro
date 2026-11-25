BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    . (Join-Path $Arquivos 'instalacao.ps1')

    function New-Base($Launcher, $Romm) {
        $base = Join-Path $TestDrive ([guid]::NewGuid())
        $Launcher.rommConfig = Join-Path $base 'romm.json'
        Write-Utf8 (Join-Path $base 'launcher.json') ($Launcher | ConvertTo-Json -Depth 5)
        Write-Utf8 $Launcher.rommConfig ($Romm | ConvertTo-Json -Depth 5)
        $base
    }
}

Describe 'Get-CaminhoJogo' {
    It 'pasta com o nome do jogo (padrao do plugin do RomM)' {
        Get-CaminhoJogo @{ DestinationPath = 'C:\R\psx'; InstallFlat = $false } 'Jogo [USA].chd' | Should -Be 'C:\R\psx\Jogo [USA]\Jogo [USA].chd'
    }
    It 'mapeamento plano' {
        Get-CaminhoJogo @{ DestinationPath = 'C:\R\gba'; InstallFlat = $true } 'Jogo.gba' | Should -Be 'C:\R\gba\Jogo.gba'
    }
}

Describe 'Get-RommConexao' {
    BeforeAll {
        $romm = @{ RomMUsername = 'amigo'; RomMPassword = 's3nha'; Mappings = @(@{ Enabled = $true; Nome = 'psx' }, @{ Enabled = $false; Nome = 'ps2' }) }
        $aberta = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $aberta.Start()
        $portaAberta = $aberta.LocalEndpoint.Port
    }
    AfterAll { $aberta.Stop() }

    It 'usa a rede local quando responde' {
        $base = New-Base @{ lan = "http://127.0.0.1:$portaAberta/"; tailscale = 'https://ts.exemplo' } $romm
        $c = Get-RommConexao $base
        $c.Api | Should -Be "http://127.0.0.1:$portaAberta/api"
        $c.Auth | Should -Be ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('amigo:s3nha')))
        @($c.Mappings).Nome | Should -Be 'psx'
    }

    It 'cai para o NetBird e depois para o Tailscale' {
        $fechada = "http://127.0.0.1:$(Get-PortaFechada)"
        (Get-RommConexao (New-Base @{ lan = $fechada; netbird = "http://127.0.0.1:$portaAberta"; tailscale = 'https://ts.exemplo' } $romm)).Api |
            Should -Be "http://127.0.0.1:$portaAberta/api"
        (Get-RommConexao (New-Base @{ lan = $fechada; netbird = $fechada; tailscale = 'https://ts.exemplo' } $romm)).Api | Should -Be 'https://ts.exemplo/api'
    }
}

Describe 'Test-PlayniteAberto' {
    BeforeAll { $base = New-Base @{ playnite = 'C:\Jogos\Playnite' } @{} }

    It 'so conta o Playnite desta instalacao' {
        Mock Get-Process { [pscustomobject]@{ Name = 'Playnite.DesktopApp'; Path = 'D:\Outro\Playnite\Playnite.DesktopApp.exe' } }
        Test-PlayniteAberto $base | Should -BeFalse
        Mock Get-Process { [pscustomobject]@{ Name = 'Playnite.FullscreenApp'; Path = 'c:\jogos\playnite\Playnite.FullscreenApp.exe' } }
        Test-PlayniteAberto $base | Should -BeTrue
    }
}

Describe 'Sync-JogosInstalados (games.db real do Playnite)' {
    BeforeAll {
        $Playnite = Find-Playnite
        if ($Playnite) {
            $raiz = Join-Path $TestDrive 'Playnite'
            New-Item "$raiz\library" -ItemType Directory -Force | Out-Null
            Copy-Item (Join-Path $Playnite 'LiteDB.dll') $raiz
            $base = New-Base @{ playnite = $raiz } @{}
            New-Item "$raiz\Roms\psx\Jogo [USA]" -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath "$raiz\Roms\psx\Jogo [USA]\Jogo [USA].chd" 'x'

            # Banco montado num processo separado: a LiteDB.dll fica presa ao processo que a carrega.
            $script = @'
Add-Type -Path '{0}\LiteDB.dll'
$db = New-Object LiteDB.LiteDatabase('Filename={0}\library\games.db')
$col = $db.GetCollection('Game')
function Novo($nome, $plugin, $instalado, $caminho) {{
    $d = New-Object LiteDB.BsonDocument
    $d['_id'] = New-Object LiteDB.BsonValue([guid]::NewGuid()); $d['Name'] = New-Object LiteDB.BsonValue($nome)
    $d['PluginId'] = New-Object LiteDB.BsonValue([guid]$plugin); $d['IsInstalled'] = New-Object LiteDB.BsonValue($instalado)
    if ($caminho) {{
        $rom = New-Object LiteDB.BsonDocument; $rom['Path'] = New-Object LiteDB.BsonValue($caminho)
        $arr = New-Object LiteDB.BsonArray; $arr.Add($rom); $d['Roms'] = $arr
    }}
    [void]$col.Insert($d)
}}
$romm = '9700aa21-447d-41b4-a989-acd38f407d9f'
Novo 'Baixado' $romm $false '{{PlayniteDir}}\Roms\psx\Jogo [USA]\Jogo [USA].chd'
Novo 'Nao baixado' $romm $false '{{PlayniteDir}}\Roms\psx\Outro\Outro.chd'
Novo 'Sem rom' $romm $false $null
Novo 'Outro plugin' ([guid]::NewGuid()) $false '{{PlayniteDir}}\Roms\psx\Jogo [USA]\Jogo [USA].chd'
$db.Dispose()
'@ -f $raiz
            powershell.exe -NoProfile -Command $script
        }
    }

    It 'marca como instalado so o jogo do RomM cujo arquivo existe' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $r = powershell.exe -NoProfile -Command ". '$Arquivos\instalacao.ps1'; Sync-JogosInstalados '$base'"
        $r | Should -Be 'Baixado'
        powershell.exe -NoProfile -Command ". '$Arquivos\instalacao.ps1'; @(Sync-JogosInstalados '$base').Count" | Should -Be '0'
    }
}
