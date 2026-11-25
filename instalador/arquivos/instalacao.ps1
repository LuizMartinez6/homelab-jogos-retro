# Funcoes compartilhadas pelas ferramentas que rodam depois da instalacao
# (Conectar Conquistas, Baixar Jogo).

function Find-Instalacao {
    # A pasta da instalacao e a do launcher.ps1 que o atalho "Jogos Retro" abre.
    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Jogos Retro.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Jogos Retro.lnk'))) {
        if ((Test-Path $lnk) -and $ws.CreateShortcut($lnk).Arguments -match '-File "([^"]+)\\launcher\.ps1"') { return $Matches[1] }
    }
    if (Test-Path "$env:SystemDrive\JogosRetro\Emuladores") { return "$env:SystemDrive\JogosRetro" }
    $null
}

function Get-RommConexao($base) {
    # Endereco (rede local se der, senao NetBird, senao Tailscale), login e pastas por
    # console, tudo tirado da configuracao que o instalador deixou para o plugin do RomM.
    $L = Get-Content (Join-Path $base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg = Get-Content $L.rommConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    $alvo = @($L.tailscale, $L.netbird, $L.lan) | Where-Object { $_ } | Select-Object -First 1
    foreach ($t in @(@($L.lan, 1500), @($L.netbird, 3000))) {
        if (-not $t[0]) { continue }
        $u = [Uri]$t[0]
        $ok = try { $c = New-Object Net.Sockets.TcpClient; $r = $c.ConnectAsync($u.Host, $u.Port).Wait($t[1]); $c.Close(); $r } catch { $false }
        if ($ok) { $alvo = $t[0]; break }
    }
    [pscustomobject]@{
        Api      = $alvo.TrimEnd('/') + '/api'
        Auth     = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cfg.RomMUsername):$($cfg.RomMPassword)"))
        Mappings = @($cfg.Mappings | Where-Object { $_.Enabled })
    }
}

function Test-PlayniteAberto($base) {
    $raiz = (Get-Content (Join-Path $base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json).playnite
    [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Playnite.*' -and $_.Path -and $_.Path.StartsWith($raiz, 'OrdinalIgnoreCase') })
}

function Sync-JogosInstalados($base) {
    # O plugin do RomM so confere se o arquivo existe quando o jogo entra pela primeira vez
    # na biblioteca; jogo ja importado continua "nao instalado". Marca como instalado o jogo
    # do RomM cujo arquivo ja esta no caminho registrado. Exige o Playnite fechado.
    $raiz = (Get-Content (Join-Path $base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json).playnite
    Add-Type -Path (Join-Path $raiz 'LiteDB.dll')
    $db = New-Object LiteDB.LiteDatabase("Filename=$(Join-Path $raiz 'library\games.db')")
    $marcados = @()
    try {
        $col = $db.GetCollection('Game')
        foreach ($g in @($col.FindAll())) {
            if ($g['PluginId'].AsGuid -ne [guid]'9700aa21-447d-41b4-a989-acd38f407d9f' -or $g['IsInstalled'].AsBoolean) { continue }
            if ($g['Roms'].IsNull -or $g['Roms'].AsArray.Count -eq 0) { continue }
            $arquivo = $g['Roms'].AsArray[0]['Path'].AsString
            if ($arquivo) { $arquivo = $arquivo.Replace('{PlayniteDir}', $raiz) }
            if ($arquivo -and (Test-Path -LiteralPath $arquivo)) {
                $g['IsInstalled'] = New-Object LiteDB.BsonValue($true); [void]$col.Update($g); $marcados += $g['Name'].AsString
            }
        }
    } finally { $db.Dispose() }
    $marcados
}

function Get-CaminhoJogo($mapping, $fsName) {
    # Mesma regra do plugin (RomMInstallPaths): <pasta>\<nome sem extensao>\<arquivo>,
    # ou <pasta>\<arquivo> quando o mapeamento e "plano".
    if ($mapping.InstallFlat) { return Join-Path $mapping.DestinationPath $fsName }
    Join-Path (Join-Path $mapping.DestinationPath ([IO.Path]::GetFileNameWithoutExtension($fsName))) $fsName
}
