BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    . (Join-Path $Arquivos 'atualizador.ps1')
    $Chave = New-ChaveRsa
    $AtualizacaoChavePublica = $Chave.Publica

    $Srv = Join-Path $TestDrive 'srv'
    Write-Utf8 (Join-Path $Srv 'saude') 'ok'
    $Servidor = Start-ServidorTeste -Pasta $Srv -Usuario 'ana' -Senha 'certa'

    function Publish-Versao {
        # Mesmo pacote que ferramentas\publicar-atualizacao.ps1 monta; os parametros estragam uma parte.
        param([int]$Versao, [int]$VersaoNoPacote = $Versao, [string]$Arquivo = "programa-$Versao.zip", [string]$ChavePrivada = $Chave.Privada,
            [switch]$CorromperZip, [string]$Launcher = "# launcher v$Versao", [string]$Manifesto = 'versao.json', [string]$Json = '[]')
        $etapa = Join-Path $TestDrive "etapa-$([guid]::NewGuid())"
        Write-Utf8 (Join-Path $etapa 'versao.txt') "$VersaoNoPacote`n"
        Write-Utf8 (Join-Path $etapa 'launcher.ps1') $Launcher
        Write-Utf8 (Join-Path $etapa 'correcoes.json') $Json
        Write-Utf8 (Join-Path $etapa 'novo.txt') 'novo'
        $zip = Join-Path $Srv "instalador\programa-$Versao.zip"
        New-Item (Split-Path $zip) -ItemType Directory -Force | Out-Null
        Remove-Item $zip -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::CreateFromDirectory($etapa, $zip)
        $sha = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($CorromperZip) { [IO.File]::AppendAllText($zip, 'lixo') }
        $m = @{ versao = $Versao; arquivo = $Arquivo; sha256 = $sha; assinatura = (Get-AssinaturaTeste $ChavePrivada "$Versao|$sha") }
        Write-Utf8 (Join-Path $Srv "instalador\$Manifesto") ($m | ConvertTo-Json -Compress)
    }

    function New-Instalacao([string]$Url = $Servidor.Url, [string]$Senha = 'certa') {
        $base = Join-Path $TestDrive "base-$([guid]::NewGuid())"
        Write-Utf8 (Join-Path $base 'launcher.json') (@{ jogos = @{ lan = $Url; usuario = 'ana'; senha = $Senha } } | ConvertTo-Json)
        Write-Utf8 (Join-Path $base 'programa\versao.txt') "3`n"
        Write-Utf8 (Join-Path $base 'programa\velho.txt') 'velho'
        $base
    }

    function Assert-Intacta($base) {
        Get-Content (Join-Path $base 'programa\versao.txt') | Should -Be '3'
        Test-Path (Join-Path $base 'programa\velho.txt') | Should -BeTrue
        @(Get-ChildItem $base -Name) | Sort-Object | Should -Be @('launcher.json', 'programa')
    }
}
AfterAll { Stop-ServidorTeste $Servidor }

Describe 'Update-JogosRetro' {
    It 'troca o programa por uma versao nova assinada' {
        Publish-Versao 4
        $base = New-Instalacao
        Update-JogosRetro $base | Should -BeTrue
        Get-Content (Join-Path $base 'programa\versao.txt') | Should -Be '4'
        Test-Path (Join-Path $base 'programa\novo.txt') | Should -BeTrue
        Test-Path (Join-Path $base 'programa\velho.txt') | Should -BeFalse
        Get-Content (Join-Path $base 'launcher.ps1') | Should -Be '# launcher v4'
        # Nada de programa.novo, programa.antigo ou zip sobrando.
        @(Get-ChildItem $base -Name) | Sort-Object | Should -Be @('launcher.json', 'launcher.ps1', 'programa')
    }

    It 'nao faz nada quando ja esta na versao publicada ou mais nova' {
        Publish-Versao 3
        Update-JogosRetro (New-Instalacao) | Should -BeFalse
        Publish-Versao 2
        Update-JogosRetro (New-Instalacao) | Should -BeFalse
    }

    It 'instalacao sem programa (primeira vez) recebe a versao' {
        Publish-Versao 1
        $base = New-Instalacao
        Remove-Item (Join-Path $base 'programa') -Recurse
        Update-JogosRetro $base | Should -BeTrue
        Get-Content (Join-Path $base 'programa\versao.txt') | Should -Be '1'
    }

    It 'recusa pacote assinado com outra chave' {
        Publish-Versao 5 -ChavePrivada (New-ChaveRsa).Privada
        $base = New-Instalacao
        { Update-JogosRetro $base } | Should -Throw 'Assinatura invalida.'
        Assert-Intacta $base
    }

    It 'recusa zip diferente do que foi assinado' {
        Publish-Versao 5 -CorromperZip
        $base = New-Instalacao
        { Update-JogosRetro $base } | Should -Throw 'Pacote corrompido.'
        Assert-Intacta $base
    }

    It 'recusa pacote cuja versao interna nao confere (replay de pacote antigo)' {
        Publish-Versao 5 -VersaoNoPacote 4
        $base = New-Instalacao
        { Update-JogosRetro $base } | Should -Throw 'Versao do pacote nao confere.'
        Assert-Intacta $base
    }

    It 'recusa nome de pacote fora do padrao' -TestCases @(@{ n = '../programa-5.zip' }, @{ n = 'programa-5.zip/../x' }, @{ n = 'outro.zip' }) {
        Publish-Versao 5 -Arquivo $n
        $base = New-Instalacao
        { Update-JogosRetro $base } | Should -Throw 'Nome de pacote invalido.'
        Assert-Intacta $base
    }

    It 'recusa assinatura que nao e base64 sem quebrar' {
        Test-AssinaturaAtualizacao 5 'ABC' '%%%' | Should -BeFalse
    }

    It 'sem servidor ou sem launcher.jogos devolve $false' {
        Update-JogosRetro (New-Instalacao -Url "http://127.0.0.1:$(Get-PortaFechada)") | Should -BeFalse
        $base = New-Instalacao
        Write-Utf8 (Join-Path $base 'launcher.json') '{"lan":"x"}'
        Update-JogosRetro $base | Should -BeFalse
    }

    It 'usa o login do launcher.json' {
        Publish-Versao 6
        { Update-JogosRetro (New-Instalacao -Senha 'errada') } | Should -Throw
        Get-PedidoTeste $Servidor | Should -Contain 'GET /saude -'
    }

    It 'recusa pacote assinado com script que nao abre no PowerShell 5.1' {
        Publish-Versao 7 -Launcher "function Abrir {`r`n    if (`$x) {"
        $base = New-Instalacao
        { Update-JogosRetro $base } | Should -Throw '*Pacote com erro em launcher.ps1*'
        Assert-Intacta $base
    }

    It 'recusa pacote assinado com JSON quebrado' {
        Publish-Versao 8 -Json '[{"id": '
        $base = New-Instalacao
        { Update-JogosRetro $base } | Should -Throw '*JSON invalido: correcoes.json*'
        Assert-Intacta $base
    }

    It 'canal de teste pega a versao de teste; os outros ficam na publicada' {
        Publish-Versao 9
        Publish-Versao 10 -Manifesto 'versao-teste.json'
        try {
            $base = New-Instalacao
            Update-JogosRetro $base | Should -BeTrue
            Get-Content (Join-Path $base 'programa\versao.txt') | Should -Be '9'

            $base = New-Instalacao
            $L = Get-Content (Join-Path $base 'launcher.json') -Raw | ConvertFrom-Json
            $L | Add-Member canal 'teste'
            Write-Utf8 (Join-Path $base 'launcher.json') ($L | ConvertTo-Json -Depth 4)
            Update-JogosRetro $base | Should -BeTrue
            Get-Content (Join-Path $base 'programa\versao.txt') | Should -Be '10'
        } finally { Remove-Item (Join-Path $Srv 'instalador\versao-teste.json') }
    }
}

Describe 'Find-ServidorJogos' {
    It 'prefere a rede local e cai para NetBird e Tailscale' {
        $fechada = "http://127.0.0.1:$(Get-PortaFechada)"
        Find-ServidorJogos ([pscustomobject]@{ lan = "$($Servidor.Url)/"; netbird = $fechada }) | Should -Be $Servidor.Url
        Find-ServidorJogos ([pscustomobject]@{ lan = $fechada; netbird = $Servidor.Url }) | Should -Be $Servidor.Url
        Find-ServidorJogos ([pscustomobject]@{ lan = $fechada; tailscale = $Servidor.Url }) | Should -Be $Servidor.Url
        Find-ServidorJogos ([pscustomobject]@{ lan = $fechada }) | Should -BeNullOrEmpty
    }
}
