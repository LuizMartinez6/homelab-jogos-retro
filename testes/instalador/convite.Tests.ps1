BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    . (Join-Path $Arquivos 'convite.ps1')

    function New-Codigo($Objeto) {
        # Mesmo formato do painel Amigos: "JR1-" + base64url sem "=".
        $json = $Objeto | ConvertTo-Json -Compress
        'JR1-' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
}

Describe 'ConvertFrom-Convite' {
    It 'le um codigo sozinho' {
        $c = ConvertFrom-Convite (New-Codigo @{ u = 'ana'; s = 'segredo'; k = 'CHAVE' })
        $c.u | Should -Be 'ana'; $c.s | Should -Be 'segredo'; $c.k | Should -Be 'CHAVE'
    }

    It 'acha o codigo no meio da mensagem colada, com quebras de linha' {
        $codigo = New-Codigo @{ u = 'joao_2'; s = 'x' * 32; k = '' }
        $msg = "Oi! Cola isso no instalador:`r`n$($codigo.Substring(0, 20))`r`n  $($codigo.Substring(20))`r`n`r`nQualquer coisa me chama."
        $c = ConvertFrom-Convite $msg
        $c.u | Should -Be 'joao_2'; $c.s | Should -Be ('x' * 32); $c.k | Should -Be ''
    }

    It 'aceita qualquer sobra de "=" (tamanhos diferentes de base64)' {
        foreach ($n in 1..4) {
            (ConvertFrom-Convite (New-Codigo @{ u = 'a' * $n; s = 'b' })).u | Should -Be ('a' * $n)
        }
    }

    It 'base64url com "-" e "_" no meio' {
        # "~~~" e "???" geram "+" e "/" no base64 padrao.
        $c = ConvertFrom-Convite (New-Codigo @{ u = 'ana'; s = '~~~???>>>'; k = '' })
        $c.s | Should -Be '~~~???>>>'
    }

    It 'devolve nada para texto sem codigo, codigo cortado ou sem login' {
        ConvertFrom-Convite 'mensagem sem codigo' | Should -BeNullOrEmpty
        ConvertFrom-Convite 'JR1-!!!!' | Should -BeNullOrEmpty
        ConvertFrom-Convite ((New-Codigo @{ u = 'ana'; s = 'segredo' }).Substring(0, 12)) | Should -BeNullOrEmpty
        ConvertFrom-Convite (New-Codigo @{ u = 'ana' }) | Should -BeNullOrEmpty
    }
}

Describe 'Test-LoginJogos' {
    BeforeAll {
        $pasta = Join-Path $TestDrive 'srv'
        Write-Utf8 (Join-Path $pasta 'instalador\versao.json') '{"versao":1}'
        $srv = Start-ServidorTeste -Pasta $pasta -Usuario 'ana' -Senha 'certa'
    }
    AfterAll { Stop-ServidorTeste $srv }

    It 'login aceito' { Test-LoginJogos "$($srv.Url)/" 'ana' 'certa' | Should -BeTrue }
    It 'login recusado' { Test-LoginJogos $srv.Url 'ana' 'errada' | Should -Be $false }
    It 'servidor fora do ar' { Test-LoginJogos "http://127.0.0.1:$(Get-PortaFechada)" 'ana' 'certa' | Should -BeNullOrEmpty }
}
