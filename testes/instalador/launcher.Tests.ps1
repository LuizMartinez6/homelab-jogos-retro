BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    $Launcher = Join-Path $Arquivos 'launcher.ps1'
    $ExeFalso = Join-Path $TestDrive 'falso.exe'
    New-ExeFalso $ExeFalso

    # RomM falso: /api/platforms com psx e ps2 (n64 nao existe no servidor).
    $Srv = Join-Path $TestDrive 'srv'
    $plats = @(
        @{ id = 1; slug = 'ps'; fs_slug = 'psx'; name = 'PlayStation'; display_name = 'PlayStation'; rom_count = 10; extra = 'some' }
        @{ id = 2; slug = 'ps2'; fs_slug = 'ps2'; name = 'PlayStation 2'; display_name = 'PS2'; rom_count = 3; firmware = @() }
    )
    Write-Utf8 (Join-Path $Srv 'api\platforms') (ConvertTo-Json @($plats) -Depth 4)
    $Romm = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 'r0mm'

    function New-Instalacao([string]$Lan = $Romm.Url, [string]$Tailscale = 'https://ts.exemplo', [string]$RommDllHash) {
        $base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        $pn = Join-Path $base 'Playnite'
        New-Item "$base\programa", "$pn\Extensions\JogosRetroJogosPC", "$pn\Extensions\RomM_9700aa21-447d-41b4-a989-acd38f407d9f" -ItemType Directory -Force | Out-Null
        Copy-Item $Launcher $base
        Copy-Item (Join-Path $Arquivos 'atualizador.ps1') "$base\programa"
        [IO.File]::WriteAllText("$base\programa\JogosPc.dll", 'plugin novo')
        [IO.File]::WriteAllText("$base\programa\RomMSemInstalador.dll", 'romm sem instalador')
        [IO.File]::WriteAllText("$pn\Extensions\RomM_9700aa21-447d-41b4-a989-acd38f407d9f\RomM.dll", 'romm de outra versao')
        Copy-Item $ExeFalso "$pn\Playnite.DesktopApp.exe"
        Copy-Item $ExeFalso "$pn\Playnite.FullscreenApp.exe"
        $mapa = { param($slug) @{ slug = $slug; emuladorId = "emu-$slug"; perfilId = "perfil-$slug"; perfil = "Perfil $slug"; destino = "C:\Roms\$slug" } }
        $L = [ordered]@{ lan = $Lan; tailscale = $Tailscale; rommConfig = "$base\romm.json"; playnite = $pn; fullscreen = $false
            mapas = @((& $mapa 'psx'), (& $mapa 'ps2'), (& $mapa 'n64'))
            jogos = @{ lan = "http://127.0.0.1:$(Get-PortaFechada)"; usuario = 'a'; senha = 'b' } }
        Write-Utf8 "$base\launcher.json" ($L | ConvertTo-Json -Depth 5)
        $cfg = [ordered]@{ RomMHost = 'http://antigo'; RomMUsername = 'amigo'; RomMPassword = 'r0mm'; RomMPlatforms = @()
            Mappings = @(@{ MappingId = 'm1'; Enabled = $true; RomMPlatformId = 1; RomMPlatform = @{ fs_slug = 'psx' }; EmulatorId = 'emu-psx' }) }
        Write-Utf8 "$base\romm.json" ($cfg | ConvertTo-Json -Depth 6)
        $base
    }

    function Invoke-Launcher($base) {
        $log = Join-Path $base 'exe.log'
        $r = Invoke-Worker (Join-Path $base 'launcher.ps1') @{ EXE_FALSO_LOG = $log }
        $r.Codigo | Should -Be 0 -Because $r.Erro
        # O launcher abre o Playnite (o .exe falso) sem esperar: da tempo de ele gravar o log.
        for ($i = 0; $i -lt 300 -and -not (Test-Path $log); $i++) { Start-Sleep -Milliseconds 100 }
        $log
    }

    $PlayniteAberto = [bool](Get-Process Playnite.DesktopApp, Playnite.FullscreenApp -ErrorAction SilentlyContinue)
}
AfterAll { Stop-ServidorTeste $Romm }

Describe 'launcher.ps1' {
    BeforeEach {
        # Com um Playnite de verdade aberto o launcher (corretamente) nao mexe em nada.
        if ($PlayniteAberto) { Set-ItResult -Skipped -Because 'feche o Playnite para rodar os testes do launcher' }
    }

    It 'aponta o RomM para a rede local, completa os mapeamentos e abre o Playnite' {
        $base = New-Instalacao
        $log = Invoke-Launcher $base

        $bytes = [IO.File]::ReadAllBytes("$base\romm.json")
        $bytes[0] | Should -Be ([byte][char]'{') -Because 'o Playnite nao aceita BOM'
        $cfg = Get-Content "$base\romm.json" -Raw | ConvertFrom-Json
        $cfg.RomMHost | Should -Be $Romm.Url
        @($cfg.Mappings.RomMPlatform.fs_slug) | Should -Be @('psx', 'ps2')
        $novo = $cfg.Mappings[1]
        $novo.EmulatorId | Should -Be 'emu-ps2'; $novo.EmulatorProfileId | Should -Be 'perfil-ps2'
        $novo.RomMPlatformId | Should -Be 2; $novo.DestinationPath | Should -Be 'C:\Roms\ps2'
        $novo.MappingName | Should -Be 'PlayStation 2 -> Perfil ps2'
        $novo.Enabled | Should -BeTrue; $novo.InstallFlat | Should -BeFalse
        @($cfg.RomMPlatforms.fs_slug) | Should -Be @('psx', 'ps2')
        $cfg.RomMPlatforms[0].PSObject.Properties.Name | Should -Not -Contain 'extra'

        Get-Content $log | Should -Be 'Playnite.DesktopApp.exe|'
        # Marca para o ao-abrir.ps1 (rodado pelo plugin) nao repetir o que o launcher fez.
        Test-Path "$base\launcher-abriu.txt" | Should -BeTrue
    }

    It 'instala o plugin Jogos de PC e tira a versao antiga' {
        $base = New-Instalacao
        Invoke-Launcher $base | Out-Null
        $ext = "$base\Playnite\Extensions\JogosPc_c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3"
        Get-Content "$ext\JogosPc.dll" | Should -Be 'plugin novo'
        Get-Content "$ext\extension.yaml" | Should -Contain 'Module: JogosPc.dll'
        Get-Content "$ext\extension.yaml" | Should -Contain 'Type: GameLibrary'
        (Get-Content "$ext\instalacao.txt").Trim() | Should -Be $base
        Test-Path "$base\Playnite\Extensions\JogosRetroJogosPC" | Should -BeFalse
    }

    It 'so troca o RomM.dll quando e exatamente a versao conhecida' {
        $base = New-Instalacao
        Invoke-Launcher $base | Out-Null
        $romm = "$base\Playnite\Extensions\RomM_9700aa21-447d-41b4-a989-acd38f407d9f\RomM.dll"
        Get-Content $romm | Should -Be 'romm de outra versao'
        Test-Path "$romm.original" | Should -BeFalse
    }

    It 'sem nenhum caminho ate o servidor mantem o ultimo endereco e nao mexe nos mapeamentos' {
        $fechada = "http://127.0.0.1:$(Get-PortaFechada)"
        $base = New-Instalacao -Lan $fechada -Tailscale $fechada
        Invoke-Launcher $base | Out-Null
        $cfg = Get-Content "$base\romm.json" -Raw | ConvertFrom-Json
        $cfg.RomMHost | Should -Be 'http://antigo'
        @($cfg.Mappings).Count | Should -Be 1
    }

    It 'abre em tela cheia quando configurado' {
        $base = New-Instalacao
        $L = Get-Content "$base\launcher.json" -Raw | ConvertFrom-Json
        $L.fullscreen = $true
        Write-Utf8 "$base\launcher.json" ($L | ConvertTo-Json -Depth 5)
        Get-Content (Invoke-Launcher $base) | Should -Be 'Playnite.FullscreenApp.exe|'
    }
}

Describe 'Funcoes do launcher' {
    BeforeAll { . (Get-Funcao $Launcher 'Test-Porta', 'Out-Utf8') }

    It 'Test-Porta' {
        Test-Porta $Romm.Url 1000 | Should -BeTrue
        Test-Porta "http://127.0.0.1:$(Get-PortaFechada)" 1000 | Should -BeFalse
        Test-Porta $null 1000 | Should -BeFalse
    }

    It 'Out-Utf8 grava sem BOM e com acentos' {
        $f = Join-Path $TestDrive 'x.json'
        $acao = "a$([char]0xE7)$([char]0xE3)o"
        $acao, 'b' | Out-Utf8 $f
        [IO.File]::ReadAllBytes($f)[0] | Should -Be ([byte][char]'a')
        [IO.File]::ReadAllText($f) | Should -Be "$acao`r`nb`r`n"
    }
}
