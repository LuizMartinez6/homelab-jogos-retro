BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    $Worker = Join-Path $Arquivos 'jogos-pc-worker.ps1'
    $Srv = Join-Path $TestDrive 'srv'
    $Pasta = 'Colecao/Jogo Portatil [v2]'
    $ArquivosJogo = @{ 'bin/jogo.exe' = 'MZ executavel'; 'dados/fase 1.pak' = ('x' * 5000) }
    foreach ($rel in $ArquivosJogo.Keys) { Write-Utf8 (Join-Path $Srv "jogos/$Pasta/$rel") $ArquivosJogo[$rel] }

    function New-Jogo([string]$Executavel = 'bin/jogo.exe', [switch]$ShaErrado) {
        $arquivos = foreach ($rel in $ArquivosJogo.Keys | Sort-Object) {
            $f = Join-Path $Srv "jogos/$Pasta/$rel"
            @{ caminho = $rel; tamanho = (Get-Item -LiteralPath $f).Length
               sha256 = $(if ($ShaErrado) { 'ab' * 32 } else { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() }) }
        }
        @{ id = 'portatil'; nome = 'Jogo: Portatil?'; tipo = 'pasta'; pasta = $Pasta; executavel = $Executavel
           tamanho = ($arquivos | ForEach-Object { $_.tamanho } | Measure-Object -Sum).Sum; arquivos = @($arquivos) }
    }

    function Invoke-JogoPc($Servidor, $Jogo, [string]$Raiz = (Join-Path $TestDrive "raiz-$([guid]::NewGuid())")) {
        $base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        New-Item $base, $Raiz -ItemType Directory -Force | Out-Null
        $prog = Join-Path $base 'progresso.json'
        $job = Join-Path $base 'trabalho.json'
        # Mesmo JSON que o plugin (classe Trabalho do JogosPc.cs) grava.
        Write-Utf8 $job (@{ url = $Servidor.Url; auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('amigo:s')); jogo = $Jogo
                raiz = $Raiz; base = $base; progresso = $prog } | ConvertTo-Json -Depth 6)
        $r = Invoke-Worker $Worker @{ JOGOSPC_JOB_ARQ = $job }
        [pscustomobject]@{ Codigo = $r.Codigo; Erro = $r.Erro; Raiz = $Raiz; Base = $base; Progresso = (Get-Content $prog -Raw | ConvertFrom-Json) }
    }
}

Describe 'jogos-pc-worker.ps1 (jogo que e so uma pasta)' {
    BeforeAll { $Servidor = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's' }
    AfterAll { Stop-ServidorTeste $Servidor }

    It 'baixa cada arquivo, confere, move para a pasta do jogo e registra' {
        $r = Invoke-JogoPc $Servidor (New-Jogo)
        $r.Codigo | Should -Be 0 -Because $r.Erro
        $r.Progresso.estado | Should -Be 'ok'
        # Caracteres proibidos no Windows saem do nome da pasta.
        $destino = Join-Path $r.Raiz 'Jogo Portatil'
        Get-Content -LiteralPath (Join-Path $destino 'bin\jogo.exe') | Should -Be 'MZ executavel'
        (Get-Item -LiteralPath (Join-Path $destino 'dados\fase 1.pak')).Length | Should -Be 5000
        @(Get-ChildItem -LiteralPath $destino -Recurse -Filter '*.parcial').Count | Should -Be 0
        Test-Path (Join-Path $r.Raiz '_baixando') | Should -BeFalse
        $estado = Get-Content (Join-Path $r.Base 'jogos-pc.json') -Raw | ConvertFrom-Json
        $estado.portatil.pasta | Should -Be $destino
        $estado.portatil.executavel | Should -Be 'bin/jogo.exe'
        # Espacos e colchetes vao escapados na URL.
        Get-PedidoTeste $Servidor | Should -Contain 'GET /jogos/Colecao/Jogo%20Portatil%20%5Bv2%5D/dados/fase%201.pak -'
    }

    It 'mantem os outros jogos ja registrados' {
        $raiz = Join-Path $TestDrive 'raiz-registro'
        $r = Invoke-JogoPc $Servidor (New-Jogo) -Raiz $raiz
        Write-Utf8 (Join-Path $r.Base 'jogos-pc.json') '{"outro":{"nome":"Outro","pasta":"C:\\x","executavel":"a.exe"}}'
        Remove-Item (Join-Path $raiz 'Jogo Portatil') -Recurse
        (Invoke-Worker $Worker @{ JOGOSPC_JOB_ARQ = (Join-Path $r.Base 'trabalho.json') }).Codigo | Should -Be 0
        $estado = Get-Content (Join-Path $r.Base 'jogos-pc.json') -Raw | ConvertFrom-Json
        @($estado.PSObject.Properties.Name | Sort-Object) | Should -Be @('outro', 'portatil')
    }

    It 'arquivo corrompido duas vezes: desiste e nao instala' {
        $r = Invoke-JogoPc $Servidor (New-Jogo -ShaErrado)
        $r.Codigo | Should -Be 1
        $r.Progresso.msg | Should -Match 'corrompido duas vezes'
        Test-Path (Join-Path $r.Raiz 'Jogo Portatil') | Should -BeFalse
        Test-Path (Join-Path $r.Base 'jogos-pc.json') | Should -BeFalse
    }

    It 'executavel que nao existe no jogo e erro' {
        $r = Invoke-JogoPc $Servidor (New-Jogo -Executavel 'bin/outro.exe')
        $r.Codigo | Should -Be 1
        $r.Progresso.msg | Should -Match 'nao encontrei o programa do jogo'
    }

    It 'pasta de destino que ja existe e erro (nao mistura arquivos)' {
        $raiz = Join-Path $TestDrive 'raiz-existe'
        New-Item (Join-Path $raiz 'Jogo Portatil') -ItemType Directory -Force | Out-Null
        $r = Invoke-JogoPc $Servidor (New-Jogo) -Raiz $raiz
        $r.Codigo | Should -Be 1
        $r.Progresso.msg | Should -Match 'Ja existe a pasta'
    }

    It 'arquivo ja baixado inteiro nao e baixado de novo' {
        $raiz = Join-Path $TestDrive 'raiz-meio'
        $jogo = New-Jogo
        Write-Utf8 (Join-Path $raiz "_baixando\portatil\bin\jogo.exe") 'MZ executavel'
        $antes = @(Get-PedidoTeste $Servidor).Count
        (Invoke-JogoPc $Servidor $jogo -Raiz $raiz).Codigo | Should -Be 0
        # So os downloads: os avisos ao painel (POST /relato) nao contam.
        $novos = @(Get-PedidoTeste $Servidor | Select-Object -Skip $antes | Where-Object { $_ -like 'GET *' })
        $novos | Should -Be @('GET /jogos/Colecao/Jogo%20Portatil%20%5Bv2%5D/dados/fase%201.pak -')
    }
}

Describe 'Get-ExecutavelGog' {
    BeforeAll { . (Get-Funcao $Worker 'Get-ExecutavelGog') }

    It 'le o programa principal do goggame-*.info' {
        $p = Join-Path $TestDrive 'gog'
        Write-Utf8 "$p\goggame-123.info" '{"playTasks":[{"isPrimary":false,"type":"FileTask","path":"extra.exe"},{"isPrimary":true,"type":"URLTask","path":"http://x"},{"isPrimary":true,"type":"FileTask","path":"bin/jogo.exe"}]}'
        Get-ExecutavelGog $p | Should -Be 'bin/jogo.exe'
    }

    It 'sem .info devolve nada' {
        New-Item (Join-Path $TestDrive 'vazio') -ItemType Directory -Force | Out-Null
        Get-ExecutavelGog (Join-Path $TestDrive 'vazio') | Should -BeNullOrEmpty
    }
}
