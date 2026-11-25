BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    $Worker = Join-Path $Arquivos 'baixar-worker.ps1'
    $Srv = Join-Path $TestDrive 'srv'
    # 3 MB: o worker le em blocos de 1 MB, entao a queda acontece no meio de um bloco.
    $Dados = New-Object byte[] (3MB + 123)
    (New-Object Random 42).NextBytes($Dados)
    New-Item "$Srv\roms" -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllBytes("$Srv\roms\jogo.chd", $Dados)
    $Sha1 = (Get-FileHash "$Srv\roms\jogo.chd" -Algorithm SHA1).Hash.ToLower()
    $Auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('amigo:s'))

    function Invoke-Download {
        param($Servidor, [string]$Destino = (Join-Path $TestDrive "dest-$([guid]::NewGuid())\Jogo [USA]\Jogo [USA].chd"), [string]$Sha = $Sha1, [string]$Caminho = '/roms/jogo.chd')
        $prog = Join-Path $TestDrive "prog-$([guid]::NewGuid()).json"
        $job = @{ url = "$($Servidor.Url)$Caminho"; auth = $Auth; destino = $Destino; total = $Dados.Length; progresso = $prog; sha1 = $Sha } | ConvertTo-Json -Compress
        $r = Invoke-Worker $Worker @{ JOGOSRETRO_DOWNLOAD = $job }
        [pscustomobject]@{ Codigo = $r.Codigo; Erro = $r.Erro; Destino = $Destino; Progresso = (Get-Content $prog -Raw | ConvertFrom-Json) }
    }

    function Assert-Baixado($r) {
        $r.Codigo | Should -Be 0 -Because $r.Erro
        $r.Progresso.estado | Should -Be 'ok'
        $r.Progresso.baixado | Should -Be $Dados.Length
        (Get-FileHash -LiteralPath $r.Destino -Algorithm SHA1).Hash | Should -Be $Sha1.ToUpper()
        Test-Path -LiteralPath "$($r.Destino).parcial" | Should -BeFalse
    }
}

Describe 'baixar-worker.ps1' {
    It 'baixa, confere o SHA-1 e entrega o arquivo (nome com colchetes)' {
        $s = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's'
        try { Assert-Baixado (Invoke-Download $s) } finally { Stop-ServidorTeste $s }
    }

    It 'continua de onde parou pedindo so o que falta (Range)' {
        $s = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's'
        try {
            $dest = Join-Path $TestDrive 'retoma\Jogo [EUR]\Jogo.chd'
            New-Item (Split-Path $dest) -ItemType Directory -Force | Out-Null
            [IO.File]::WriteAllBytes("$dest.parcial", $Dados[0..999999])
            Assert-Baixado (Invoke-Download $s -Destino $dest)
            Get-PedidoTeste $s | Should -Be @('GET /roms/jogo.chd bytes=1000000-')
        } finally { Stop-ServidorTeste $s }
    }

    It 'servidor que ignora o Range: recomeca do zero sem duplicar bytes' {
        $s = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's' -IgnorarRange
        try {
            $dest = Join-Path $TestDrive 'semrange\Jogo.chd'
            New-Item (Split-Path $dest) -ItemType Directory -Force | Out-Null
            [IO.File]::WriteAllBytes("$dest.parcial", $Dados[0..999])
            Assert-Baixado (Invoke-Download $s -Destino $dest)
        } finally { Stop-ServidorTeste $s }
    }

    It 'conexao que cai no meio: reconecta e termina' {
        $s = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's' -CairApos 1500000
        try {
            Assert-Baixado (Invoke-Download $s)
            $pedidos = Get-PedidoTeste $s
            $pedidos.Count | Should -Be 2
            $pedidos[1] | Should -Match '^GET /roms/jogo.chd bytes=\d+-$'
        } finally { Stop-ServidorTeste $s }
    }

    It 'parcial maior que o jogo e descartado' {
        $s = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's'
        try {
            $dest = Join-Path $TestDrive 'grande\Jogo.chd'
            New-Item (Split-Path $dest) -ItemType Directory -Force | Out-Null
            [IO.File]::WriteAllBytes("$dest.parcial", (New-Object byte[] ($Dados.Length + 10)))
            Assert-Baixado (Invoke-Download $s -Destino $dest)
        } finally { Stop-ServidorTeste $s }
    }

    It 'arquivo corrompido e descartado com erro' {
        $s = Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 's'
        try {
            $r = Invoke-Download $s -Sha ('0' * 40)
            $r.Codigo | Should -Be 1
            $r.Progresso.estado | Should -Be 'erro'
            $r.Progresso.msg | Should -Match 'corrompido'
            Test-Path -LiteralPath $r.Destino | Should -BeFalse
            Test-Path -LiteralPath "$($r.Destino).parcial" | Should -BeFalse
        } finally { Stop-ServidorTeste $s }
    }

    It 'erro do servidor (<status>) para na hora, sem tentar de novo' -TestCases @(@{ status = 401 }, @{ status = 404 }) {
        $s = if ($status -eq 401) { Start-ServidorTeste -Pasta $Srv -Usuario 'amigo' -Senha 'outra' } else { Start-ServidorTeste -Pasta $Srv -Status 404 }
        try {
            $r = Invoke-Download $s
            $r.Codigo | Should -Be 1
            $r.Progresso.estado | Should -Be 'erro'
            $r.Progresso.msg | Should -Match "erro $status"
            @(Get-PedidoTeste $s).Count | Should -Be 1
        } finally { Stop-ServidorTeste $s }
    }

    It 'sem sha1 no pedido nao confere o hash' {
        $s = Start-ServidorTeste -Pasta $Srv
        try { (Invoke-Download $s -Sha '').Progresso.estado | Should -Be 'ok' } finally { Stop-ServidorTeste $s }
    }
}
