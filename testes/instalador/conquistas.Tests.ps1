BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Ajuda.psm1') -Force
    . (Join-Path $Arquivos 'conquistas.ps1')
    function Read-Texto($p) { [IO.File]::ReadAllText($p) }
}

Describe 'Set-IniValue' {
    It 'cria arquivo, pasta e secao' {
        $ini = Join-Path $TestDrive 'novo\sub\a.ini'
        Set-IniValue $ini 'Achievements' 'Enabled' 'true'
        Read-Texto $ini | Should -Be "[Achievements]`r`nEnabled = true`r`n"
    }

    It 'troca a chave so na secao certa e mantem o resto' {
        $ini = Join-Path $TestDrive 'b.ini'
        [IO.File]::WriteAllText($ini, "[Outra]`r`nToken = fica`r`n`r`n[achievements]`r`nToken=velho`r`nUsername = x`r`n")
        Set-IniValue $ini 'Achievements' 'Token' 'novo'
        Read-Texto $ini | Should -Be "[Outra]`r`nToken = fica`r`n`r`n[achievements]`r`nToken = novo`r`nUsername = x`r`n"
    }

    It 'acrescenta a chave no fim da secao, antes das linhas em branco' {
        $ini = Join-Path $TestDrive 'c.ini'
        [IO.File]::WriteAllText($ini, "[Achievements]`r`nEnabled = true`r`n`r`n[UI]`r`nTema = escuro`r`n")
        Set-IniValue $ini 'Achievements' 'Username' 'ana'
        Read-Texto $ini | Should -Be "[Achievements]`r`nEnabled = true`r`nUsername = ana`r`n`r`n[UI]`r`nTema = escuro`r`n"
    }

    It 'nao confunde chave com prefixo nem caracteres de regex' {
        $ini = Join-Path $TestDrive 'd.ini'
        [IO.File]::WriteAllText($ini, "[S]`r`nTokenAntigo = 1`r`n")
        Set-IniValue $ini 'S' 'Token' '2'
        Set-IniValue $ini 'S' 'a.b' '3'
        Read-Texto $ini | Should -Be "[S]`r`nTokenAntigo = 1`r`nToken = 2`r`na.b = 3`r`n"
    }

    It 'grava sem BOM' {
        $ini = Join-Path $TestDrive 'e.ini'
        Set-IniValue $ini 'S' 'Nome' 'Joao'
        [IO.File]::ReadAllBytes($ini)[0] | Should -Be ([byte][char]'[')
    }
}

Describe 'Set-CfgValue' {
    It 'troca a linha existente e acrescenta a que falta, com aspas' {
        $cfg = Join-Path $TestDrive 'retroarch.cfg'
        [IO.File]::WriteAllText($cfg, "video_driver = `"gl`"`r`ncheevos_enable = `"false`"`r`n")
        Set-CfgValue $cfg 'cheevos_enable' 'true'
        Set-CfgValue $cfg 'cheevos_username' 'ana'
        Read-Texto $cfg | Should -Be "video_driver = `"gl`"`r`ncheevos_enable = `"true`"`r`ncheevos_username = `"ana`"`r`n"
    }
}

Describe 'Set-RaLogin' {
    It 'grava o token em cada emulador instalado e so neles' {
        $emu = Join-Path $TestDrive 'Emuladores'
        New-Item "$emu\RetroArch", "$emu\PPSSPP", "$emu\Dolphin" -ItemType Directory -Force | Out-Null
        Set-Content "$emu\RetroArch\retroarch.exe" ''

        $feito = Set-RaLogin $emu 'ana' 'TOKEN123'

        $feito | Should -Be @('RetroArch (PS1, DS, Game Boy)', 'PPSSPP (PSP)', 'Dolphin (GameCube)')
        $ra = Read-Texto "$emu\RetroArch\retroarch.cfg"
        $ra | Should -Match 'cheevos_token = "TOKEN123"'
        $ra | Should -Match 'cheevos_password = ""'
        Read-Texto "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp_retroachievements.dat" | Should -Be 'TOKEN123'
        Read-Texto "$emu\PPSSPP\memstick\PSP\SYSTEM\ppsspp.ini" | Should -Match 'AchievementsUserName = ana'
        Read-Texto "$emu\Dolphin\User\Config\RetroAchievements.ini" | Should -Match 'ApiToken = TOKEN123'
        Test-Path "$emu\PCSX2" | Should -BeFalse
    }

    It 'PCSX2 recebe token e horario do login' {
        $emu = Join-Path $TestDrive 'Emu2'
        New-Item "$emu\PCSX2\inis" -ItemType Directory -Force | Out-Null
        Set-RaLogin $emu 'ana' 'T' | Should -Be 'PCSX2 (PS2)'
        $ini = Read-Texto "$emu\PCSX2\inis\PCSX2.ini"
        $ini | Should -Match 'Token = T'
        $ini | Should -Match 'LoginTimestamp = \d{10}'
    }

    It 'RetroArch sem o exe fica de fora' {
        $emu = Join-Path $TestDrive 'Emu3'
        New-Item "$emu\RetroArch" -ItemType Directory -Force | Out-Null
        Set-RaLogin $emu 'ana' 'T' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RaToken' {
    It 'devolve usuario e token' {
        Mock Invoke-RestMethod { [pscustomobject]@{ Success = $true; User = 'Ana'; Token = 'TK' } }
        $r = Get-RaToken 'ana' 'senha'
        $r.Usuario | Should -Be 'Ana'; $r.Token | Should -Be 'TK'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $Body.r -eq 'login2' -and $Body.u -eq 'ana' -and $Body.p -eq 'senha' }
    }

    It 'resposta sem sucesso vira erro' {
        Mock Invoke-RestMethod { [pscustomobject]@{ Success = $false; Error = 'Conta bloqueada' } }
        { Get-RaToken 'ana' 'x' } | Should -Throw 'Conta bloqueada'
    }

    It 'senha errada vira mensagem em portugues' {
        Mock Invoke-RestMethod {
            $e = New-Object Management.Automation.ErrorRecord ([Exception]'401'), 'x', 'NotSpecified', $null
            $e.ErrorDetails = '{"Success":false,"Error":"Invalid user/password combination. Please try again."}'
            throw $e
        }
        { Get-RaToken 'ana' 'x' } | Should -Throw 'Usuario ou senha incorretos.'
    }

    It 'sem internet' {
        Mock Invoke-RestMethod { throw 'nome nao resolvido' }
        { Get-RaToken 'ana' 'x' } | Should -Throw 'Nao consegui falar com o RetroAchievements*'
    }
}
