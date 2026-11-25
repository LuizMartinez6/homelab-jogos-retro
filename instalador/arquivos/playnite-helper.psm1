# Extensao temporaria do Playnite: cadastra os emuladores escolhidos usando as
# definicoes oficiais do Playnite e grava os IDs para o instalador.

function OnApplicationStarted()
{
    param($OnApplicationStartedEventArgs)
    $dir = Split-Path -Parent $PSCommandPath
    $log = Join-Path $dir 'result.txt'
    try {
        $wanted = Get-Content (Join-Path $dir 'wanted.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $defs = $PlayniteApi.Emulation.Emulators
        $out = New-Object System.Collections.ArrayList
        foreach ($prop in $wanted.PSObject.Properties) {
            $id = $prop.Name
            $def = $defs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if (-not $def) { [void]$out.Add("AVISO|sem definicao para $id"); continue }
            $emu = $PlayniteApi.Database.Emulators | Where-Object { $_.BuiltInConfigId -eq $def.Id } | Select-Object -First 1
            $novo = -not $emu
            if ($novo) {
                $emu = New-Object Playnite.SDK.Models.Emulator $def.Name
                $emu.InstallDir = $prop.Value.dir
                $emu.BuiltInConfigId = $def.Id
                $emu.BuiltinProfiles = New-Object 'System.Collections.ObjectModel.ObservableCollection[Playnite.SDK.Models.BuiltInEmulatorProfile]'
            }
            # Acrescenta perfis que faltam (ex.: rodar o instalador de novo marcando outro console do RetroArch).
            $mudou = $false
            foreach ($pn in $prop.Value.profiles) {
                if ($emu.BuiltinProfiles | Where-Object { $_.BuiltInProfileName -eq $pn }) { continue }
                $pd = $def.Profiles | Where-Object { $_.Name -eq $pn } | Select-Object -First 1
                if (-not $pd) { [void]$out.Add("AVISO|sem perfil $id/$pn"); continue }
                $bp = New-Object Playnite.SDK.Models.BuiltInEmulatorProfile
                $bp.Name = $pd.Name
                $bp.BuiltInProfileName = $pd.Name
                $emu.BuiltinProfiles.Add($bp); $mudou = $true
            }
            if ($novo) { $PlayniteApi.Database.Emulators.Add($emu) }
            elseif ($mudou) { $PlayniteApi.Database.Emulators.Update($emu) }
            foreach ($p in $emu.BuiltinProfiles) { [void]$out.Add("EMU|$($def.Id)|$($emu.Id)|$($p.Id)|$($p.Name)") }
        }
        [System.IO.File]::WriteAllLines($log, $out)
    } catch {
        [System.IO.File]::WriteAllText($log, "ERRO: $($_.Exception.ToString())")
    }
}
