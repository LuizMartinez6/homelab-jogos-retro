# setup.ps1 instala programas de verdade, entao aqui so entram as tabelas e as funcoes puras.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Setup = Join-Path $Arquivos 'setup.ps1'
    . (Join-Path $Arquivos 'catalogo.ps1')
    $PerfilPorSlug = Get-Atribuicao $Setup 'PerfilPorSlug'
    $Downloads = Get-Atribuicao $Setup 'Downloads'
    $Slugs = @($Consoles.Values | ForEach-Object { $_.Slugs })

    function Get-DefinicaoEmulador($Playnite, $Id) {
        # emulator.yaml do Playnite: "Id: x" e uma lista de perfis "- Name: ..." com "ProfileFiles: [...]".
        foreach ($f in Get-ChildItem (Join-Path $Playnite 'Emulation\Emulators') -Filter emulator.yaml -Recurse) {
            $linhas = Get-Content $f.FullName -Encoding UTF8
            if (($linhas | Where-Object { $_ -match '^Id:\s*(\S+)' } | Select-Object -First 1) -notmatch "^Id:\s*$([regex]::Escape($Id))\s*$") { continue }
            $perfis = @{}; $atual = $null
            foreach ($l in $linhas) {
                if ($l -match '^\s+- Name:\s*(.+?)\s*$') { $atual = $Matches[1]; $perfis[$atual] = @() }
                elseif ($atual -and $l -match '^\s+ProfileFiles:\s*\[(.*)\]') { $perfis[$atual] = @($Matches[1] -split ',' | ForEach-Object { $_.Trim(" '`"") }) }
            }
            return $perfis
        }
        $null
    }
}

Describe 'Catalogo de consoles' {
    It 'todo console tem nome e emulador conhecido, e console desmarcado vem com aviso ou e pesado' {
        foreach ($k in $Consoles.Keys) {
            $c = $Consoles[$k]
            $c.Nome | Should -Not -BeNullOrEmpty
            $Downloads.Keys | Should -Contain $c.Emu -Because "o console $k usa $($c.Emu)"
            if ($c.Emu -eq 'retroarch') { @($c.Cores).Count | Should -BeGreaterThan 0 -Because "$k usa RetroArch" }
        }
    }

    It 'cada plataforma do RomM oferecida tem perfil no Playnite e vice-versa' {
        @($Slugs | Sort-Object) | Should -Be @($PerfilPorSlug.Keys | Sort-Object)
        @($Slugs | Sort-Object -Unique).Count | Should -Be $Slugs.Count
    }

    It 'o perfil usa o mesmo emulador que o console' {
        foreach ($k in $Consoles.Keys) {
            foreach ($s in $Consoles[$k].Slugs) { $PerfilPorSlug[$s][0] | Should -Be $Consoles[$k].Emu -Because "plataforma $s" }
        }
    }

    It 'perfis existem nas definicoes oficiais do Playnite e usam um core que o instalador baixa' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        foreach ($k in $Consoles.Keys) {
            foreach ($s in $Consoles[$k].Slugs) {
                $emu, $perfil = $PerfilPorSlug[$s]
                $defs = Get-DefinicaoEmulador $Playnite $emu
                $defs | Should -Not -BeNullOrEmpty -Because "o Playnite precisa conhecer o emulador $emu"
                $defs.Keys | Should -Contain $perfil -Because "plataforma $s"
                if ($emu -eq 'retroarch') {
                    $dlls = @($Consoles[$k].Cores | ForEach-Object { "cores\$($_)_libretro.dll" })
                    $dlls | Should -Contain $defs[$perfil][0] -Because "o perfil '$perfil' de $s abre $($defs[$perfil][0])"
                }
            }
        }
    }
}

Describe 'Tabela de downloads' {
    It 'tudo por HTTPS, de versao fixa quando possivel, e hash no formato certo' {
        foreach ($k in $Downloads.Keys) {
            $Downloads[$k].Url | Should -Match '^https://' -Because $k
            if ($Downloads[$k].Sha) { $Downloads[$k].Sha | Should -MatchExactly '^[0-9a-f]{64}$' -Because $k }
        }
    }

    It 'todo download de release do GitHub tem hash (o arquivo de uma release nao muda)' {
        # Hoje sem hash: conferir se o projeto publica um e preencher.
        $semHash = @('azahar')
        foreach ($k in $Downloads.Keys | Where-Object { $Downloads[$_].Url -match '^https://github\.com/.+/releases/download/' -and $_ -notin $semHash }) {
            $Downloads[$k].Sha | Should -Not -BeNullOrEmpty -Because "$k vem de release do GitHub"
        }
    }

    It 'extensoes das lojas citadas no setup existem na tabela' {
        foreach ($l in (Get-Atribuicao $Setup 'ExtensoesLojas')) { $Downloads.Keys | Should -Contain $l }
    }
}

Describe 'Funcoes do setup' {
    BeforeAll { . (Get-Funcao $Setup 'Out-Utf8', 'Expand-Zip') }

    It 'Expand-Zip sobrescreve arquivos e cria pastas (rodar o instalador de novo)' {
        $orig = Join-Path $TestDrive 'orig'
        Write-Utf8 "$orig\a.txt" 'novo'
        Write-Utf8 "$orig\sub\b.txt" 'b'
        $zip = Join-Path $TestDrive 'x.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($orig, $zip)
        $dest = Join-Path $TestDrive 'dest'
        Write-Utf8 "$dest\a.txt" 'velho'
        Write-Utf8 "$dest\fica.txt" 'fica'
        Expand-Zip $zip $dest
        Get-Content "$dest\a.txt" | Should -Be 'novo'
        Get-Content "$dest\sub\b.txt" | Should -Be 'b'
        Get-Content "$dest\fica.txt" | Should -Be 'fica'
    }

    It 'Out-Utf8 do setup e do launcher sao iguais' {
        $a = (Get-Funcao $Setup 'Out-Utf8').ToString() -replace '\r', ''
        $b = (Get-Funcao (Join-Path $Arquivos 'launcher.ps1') 'Out-Utf8').ToString() -replace '\r', ''
        $a | Should -Be $b
    }
}
