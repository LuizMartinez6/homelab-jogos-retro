# Consoles oferecidos no instalador (usado pela interface e pelo setup.ps1).
# $Consoles e lido por quem carrega este arquivo com ". catalogo.ps1".
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()
$Consoles = [ordered]@{
    snes   = @{ Nome = 'Super Nintendo';     Slugs = @('snes');       Emu = 'retroarch'; Cores = @('snes9x') }
    n64    = @{ Nome = 'Nintendo 64';        Slugs = @('n64');        Emu = 'retroarch'; Cores = @('mupen64plus_next') }
    sega   = @{ Nome = 'Mega Drive / Master System / Game Gear / Sega CD'; Slugs = @('genesis', 'sms', 'gamegear', 'segacd'); Emu = 'retroarch'; Cores = @('genesis_plus_gx') }
    saturn = @{ Nome = 'Sega Saturn';        Slugs = @('saturn');     Emu = 'retroarch'; Cores = @('mednafen_saturn'); Aviso = 'precisa da BIOS do Saturn'; Desmarcado = $true }
    dc     = @{ Nome = 'Dreamcast';          Slugs = @('dc');         Emu = 'retroarch'; Cores = @('flycast'); Desmarcado = $true }
    n3ds   = @{ Nome = 'Nintendo 3DS';       Slugs = @('3ds');        Emu = 'azahar';    Aviso = 'ROMs descriptografadas'; Desmarcado = $true }
    psp    = @{ Nome = 'PSP';                Slugs = @('psp');        Emu = 'ppsspp' }
    nds    = @{ Nome = 'Nintendo DS';        Slugs = @('nds');        Emu = 'retroarch'; Cores = @('melondsds') }
    gb     = @{ Nome = 'Game Boy / GBA';     Slugs = @('gb', 'gba');  Emu = 'retroarch'; Cores = @('gambatte', 'mgba', 'gpsp') }
    psx    = @{ Nome = 'PlayStation 1';      Slugs = @('psx');        Emu = 'retroarch'; Cores = @('pcsx_rearmed') }
    ps2    = @{ Nome = 'PlayStation 2';      Slugs = @('ps2');        Emu = 'pcsx2';     Aviso = 'precisa da BIOS do PS2' }
    ngc    = @{ Nome = 'GameCube / Wii';     Slugs = @('ngc', 'wii'); Emu = 'dolphin' }
    switch = @{ Nome = 'Nintendo Switch';    Slugs = @('switch');     Emu = 'eden';      Aviso = 'precisa de prod.keys e firmware; PC forte'; Desmarcado = $true }
    ps3    = @{ Nome = 'PlayStation 3';      Slugs = @('ps3');        Emu = 'rpcs3';     Aviso = 'PC forte; baixa ~240 MB a mais'; Desmarcado = $true }
}
