# recomp.ps1 rodando como o plugin Recomps chama (Windows PowerShell 5.1, processo separado), contra o
# servidor de teste no lugar do RomM e do GitHub.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    function Get-Sha256Hex($arquivo) { (Get-FileHash -LiteralPath $arquivo -Algorithm SHA256).Hash }

    function New-ZipTeste($caminho, [hashtable]$entradas) {
        $z = [IO.Compression.ZipFile]::Open($caminho, 'Create')
        try {
            foreach ($k in $entradas.Keys) {
                $s = $z.CreateEntry($k).Open()
                $b = [Text.Encoding]::UTF8.GetBytes($entradas[$k])
                $s.Write($b, 0, $b.Length); $s.Dispose()
            }
        } finally { $z.Dispose() }
    }

    # GitHub falso (sem login): uma release por repo t/<nome>, com o zip e o SHA-256 dele.
    $Gh = Join-Path $TestDrive 'gh'
    New-Item $Gh -ItemType Directory -Force | Out-Null
    $GitHub = Start-ServidorTeste -Pasta $Gh
    New-ZipTeste "$Gh\ok.zip" @{ 'Jogo/pronto.txt' = 'pronto'; 'Jogo/jogo.exe' = 'exe' }
    New-ZipTeste "$Gh\fora.zip" @{ 'Jogo/pronto.txt' = 'pronto'; '../../fora.txt' = 'zip-slip' }
    # Tipo "comando": um exe de verdade (sai com o codigo do 1o argumento e, com o 2o, grava esse arquivo).
    $Fw = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319"
    Write-Utf8 "$TestDrive\prep.cs" 'class P { static int Main(string[] a) { if (a.Length > 1) { System.IO.File.WriteAllText(a[1], "ok"); } return int.Parse(a[0]); } }'
    $null = & "$Fw\csc.exe" /nologo /target:exe "/out:$TestDrive\prep.exe" "$TestDrive\prep.cs"
    $z = [IO.Compression.ZipFile]::Open("$Gh\cmd.zip", 'Create')
    try {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, "$TestDrive\prep.exe", 'Jogo/ferramentas/prep.exe')
        $s = $z.CreateEntry('Jogo/jogo.exe').Open(); $s.WriteByte(1); $s.Dispose()
    } finally { $z.Dispose() }
    foreach ($r in @(@('ok', 'ok', $null), @('sha', 'ok', ('0' * 64)), @('fora', 'fora', $null), @('cmd', 'cmd', $null))) {
        $zip = "$Gh\$($r[1]).zip"
        $sha = if ($r[2]) { $r[2] } else { (Get-Sha256Hex $zip).ToLower() }
        $rel = @(@{ draft = $false; tag_name = 'v1'; assets = @(@{ name = "$($r[1])-win.zip"; size = (Get-Item $zip).Length; digest = "sha256:$sha"; browser_download_url = "$($GitHub.Url)/$($r[1]).zip" }) })
        Write-Utf8 "$Gh\api\repos\t\$($r[0])\releases" (ConvertTo-Json $rel -Depth 5)
    }

    # RomM falso (com login): a ROM 1.
    $Srv = Join-Path $TestDrive 'srv'
    Write-Utf8 "$Srv\saude" 'ok'
    $Rom = New-Object byte[] 4096
    (New-Object Random 7).NextBytes($Rom)
    $NomeRom = 'Jogo [teste].nsp'
    $Rom1 = @{ id = 1; platform_id = 9; fs_name = $NomeRom; fs_size_bytes = $Rom.Length; has_simple_single_file = $true; missing_from_fs = $false
        sha1_hash = ([BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash($Rom)) -replace '-', '').ToLower() }
    Write-Utf8 "$Srv\api\roms\1" (ConvertTo-Json $Rom1)
    $Servidor = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's'

    # Instalacao falsa: programa (recomp.ps1 com o GitHub trocado e os scripts que ele usa), launcher.json,
    # config do plugin do RomM com o mapeamento do Switch e a pasta dos Recomps.
    function New-Instalacao($url) {
        $b = Join-Path $TestDrive "base-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $prog = Join-Path $b 'programa'
        # (a versao fixa so aceita https; aqui, o http do servidor de teste)
        Copy-ScriptTrocado (Join-Path $Arquivos 'recomp.ps1') "$prog\recomp.ps1" @{ "`$GitHubApi = 'https://api.github.com'" = "`$GitHubApi = '$($GitHub.Url)/api'"
            "`$UrlFixa = '^https://'" = "`$UrlFixa = '^https?://'" }
        foreach ($s in 'baixar-worker.ps1', 'relato.ps1', 'instalacao.ps1', 'atualizador.ps1') { Copy-Item (Join-Path $Arquivos $s) $prog }
        $roms = Join-Path $b 'Roms\switch'
        Write-Utf8 "$b\romm.json" (ConvertTo-Json @{ RomMUsername = 'amigo'; RomMPassword = 's'; Mappings = @(@{ Enabled = $true; RomMPlatformId = 9; DestinationPath = $roms; InstallFlat = $false }) } -Depth 4)
        Write-Utf8 "$b\launcher.json" (ConvertTo-Json @{ lan = $url; rommConfig = "$b\romm.json"; mapas = @(@{ slug = 'switch'; destino = $roms }); jogos = @{ lan = $url; usuario = 'amigo'; senha = 's' } } -Depth 4)
        [pscustomobject]@{ Base = $b; Script = "$prog\recomp.ps1"; Recomps = "$b\Recomps"; Roms = $roms }
    }

    # Catalogo resolvido como o plugin grava (caminhos absolutos), com um jogo "t".
    function New-Config($inst, [hashtable]$jogo = @{}) {
        $r = $inst.Recomps
        $j = [ordered]@{ id = 't'; nome = 'Teste'; pasta = "$r\Jogo"; exe = 'jogo.exe'; pronto = 'pronto.txt'; manter = @(); repo = 't/ok'; asset = '-win\.zip$'
            achatar = $true; tipo = 'pronto'; precisa = @() }
        foreach ($k in $jogo.Keys) { $j[$k] = $jogo[$k] }
        [ordered]@{ base = $inst.Base; recomps = $r; raizes = @(); salvos = "$r\_saves"; downloads = "$r\_downloads"; pastaOrigem = "$r\_origem"; jogos = @($j) }
    }

    function Invoke-Recomp($inst, $acao, $cfg, [hashtable]$ambiente = @{}) {
        $arq = Join-Path $TestDrive "cfg-$([guid]::NewGuid()).json"
        Write-Utf8 $arq (ConvertTo-Json $cfg -Depth 8)
        $psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File `"$($inst.Script)`" -Acao $acao -Id `"$(@($cfg.jogos)[0].id)`" -Config `"$arq`" -Base `"$($inst.Base)`""
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        foreach ($k in $ambiente.Keys) { $psi.EnvironmentVariables[$k] = $ambiente[$k] }
        $p = [Diagnostics.Process]::Start($psi)
        $saida = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(240000)) { $p.Kill(); throw 'recomp.ps1 passou de 240 s' }
        @($saida.Result -split "`r?`n" | Where-Object { $_ })
    }

    function Get-Fim($linhas) { @($linhas | Where-Object { $_ -like 'OK: *' -or $_ -like 'ERRO: *' })[-1] }
}

AfterAll { Stop-ServidorTeste $Servidor; Stop-ServidorTeste $GitHub }

Describe 'recomp.ps1 -Acao verificar' {
    It 'sem prod.keys, RPCS3 e Python: FALTA de cada um, sem baixar nada' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'verificar' (New-Config $inst @{ precisa = @('keys', 'rpcs3', 'python') }) @{ PATH = "$env:SystemRoot\System32" }
        Get-Fim $l | Should -Be 'OK: verificado'
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: keys', 'FALTA: rpcs3', 'FALTA: python')
        @($l | Where-Object { $_ -match '^ESPACO: \d+ \d+ [A-Z]:$' }).Count | Should -Be 1
    }

    It 'pouco espaco: FALTA antes de baixar, e o instalar para sem baixar nada' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-Config $inst @{ espacoGb = 1000000; origem = 'rom'; romm = @{ id = 1; arquivo = $NomeRom } }
        $antes = @(Get-PedidoTeste $Servidor).Count
        $l = Invoke-Recomp $inst 'verificar' $cfg
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: espaco')
        $l = Invoke-Recomp $inst 'instalar' $cfg
        Get-Fim $l | Should -Match '^ERRO: falta: espaco'
        @(Get-PedidoTeste $Servidor | Select-Object -Skip $antes | Where-Object { $_ -match '/content/|/jogos/' }) | Should -BeNullOrEmpty
        Test-Path "$($inst.Recomps)\_origem" | Should -BeFalse
        Test-Path "$($inst.Recomps)\Jogo" | Should -BeFalse
    }

    It 'jogo que mudou no servidor: FALTA mudou' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'verificar' (New-Config $inst @{ origem = 'rom'; romm = @{ id = 1; arquivo = 'Outro nome.nsp' } })
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: mudou')
    }

    It 'servidor fora do ar: FALTA servidor' {
        $inst = New-Instalacao "http://127.0.0.1:$(Get-PortaFechada)"
        $l = Invoke-Recomp $inst 'verificar' (New-Config $inst @{ origem = 'rom'; romm = @{ id = 1; arquivo = $NomeRom } })
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: servidor')
    }
}

Describe 'recomp.ps1 -Acao instalar' {
    It 'ROM ja baixada no emulador vira link/copia em _origem; apagar a ROM depois nao quebra o Recomp' {
        $inst = New-Instalacao $Servidor.Url
        $arqRom = Join-Path $inst.Roms "Jogo [teste]\$NomeRom"
        New-Item (Split-Path $arqRom) -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllBytes($arqRom, $Rom)
        $antes = @(Get-PedidoTeste $Servidor).Count
        $l = Invoke-Recomp $inst 'instalar' (New-Config $inst @{ origem = 'rom'; romm = @{ id = 1; arquivo = $NomeRom } })
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v1) instalado'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\pronto.txt" | Should -BeTrue
        @(Get-PedidoTeste $Servidor | Select-Object -Skip $antes | Where-Object { $_ -match '/content/' }) | Should -BeNullOrEmpty
        $origem = "$($inst.Recomps)\_origem\t\$NomeRom"
        Remove-Item -LiteralPath $arqRom -Force
        [IO.File]::ReadAllBytes($origem).Length | Should -Be $Rom.Length
        (Get-Sha256Hex $origem) | Should -Be ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Rom)) -replace '-', '')
    }

    It 'zip do GitHub com SHA-256 errado: nada instalado' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Config $inst @{ repo = 't/sha' })
        Get-Fim $l | Should -Be 'ERRO: o arquivo baixado nao confere com o SHA-256 do GitHub'
        Test-Path "$($inst.Recomps)\Jogo" | Should -BeFalse
    }

    It 'zip com caminho para fora da pasta (zip-slip): nada instalado nem escrito fora' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Config $inst @{ repo = 't/fora' })
        Get-Fim $l | Should -Match '^ERRO: o zip tem um caminho fora da pasta'
        Test-Path "$($inst.Recomps)\Jogo" | Should -BeFalse
        @(Get-ChildItem $inst.Base -Recurse -Filter 'fora.txt') | Should -BeNullOrEmpty
    }
}

Describe 'recomp.ps1 arquivo direto v47a' {
    BeforeAll {
        function New-N64($inst, $dump = $null) {
            $j = @{ origem = 'rom'; plataforma = 'n64'; romm = @{ id = 2; arquivo = 'Jogo [teste].z64' }; pronto = '.recomp-pronto' }
            if ($dump) { $j.dump = $dump }
            $cfg = New-Config $inst $j
            $cfg.contrato = 2
            $cfg
        }
    }

    It 'recebe z64 em _origem sem tentar abrir como NSP, mesmo com colchetes no nome' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-N64 $inst
        $nome = $cfg.jogos[0].romm.arquivo
        $romN64 = $Rom1.Clone()
        $romN64.id = 2
        $romN64.fs_name = $nome
        Write-Utf8 "$Srv\api\roms\2" (ConvertTo-Json $romN64)
        $local = Join-Path $inst.Roms ([IO.Path]::Combine([IO.Path]::GetFileNameWithoutExtension($nome), $nome))
        New-Item -ItemType Directory -Force (Split-Path $local) | Out-Null
        [IO.File]::WriteAllBytes($local, $Rom)
        Get-Fim (Invoke-Recomp $inst 'instalar' $cfg) | Should -Be 'OK: Recomp de Teste (v1) instalado'
        Get-Sha256Hex "$($inst.Recomps)\_origem\t\$nome" | Should -Be (Get-Sha256Hex $local)
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeTrue
        . (Get-Funcao (Join-Path $Arquivos 'recomp.ps1') 'Format-Campos')
        { Format-Campos '{nsp}' ([pscustomobject]@{ dump = $local }) } | Should -Throw '*{nsp}*'
    }

    It 'recusa formato incompativel e nao baixa uma origem invalida' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-N64 $inst
        $cfg.jogos[0].romm.arquivo = 'Jogo.nsp'
        $antes = @(Get-PedidoTeste $Servidor).Count
        $l = Invoke-Recomp $inst 'verificar' $cfg
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: formato')
        @(Get-PedidoTeste $Servidor | Select-Object -Skip $antes) | Should -BeNullOrEmpty
    }

    It 'bloqueia plugin antigo antes de acessar o RomM' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-N64 $inst
        $cfg.Remove('contrato')
        $antes = @(Get-PedidoTeste $Servidor).Count
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Match '^ERRO: O Jogos Retro deste PC ainda .* terminou de se atualizar\.'
        @(Get-PedidoTeste $Servidor | Select-Object -Skip $antes) | Should -BeNullOrEmpty
    }

    It 'reconhece PS2 ISO do pacote mesmo quando a DLL velha perde a plataforma' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-Config $inst @{ origem = 'rom'; romm = @{ id = 2; arquivo = 'Jogo.iso' } }
        $pacote = New-Config $inst @{ origem = 'rom'; plataforma = 'ps2'; romm = @{ id = 2; arquivo = 'Jogo.iso' } }
        Write-Utf8 (Join-Path (Split-Path $inst.Script) 'recomps.json') (ConvertTo-Json $pacote -Depth 8)
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Match '^ERRO: O Jogos Retro deste PC ainda .* terminou de se atualizar\.'
    }

    It 'bloqueia DLL antiga quando o Jogar usa caminho sem aspas que a DLL nova precisa cotar' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-Config $inst @{ args = '-Pasta {pasta}' }
        $pacote = New-Config $inst @{ plataforma = 'ps3'; args = '-Pasta {pasta}' }
        Write-Utf8 (Join-Path (Split-Path $inst.Script) 'recomps.json') (ConvertTo-Json $pacote -Depth 8)
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Match '^ERRO: O Jogos Retro deste PC ainda .* terminou de se atualizar\.'
        $cfg.contrato = 2
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Be 'OK: verificado'
    }

    It 'permite plugin antigo com origem legada <Plataforma> <Ext> mesmo se o pacote grava a plataforma' -TestCases @(
        @{ Plataforma = 'switch'; Ext = '.nsp'; Campo = 'nsp' }
        @{ Plataforma = 'ps3'; Ext = '.iso'; Campo = 'iso' }
    ) {
        $inst = New-Instalacao $Servidor.Url
        $nome = 'Jogo' + $Ext
        $j = @{ origem = 'rom'; plataforma = $Plataforma; romm = @{ id = 2; arquivo = $nome } }
        $arquivo = Join-Path $inst.Base $nome
        [IO.File]::WriteAllBytes($arquivo, $Rom)
        $j[$Campo] = $arquivo
        $cfg = New-Config $inst $j
        Write-Utf8 (Join-Path (Split-Path $inst.Script) 'recomps.json') (ConvertTo-Json $cfg -Depth 8)
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Be 'OK: verificado'
        $cfg.jogos[0].Remove('plataforma')
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Be 'OK: verificado'
    }

    It 'recomps.json do programa estragado: plugin antigo decide so pela entrada recebida, sem erro tecnico' {
        $inst = New-Instalacao $Servidor.Url
        $arquivo = Join-Path $inst.Base 'Jogo.nsp'
        [IO.File]::WriteAllBytes($arquivo, $Rom)
        $cfg = New-Config $inst @{ origem = 'rom'; romm = @{ id = 2; arquivo = 'Jogo.nsp' }; nsp = $arquivo }
        Write-Utf8 (Join-Path (Split-Path $inst.Script) 'recomps.json') '{ "jogos": [ { "id": "t", '
        Get-Fim (Invoke-Recomp $inst 'verificar' $cfg) | Should -Be 'OK: verificado'
        # (a entrada recebida ja e da v47a: continua bloqueada)
        $novo = New-N64 $inst
        $novo.Remove('contrato')
        Get-Fim (Invoke-Recomp $inst 'verificar' $novo) | Should -Match '^ERRO: O Jogos Retro deste PC ainda .* terminou de se atualizar\.'
    }

    It 'recusa romm.arquivo que nao e nome simples (<Nome>) antes de baixar ou linkar' -TestCases @(
        @{ Nome = '..\fora.z64' }
        @{ Nome = 'sub\Jogo.z64' }
        @{ Nome = 'Jogo|x.z64' }
    ) {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-N64 $inst
        $cfg.jogos[0].romm.arquivo = $Nome
        $antes = @(Get-PedidoTeste $Servidor).Count
        Get-Fim (Invoke-Recomp $inst 'instalar' $cfg) | Should -BeLike 'ERRO: catalogo com um arquivo do RomM que nao serve para nome de arquivo*avise o Neto'
        @(Get-PedidoTeste $Servidor | Select-Object -Skip $antes) | Should -BeNullOrEmpty
        Test-Path "$($inst.Recomps)\_origem" | Should -BeFalse
        Test-Path "$($inst.Recomps)\Jogo" | Should -BeFalse
    }

    It 'Test-NomeSimples aceita so nome de arquivo sem pasta' {
        . (Get-Funcao (Join-Path $Arquivos 'recomp.ps1') 'Test-NomeSimples')
        foreach ($ok in 'Jogo [teste].z64', 'Metroid(TM) v1.0.iso') { Test-NomeSimples $ok | Should -BeTrue -Because $ok }
        foreach ($ruim in '', '.', '..', '..\a.z64', 'a/b.z64', 'C:\a.z64', 'a:b.z64', 'a?.z64', "a`0.z64") { Test-NomeSimples $ruim | Should -BeFalse -Because $ruim }
    }

    It 'verifica BIOS do PS2 pelo INI se houver mais de um arquivo' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-Config $inst @{ plataforma = 'ps2'; precisa = @('bios'); pronto = '.recomp-pronto' }
        $cfg.contrato = 2
        $pcsx2 = Join-Path $inst.Base 'Emuladores\PCSX2'
        foreach ($nome in 'a.bin', 'b.bin') { Write-Utf8 "$pcsx2\bios\$nome" 'dados falsos' }
        @(Invoke-Recomp $inst 'verificar' $cfg | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: bios')
        Write-Utf8 "$pcsx2\inis\PCSX2.ini" "[Filenames]`r`nBIOS = b.bin"
        @(Invoke-Recomp $inst 'verificar' $cfg | Where-Object { $_ -like 'FALTA: *' }) | Should -BeNullOrEmpty
    }

    It 'verifica marcador do firmware de <Plataforma> e encaminha requisito desconhecido' -TestCases @(
        @{ Plataforma = 'switch'; Marcador = 'Emuladores\Eden\user\nand\system\Contents\registered\teste.nca' }
        @{ Plataforma = 'ps3'; Marcador = 'Emuladores\RPCS3\dev_flash\vsh\etc\version.txt' }
    ) {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-Config $inst @{ plataforma = $Plataforma; precisa = @('firmware', 'teste-futuro') }
        $cfg.contrato = 2
        @(Invoke-Recomp $inst 'verificar' $cfg | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: firmware', 'FALTA: teste-futuro')
        Write-Utf8 (Join-Path $inst.Base $Marcador) 'dados falsos'
        @(Invoke-Recomp $inst 'verificar' $cfg | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: teste-futuro')
    }

    It 'o comando que altera o dump falha e nao marca o Recomp' {
        $inst = New-Instalacao $Servidor.Url
        $dump = Join-Path $inst.Base 'Jogo [teste].z64'
        [IO.File]::WriteAllBytes($dump, $Rom)
        $cfg = New-N64 $inst $dump
        $j = $cfg.jogos[0]
        $j.repo = 't/cmd'
        $j.tipo = 'comando'
        $j.preparo = @{ exe = 'ferramentas\prep.exe'; args = @('0', '{dump}') }
        Get-Fim (Invoke-Recomp $inst 'instalar' $cfg) | Should -Match '^ERRO: O arquivo do jogo mudou durante a prepara'
        Test-Path -LiteralPath (Join-Path $j.pasta $j.pronto) | Should -BeFalse
    }

    It 'o verificador de origem detecta mudanca de data e desaparecimento do arquivo' {
        $arquivo = Join-Path $TestDrive 'estado [z64].z64'
        [IO.File]::WriteAllBytes($arquivo, $Rom)
        $item = Get-Item -LiteralPath $arquivo
        $origem = [pscustomobject]@{ Caminho = $arquivo; Tamanho = $item.Length; Data = $item.LastWriteTimeUtc }
        . (Get-Funcao (Join-Path $Arquivos 'recomp.ps1') 'Assert-OrigemIgual')
        { Assert-OrigemIgual $origem $false } | Should -Not -Throw
        [IO.File]::SetLastWriteTimeUtc($arquivo, $origem.Data.AddMinutes(-1))
        { Assert-OrigemIgual $origem $false } | Should -Throw '*arquivo do jogo mudou*'
        Remove-Item -LiteralPath $arquivo
        { Assert-OrigemIgual $origem $true } | Should -Throw '*arquivo do jogo mudou*'
    }
}

Describe 'recomp.ps1 tipos genericos (pronto e comando)' {
    BeforeAll {
        function New-Comando($inst, $preparo) {
            New-Config $inst @{ repo = 't/cmd'; pronto = '.recomp-pronto'; tipo = 'comando'; preparo = $preparo }
        }
    }

    It 'pronto: so extrai e grava a marca .recomp-pronto' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Config $inst @{ pronto = '.recomp-pronto' })
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v1) instalado'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeTrue
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\pronto.txt" | Should -BeTrue
    }

    It 'extrai em <Recomps>\_tmp\<id>: a pasta "<pasta>.tmp" de outro Recomp nao e apagada' {
        $inst = New-Instalacao $Servidor.Url
        Write-Utf8 "$($inst.Recomps)\Jogo.tmp\save.bin" 'progresso de outro Recomp'
        $l = Invoke-Recomp $inst 'instalar' (New-Config $inst @{ pronto = '.recomp-pronto' })
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v1) instalado'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo.tmp\save.bin" | Should -BeTrue
        Test-Path -LiteralPath "$($inst.Recomps)\_tmp\t" | Should -BeFalse
    }

    It 'comando: catalogo sem preparo ou com exe que nao serve (nao .exe, ":" de fluxo do NTFS) para antes de baixar' {
        $inst = New-Instalacao $Servidor.Url
        foreach ($p in @($null, @{ exe = 'prep.bat' }, @{ exe = 'jogo.exe:escondido.exe' }, @{ exe = 'C:prep.exe' })) {
            $antes = @(Get-PedidoTeste $GitHub).Count
            $cfg = New-Config $inst @{ repo = 't/cmd'; pronto = '.recomp-pronto'; tipo = 'comando' }
            if ($p) { $cfg.jogos[0].preparo = $p }
            Get-Fim (Invoke-Recomp $inst 'instalar' $cfg) | Should -Match '^ERRO: (catalogo sem o preparo|o preparo aponta para fora)' -Because "$($p.exe)"
            @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes | Where-Object { $_ -match 'cmd\.zip' }) | Should -BeNullOrEmpty
        }
        Test-Path "$($inst.Recomps)\Jogo" | Should -BeFalse
    }

    It 'Format-Argumento segue o CommandLineToArgvW (aspas e barras)' {
        . (Get-Funcao (Join-Path $Arquivos 'recomp.ps1') 'Format-Argumento')
        Add-Type -Namespace RecompTeste -Name Argv -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CommandLineToArgvW(string linha, out int n);
[DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
public static string[] Separar(string linha) {
    int n; var p = CommandLineToArgvW(linha, out n); var r = new string[n];
    for (var i = 0; i < n; i++) { r[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size)); }
    LocalFree(p); return r;
}
'@
        $casos = @('simples', 'com espaco', 'C:\pasta com espaco\', 'a"b', 'a\"b', 'fim\\', '"', '', 'x\y z\\"w')
        $linha = 'prep.exe ' + (@($casos | ForEach-Object { Format-Argumento $_ }) -join ' ')
        $volta = [RecompTeste.Argv]::Separar($linha)
        $volta.Count | Should -Be ($casos.Count + 1)
        for ($i = 0; $i -lt $casos.Count; $i++) { $volta[$i + 1] | Should -BeExactly $casos[$i] -Because $casos[$i] }
    }

    It 'comando: roda o exe de dentro da pasta com os campos trocados, na etapa instalando, e so no fim grava a marca' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Comando $inst @{ exe = 'ferramentas\prep.exe'; args = @('0', '{pasta}\gerado dentro.txt'); etapa = 'gerando o jogo'; minutos = 5 })
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v1) instalado'
        $l | Should -Contain 'ETAPA: instalando: gerando o jogo (uns 5 minutos)'
        [IO.File]::ReadAllText("$($inst.Recomps)\Jogo\gerado dentro.txt") | Should -Be 'ok'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeTrue
    }

    It 'comando com saida diferente de 0: erro e nada de marca' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Comando $inst @{ exe = 'ferramentas\prep.exe'; args = @('3') })
        Get-Fim $l | Should -Match '^ERRO: o preparo \(ferramentas\\prep\.exe\) terminou com codigo 3'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
    }

    It 'comando com exe fora da pasta do Recomp: recusado sem rodar' {
        $inst = New-Instalacao $Servidor.Url
        foreach ($exe in '..\..\prep.exe', "$env:SystemRoot\System32\cmd.exe") {
            $l = Invoke-Recomp $inst 'instalar' (New-Comando $inst @{ exe = $exe; args = @('/c', 'exit 0') })
            Get-Fim $l | Should -Match '^ERRO: o preparo aponta para fora da pasta do Recomp' -Because $exe
            Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
        }
    }

    It 'comando com campo desconhecido ou sem valor: erro antes de rodar' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Comando $inst @{ exe = 'ferramentas\prep.exe'; args = @('0', '{outro}\x.txt') })
        Get-Fim $l | Should -Match '^ERRO: o preparo usa um campo desconhecido: \{outro\}'
        $l = Invoke-Recomp $inst 'instalar' (New-Comando $inst @{ exe = 'ferramentas\prep.exe'; args = @('0', '{nsp}') })
        Get-Fim $l | Should -Match '^ERRO: o preparo usa \{nsp\}'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
    }

    It 'tipo desconhecido: erro, nunca "instalado" sem preparar' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'instalar' (New-Config $inst @{ tipo = 'outro'; pronto = '.recomp-pronto' })
        Get-Fim $l | Should -Be 'ERRO: tipo desconhecido no catalogo: outro; avise o Neto'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
    }
}

Describe 'recomp.ps1 Remove-Seguro' {
    It 'so apaga dentro das raizes; nunca raiz de drive, _saves, programa, emuladores ou pasta de ROMs' {
        $inst = New-Instalacao $Servidor.Url
        $r = $inst.Recomps
        $script = @'
param($Ajuda, $Recomp, $R, $Base, $Roms)
Import-Module $Ajuda
. (Get-Funcao $Recomp 'Test-Dentro', 'Test-PodeApagar')
$script:Raizes = @($R); $script:PastasJogos = @('D:\Fora\WeepingOfTheEmpire')
$script:Proibidas = @("$Base\programa", "$Base\Emuladores", "$R\_saves", "$R\_downloads", $Roms)
$casos = [ordered]@{ jogo = "$R\Jogo"; tmp = "$R\Jogo.tmp"; pastaDoCatalogo = 'D:\Fora\WeepingOfTheEmpire'; raiz = $R; drive = 'C:\'; saves = "$R\_saves\t"
    origem = "$R\_origem\t"; fora = 'D:\Fora\Outro'; programa = "$Base\programa"; base = $Base; roms = "$Roms\Jogo" }
$saida = [ordered]@{}
foreach ($k in $casos.Keys) { $saida[$k] = [bool](Test-PodeApagar $casos[$k]) }
$saida | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\seguro.ps1" $script
        $saida = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\seguro.ps1" (Join-Path $PSScriptRoot '..\Ajuda.psm1') (Join-Path $Arquivos 'recomp.ps1') $r $inst.Base $inst.Roms
        $c = ($saida -join '') | ConvertFrom-Json
        $c.jogo | Should -BeTrue
        $c.tmp | Should -BeTrue
        $c.pastaDoCatalogo | Should -BeTrue
        foreach ($k in 'raiz', 'drive', 'saves', 'origem', 'fora', 'programa', 'base', 'roms') { $c.$k | Should -BeFalse -Because $k }
    }

    It 'desinstalar recusa apagar a raiz do drive' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Recomp $inst 'desinstalar' (New-Config $inst @{ pasta = "$env:SystemDrive\" })
        Get-Fim $l | Should -Match '^ERRO: recusei apagar'
    }
}

Describe 'recomp.ps1 tipo triforce (versao fixa com SHA-256 no catalogo)' {
    BeforeAll {
        # Python falso do Triforce-Tools.zip: le o roteiro (TRIFORCE_ROTEIRO), imprime as linhas do modo (check ou build),
        # "exit N" da o codigo e "touch <arquivo>" mexe no arquivo; anota os argumentos em TRIFORCE_ARGS. Sem a entrada
        # fechada (ReadToEnd) ou fora da pasta tools, o teste trava ou falha.
        Write-Utf8 "$TestDrive\pyfalso.cs" @'
using System; using System.IO;
class P {
    static int Main(string[] a) {
        var modo = Array.IndexOf(a, "--check") >= 0 ? "check" : "build";
        var reg = Environment.GetEnvironmentVariable("TRIFORCE_ARGS");
        if (reg != null) { File.AppendAllText(reg, modo + ": " + string.Join(" ", a) + "\r\n"); }
        Console.In.ReadToEnd();
        if (!File.Exists(@"nx2\make_game.py")) { Console.WriteLine("@@error fora da pasta tools"); return 9; }
        var i = Array.IndexOf(a, "--out");
        if (modo == "build" && i >= 0) { Directory.CreateDirectory(a[i + 1]); File.WriteAllText(Path.Combine(a[i + 1], "Triforce.exe"), "x"); }
        var codigo = 0;
        foreach (var l in File.ReadAllLines(Environment.GetEnvironmentVariable("TRIFORCE_ROTEIRO"))) {
            if (!l.StartsWith(modo + " ")) { continue; }
            var resto = l.Substring(modo.Length + 1);
            if (resto.StartsWith("exit ")) { codigo = int.Parse(resto.Substring(5)); }
            else if (resto.StartsWith("touch ")) { using (var f = File.Open(resto.Substring(6), FileMode.Append)) { f.WriteByte(1); } }
            else { Console.WriteLine(resto); }
        }
        return codigo;
    }
}
'@
        $null = & "$Fw\csc.exe" /nologo /target:exe "/out:$TestDrive\pyfalso.exe" "$TestDrive\pyfalso.cs"
        $z = [IO.Compression.ZipFile]::Open("$Gh\triforce.zip", 'Create')
        try {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, "$TestDrive\pyfalso.exe", 'tools/python/python.exe')
            $s = $z.CreateEntry('tools/nx2/make_game.py').Open(); $s.WriteByte(35); $s.Dispose()
        } finally { $z.Dispose() }
        $ShaTri = Get-Sha256Hex "$Gh\triforce.zip"
        $TamTri = (Get-Item "$Gh\triforce.zip").Length
        # (para a queda de conexao: um arquivo maior que o -CairApos)
        $Grande = New-Object byte[] (3MB)
        (New-Object Random 3).NextBytes($Grande)
        [IO.File]::WriteAllBytes("$Gh\grande.zip", $Grande)
        $NomeNup = 'Jogo [TITULO-TESTE][v2].nup'

        # Um .nup proprio por teste (o "touch" mexe nele), com data antiga para a conferencia de data valer.
        function New-Nup($inst, $nome = $NomeNup) {
            $arq = Join-Path $inst.Base "servidor\$nome"
            [void][IO.Directory]::CreateDirectory((Split-Path $arq))
            [IO.File]::WriteAllBytes($arq, [byte[]](1..200))
            [IO.File]::SetLastWriteTimeUtc($arq, [datetime]'2026-01-02T03:04:05Z')
            $arq
        }

        function New-Triforce($inst, $nup, [hashtable]$fixa = @{}) {
            $f = [ordered]@{ versao = 'v9'; titulo = 'TITULO-TESTE'; versaoJogo = 'v2'; versaoJogoTexto = 'o jogo na versao v2 (build 00000000)'
                arquivos = @([ordered]@{ nome = 'Triforce-Tools.zip'; url = "$($GitHub.Url)/triforce.zip"; tamanho = $TamTri; sha256 = $ShaTri.ToLower() }) }
            foreach ($k in $fixa.Keys) { $f[$k] = $fixa[$k] }
            New-Config $inst @{ gameId = ''; tipo = 'triforce'; pronto = '.recomp-pronto'; exe = 'Triforce.exe'; manter = @('user', 'triforce_options.ini'); semEmulador = $true
                espacoGb = 0.001; nup = $nup; fixa = $f; avisoInstalar = 'Demora.' }
        }

        function Invoke-Triforce($inst, $cfg, [string[]]$roteiro) {
            $arqRoteiro = Join-Path $inst.Base 'roteiro.txt'
            [IO.File]::WriteAllLines($arqRoteiro, $roteiro)
            Invoke-Recomp $inst 'instalar' $cfg @{ TRIFORCE_ROTEIRO = $arqRoteiro; TRIFORCE_ARGS = (Join-Path $inst.Base 'args.txt') }
        }

        function Get-Args($inst) { $a = Join-Path $inst.Base 'args.txt'; if (Test-Path $a) { @(Get-Content $a) } else { @() } }

        $Feliz = @('check @@check ok This is the version Triforce supports (build 00000000).', 'build @@stage read Reading your game files', 'build @@progress 0.5',
            'build @@stage lift Translating the game to PC code', 'build @@stage compile Compiling', 'build @@progress 1e-05', 'build @@plan 3 10',
            'build @@stage finish Putting the game folder together', 'build @@stage shaders Preparing shaders', 'build @@done X')
    }

    It 'instala sem tela: confere a versao, monta com --no-renodx, mostra as 5 etapas em portugues, devolve os saves e so no fim grava a marca' {
        $inst = New-Instalacao $Servidor.Url
        $nup = New-Nup $inst
        Write-Utf8 "$($inst.Recomps)\_saves\t\user\save\1\slot.bin" 'save guardado'
        Write-Utf8 "$($inst.Recomps)\_saves\t\triforce_options.ini" 'opcao=1'
        $antes = @(Get-PedidoTeste $GitHub).Count
        $l = Invoke-Triforce $inst (New-Triforce $inst $nup) $Feliz
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v9) instalado'
        $etapas = @($l | Where-Object { $_ -like 'ETAPA: *' })
        $etapas | Should -Contain "ETAPA: baixando: Triforce-Tools.zip ($([math]::Round($TamTri / 1MB)) MB)"
        $etapas | Should -Contain 'ETAPA: preparando: conferindo Triforce-Tools.zip'
        $etapas | Should -Contain 'ETAPA: extraindo: Triforce v9'
        $etapas | Should -Contain 'ETAPA: conferindo: a versao do jogo'
        foreach ($e in 'compilando: etapa 1 de 5: lendo os arquivos do jogo', 'compilando: etapa 2 de 5: traduzindo o jogo para codigo de PC',
            'compilando: etapa 3 de 5: compilando o jogo (a etapa mais longa, uns 35 minutos)', 'compilando: etapa 4 de 5: montando a pasta do jogo',
            'compilando: etapa 5 de 5: preparando os shaders (de minutos a mais de 1 hora)') { $etapas | Should -Contain "ETAPA: $e" }
        # (o texto do Triforce nunca vai para o card)
        @($etapas | Where-Object { $_ -match 'Reading|Translating|Compiling|Putting|Preparing' }) | Should -BeNullOrEmpty
        $l | Should -Contain 'PROGRESSO: 500 1000'
        $l | Should -Contain 'PROGRESSO: 0 1000'
        $l | Should -Not -Contain 'AVISO: shaders'
        $chamadas = Get-Args $inst
        $chamadas.Count | Should -Be 2
        $chamadas[0] | Should -Match '^check: -I -u nx2\\make_game\.py --check --nup .*\.nup --work '
        $chamadas[1] | Should -Match '^build: -I -u nx2\\make_game\.py --nup .*\.nup --out .*\\Jogo --work .* --no-renodx --log '
        @($chamadas | Where-Object { $_ -match '--fsr|--fetch-ngx-sdk' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeTrue
        [IO.File]::ReadAllText("$($inst.Recomps)\Jogo\user\save\1\slot.bin") | Should -Be 'save guardado'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\triforce_options.ini" | Should -BeTrue
        # (ferramentas fora da pasta do jogo; _tmp apagado; .nup intacto; nada do GitHub: a versao fixa nao procura release)
        Test-Path -LiteralPath "$($inst.Recomps)\_downloads\triforce-v9\tools\python\python.exe" | Should -BeTrue
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\python" | Should -BeFalse
        Test-Path -LiteralPath "$($inst.Recomps)\_tmp\t" | Should -BeFalse
        (Get-Item -LiteralPath $nup).Length | Should -Be 200
        (Get-Item -LiteralPath $nup).LastWriteTimeUtc | Should -Be ([datetime]'2026-01-02T03:04:05Z').ToUniversalTime()
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes | Where-Object { $_ -match '/api/' }) | Should -BeNullOrEmpty
    }

    It 'shaders nao preparados: instala e manda AVISO: shaders antes do OK' {
        $inst = New-Instalacao $Servidor.Url
        $roteiro = @($Feliz | Where-Object { $_ -notlike '*@@done*' }) + 'build the shaders were not prepared now (out of memory): the game prepares them at its first start' + 'build @@done X'
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst)) $roteiro
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v9) instalado'
        [array]::IndexOf($l, 'AVISO: shaders') | Should -BeGreaterThan -1
        [array]::IndexOf($l, 'AVISO: shaders') | Should -BeLessThan ([array]::IndexOf($l, (Get-Fim $l)))
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeTrue
    }

    It 'zip ja baixado com o SHA-256 certo e ferramentas ja extraidas: nao baixa nem extrai de novo' {
        $inst = New-Instalacao $Servidor.Url
        $nup = New-Nup $inst
        $cfg = New-Triforce $inst $nup
        Get-Fim (Invoke-Triforce $inst $cfg $Feliz) | Should -Match '^OK: '
        Remove-Item -LiteralPath "$($inst.Recomps)\Jogo" -Recurse -Force
        $antes = @(Get-PedidoTeste $GitHub).Count
        $l = Invoke-Triforce $inst $cfg $Feliz
        Get-Fim $l | Should -Be 'OK: Recomp de Teste (v9) instalado'
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes) | Should -BeNullOrEmpty
        @($l | Where-Object { $_ -like 'ETAPA: baixando*' -or $_ -like 'ETAPA: extraindo*' }) | Should -BeNullOrEmpty
    }

    It '@@check bad: para antes de montar, com a versao que precisa e a resposta do Triforce' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst)) @('check @@check bad This dump is v1, Triforce needs v2.', 'build @@done X')
        Get-Fim $l | Should -Be 'ERRO: o arquivo do jogo nao e a versao que o Triforce aceita. Precisa: o jogo na versao v2 (build 00000000). Resposta do Triforce: This dump is v1, Triforce needs v2.. Nada foi montado e o arquivo do jogo nao foi alterado.'
        @(Get-Args $inst | Where-Object { $_ -like 'build:*' }) | Should -BeNullOrEmpty
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo" | Should -BeFalse
    }

    It '@@error: erro com a etapa em portugues e o texto do Triforce (sem "closing" inteiro), nada de marca' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst)) @($Feliz[0], 'build @@stage read x', 'build @@stage lift x', 'build @@error compiler crashed while closing files', 'build exit 3')
        $fim = Get-Fim $l
        $fim | Should -Match '^ERRO: a montagem do jogo parou na etapa 2 de 5 \(traduzindo o jogo para codigo de PC\)\. O Triforce disse: compiler crashed while clos.ing files\. Detalhes em .*make_game-t\.log$'
        $fim | Should -Not -Match 'closing'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
    }

    It 'codigo diferente de 0 sem @@error, ou 0 sem @@done: erro com o codigo e nada de marca' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst)) @($Feliz[0], 'build @@stage read x', 'build exit 5')
        Get-Fim $l | Should -Match '^ERRO: o Triforce terminou com codigo 5 sem dizer o motivo\. Detalhes em '
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst)) @($Feliz[0], 'build @@stage read x')
        Get-Fim $l | Should -Match '^ERRO: o Triforce terminou com codigo 0 sem dizer o motivo\.'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
    }

    It '.nup com tamanho ou data diferentes depois da montagem: erro e nada de marca' {
        $inst = New-Instalacao $Servidor.Url
        $nup = New-Nup $inst
        $l = Invoke-Triforce $inst (New-Triforce $inst $nup) @($Feliz[0], "build touch $nup", 'build @@done X')
        Get-Fim $l | Should -Be 'ERRO: o arquivo do jogo (.nup) mudou durante a montagem (tamanho ou data). Nada foi marcado como instalado. Avise o Neto.'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo\.recomp-pronto" | Should -BeFalse
    }

    It 'zip com SHA-256 diferente do fixado: apaga o arquivo e nao instala' {
        $inst = New-Instalacao $Servidor.Url
        $f = @{ arquivos = @(@{ nome = 'Triforce-Tools.zip'; url = "$($GitHub.Url)/triforce.zip"; tamanho = $TamTri; sha256 = ('0' * 64) }) }
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst) $f) $Feliz
        Get-Fim $l | Should -Be 'ERRO: o Triforce-Tools.zip baixado nao confere com o SHA-256 fixado no recomps.json; apaguei o arquivo e nao instalei. Avise o Neto.'
        @(Get-ChildItem -LiteralPath "$($inst.Recomps)\_downloads\triforce-v9" -Force) | Should -BeNullOrEmpty
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo" | Should -BeFalse
        Get-Args $inst | Should -BeNullOrEmpty
    }

    It 'conexao cai no meio do download: erro, so sobra o .parcial' {
        $cai = Start-ServidorTeste -Pasta $Gh -CairApos 1000000
        try {
            $inst = New-Instalacao $Servidor.Url
            $f = @{ arquivos = @(@{ nome = 'Triforce-Tools.zip'; url = "$($cai.Url)/grande.zip"; tamanho = $Grande.Length; sha256 = ('0' * 64) }) }
            $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst) $f) $Feliz
            Get-Fim $l | Should -Match '^ERRO: '
            @(Get-ChildItem -LiteralPath "$($inst.Recomps)\_downloads\triforce-v9" -Force | ForEach-Object Name) | Should -Be @('Triforce-Tools.zip.parcial')
            Test-Path -LiteralPath "$($inst.Recomps)\Jogo" | Should -BeFalse
        } finally { Stop-ServidorTeste $cai }
    }

    It 'nome do .nup com outra versao: para antes de baixar, dizendo a que precisa e a encontrada' {
        $inst = New-Instalacao $Servidor.Url
        $antes = @(Get-PedidoTeste $GitHub).Count
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst 'Jogo [TITULO-TESTE][v1].nup')) $Feliz
        Get-Fim $l | Should -Be 'ERRO: o arquivo do jogo nao e a versao que o Triforce aceita. Precisa: o jogo na versao v2 (build 00000000) [TITULO-TESTE][v2]. Encontrado: Jogo [TITULO-TESTE][v1].nup. Nada foi montado e o arquivo do jogo nao foi alterado.'
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes) | Should -BeNullOrEmpty
        Test-Path -LiteralPath "$($inst.Recomps)\_downloads" | Should -BeFalse
    }

    It '.nup ausente (ou servidor que nao responde na 445): FALTA nup, sem baixar nada; verificar com gameId vazio funciona' {
        $inst = New-Instalacao $Servidor.Url
        $antes = @(Get-PedidoTeste $GitHub).Count
        $cfg = New-Triforce $inst (Join-Path $inst.Base "servidor\$NomeNup")
        $l = Invoke-Recomp $inst 'verificar' $cfg
        Get-Fim $l | Should -Be 'OK: verificado'
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: nup')
        Get-Fim (Invoke-Triforce $inst $cfg $Feliz) | Should -Be 'ERRO: falta: nup'
        # (endereco de documentacao, que nao responde: a porta 445 corta em ~3 s)
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        $l = Invoke-Recomp $inst 'verificar' (New-Triforce $inst "\\192.0.2.1\jogos\$NomeNup")
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -Be @('FALTA: nup')
        $relogio.Elapsed.TotalSeconds | Should -BeLessThan 20
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes) | Should -BeNullOrEmpty
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo" | Should -BeFalse
    }

    It 'verificar com o .nup presente: soma o tamanho fixo do zip (sem perguntar ao GitHub) e nada falta' {
        $inst = New-Instalacao $Servidor.Url
        $antes = @(Get-PedidoTeste $GitHub).Count
        $l = Invoke-Recomp $inst 'verificar' (New-Triforce $inst (New-Nup $inst))
        @($l | Where-Object { $_ -like 'FALTA: *' }) | Should -BeNullOrEmpty
        $precisa = [long](@($l | Where-Object { $_ -like 'ESPACO: *' })[0] -split ' ')[1]
        $precisa | Should -Be ($TamTri + [long](0.001 * 1GB))
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes) | Should -BeNullOrEmpty
    }

    It 'remover: guarda user e triforce_options.ini em _saves e apaga a pasta' {
        $inst = New-Instalacao $Servidor.Url
        $cfg = New-Triforce $inst (New-Nup $inst)
        Get-Fim (Invoke-Triforce $inst $cfg $Feliz) | Should -Match '^OK: '
        Write-Utf8 "$($inst.Recomps)\Jogo\user\save\1\slot.bin" 'meu save'
        Write-Utf8 "$($inst.Recomps)\Jogo\triforce_options.ini" 'opcao=2'
        Get-Fim (Invoke-Recomp $inst 'desinstalar' $cfg) | Should -Match '^OK: Recomp de Teste desinstalado'
        [IO.File]::ReadAllText("$($inst.Recomps)\_saves\t\user\save\1\slot.bin") | Should -Be 'meu save'
        [IO.File]::ReadAllText("$($inst.Recomps)\_saves\t\triforce_options.ini") | Should -Be 'opcao=2'
        Test-Path -LiteralPath "$($inst.Recomps)\Jogo" | Should -BeFalse
        Test-Path -LiteralPath "$($inst.Recomps)\_downloads\triforce-v9\tools\python\python.exe" | Should -BeTrue
    }

    It '--check que sai com codigo sem nenhuma linha @@check: para antes de montar, com "nenhuma (saiu com codigo N)"' {
        $inst = New-Instalacao $Servidor.Url
        $l = Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst)) @('check exit 4', 'build @@done X')
        Get-Fim $l | Should -Be 'ERRO: o arquivo do jogo nao e a versao que o Triforce aceita. Precisa: o jogo na versao v2 (build 00000000). Resposta do Triforce: nenhuma (saiu com codigo 4). Nada foi montado e o arquivo do jogo nao foi alterado.'
        @(Get-Args $inst | Where-Object { $_ -like 'build:*' }) | Should -BeNullOrEmpty
    }

    It 'pasta do jogo fora da area dos Recomps ou id com caminho: recusa antes de baixar e sem rodar o make_game' {
        $inst = New-Instalacao $Servidor.Url
        $nup = New-Nup $inst
        $antes = @(Get-PedidoTeste $GitHub).Count
        foreach ($pasta in "$env:SystemDrive\", "$($inst.Recomps)\_saves\Jogo", "$($inst.Recomps)\_downloads\Jogo") {
            $cfg = New-Triforce $inst $nup
            $cfg.jogos[0].pasta = $pasta
            Get-Fim (Invoke-Triforce $inst $cfg $Feliz) | Should -Match '^ERRO: a pasta do Recomp \(.*\) esta fora da area dos Recomps; nada foi montado' -Because $pasta
        }
        foreach ($id in 'a..b', '..', 'a\b', 'a b') {
            $cfg = New-Triforce $inst $nup
            $cfg.jogos[0].id = $id
            Get-Fim (Invoke-Triforce $inst $cfg $Feliz) | Should -Match '^ERRO: catalogo com um id que nao serve para nome de pasta' -Because $id
        }
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes) | Should -BeNullOrEmpty
        Get-Args $inst | Should -BeNullOrEmpty
    }

    It 'versao fixa: recusa nome "." ou "..", nome com caminho e endereco que nao e https (o do pacote so aceita https)' {
        Get-Atribuicao (Join-Path $Arquivos 'recomp.ps1') 'UrlFixa' | Should -Be '^https://'
        $UrlFixa = Get-Atribuicao (Join-Path $Arquivos 'recomp.ps1') 'UrlFixa'
        . (Get-Funcao (Join-Path $Arquivos 'recomp.ps1') 'Test-Fixa')
        function New-Jogo($nome, $url) {
            [pscustomobject]@{ fixa = [pscustomobject]@{ versao = 'v1'; arquivos = @([pscustomobject]@{ nome = $nome; url = $url; tamanho = 1; sha256 = ('A' * 64) }) } }
        }
        { Test-Fixa (New-Jogo 'Triforce-Tools.zip' 'https://x/y.zip') } | Should -Not -Throw
        foreach ($c in @(@('.', 'https://x/y.zip'), @('..', 'https://x/y.zip'), @('a\b.zip', 'https://x/y.zip'), @('t.zip', 'http://x/y.zip'), @('t.zip', 'ftp://x/y.zip'), @('t.zip', ''))) {
            { Test-Fixa (New-Jogo $c[0] $c[1]) } | Should -Throw 'catalogo com um arquivo da versao fixa sem nome, endereco https ou SHA-256*' -Because "$($c[0]) $($c[1])"
        }
        { Test-Fixa ([pscustomobject]@{ fixa = [pscustomobject]@{ versao = '..'; arquivos = @() } }) } | Should -Throw 'catalogo sem a versao fixa*'
        # (no script que roda, tambem antes de baixar)
        $inst = New-Instalacao $Servidor.Url
        $f = @{ arquivos = @(@{ nome = '..'; url = "$($GitHub.Url)/triforce.zip"; tamanho = $TamTri; sha256 = $ShaTri }) }
        Get-Fim (Invoke-Triforce $inst (New-Triforce $inst (New-Nup $inst) $f) $Feliz) | Should -Match '^ERRO: catalogo com um arquivo da versao fixa'
    }

    It 'nao-regressao: sem "fixa" o recomp continua no Get-Release (GitHub)' {
        $inst = New-Instalacao $Servidor.Url
        $antes = @(Get-PedidoTeste $GitHub).Count
        Get-Fim (Invoke-Recomp $inst 'instalar' (New-Config $inst @{ pronto = '.recomp-pronto' })) | Should -Be 'OK: Recomp de Teste (v1) instalado'
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes | Where-Object { $_ -match '/api/repos/t/ok/releases' }).Count | Should -BeGreaterThan 0
        @(Get-PedidoTeste $GitHub | Select-Object -Skip $antes | Where-Object { $_ -match '/ok\.zip' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Catalogo recomps.json do pacote' {
    BeforeAll {
        $Arq = Join-Path $Arquivos 'recomps.json'
        $Bytes = [IO.File]::ReadAllBytes($Arq)
        $Cat = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
    }

    It 'UTF-8 sem BOM, sem gameId e sem caminho absoluto' {
        ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) | Should -BeFalse
        $texto = [Text.Encoding]::UTF8.GetString($Bytes)
        $texto | Should -Not -Match '"gameId"'
        $texto | Should -Not -Match '"[A-Za-z]:\\\\'
        $texto | Should -Not -Match '"\\\\\\\\'
    }

    It 'Recomps legados mantem o campo de origem e os argumentos conhecidos em cada entrada' {
        $scriptRecomp = Join-Path $Arquivos 'recomp.ps1'
        $FormatosOrigem = Get-Atribuicao $scriptRecomp 'FormatosOrigem'
        . (Get-Funcao $scriptRecomp @('Get-ModoOrigem', 'Sync-CampoDump', 'Set-Campo', 'Format-Campos', 'Test-Entrada47a'))
        function Get-CampoOrigemAntigo($jogo) {
            if ($jogo.origem -ne 'rom' -or -not $jogo.romm -or -not $jogo.romm.arquivo) { return $null }
            if ([IO.Path]::GetExtension($jogo.romm.arquivo) -eq '.iso') { 'iso' } else { 'nsp' }
        }
        foreach ($j in $Cat.jogos) {
            $original = Get-CampoOrigemAntigo $j
            $modo = Get-ModoOrigem $j
            $modo.Campo | Should -Be $original -Because $j.id
            Test-Entrada47a $j | Should -BeFalse -Because $j.id
            if ($original) {
                $arquivo = Join-Path $TestDrive $j.romm.arquivo
                Set-Campo $j $original $arquivo
                Sync-CampoDump $j $modo
                Format-Campos "{$original}" $j | Should -Be $arquivo -Because $j.id
                Format-Campos '{dump}' $j | Should -Be $arquivo -Because $j.id
            }
        }
    }

    It 'cada jogo liga pelo RomM' {
        @($Cat.jogos).Count | Should -BeGreaterThan 0
        foreach ($j in $Cat.jogos) {
            [long]$j.romm.id | Should -BeGreaterThan 0 -Because $j.id
            $j.romm.arquivo | Should -Not -BeNullOrEmpty -Because $j.id
            # (o "pronto" nao usa a ROM; o "comando" so quando o preparo usa {nsp}/{iso})
            if ($j.tipo -notin 'pronto', 'comando') { $j.origem | Should -Be 'rom' -Because $j.id }
            if ($j.tipo -eq 'pronto') { $j.origem | Should -BeNullOrEmpty -Because $j.id }
            if ($j.tipo -in 'pronto', 'comando') { $j.pronto | Should -Be '.recomp-pronto' -Because $j.id }
            if ($j.tipo -eq 'comando') { $j.preparo.exe | Should -Not -BeNullOrEmpty -Because $j.id }
            [double]$j.espacoGb | Should -BeGreaterThan 0 -Because $j.id
        }
    }

    It 'contrato com o plugin: toda chave do catalogo existe na classe do Recomps.cs (o plugin regrava o catalogo e o campo de fora some)' {
        $cs = [IO.File]::ReadAllText((Join-Path $Raiz 'ferramentas\plugin\Recomps.cs'))
        function Get-Propriedades($classe) {
            $m = [regex]::Match($cs, "public class $classe\s*\{(.*?)\r?\n    \}", 'Singleline')
            $m.Success | Should -BeTrue -Because $classe
            @([regex]::Matches($m.Groups[1].Value, 'public [\w<>?,\s]+? (\w+) \{ get; set; \}') | ForEach-Object { $_.Groups[1].Value })
        }
        $classes = @{ '' = 'JogoRecomp'; romm = 'RommRecomp'; preparo = 'PreparoRecomp' }
        $props = @{}
        foreach ($k in $classes.Keys) { $props[$k] = Get-Propriedades $classes[$k] }
        $props[''].Count | Should -BeGreaterThan 20
        foreach ($j in $Cat.jogos) {
            foreach ($p in $j.PSObject.Properties) {
                $props[''] -contains $p.Name | Should -BeTrue -Because "$($j.id).$($p.Name)"
                if ($props.ContainsKey($p.Name)) {
                    foreach ($v in @($p.Value)) { foreach ($q in $v.PSObject.Properties) { $props[$p.Name] -contains $q.Name | Should -BeTrue -Because "$($j.id).$($p.Name).$($q.Name)" } }
                }
            }
        }
        # (os campos novos dos tipos genericos tambem, mesmo sem entrada que use)
        foreach ($c in 'Preparo', 'Versao', 'AvisoInstalar', 'Plataforma', 'Dump', 'Bios', 'Firmware') { $props[''] -contains $c | Should -BeTrue -Because $c }
        foreach ($c in 'Exe', 'Args', 'Etapa', 'Minutos') { $props['preparo'] -contains $c | Should -BeTrue -Because $c }
        # (tipo triforce: o OoT de Switch 2 so esta no recomps.json do dono, mas passa pelo plugin do mesmo jeito)
        foreach ($c in 'Nup', 'Fixa', 'SemEmulador') { $props[''] -contains $c | Should -BeTrue -Because $c }
        $cs | Should -Match 'public ReleaseFixa Fixa \{ get; set; \}'
        $cs | Should -Match 'public List<ArquivoFixo> Arquivos \{ get; set; \}'
        foreach ($c in 'Versao', 'Titulo', 'VersaoJogo', 'VersaoJogoTexto', 'Arquivos') { Get-Propriedades 'ReleaseFixa' | Should -Contain $c -Because "fixa.$c" }
        foreach ($c in 'Nome', 'Url', 'Tamanho', 'Sha256') { Get-Propriedades 'ArquivoFixo' | Should -Contain $c -Because "fixa.arquivos.$c" }
    }

    It 'contrato com o plugin: todo FALTA do recomp.ps1 tem texto no Recomps.cs' {
        $codigos = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $Arquivos 'recomp.ps1')), "faltas\.Add\('(\w+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $codigos.Count | Should -BeGreaterThan 5
        $cs = [IO.File]::ReadAllText((Join-Path $Raiz 'ferramentas\plugin\Recomps.cs'))
        foreach ($c in $codigos) { $cs | Should -Match ('new\[\] \{ "' + $c + '",') -Because $c }
        $codigos | Should -Contain 'nup'
    }
}
