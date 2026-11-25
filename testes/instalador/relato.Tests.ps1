BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    . (Join-Path $Arquivos 'relato.ps1')

    function Receive-Pedido($escuta) {
        # Le um pedido HTTP inteiro (cabecalhos + corpo) e responde 200.
        $tarefa = $escuta.AcceptTcpClientAsync()
        if (-not $tarefa.Wait(5000)) { throw 'nenhum pedido chegou' }
        $c = $tarefa.Result
        try {
            $s = $c.GetStream(); $s.ReadTimeout = 5000
            $buf = New-Object byte[] 65536; $texto = ''
            while ($texto -notmatch "`r`n`r`n") { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $texto += [Text.Encoding]::UTF8.GetString($buf, 0, $n) }
            $cab, $corpo = $texto -split "`r`n`r`n", 2
            $tam = if ($cab -match '(?im)^Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
            while ([Text.Encoding]::UTF8.GetByteCount($corpo) -lt $tam) { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $corpo += [Text.Encoding]::UTF8.GetString($buf, 0, $n) }
            $r = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`n{}")
            $s.Write($r, 0, $r.Length)
            [pscustomobject]@{ Cabecalhos = $cab; Corpo = ($corpo | ConvertFrom-Json) }
        } finally { $c.Close() }
    }
}

Describe 'Get-DestinoRelato' {
    It 'usa os caminhos do servidor de jogos e o login do amigo' {
        $base = Join-Path $TestDrive 'base'
        Write-Utf8 "$base\launcher.json" (@{ jogos = @{ lan = 'http://192.168.0.10:8095'; netbird = 'http://100.64.0.10:8095'; usuario = 'ana'; senha = 's3nha' } } | ConvertTo-Json)
        $d = Get-DestinoRelato $base
        $d.urls | Should -Be @('http://192.168.0.10:8095', 'http://100.64.0.10:8095')
        $d.auth | Should -Be ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ana:s3nha')))
    }

    It 'sem launcher.json ou sem login nao avisa' {
        Get-DestinoRelato (Join-Path $TestDrive 'nao-existe') | Should -BeNullOrEmpty
        $base = Join-Path $TestDrive 'sem-login'
        Write-Utf8 "$base\launcher.json" (@{ jogos = @{ lan = 'http://x' } } | ConvertTo-Json)
        Get-DestinoRelato $base | Should -BeNullOrEmpty
    }
}

Describe 'Get-ConsoleRelato' {
    It 'tira o console da pasta Jogos' {
        Get-ConsoleRelato 'C:\JogosRetro\Jogos\gba\Pokemon [USA]\Pokemon [USA].gba' | Should -Be 'gba'
        Get-ConsoleRelato 'D:\Outro\lugar\x.iso' | Should -Be ''
    }
}

Describe 'Send-Relato' {
    BeforeEach {
        $Escuta = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $Escuta.Start()
        $Destino = [pscustomobject]@{ urls = @("http://127.0.0.1:$($Escuta.LocalEndpoint.Port)/"); auth = 'Basic YW5hOng=' }
        $script:RelatoUltimoEstado = $null; $script:RelatoUltimoEnvio = [datetime]::MinValue
    }
    AfterEach { $Escuta.Stop() }

    It 'manda o andamento em JSON com o login do amigo para /relato' {
        Send-Relato $Destino @{ tipo = 'rom'; jogo = 'Zelda'; console = 'snes'; estado = 'baixando'; baixado = 10; total = 100; velocidade = 5; msg = '' } | Should -BeTrue
        $p = Receive-Pedido $Escuta
        $p.Cabecalhos | Should -Match '^POST /relato HTTP/1\.1'
        $p.Cabecalhos | Should -Match '(?im)^Authorization: Basic YW5hOng=\r?$'
        $p.Cabecalhos | Should -Match '(?im)^Content-Type: application/json'
        $p.Corpo.jogo | Should -Be 'Zelda'; $p.Corpo.estado | Should -Be 'baixando'; $p.Corpo.baixado | Should -Be 10
    }

    It 'no mesmo estado so manda de novo depois do intervalo' {
        Send-Relato $Destino @{ jogo = 'Zelda'; estado = 'baixando' } | Should -BeTrue
        Receive-Pedido $Escuta | Out-Null
        Send-Relato $Destino @{ jogo = 'Zelda'; estado = 'baixando' } | Should -BeFalse
        Send-Relato $Destino @{ jogo = 'Zelda'; estado = 'verificando' } | Should -BeTrue -Because 'estado mudou'
        (Receive-Pedido $Escuta).Corpo.estado | Should -Be 'verificando'
        $script:RelatoUltimoEnvio = (Get-Date).AddSeconds(-11)
        Send-Relato $Destino @{ jogo = 'Zelda'; estado = 'verificando' } | Should -BeTrue
        Receive-Pedido $Escuta | Out-Null
    }

    It 'servidor fora do ar nao trava nem da erro' {
        $fechado = [pscustomobject]@{ urls = @("http://127.0.0.1:$(Get-PortaFechada)"); auth = 'x' }
        $t = Measure-Command { Send-Relato $fechado @{ jogo = 'Zelda'; estado = 'erro' } | Should -BeTrue }
        $t.TotalSeconds | Should -BeLessThan 6
    }

    It 'sem destino nao faz nada' {
        Send-Relato $null @{ jogo = 'Zelda'; estado = 'ok' } | Should -BeFalse
    }
}

Describe 'Send-Erro' {
    BeforeEach {
        $Escuta = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $Escuta.Start()
        $Base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        Write-Utf8 "$Base\launcher.json" (@{ jogos = @{ lan = "http://127.0.0.1:$($Escuta.LocalEndpoint.Port)"; usuario = 'ana'; senha = 'x' } } | ConvertTo-Json)
        Write-Utf8 "$Base\programa\versao.txt" '25'
    }
    AfterEach { $Escuta.Stop() }

    It 'manda a etapa, a mensagem do erro e a versao instalada' {
        try { throw 'Assinatura invalida.' } catch { $e = $_ }
        $tarefa = [powershell]::Create().AddScript({ param($f, $b, $e) . $f; Send-Erro $b 'atualizacao' $e }).AddArgument((Join-Path $Arquivos 'relato.ps1')).AddArgument($Base).AddArgument($e)
        $assinc = $tarefa.BeginInvoke()
        $p = Receive-Pedido $Escuta
        $tarefa.EndInvoke($assinc) | Should -Be $true
        $p.Cabecalhos | Should -Match '^POST /relato HTTP/1\.1'
        $p.Corpo.tipo | Should -Be 'erro'; $p.Corpo.etapa | Should -Be 'atualizacao'
        $p.Corpo.msg | Should -Be 'Assinatura invalida.'; $p.Corpo.versao | Should -Be 25
    }

    It 'mensagem longa e cortada e sem login nao manda' {
        $tarefa = [powershell]::Create().AddScript({ param($f, $b) . $f; Send-Erro $b 'multiplayer' ('x' * 500) }).AddArgument((Join-Path $Arquivos 'relato.ps1')).AddArgument($Base)
        $assinc = $tarefa.BeginInvoke()
        (Receive-Pedido $Escuta).Corpo.msg.Length | Should -Be 300
        $tarefa.EndInvoke($assinc) | Out-Null
        Send-Erro (Join-Path $TestDrive 'nao-existe') 'multiplayer' 'x' | Should -BeFalse
    }
}
