BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Ferramentas = Join-Path $Raiz 'ferramentas'
    $ExeFalso = Join-Path $TestDrive 'falso\scp.exe'
    New-ExeFalso $ExeFalso -Console
    # O dono roda as ferramentas no PowerShell 7; sem ele, o 5.1 serve.
    $Pwsh = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

    function Invoke-Ferramenta([string]$Script, [hashtable]$Ambiente = @{}, [string]$Argumentos = '') {
        $psi = New-Object Diagnostics.ProcessStartInfo $Pwsh, "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" $Argumentos"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        foreach ($k in $Ambiente.Keys) { $psi.EnvironmentVariables[$k] = $Ambiente[$k] }
        $p = [Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "$Script passou de 3 min" }
        [pscustomobject]@{ Codigo = $p.ExitCode; Saida = $out + $err.Result }
    }

    function Get-EntradaZip($zip, $nome) {
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $e = $z.Entries | Where-Object FullName -eq $nome
            if (-not $e) { return $null }
            $r = New-Object IO.StreamReader($e.Open()); try { $r.ReadToEnd() } finally { $r.Dispose() }
        } finally { $z.Dispose() }
    }

    # Copia do repositorio: as ferramentas acham o resto pelo caminho relativo.
    function New-Repo {
        $repo = Join-Path $TestDrive "repo-$([guid]::NewGuid())"
        Copy-Item (Join-Path $Raiz 'instalador') "$repo\instalador" -Recurse
        Copy-Item (Join-Path $Raiz 'instalador\arquivos\config.example.json') "$repo\instalador\arquivos\config.json"
        New-Item "$repo\ferramentas\exe" -ItemType Directory -Force | Out-Null
        $repo
    }
}

Describe 'gerar-chaves.ps1' {
    It 'cria a chave privada RSA 3072 e mostra a publica; nao sobrescreve' {
        $pasta = Join-Path $TestDrive 'chaves'
        New-Item $pasta -ItemType Directory | Out-Null
        Copy-Item "$Ferramentas\gerar-chaves.ps1" $pasta
        $r = Invoke-Ferramenta "$pasta\gerar-chaves.ps1"
        $r.Codigo | Should -Be 0 -Because $r.Saida
        $privada = Get-Content "$pasta\atualizacao-privada.xml" -Raw
        $privada | Should -Match '<D>'
        $publica = [regex]::Match($r.Saida, '<RSAKeyValue>.*?</RSAKeyValue>').Value
        $publica | Should -Not -Match '<D>'
        [Convert]::FromBase64String(([xml]$publica).RSAKeyValue.Modulus).Length * 8 | Should -Be 3072

        $sig = Get-AssinaturaTeste $privada 'teste'
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider; $rsa.FromXmlString($publica)
        $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes('teste'), 'SHA256', [Convert]::FromBase64String($sig)) | Should -BeTrue

        (Invoke-Ferramenta "$pasta\gerar-chaves.ps1").Codigo | Should -Not -Be 0
        Get-Content "$pasta\atualizacao-privada.xml" -Raw | Should -Be $privada
    }
}

Describe 'publicar-atualizacao.ps1 + atualizador.ps1 (ponta a ponta)' {
    BeforeAll {
        $repo = New-Repo
        $Chave = New-ChaveRsa
        [IO.File]::WriteAllText("$repo\ferramentas\atualizacao-privada.xml", $Chave.Privada)
        Copy-ScriptTrocado "$Ferramentas\publicar-atualizacao.ps1" "$repo\ferramentas\publicar-atualizacao.ps1" @{
            '"$env:WINDIR\System32\OpenSSH\ssh.exe"' = "'$ExeFalso'"
            '"$env:WINDIR\System32\OpenSSH\scp.exe"' = "'$ExeFalso'"
        }
        $Servidor = Join-Path $TestDrive 'servidor'
        $Log = Join-Path $TestDrive 'publicar.log'
        $r = Invoke-Ferramenta "$repo\ferramentas\publicar-atualizacao.ps1" @{ EXE_FALSO_LOG = $Log; EXE_FALSO_COPIA = "$Servidor\instalador" }
    }

    It 'envia pacote e manifesto, e ativa o manifesto por ultimo' {
        $r.Codigo | Should -Be 0 -Because $r.Saida
        $r.Saida | Should -Match 'Versao 1 publicada.'
        Get-Content "$repo\ferramentas\versao-publicada.txt" | Should -Be '1'
        $chamadas = Get-Content $Log
        $chamadas.Count | Should -Be 3
        $chamadas[0] | Should -Match '\|usuario@192\.168\.0\.10:/DATA/AppData/jogos-pc/instalador/programa-1\.zip$'
        $chamadas[1] | Should -Match ':/DATA/AppData/jogos-pc/instalador/versao\.json\.tmp$'
        $chamadas[2] | Should -Match 'mv /DATA/AppData/jogos-pc/instalador/versao\.json\.tmp /DATA/AppData/jogos-pc/instalador/versao\.json$'
        $chamadas | ForEach-Object { $_ | Should -Match '\|BatchMode=yes\|' }
    }

    It 'o pacote leva todos os scripts, menos o config.json com a senha' {
        $zip = "$Servidor\instalador\programa-1.zip"
        $nomes = [IO.Compression.ZipFile]::OpenRead($zip) | ForEach-Object { try { $_.Entries.FullName } finally { $_.Dispose() } }
        $nomes | Should -Not -Contain 'config.json'
        $nomes | Should -Contain 'launcher.ps1'
        $nomes | Should -Contain 'atualizador.ps1'
        (Get-EntradaZip $zip 'versao.txt').Trim() | Should -Be '1'
        @($nomes).Count | Should -Be (@(Get-ChildItem "$Raiz\instalador\arquivos" -File | Where-Object Name -ne 'config.json').Count + 1)
    }

    It 'o atualizador de um amigo aceita a versao publicada' {
        Copy-Item "$Servidor\instalador\versao.json.tmp" "$Servidor\instalador\versao.json"
        Write-Utf8 "$Servidor\saude" 'ok'
        $srv = Start-ServidorTeste -Pasta $Servidor -Usuario 'ana' -Senha 's'
        try {
            . (Join-Path $Arquivos 'atualizador.ps1')
            $AtualizacaoChavePublica = $Chave.Publica
            $base = Join-Path $TestDrive 'amigo'
            Write-Utf8 "$base\launcher.json" (@{ jogos = @{ lan = $srv.Url; usuario = 'ana'; senha = 's' } } | ConvertTo-Json)
            Update-JogosRetro $base | Should -BeTrue
            Get-Content "$base\programa\versao.txt" | Should -Be '1'
            Test-Path "$base\launcher.ps1" | Should -BeTrue
        } finally { Stop-ServidorTeste $srv }
    }

    It 'a versao seguinte sobe o numero' {
        (Invoke-Ferramenta "$repo\ferramentas\publicar-atualizacao.ps1" @{ EXE_FALSO_COPIA = "$Servidor\instalador" }).Codigo | Should -Be 0
        Get-Content "$repo\ferramentas\versao-publicada.txt" | Should -Be '2'
        (Get-Content "$Servidor\instalador\versao.json.tmp" -Raw | ConvertFrom-Json).arquivo | Should -Be 'programa-2.zip'
    }

    It '-Teste publica so no manifesto de teste' {
        Remove-Item $Log -ErrorAction SilentlyContinue
        $r = Invoke-Ferramenta "$repo\ferramentas\publicar-atualizacao.ps1" @{ EXE_FALSO_LOG = $Log; EXE_FALSO_COPIA = "$Servidor\instalador" } '-Teste'
        $r.Codigo | Should -Be 0 -Because $r.Saida
        $r.Saida | Should -Match 'Versao 3 publicada so para o canal de teste'
        (Get-Content $Log)[2] | Should -Match 'mv /DATA/AppData/jogos-pc/instalador/versao-teste\.json\.tmp /DATA/AppData/jogos-pc/instalador/versao-teste\.json$'
        (Get-Content "$Servidor\instalador\versao-teste.json.tmp" -Raw | ConvertFrom-Json).versao | Should -Be 3
    }

    It '-Liberar troca o manifesto de todos pelo de teste, sem novo pacote' {
        Remove-Item $Log -ErrorAction SilentlyContinue
        $r = Invoke-Ferramenta "$repo\ferramentas\publicar-atualizacao.ps1" @{ EXE_FALSO_LOG = $Log } '-Liberar'
        $r.Codigo | Should -Be 0 -Because $r.Saida
        @(Get-Content $Log).Count | Should -Be 1
        @(Get-Content $Log)[0] | Should -Match 'cp /DATA/AppData/jogos-pc/instalador/versao-teste\.json /DATA/AppData/jogos-pc/instalador/versao\.json\.tmp && .* && mv '
        Get-Content "$repo\ferramentas\versao-publicada.txt" | Should -Be '3'
    }

    It '-Voltar republica o conteudo de uma versao antiga com numero novo' {
        $r = Invoke-Ferramenta "$repo\ferramentas\publicar-atualizacao.ps1" @{ EXE_FALSO_COPIA = "$Servidor\instalador" } '-Voltar 1'
        $r.Codigo | Should -Be 0 -Because $r.Saida
        $zip = "$Servidor\instalador\programa-4.zip"
        (Get-EntradaZip $zip 'versao.txt').Trim() | Should -Be '4'
        $nomes = { param($z) [IO.Compression.ZipFile]::OpenRead($z) | ForEach-Object { try { $_.Entries.FullName | Sort-Object } finally { $_.Dispose() } } }
        & $nomes $zip | Should -Be (& $nomes "$Servidor\instalador\programa-1.zip")
    }

    It 'recusa publicar pacote com script que nao abre no PowerShell 5.1' {
        [IO.File]::WriteAllText("$repo\instalador\arquivos\quebrado.ps1", "function Teste {`r`n")
        try {
            $r = Invoke-Ferramenta "$repo\ferramentas\publicar-atualizacao.ps1" @{ EXE_FALSO_COPIA = "$Servidor\instalador" }
            $r.Codigo | Should -Not -Be 0
            $r.Saida | Should -Match 'quebrado\.ps1'
            Get-Content "$repo\ferramentas\versao-publicada.txt" | Should -Be '4'
        } finally { Remove-Item "$repo\instalador\arquivos\quebrado.ps1" }
    }
}

Describe 'gerar-icone.ps1 + gerar-zips.ps1' {
    BeforeAll {
        $repo = New-Repo
        Copy-Item "$Ferramentas\exe\Instalador.cs", "$Ferramentas\exe\gerar-icone.ps1" "$repo\ferramentas\exe"
        Copy-ScriptTrocado "$Ferramentas\gerar-zips.ps1" "$repo\ferramentas\gerar-zips.ps1" @{ '"$env:WINDIR\System32\OpenSSH\scp.exe"' = "'$ExeFalso'" }
        $Painel = Join-Path $TestDrive 'painel'
        $icone = Invoke-Ferramenta "$repo\ferramentas\exe\gerar-icone.ps1"
        $r = Invoke-Ferramenta "$repo\ferramentas\gerar-zips.ps1" @{ EXE_FALSO_COPIA = $Painel }
        $Saida = "$repo\saida"
    }

    It 'gera um .ico valido com 7 tamanhos' {
        $icone.Codigo | Should -Be 0 -Because $icone.Saida
        $b = [IO.File]::ReadAllBytes("$repo\ferramentas\exe\jogos.ico")
        [BitConverter]::ToUInt16($b, 2) | Should -Be 1   # tipo icone
        [BitConverter]::ToUInt16($b, 4) | Should -Be 7   # quantidade de imagens
    }

    It 'gera as duas edicoes em zip e exe e manda os exe para o painel Amigos' {
        $r.Codigo | Should -Be 0 -Because $r.Saida
        @(Get-ChildItem $Saida -Name | Sort-Object) | Should -Be @('Instalador-Jogos-NetBird.zip', 'Instalador-Jogos-Tailscale.zip',
            'Instalar Jogos Retro (NetBird).exe', 'Instalar Jogos Retro (Tailscale).exe')
        @(Get-ChildItem $Painel -Name | Sort-Object) | Should -Be @('Instalar Jogos Retro (NetBird).exe', 'Instalar Jogos Retro (Tailscale).exe')
    }

    It 'cada edicao so conhece o proprio caminho' {
        $nb = Get-EntradaZip "$Saida\Instalador-Jogos-NetBird.zip" 'arquivos/config.json' | ConvertFrom-Json
        $ts = Get-EntradaZip "$Saida\Instalador-Jogos-Tailscale.zip" 'arquivos/config.json' | ConvertFrom-Json
        $nb.servidor.PSObject.Properties.Name | Should -Be @('lan', 'netbird')
        $nb.jogos.PSObject.Properties.Name | Should -Be @('lan', 'netbird')
        $ts.servidor.PSObject.Properties.Name | Should -Be @('lan', 'tailscale')
        $ts.jogos.PSObject.Properties.Name | Should -Be @('lan', 'tailscale')
    }

    It 'LEIA-ME da edicao Tailscale fala do Tailscale' {
        $nb = Get-EntradaZip "$Saida\Instalador-Jogos-NetBird.zip" 'LEIA-ME.txt'
        $ts = Get-EntradaZip "$Saida\Instalador-Jogos-Tailscale.zip" 'LEIA-ME.txt'
        $nb | Should -Match 'NetBird precisa estar ligado'
        $ts | Should -Match 'o Tailscale precisa estar ligado'
        $ts | Should -Not -Match 'NetBird'
    }

    It 'o exe leva o zip da mesma edicao embutido' {
        $exe = "$Saida\Instalar Jogos Retro (Tailscale).exe"
        # Em outro processo, para o exe nao ficar preso a este.
        $rec = powershell.exe -NoProfile -Command "[Reflection.Assembly]::LoadFile('$exe').GetManifestResourceNames()"
        $rec | Should -Be 'pacote.zip'
        $m = powershell.exe -NoProfile -Command "`$s = [Reflection.Assembly]::LoadFile('$exe').GetManifestResourceStream('pacote.zip'); `$m = New-Object IO.MemoryStream; `$s.CopyTo(`$m); [Convert]::ToBase64String((New-Object Security.Cryptography.SHA256Managed).ComputeHash(`$m.ToArray()))"
        $m | Should -Be ([Convert]::ToBase64String((New-Object Security.Cryptography.SHA256Managed).ComputeHash([IO.File]::ReadAllBytes("$Saida\Instalador-Jogos-Tailscale.zip"))))
    }

    It 'recusa gerar se o config.json tiver o login de alguem' {
        $cfg = Get-Content "$repo\instalador\arquivos\config.json" -Raw | ConvertFrom-Json
        $cfg.jogos | Add-Member usuario 'ana'
        Write-Utf8 "$repo\instalador\arquivos\config.json" ($cfg | ConvertTo-Json -Depth 5)
        $r2 = Invoke-Ferramenta "$repo\ferramentas\gerar-zips.ps1"
        $r2.Codigo | Should -Not -Be 0
        $r2.Saida | Should -Match 'tem login de pessoa'
    }
}
