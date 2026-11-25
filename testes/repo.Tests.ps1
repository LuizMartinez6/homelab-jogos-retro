# Regras do repositorio que ja quebraram ou que protegem segredos.
BeforeDiscovery {
    $RaizRepo = Split-Path $PSScriptRoot -Parent
    $Scripts = @(Get-ChildItem $RaizRepo -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\(\.git|saida)\\' } |
        ForEach-Object { $_.FullName.Substring($RaizRepo.Length + 1) })
}
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Ajuda.psm1') -Force
    $Git = [bool](Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $Raiz '.git'))
    function Get-Rastreado { git -C $Raiz ls-files }
}

Describe 'Scripts PowerShell' {
    It '<_> abre sem erro de sintaxe no Windows PowerShell 5.1' -ForEach $Scripts {
        $erros = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Raiz $_), [ref]$null, [ref]$erros)
        $erros | Should -BeNullOrEmpty
    }

    It '<_> com acento tem BOM (sem BOM o 5.1 le como ANSI e estraga o texto)' -ForEach $Scripts {
        $b = [IO.File]::ReadAllBytes((Join-Path $Raiz $_))
        $temBom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
        $naoAscii = @($b | Where-Object { $_ -gt 127 }).Count -gt ($(if ($temBom) { 3 } else { 0 }))
        if ($naoAscii) { $temBom | Should -BeTrue }
    }

    It 'os .bat abrem scripts que existem' {
        foreach ($bat in Get-ChildItem (Join-Path $Raiz 'instalador') -Filter *.bat) {
            $m = [regex]::Match((Get-Content $bat.FullName -Raw), '-File "%~dp0arquivos\\([^"]+)"')
            $m.Success | Should -BeTrue -Because $bat.Name
            Test-Path (Join-Path $Arquivos $m.Groups[1].Value) | Should -BeTrue -Because $bat.Name
        }
    }
}

Describe 'Contratos entre arquivos' {
    It 'o Id da extensao Jogos de PC e o mesmo no launcher e no publicar-plugin' {
        $id = 'JogosPc_c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3'
        Get-Content (Join-Path $Arquivos 'launcher.ps1') -Raw | Should -Match ([regex]::Escape("Extensions\$id"))
        Get-Content (Join-Path $Raiz 'ferramentas\publicar-plugin.ps1') -Raw | Should -Match ([regex]::Escape("Extensions\$id"))
        ([regex]::Matches((Get-Content (Join-Path $Arquivos 'launcher.ps1') -Raw), 'JogosPc_[0-9a-f-]{36}') | ForEach-Object Value | Sort-Object -Unique) | Should -Be $id
    }

    It 'o GUID do plugin do RomM e o mesmo em todo lugar' {
        $guid = '9700aa21-447d-41b4-a989-acd38f407d9f'
        foreach ($f in 'instalador\arquivos\setup.ps1', 'instalador\arquivos\instalacao.ps1', 'instalador\arquivos\launcher.ps1', 'ferramentas\plugin\gerar-romm-sem-instalador.ps1') {
            Get-Content (Join-Path $Raiz $f) -Raw | Should -Match $guid -Because $f
        }
        (Get-Atribuicao (Join-Path $Arquivos 'setup.ps1') 'RommPluginGuid') | Should -Be $guid
    }

    It 'publicar-atualizacao assina exatamente o que o atualizador confere ("versao|sha256", SHA256)' {
        Get-Content (Join-Path $Raiz 'ferramentas\publicar-atualizacao.ps1') -Raw | Should -Match ([regex]::Escape('SignData([Text.Encoding]::UTF8.GetBytes("$versao|$sha"), ''SHA256'')'))
        Get-Content (Join-Path $Arquivos 'atualizador.ps1') -Raw | Should -Match ([regex]::Escape('[Text.Encoding]::UTF8.GetBytes("$versao|$sha256")'))
    }

    It 'trechos do LEIA-ME trocados na edicao Tailscale existem' {
        $leia = (Get-Content (Join-Path $Raiz 'instalador\LEIA-ME.txt') -Raw -Encoding UTF8) -replace '\r?\n', "`r`n"
        $trocas = Get-Atribuicao (Join-Path $Raiz 'ferramentas\gerar-zips.ps1') 'TrocasTailscale'
        foreach ($t in $trocas.Keys) { $leia.Contains($t) | Should -BeTrue -Because $t.Substring(0, 40) }
    }
}

Describe 'Segredos fora do git' {
    BeforeAll { if (-not $Git) { return } ; $Rastreados = @(Get-Rastreado) }

    It 'nenhum arquivo de segredo esta no git' {
        if (-not $Git) { Set-ItResult -Skipped -Because 'sem git'; return }
        $proibidos = $Rastreados | Where-Object { $_ -match '(^|/)(config\.json|atualizacao-privada\.xml|logins\.txt|amigos\.json|painel\.json|netbird-token\.txt|senha-painel\.txt|\.env)$|\.(htpasswd|pem|key)$' }
        $proibidos | Should -BeNullOrEmpty
    }

    It 'nenhuma chave privada RSA versionada (<D> e <P> so existem na privada)' {
        if (-not $Git) { Set-ItResult -Skipped -Because 'sem git'; return }
        # Conteudo de chave de verdade (<D> seguido de base64), nao a simples mencao nos documentos.
        $achou = git -C $Raiz grep -nIlE '<(D|P|Q|DP|DQ|InverseQ)>[A-Za-z0-9+/]{16}|BEGIN [A-Z ]*PRIVATE KEY' -- . ':!testes/*'
        $achou | Should -BeNullOrEmpty
    }

    It 'a chave publica no atualizador nao e a privada' {
        $chave = Get-Atribuicao (Join-Path $Arquivos 'atualizador.ps1') 'AtualizacaoChavePublica'
        $chave | Should -Not -Match '<D>|<P>|<Q>'
    }

    It 'o .gitignore cobre os segredos que as ferramentas criam' {
        $ignorar = Get-Content (Join-Path $Raiz '.gitignore')
        foreach ($p in 'config.json', 'atualizacao-privada.xml', 'versao-publicada.txt', 'saida/', '*.zip', '*.exe') { $ignorar | Should -Contain $p }
    }
}

Describe 'Finais de linha' {
    It 'o git guarda tudo normalizado (LF no indice)' {
        if (-not $Git) { Set-ItResult -Skipped -Because 'sem git'; return }
        $ruins = git -C $Raiz ls-files --eol | Where-Object { $_ -match '^i/(crlf|mixed)' }
        $ruins | Should -BeNullOrEmpty
    }

    It 'a copia de trabalho segue o .gitattributes (CRLF nos scripts do Windows, LF no servidor)' {
        if (-not $Git) { Set-ItResult -Skipped -Because 'sem git'; return }
        $ruins = git -C $Raiz ls-files --eol | Where-Object { ($_ -match 'eol=crlf' -and $_ -notmatch 'w/crlf') -or ($_ -match 'eol=lf' -and $_ -notmatch 'w/lf') }
        $ruins | Should -BeNullOrEmpty -Because 'com tudo commitado, rode: git rm -r --cached -q . ; git reset --hard'
    }
}
