BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force

    # Servidor de jogos falso: so precisa registrar quem foi procurado.
    $Srv = Join-Path $TestDrive 'srv'
    Write-Utf8 "$Srv\saude" 'ok'
    Write-Utf8 "$Srv\instalador\versao.json" '{"versao":1,"arquivo":"programa-1.zip","sha256":"x","assinatura":"x"}'
    $Servidor = Start-ServidorTeste -Pasta $Srv -Usuario 'beto' -Senha 's3nha'

    function New-Instalacao {
        $base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        New-Item "$base\programa" -ItemType Directory -Force | Out-Null
        foreach ($s in 'ao-abrir.ps1', 'atualizador.ps1', 'relato.ps1', 'multiplayer.ps1', 'correcoes.ps1', 'correcoes.json', 'conquistas.ps1', 'baixar-worker.ps1') {
            Copy-Item (Join-Path $Arquivos $s) "$base\programa"
        }
        Write-Utf8 "$base\launcher.json" (@{ playnite = "$base\Playnite"; mapas = @(); jogos = @{ lan = $Servidor.Url; usuario = 'beto'; senha = 's3nha' } } | ConvertTo-Json -Depth 4)
        $base
    }

    function Get-Procuras { @(Get-PedidoTeste $Servidor | Where-Object { $_ -like 'GET /saude*' -or $_ -like 'GET /instalador/*' }) }
}
AfterAll { Stop-ServidorTeste $Servidor }

Describe 'ao-abrir.ps1' {
    BeforeEach { Remove-Item $Servidor.Log -Force -ErrorAction SilentlyContinue }

    It 'Playnite aberto por outro atalho: procura atualizacao no servidor' {
        $base = New-Instalacao
        $r = Invoke-Worker "$base\programa\ao-abrir.ps1" @{}
        $r.Codigo | Should -Be 0 -Because $r.Erro
        Get-Procuras | Should -Contain 'GET /instalador/versao.json -'
    }

    It 'avisa o painel quando a atualizacao falha' {
        # O versao.json do servidor falso tem assinatura invalida.
        $base = New-Instalacao
        $r = Invoke-Worker "$base\programa\ao-abrir.ps1" @{}
        $r.Codigo | Should -Be 0 -Because $r.Erro
        $aviso = @(Get-PedidoTeste $Servidor | Where-Object { $_ -like 'POST /relato *' })
        $aviso.Count | Should -Be 1
        $corpo = $aviso[0].Substring('POST /relato '.Length) | ConvertFrom-Json
        $corpo.tipo | Should -Be 'erro'; $corpo.etapa | Should -Be 'atualizacao'; $corpo.msg | Should -Be 'Assinatura invalida.'
    }

    It 'nao repete o que o launcher acabou de fazer' {
        $base = New-Instalacao
        [IO.File]::WriteAllText("$base\launcher-abriu.txt", 'agora')
        $r = Invoke-Worker "$base\programa\ao-abrir.ps1" @{}
        $r.Codigo | Should -Be 0 -Because $r.Erro
        Get-Procuras | Should -BeNullOrEmpty
    }

    It 'marca antiga do launcher nao impede' {
        $base = New-Instalacao
        [IO.File]::WriteAllText("$base\launcher-abriu.txt", 'ontem')
        (Get-Item "$base\launcher-abriu.txt").LastWriteTime = (Get-Date).AddHours(-1)
        $r = Invoke-Worker "$base\programa\ao-abrir.ps1" @{}
        $r.Codigo | Should -Be 0 -Because $r.Erro
        Get-Procuras | Should -Contain 'GET /instalador/versao.json -'
    }
}
