# Login unico no RetroAchievements para todos os emuladores: troca usuario e
# senha pelo token da conta (a senha nao e guardada em lugar nenhum) e grava o
# token onde cada emulador procura. Usado pelo setup.ps1 e pelo Conectar Conquistas.

function Get-RaToken($usuario, $senha) {
    $body = @{ r = 'login2'; u = $usuario; p = $senha }
    try { $r = Invoke-RestMethod -Method Post -Uri 'https://retroachievements.org/dorequest.php' -Body $body -UserAgent 'JogosRetro/1.0' -UseBasicParsing -TimeoutSec 30 }
    catch {
        $msg = try { ($_.ErrorDetails.Message | ConvertFrom-Json).Error } catch { $null }
        if ($msg -match 'Invalid user/password') { $msg = 'Usuario ou senha incorretos.' }
        throw $(if ($msg) { $msg } else { "Nao consegui falar com o RetroAchievements: $($_.Exception.Message)" })
    }
    if (-not $r.Success -or -not $r.Token) { throw $(if ($r.Error) { $r.Error } else { 'Usuario ou senha incorretos.' }) }
    [pscustomobject]@{ Usuario = $r.User; Token = $r.Token }
}

function Set-IniValue($path, $section, $key, $value) {
    # Grava "key = value" dentro de [section], criando arquivo/secao/chave se faltar.
    $linhas = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path $path) { foreach ($l in [IO.File]::ReadAllLines($path)) { $linhas.Add($l) } }
    $ini = -1
    for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i].Trim() -ieq "[$section]") { $ini = $i; break } }
    if ($ini -lt 0) {
        if ($linhas.Count -and $linhas[$linhas.Count - 1].Trim()) { $linhas.Add('') }
        $linhas.Add("[$section]"); $linhas.Add("$key = $value")
    } else {
        $fim = $linhas.Count
        for ($i = $ini + 1; $i -lt $linhas.Count; $i++) { if ($linhas[$i].TrimStart().StartsWith('[')) { $fim = $i; break } }
        $achou = $false
        for ($i = $ini + 1; $i -lt $fim; $i++) {
            if ($linhas[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $linhas[$i] = "$key = $value"; $achou = $true; break }
        }
        if (-not $achou) {
            $pos = $fim; while ($pos -gt $ini + 1 -and -not $linhas[$pos - 1].Trim()) { $pos-- }
            $linhas.Insert($pos, "$key = $value")
        }
    }
    New-Item (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllLines($path, $linhas, (New-Object Text.UTF8Encoding $false))
}

function Set-CfgValue($path, $key, $value) {
    # retroarch.cfg nao tem secoes: uma linha key = "value" por opcao.
    $linhas = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path $path) { foreach ($l in [IO.File]::ReadAllLines($path)) { $linhas.Add($l) } }
    $nova = "$key = `"$value`""; $achou = $false
    for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $linhas[$i] = $nova; $achou = $true; break } }
    if (-not $achou) { $linhas.Add($nova) }
    [IO.File]::WriteAllLines($path, $linhas, (New-Object Text.UTF8Encoding $false))
}

function Set-RaLogin($emuladores, $usuario, $token) {
    # Devolve a lista de emuladores conectados (so os que estao instalados).
    $feito = @()
    $d = Join-Path $emuladores 'RetroArch'
    if (Test-Path (Join-Path $d 'retroarch.exe')) {
        $cfg = Join-Path $d 'retroarch.cfg'
        Set-CfgValue $cfg 'cheevos_enable' 'true'; Set-CfgValue $cfg 'cheevos_username' $usuario
        Set-CfgValue $cfg 'cheevos_token' $token; Set-CfgValue $cfg 'cheevos_password' ''
        $feito += 'RetroArch (PS1, DS, Game Boy)'
    }
    $d = Join-Path $emuladores 'PPSSPP'
    if (Test-Path $d) {
        $sys = Join-Path $d 'memstick\PSP\SYSTEM'; New-Item $sys -ItemType Directory -Force | Out-Null
        Set-IniValue (Join-Path $sys 'ppsspp.ini') 'Achievements' 'AchievementsEnable' 'True'
        Set-IniValue (Join-Path $sys 'ppsspp.ini') 'Achievements' 'AchievementsUserName' $usuario
        [IO.File]::WriteAllText((Join-Path $sys 'ppsspp_retroachievements.dat'), $token)
        $feito += 'PPSSPP (PSP)'
    }
    $d = Join-Path $emuladores 'PCSX2'
    if (Test-Path $d) {
        $ini = Join-Path $d 'inis\PCSX2.ini'
        Set-IniValue $ini 'Achievements' 'Enabled' 'true'; Set-IniValue $ini 'Achievements' 'Username' $usuario
        Set-IniValue $ini 'Achievements' 'Token' $token
        Set-IniValue $ini 'Achievements' 'LoginTimestamp' ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $feito += 'PCSX2 (PS2)'
    }
    $d = Join-Path $emuladores 'Dolphin'
    if (Test-Path $d) {
        $ini = Join-Path $d 'User\Config\RetroAchievements.ini'
        Set-IniValue $ini 'Achievements' 'Enabled' 'True'; Set-IniValue $ini 'Achievements' 'Username' $usuario
        Set-IniValue $ini 'Achievements' 'ApiToken' $token
        $feito += 'Dolphin (GameCube)'
    }
    $feito
}
