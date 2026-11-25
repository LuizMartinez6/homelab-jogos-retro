# Compila o C# com o mesmo csc que as ferramentas usam (.NET Framework 4, C# 5).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Ajuda.psm1') -Force
    $Fw = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319"
    function Invoke-Csc([string[]]$Argumentos) {
        $saida = & "$Fw\csc.exe" /nologo /optimize+ /codepage:65001 @Argumentos 2>&1
        [pscustomobject]@{ Codigo = $LASTEXITCODE; Saida = ($saida -join "`n") }
    }
}

Describe 'Instalador.cs' {
    It 'compila' {
        $r = Invoke-Csc @('/target:winexe', "/out:$TestDrive\Instalador.exe", '/reference:System.IO.Compression.dll', '/reference:System.IO.Compression.FileSystem.dll',
            '/reference:System.Windows.Forms.dll', (Join-Path $Raiz 'ferramentas\exe\Instalador.cs'))
        $r.Codigo | Should -Be 0 -Because $r.Saida
    }
}

Describe 'Recomps.cs (plugin do Playnite)' {
    It 'compila contra o Playnite.SDK, sem avisos' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $wpf = "$Fw\WPF"
        $r = Invoke-Csc @('/target:library', '/warnaserror+', "/out:$TestDrive\Recomps.dll", "/reference:$Playnite\Playnite.SDK.dll", "/reference:$wpf\PresentationFramework.dll",
            "/reference:$wpf\PresentationCore.dll", "/reference:$wpf\WindowsBase.dll", '/reference:System.Xaml.dll', (Join-Path $Raiz 'ferramentas\plugin\Recomps.cs'))
        $r.Codigo | Should -Be 0 -Because $r.Saida
    }

    It 'agrega codigos desconhecidos de FALTA e detalha os requisitos conhecidos' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$jogo = New-Object Recomps.JogoRecomp
$jogo.Nome = 'Teste'
$jogo.Plataforma = 'ps2'
$m = [Recomps.TextosRecomp].GetMethod('Faltas')
$m.Invoke($null, [object[]]@([string[]]@('futuro', 'bios', 'outro', 'futuro'), $jogo.PSObject.BaseObject, 0L, 0L, 'C:'))
'@
        Write-Utf8 "$TestDrive\faltas-recomp.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\faltas-recomp.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll"
        $LASTEXITCODE | Should -Be 0
        ($saida -join "`n") | Should -Match 'Falta:\s+\S a BIOS do PS2 \(a do seu console\)'
        @($saida | Where-Object { $_ -like '*algo que o Recomp precisa*' }).Count | Should -Be 1
        ($saida -join "`n") | Should -Match 'algo que o Recomp precisa \(futuro, outro\)'
        @($saida | Where-Object { $_ -like '*Feche o Playnite*' }).Count | Should -Be 1
    }

    It 'argumentos do Jogar cotam caminhos novos e preservam os argumentos legados do TotK' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$montar = [Recomps.PluginRecomps].GetMethod('FormatarArgumentosJogar', [Reflection.BindingFlags]'NonPublic, Static')
$j = New-Object Recomps.JogoRecomp
$j.Plataforma = 'n64'
$j.Pasta = 'D:\Meus Recomps\'
$j.DumpMostrar = 'W:\Nintendo 64\Jogo [teste].z64'
$j.Args = '--rom={dump} --dir={pasta}'
$entrada = [object[]]@($j.PSObject.BaseObject, $null)
$montar.Invoke($null, $entrada)
$j.DumpMostrar = $null
[void]$montar.Invoke($null, $entrada)
$entrada[1]
$j.Plataforma = $null
$j.Args = '-Pasta "{pasta}"'
$j.Pasta = 'D:\Meus Recomps\TotK'
$montar.Invoke($null, $entrada)
'@
        Write-Utf8 "$TestDrive\argumentos-recomp.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\argumentos-recomp.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll"
        $LASTEXITCODE | Should -Be 0
        @($saida) | Should -Be @('--rom="W:\Nintendo 64\Jogo [teste].z64" --dir="D:\Meus Recomps\\"', '{dump}', '-Pasta "D:\Meus Recomps\TotK"')
    }

    It 'dump do _origem: so com romm.arquivo de nome simples; fora disso nulo, sem excecao' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll, $Origem)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$dump = [Recomps.PluginRecomps].GetMethod('CaminhoDump', [Reflection.BindingFlags]'NonPublic, Static')
foreach ($nome in 'Jogo [teste].z64', '..\fora.z64', 'sub\Jogo.z64', 'C:\Jogo.z64', 'Jogo|x.z64', 'Jogo?.z64', '..', '.') {
    $j = New-Object Recomps.JogoRecomp
    $j.Id = 't'
    $j.Romm = New-Object Recomps.RommRecomp
    $j.Romm.Arquivo = $nome
    $c = $dump.Invoke($null, [object[]]@($j.PSObject.BaseObject, $Origem))
    if ($c -eq $null) { 'nulo' } else { $c }
}
'@
        Write-Utf8 "$TestDrive\dump-recomp.ps1" $script
        $origem = Join-Path $TestDrive 'Recomps\_origem'
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\dump-recomp.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll" $origem
        $LASTEXITCODE | Should -Be 0
        @($saida) | Should -Be @("$origem\t\Jogo [teste].z64", 'nulo', 'nulo', 'nulo', 'nulo', 'nulo', 'nulo', 'nulo')
    }

    It 'pasta da ROM: so a pasta do jogo dentro da pasta de jogos do emulador; nunca a do console, a raiz, aspas ou pasta de Recomp' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll, $B)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$P = [Recomps.PastaRom]
function Arq($c) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($c)); [IO.File]::WriteAllText($c, 'rom'); $c }
$sw = "$B\Jogos\switch"; $gba = "$B\Jogos\gba"
$rom = Arq "$sw\Jogo\Jogo.nsp"
$flat = Arq "$gba\Pokemon.gba"
$soltaNoConsole = Arq "$sw\Solta.nsp"
$outroNome = Arq "$sw\Outro\Errado.nsp"
$dupla1 = Arq "$sw\Dupla\Dupla.nsp"; $dupla2 = Arq "$sw\Dupla.nsp"
$recompNaPasta = Arq "$sw\BotW\BotW.nsp"
$comProtegida = Arq "$sw\Pai\Pai.nsp"; [void][IO.Directory]::CreateDirectory("$sw\Pai\Weeping")
[void](Arq "$sw\SoParcial\SoParcial.nsp.parcial")
function Mapa($d, $plano, $ligado = $true) { $m = New-Object Recomps.MapeamentoRomm; $m.Enabled = $ligado; $m.DestinationPath = $d; $m.InstallFlat = $plano; $m }
function Lista { $l = New-Object 'Collections.Generic.List[Recomps.MapeamentoRomm]'; foreach ($x in $args) { $l.Add($x) }; , $l }
function Nomes { $l = New-Object 'Collections.Generic.List[string]'; foreach ($x in $args) { $l.Add($x) }; , $l }
$ds = "$B\Jogos\ds"; $romDs = Arq "$ds\Solta.nds"
$snes = "$B\Jogos\snes"; $romSnes = Arq ('{0}\Solta.sfc' -f $snes)
$mapas = New-Object 'Collections.Generic.List[Recomps.MapeamentoRomm]'
$mapas.Add((Mapa $sw $false)); $mapas.Add((Mapa $gba $true))
$r = New-Object Recomps.JogoRecomp
$r.Pasta = "$sw\BotW"
$r.Protegidas = New-Object 'Collections.Generic.List[string]'
foreach ($x in "$B\Recomps", "$B\Recomps\_origem", "$sw\Pai\Weeping", 'E:\WeepingOfTheEmpire') { $r.Protegidas.Add($x) }
function Segura($pasta, $arquivo) { $m = $null; $ok = $P::PastaRomSegura($pasta, $arquivo, $mapas, $r, [ref]$m); "$ok|$m" }
function Segura2($pasta, $arquivo, $lista) { $m = $null; [bool]$P::PastaRomSegura($pasta, $arquivo, $lista, $r, [ref]$m) }
function Jogo($caminho, $pasta) {
    $g = New-Object Playnite.SDK.Models.Game
    $g.Roms = New-Object 'Collections.ObjectModel.ObservableCollection[Playnite.SDK.Models.GameRom]'
    $g.Roms.Add((New-Object Playnite.SDK.Models.GameRom 'x', $caminho))
    $g.InstallDirectory = $pasta
    $g
}
$s = [ordered]@{
    certa = Segura "$sw\Jogo" $rom
    console = Segura $sw $soltaNoConsole
    raiz = Segura ([IO.Path]::GetPathRoot($B)) $rom
    raizNormalizada = $null -eq $P::Normalizar([IO.Path]::GetPathRoot($B))
    recomp = Segura "$sw\BotW" $recompNaPasta
    protegidaDentro = Segura "$sw\Pai" $comProtegida
    weeping = Segura 'E:\WeepingOfTheEmpire' 'E:\WeepingOfTheEmpire\Jogo.nsp'
    aspas = Segura ('"' + "$sw\Jogo" + '"') $rom
    flat = Segura $gba $flat
    naoFlatOutroNome = Segura "$sw\Outro" $outroNome
    relativoPastaVazia = $P::ResolverRom((Jogo '{InstallDir}\Jogo.nsp' ''), $r, $mapas)
    relativoPastaDoConsole = $P::ResolverRom((Jogo '{InstallDir}\Jogo.nsp' $sw), $r, $mapas)
    relativoPastaCerta = $P::ResolverRom((Jogo '{InstallDir}\Jogo.nsp' "$sw\Jogo"), $r, $mapas)
    comAspas = $P::ResolverCaminho('"' + $rom + '"', '', $mapas, $r)
    absoluto = $P::ResolverCaminho($rom, '', $mapas, $r)
    dois = $null -eq $P::ResolverCaminho('{InstallDir}\Dupla.nsp', '', $mapas, $r)
    sumiu = $null -eq $P::ResolverCaminho('{InstallDir}\Nada.nsp', '', $mapas, $r)
    semRomCerta = $P::PastaSemRomSegura("$sw\Jogo", $mapas, $r, (Nomes '{InstallDir}\Jogo.nsp'))
    semRomOutroJogo = $P::PastaSemRomSegura("$sw\Outro", $mapas, $r, (Nomes 'Jogo.nsp'))
    semRomSemNome = $P::PastaSemRomSegura("$sw\Jogo", $mapas, $r, (Nomes))
    semRomConsole = $P::PastaSemRomSegura($sw, $mapas, $r, (Nomes 'switch.nsp'))
    semRomParcial = $P::PastaSemRomSegura("$sw\SoParcial", $mapas, $r, (Nomes 'SoParcial.nsp'))
    semRomRecomp = $P::PastaSemRomSegura("$sw\BotW", $mapas, $r, (Nomes 'BotW.nsp'))
    semRomFlatIgual = $P::PastaSemRomSegura($gba, $mapas, $r, (Nomes 'gba.gba'))
    # Mesmo destino com um flat e um nao-flat habilitados: a pasta do console nao vale. Flat desabilitado nao conta.
    flatEMisto = Segura2 $sw $soltaNoConsole (Lista (Mapa $sw $true) (Mapa $sw $false))
    flatDesligadoENaoFlat = Segura2 $ds $romDs (Lista (Mapa $ds $true $false) (Mapa $ds $false))
    soFlatDesligado = Segura2 $snes $romSnes (Lista (Mapa $snes $true $false))
    soFlatLigado = Segura2 $snes $romSnes (Lista (Mapa $snes $true) (Mapa $snes $true $false))
    rom = $rom
}
# Falha ao conferir a pasta: no Desinstalar (fechar) ela fica vazia e e gravada; fora dele, fica como estava.
$g1 = Jogo 'x' "$sw\Jogo"; $grav = @{ n = 0 }
$erro = $P::Proteger($g1, [Func[bool]] { throw 'falhou' }, [Action] { $grav.n++ }, $true)
$s.protegerFecha = ($null -ne $erro) -and [string]::IsNullOrEmpty($g1.InstallDirectory) -and $grav.n -eq 1
$g2 = Jogo 'x' "$sw\Jogo"
[void]$P::Proteger($g2, [Func[bool]] { throw 'falhou' }, [Action] { }, $false)
$s.protegerSemFechar = $g2.InstallDirectory -eq "$sw\Jogo"
$g3 = Jogo 'x' "$sw\Jogo"
$s.protegerGravarFalha = ($null -ne $P::Proteger($g3, [Func[bool]] { $true }, [Action] { throw 'banco' }, $true)) -and [string]::IsNullOrEmpty($g3.InstallDirectory)
$s | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\pasta-rom.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\pasta-rom.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll" "$TestDrive\pc"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.certa | Should -Be 'True|'
        $r.console | Should -Match '^False\|'
        $r.raiz | Should -Match '^False\|'
        $r.raizNormalizada | Should -BeTrue
        $r.recomp | Should -Be 'False|pasta de Recomp'
        $r.protegidaDentro | Should -Be 'False|pasta de Recomp'
        $r.weeping | Should -Match '^False\|'
        $r.aspas | Should -Match '^False\|caminho inv'
        $r.flat | Should -Be 'True|'
        $r.naoFlatOutroNome | Should -Match '^False\|n.o . a pasta deste jogo$'
        foreach ($k in 'relativoPastaVazia', 'relativoPastaDoConsole', 'relativoPastaCerta', 'comAspas', 'absoluto') { $r.$k | Should -Be $r.rom -Because $k }
        $r.dois | Should -BeTrue
        $r.sumiu | Should -BeTrue
        $r.semRomCerta | Should -BeTrue
        foreach ($k in 'semRomOutroJogo', 'semRomSemNome', 'semRomConsole', 'semRomParcial', 'semRomRecomp', 'semRomFlatIgual') { $r.$k | Should -BeFalse -Because $k }
        foreach ($k in 'flatEMisto', 'flatDesligadoENaoFlat', 'soFlatDesligado') { $r.$k | Should -BeFalse -Because $k }
        $r.soFlatLigado | Should -BeTrue
        $r.protegerFecha | Should -BeTrue
        $r.protegerSemFechar | Should -BeTrue
        $r.protegerGravarFalha | Should -BeTrue
    }

    It 'catalogo ilegivel depois de uma leitura boa: continua valendo a ultima boa' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        # (fora do Playnite o Serialization do SDK nao funciona: a leitura de verdade entra como funcao)
        $script = @'
param($Sdk, $Dll)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$P = [Recomps.PluginRecomps]
$antesDeTudo = $P::LerComReserva([Func[Recomps.Configuracao]] { throw 'ilegivel' })
$boa = New-Object Recomps.Configuracao
$boa.Jogos = New-Object 'Collections.Generic.List[Recomps.JogoRecomp]'
$j = New-Object Recomps.JogoRecomp; $j.Id = 't'; $boa.Jogos.Add($j)
$a = $P::LerComReserva([Func[Recomps.Configuracao]] { $boa })
$b = $P::LerComReserva([Func[Recomps.Configuracao]] { throw 'ilegivel' })
@{ semBoa = @($antesDeTudo.Jogos).Count; antes = @($a.Jogos).Count; depois = @($b.Jogos).Count; id = @($b.Jogos)[0].Id } | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\ler.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\ler.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.semBoa | Should -Be 0
        $r.antes | Should -Be 1
        $r.depois | Should -Be 1
        $r.id | Should -Be 't'
    }

    It 'entrada com gameId vazio (OoT de Switch 2 antes de criar o jogo): o catalogo le e ela nao casa com nenhum jogo' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        # (o Serialization do SDK so funciona dentro do Playnite: aqui, o mesmo Newtonsoft que ele usa)
        $script = @'
param($Sdk, $Dll, $Newtonsoft)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Newtonsoft; Add-Type -Path $Dll
$json = '{ "jogos": [ { "id": "a", "gameId": "96434621-d756-4d10-8501-8e63913658a5", "pasta": "D:\\R\\A", "exe": "a.exe", "pronto": "x" },
  { "id": "oot-sw2", "gameId": "", "pasta": "D:\\R\\O", "exe": "Triforce.exe", "pronto": ".recomp-pronto", "semEmulador": true, "nup": "\\\\s\\j\\o.nup",
    "fixa": { "versao": "v0.5.1", "titulo": "TITULO-TESTE", "versaoJogo": "v2", "versaoJogoTexto": "t",
      "arquivos": [ { "nome": "Triforce-Tools.zip", "url": "https://x/y.zip", "tamanho": 286744263, "sha256": "d5f7" } ] } } ] }'
$m = [Newtonsoft.Json.JsonConvert].GetMethods() | Where-Object { $_.Name -eq 'DeserializeObject' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 }
$cfg = $m.MakeGenericMethod([Recomps.Configuracao]).Invoke($null, @($json))
$o = @($cfg.Jogos)[1]
$achar = [Recomps.PluginRecomps].GetMethod('Achar', [Reflection.BindingFlags]'NonPublic, Static', $null, [type[]]@([Recomps.Configuracao], [Playnite.SDK.Models.Game]), $null)
function Casa($id) {
    $g = New-Object Playnite.SDK.Models.Game
    $g.Id = $id
    $r = $achar.Invoke($null, [object[]]@([Recomps.Configuracao]$cfg, [Playnite.SDK.Models.Game]$g))
    if ($r) { $r.Id } else { '' }
}
@{ n = @($cfg.Jogos).Count; gid = "$($o.GameId)"; sem = $o.SemEmulador; versao = $o.Fixa.Versao; tam = @($o.Fixa.Arquivos)[0].Tamanho; nup = $o.Nup
    vazio = Casa ([guid]::Empty); outro = Casa ([guid]::NewGuid()); certo = Casa ([guid]'96434621-d756-4d10-8501-8e63913658a5') } | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\gameid.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\gameid.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll" "$Playnite\Newtonsoft.Json.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.n | Should -Be 2
        $r.gid | Should -Be ''
        $r.sem | Should -BeTrue
        $r.versao | Should -Be 'v0.5.1'
        $r.tam | Should -Be 286744263
        $r.nup | Should -Be '\\s\j\o.nup'
        $r.vazio | Should -Be ''
        $r.outro | Should -Be ''
        $r.certo | Should -Be 'a'
    }

    It 'botao "Instalar o Recomp" do Selene: quando aparece, dispensados gravados por jogo e nao encaixa sem a parte do tema' {
        $Playnite = Find-Playnite
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll, $Pasta)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$B = [Recomps.BotaoRecompSelene]
$s = [ordered]@{}
# tela cheia, Recomp no catalogo, ROM completa, Recomp instalado, instalando, dispensado
$s.aparece = $B::Visivel($true, $true, $true, $false, $false, $false)
$s.desktop = $B::Visivel($false, $true, $true, $false, $false, $false)
$s.semRecomp = $B::Visivel($true, $false, $true, $false, $false, $false)
$s.semRom = $B::Visivel($true, $true, $false, $false, $false, $false)
$s.instalado = $B::Visivel($true, $true, $true, $true, $false, $false)
$s.instalando = $B::Visivel($true, $true, $true, $false, $true, $false)
$s.dispensado = $B::Visivel($true, $true, $true, $false, $false, $true)

$arq = "$Pasta\dados\aviso-recomp-dispensado.json"
$s.semArquivo = $B::LerDispensados($arq).Count
$g1 = [guid]::NewGuid(); $g2 = [guid]::NewGuid()
$B::GravarDispensados($arq, [guid[]]@($g1, $g2, $g1))
$l = $B::LerDispensados($arq)
$s.lidos = $l.Count; $s.temG1 = $l.Contains($g1)
$s.semBom = [IO.File]::ReadAllBytes($arq)[0] -ne 0xEF
$B::GravarDispensados($arq, [guid[]]@($g2))
$s.trocado = (@($B::LerDispensados($arq)) -join ',') -eq "$g2"
$s.semTmp = -not (Test-Path "$arq.tmp")
[IO.File]::WriteAllText($arq, '{ lixo')
$s.ilegivel = $B::LerDispensados($arq).Count

function Painel($comParte, $comEstilo) {
    $p = New-Object Windows.Controls.StackPanel
    # (.BaseObject: sem ele o dicionario guarda o PSObject do New-Object e o "as Style" do C# falha)
    if ($comEstilo) { $p.Resources['SeleneDetailsButton'] = (New-Object Windows.Style ([Windows.Controls.Button])).psobject.BaseObject }
    $jogar = New-Object Windows.Controls.Button
    if ($comParte) { $jogar.Name = 'PART_ButtonContext' }
    $opcoes = New-Object Windows.Controls.Button; $opcoes.Name = 'PART_ButtonOptions'
    [void]$p.Children.Add($jogar); [void]$p.Children.Add($opcoes)
    $p
}
$s.semParte = $B::Encaixar((Painel $false $true))
$s.semEstilo = $B::Encaixar((Painel $true $false))
$p = Painel $true $true
$s.comTudo = $B::Encaixar($p)
$s.ordem = (@($p.Children | ForEach-Object { if ($_.Name) { $_.Name } else { [string]$_.Content } }) -join '|')
$s.colapsado = "$($p.Children[1].Visibility)"
$s.deNovo = $B::Encaixar($p) -and $p.Children.Count -eq 3
$s | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\botao.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\botao.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\Recomps.dll" "$TestDrive\botao"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.aparece | Should -BeTrue
        foreach ($k in 'desktop', 'semRecomp', 'semRom', 'instalado', 'instalando', 'dispensado') { $r.$k | Should -BeFalse -Because $k }
        $r.semArquivo | Should -Be 0
        $r.lidos | Should -Be 2
        $r.temG1 | Should -BeTrue
        $r.semBom | Should -BeTrue
        $r.trocado | Should -BeTrue
        $r.semTmp | Should -BeTrue
        $r.ilegivel | Should -Be 0
        $r.semParte | Should -BeFalse
        $r.semEstilo | Should -BeFalse
        $r.comTudo | Should -BeTrue
        $r.ordem | Should -Be 'PART_ButtonContext|Instalar o Recomp|PART_ButtonOptions'
        $r.colapsado | Should -Be 'Collapsed'
        $r.deNovo | Should -BeTrue
    }
}

Describe 'JogosPc.cs (plugin do Playnite)' {
    BeforeAll { $Playnite = Find-Playnite }

    It 'compila contra o Playnite.SDK, sem avisos' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $wpf = "$Fw\WPF"
        $r = Invoke-Csc @('/target:library', '/warnaserror+', "/out:$TestDrive\JogosPc.dll", "/reference:$Playnite\Playnite.SDK.dll", "/reference:$wpf\PresentationFramework.dll",
            "/reference:$wpf\PresentationCore.dll", "/reference:$wpf\WindowsBase.dll", '/reference:System.Xaml.dll', (Join-Path $Raiz 'ferramentas\plugin\JogosPc.cs'))
        $r.Codigo | Should -Be 0 -Because $r.Saida
    }

    It 'avisos das salas: um por pessoa em cada sala, fora o proprio apelido' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        # Em outro processo: a DLL carregada fica presa e o Pester nao conseguiria limpar o TestDrive.
        $script = @'
param($Sdk, $Dll)
Add-Type -Path $Sdk; Add-Type -Path $Dll
$sala = New-Object JogosPc.SalaMultiplayer
$sala.titulo = 'Switch'; $sala.jogadores = New-Object 'Collections.Generic.List[string]'
foreach ($n in 'Beto', 'Zeca', '') { $sala.jogadores.Add($n) }
$salas = New-Object JogosPc.SalasMultiplayer
$salas.salas = New-Object 'Collections.Generic.List[JogosPc.SalaMultiplayer]'; $salas.salas.Add($sala)
$r = [JogosPc.AvisoSalas]::Avisos($salas, 'ze.ca')
@{ chaves = @($r.Keys); texto = $r['sala-Switch-Beto']; vazio = [JogosPc.AvisoSalas]::Avisos($null, 'x').Count } | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\salas.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\salas.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        @($r.chaves) | Should -Be @('sala-Switch-Beto')
        $r.texto | Should -Match '^Beto esta jogando online: Switch\.'
        $r.vazio | Should -Be 0
    }

    It 'card do Selene: a forma do texto nao muda com os numeros, pt-BR, sem Closing/Exiting/Shutting; topo sem as partes nao faz nada' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        # O Selene troca o card quando muda o texto sem os numeros (Kind: tira [\d/%.,()]) e o card pode nao voltar.
        $script = @'
param($Sdk, $Dll)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
function Kind($t) { ([regex]::Replace($t, '[\d/%.,()]+', '')).Trim() }
$GB = 1073741824L; $MB = 1048576L
$numeros = @((0L, 0L, 0L), (0L, (8L * $GB), 0L), ([long](0.4 * $GB), 0L, (5L * $MB)), (3865470567L, (8L * $GB), 13421773L),
    ((80L * $GB), (80L * $GB), (120L * $MB)), ([long](0.1 * $GB), (120L * $GB), [long](0.4 * $MB)), (1L, (600L * $GB), 1024L))
$formas = @{}; $proibidos = 0
foreach ($etapa in 'conectando', 'baixando', 'fila', 'reconectando', 'verificando', 'instalando', 'pausado', 'pronto', 'cancelando', 'cancelado', 'cancelado-nada', 'erro') {
    $k = @{}
    foreach ($n in $numeros) {
        foreach ($fila in 0, 1, 12) {
            $k[(Kind ([JogosPc.Textos]::Cartao('Hades', $etapa, $n[0], $n[1], $n[2], $fila)))] = 1
            foreach ($nome in 'Closing Time', 'EXITING', 'Shutting Down - Parte 2') {
                foreach ($t in [JogosPc.Textos]::Cartao($nome, $etapa, $n[0], $n[1], $n[2], $fila), [JogosPc.Textos]::Topo($nome, $etapa, $n[0], $n[1], $n[2], $fila, $false)) {
                    if ($t -match 'closing|exiting|shutting') { $proibidos++ }
                }
            }
        }
    }
    $formas[$etapa] = $k.Count
}
$p = ' ' + [char]0x00B7 + ' '
$baixando = [JogosPc.Textos]::Cartao('Hades', 'baixando', 3865470567L, 8L * $GB, 13421773L, 1)
$semTotal = [JogosPc.Textos]::Cartao('Hades', 'baixando', [long](0.4 * $GB), 0L, 5L * $MB, 0)
$topo = [JogosPc.Textos]::Topo('Hades', 'baixando', 3865470567L, 8L * $GB, 13421773L, 1, $false)
$cancelando = [JogosPc.Textos]::Cartao('Hades', 'cancelando', 0L, 0L, 0L, 0)
$nada = [JogosPc.Textos]::Cartao('Hades', 'cancelado-nada', 0L, 0L, 0L, 0)
$topoCancelando = [JogosPc.Textos]::Topo('Hades', 'cancelando', 0L, 0L, 0L, 2, $false)
$topoComplemento = [JogosPc.Textos]::Topo('BotW', 'complemento', 0L, 0L, 0L, 0, $true)
$longo = [JogosPc.Textos]::Nome(('A' * 40), 32)
$traco = [JogosPc.Textos]::Nome('Jogo - Parte 2', 32)

$raiz = New-Object Windows.Controls.Grid
[void]$raiz.Children.Add((New-Object Windows.Controls.TextBlock))
$semRelogio = [JogosPc.IndicadorTopo]::Encaixar($raiz)
$fila = New-Object Windows.Controls.StackPanel
$tocando = New-Object Windows.Controls.StackPanel; $tocando.Name = 'SeleneNowPlaying'
$relogio = New-Object Windows.Controls.TextBlock; $relogio.Name = 'PART_TextClock'
[void]$fila.Children.Add($tocando); [void]$fila.Children.Add($relogio)
$borda = New-Object Windows.Controls.Border; $borda.Child = $fila
$com = [JogosPc.IndicadorTopo]::Encaixar($borda)
$deNovo = [JogosPc.IndicadorTopo]::Encaixar($borda)
@{
    formas = $formas; proibidos = $proibidos
    baixando = $baixando -eq ('Hades - Baixando 45%' + $p + '3,6/8,0 GB' + $p + '12,8 MB/s' + $p + 'faltam 6 min' + $p + 'na fila: 1')
    semTotal = $semTotal -eq ('Hades - Baixando ...%' + $p + '0,4/... GB' + $p + '5,0 MB/s' + $p + 'faltam ... min' + $p + 'na fila: 0')
    topo = $topo -eq ('Hades' + $p + '45%' + $p + 'faltam 6 min' + $p + '+1 na fila')
    cancelando = $cancelando -match '^Hades - Cancelando\. O que j. baixou fica guardado$'
    nada = $nada -eq 'Hades - Cancelado. Nada tinha sido baixado'
    topoCancelando = $topoCancelando -eq ('Hades' + $p + 'cancelando' + $p + '+2 na fila')
    topoComplemento = $topoComplemento -eq ('BotW' + $p + 'Recomp preparando')
    longo = $longo.Length -eq 32 -and $longo.EndsWith([string][char]0x2026)
    traco = $traco.Contains([string][char]0x2013) -and -not $traco.Contains(' - ')
    semRelogio = $semRelogio; filhosRaiz = $raiz.Children.Count
    com = $com; deNovo = $deNovo; filhosFila = $fila.Children.Count
    antesDoTocando = [object]::ReferenceEquals($fila.Children[1], $tocando) -and [object]::ReferenceEquals($fila.Children[2], $relogio)
    painelInerte = -not $fila.Children[0].Focusable -and -not $fila.Children[0].IsHitTestVisible
} | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\textos.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\textos.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        foreach ($etapa in $r.formas.PSObject.Properties) { $etapa.Value | Should -Be 1 -Because "o texto de '$($etapa.Name)' nao pode mudar de forma" }
        $r.proibidos | Should -Be 0
        $r.baixando | Should -BeTrue
        $r.semTotal | Should -BeTrue
        $r.topo | Should -BeTrue
        $r.cancelando | Should -BeTrue
        $r.nada | Should -BeTrue
        $r.topoCancelando | Should -BeTrue
        $r.topoComplemento | Should -BeTrue
        $r.longo | Should -BeTrue
        $r.traco | Should -BeTrue
        $r.semRelogio | Should -BeFalse
        $r.filhosRaiz | Should -Be 1
        $r.com | Should -BeTrue
        $r.deNovo | Should -BeTrue
        $r.filhosFila | Should -Be 3
        $r.antesDoTocando | Should -BeTrue
        $r.painelInerte | Should -BeTrue
    }

    It 'fila de downloads: ordem de chegada, pausar solta a vez, continuar vai para o fim, baixar a seguir e retomada' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$G = [JogosPc.Gerenciador]
function Nova($n, $id) { if (-not $id) { $id = [guid]::NewGuid() }; New-Object JogosPc.Execucao($null, [guid]$id, 'pc', $n) }
function Nomes { ($G::Copia() | ForEach-Object { $_.Nome }) -join ',' }
$a = Nova 'A'; $b = Nova 'B'; $c = Nova 'C'
foreach ($e in $a, $b, $c) { $G::Entrar($e) }
$r = [ordered]@{}
$r.soOPrimeiro = (-not $G::TentarVez($b)) -and (-not $G::TentarVez($c)) -and $G::TentarVez($a)
$r.posicoes = (@($a, $b, $c) | ForEach-Object { $G::Posicao($_) }) -join ','
$G::Sair($a)
$r.bDepoisDeA = (-not $G::TentarVez($c)) -and $G::TentarVez($b)
$b.Pausado = $true; $G::Soltar($b)
$r.pausarSoltaAVez = $G::TentarVez($c)
$b.Pausado = $false; $G::ParaOFim($b)
$d = Nova 'D'; $G::Entrar($d)
$r.continuarNoFim = Nomes
$r.frente = $G::MoverParaFrente($d)
$r.depoisDaFrente = Nomes
$r.rodandoNaoVaiPraFrente = -not $G::MoverParaFrente($c)
$d.Cancelar()
$G::Sair($c)
$r.canceladoNaoPega = (-not $G::TentarVez($d)) -and $G::TentarVez($b)
$G::Sair($b); $G::Sair($d)
# Retomada ao abrir: o lugar guardado vem antes de quem chegou depois, e o pausado volta pausado.
$novo = Nova 'Novo'; $G::Entrar($novo)
$g1 = [guid]::NewGuid(); $g2 = [guid]::NewGuid()
$l = New-Object 'Collections.Generic.List[Collections.Generic.KeyValuePair[guid,bool]]'
$l.Add((New-Object 'Collections.Generic.KeyValuePair[guid,bool]' $g1, $false)); $l.Add((New-Object 'Collections.Generic.KeyValuePair[guid,bool]' $g2, $true))
$G::Restaurar($l)
$v1 = Nova 'Velho1' $g1; $v2 = Nova 'Velho2' $g2
$G::Entrar($v2); $G::Entrar($v1)
$r.retomada = Nomes
$r.voltouPausado = $v2.Pausado -and -not $v1.Pausado
$r.velhoPrimeiro = $G::TentarVez($v1)
$r | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\fila.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\fila.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.soOPrimeiro | Should -BeTrue
        $r.posicoes | Should -Be '0,1,2'
        $r.bDepoisDeA | Should -BeTrue
        $r.pausarSoltaAVez | Should -BeTrue
        $r.continuarNoFim | Should -Be 'C,B,D'
        $r.frente | Should -BeTrue
        $r.depoisDaFrente | Should -Be 'C,D,B'
        $r.rodandoNaoVaiPraFrente | Should -BeTrue
        $r.canceladoNaoPega | Should -BeTrue
        $r.retomada | Should -Be 'Velho1,Novo,Velho2'
        $r.voltouPausado | Should -BeTrue
        $r.velhoPrimeiro | Should -BeTrue
    }

    It 'cancelar: a consulta ao servidor nao segura o cancelamento; o fim acontece uma vez so' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
Add-Type -ReferencedAssemblies $Dll -TypeDefinition @"
using System; using System.Diagnostics; using System.Threading; using System.Threading.Tasks;
public static class AjudaCancelar {
    public static long NoMeio(JogosPc.Execucao e) {
        var relogio = Stopwatch.StartNew();
        Task.Delay(300).ContinueWith(t => e.Cancelar());
        try { e.Consultar<int>(() => { Thread.Sleep(8000); return 1; }); return -1; }
        catch (OperationCanceledException) { return relogio.ElapsedMilliseconds; }
    }
    public static int Normal(JogosPc.Execucao e) { return e.Consultar<int>(() => 7); }
}
"@
$G = [JogosPc.Gerenciador]
$e = New-Object JogosPc.Execucao($null, [guid]::NewGuid(), 'rom', 'A')
$G::Entrar($e)
$r = [ordered]@{ normal = [AjudaCancelar]::Normal($e) }
$r.ms = [AjudaCancelar]::NoMeio($e)
$r.presenteAntes = $G::Presente($e.JogoId)
$r.primeiro = $e.Finalizar('cancelado', $null, $null)
$r.segundo = $e.Finalizar('erro', $null, 'x')
$r.presenteDepois = $G::Presente($e.JogoId)
$r.vivo = $null -eq $G::Vivo($e.JogoId)
$r | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\cancelar.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\cancelar.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.normal | Should -Be 7
        $r.ms | Should -BeGreaterThan 0
        $r.ms | Should -BeLessThan 3000
        $r.presenteAntes | Should -BeTrue
        $r.primeiro | Should -BeTrue
        $r.segundo | Should -BeFalse
        $r.presenteDepois | Should -BeFalse
        $r.vivo | Should -BeTrue
    }

    It 'tela de downloads: a lista viva so troca o que mudou e a linha com foco continua a mesma' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$criar = [Func[string, JogosPc.Linha]] {
    param($c)
    $l = New-Object JogosPc.Linha
    $l.Chave = $c
    foreach ($t in 'Nome', 'Tipo', 'Pct', 'Estado', 'Aviso') { $l.$t = New-Object Windows.Controls.TextBlock }
    $l.Barra = New-Object Windows.Controls.ProgressBar
    $l.Botoes = New-Object Windows.Controls.StackPanel
    $l.Raiz = New-Object Windows.Controls.Border
    $l.Raiz.Child = $l.Botoes
    $l
}
$botao = [Func[string, Windows.Controls.Button]] { param($a) New-Object Windows.Controls.Button }
$lista = New-Object JogosPc.ListaViva($criar, $botao)
$p1 = New-Object Windows.Controls.StackPanel; $p2 = New-Object Windows.Controls.StackPanel
function Modelo($chave, $nome, $botoes) {
    $m = New-Object JogosPc.ModeloLinha
    $m.Chave = $chave; $m.Nome = $nome
    foreach ($b in $botoes) { [void]$m.Botao($b[0], $b[1]) }
    $m
}
function Secoes($um, $dois) {
    $s = New-Object 'Collections.Generic.List[Collections.Generic.KeyValuePair[Windows.Controls.Panel,Collections.Generic.List[JogosPc.ModeloLinha]]]'
    foreach ($par in @(@($p1, $um), @($p2, $dois))) {
        $ms = New-Object 'Collections.Generic.List[JogosPc.ModeloLinha]'
        foreach ($m in $par[1]) { $ms.Add($m) }
        $s.Add((New-Object 'Collections.Generic.KeyValuePair[Windows.Controls.Panel,Collections.Generic.List[JogosPc.ModeloLinha]]' $par[0], $ms))
    }
    , $s
}
$ordem1 = $lista.Aplicar((Secoes @((Modelo 'd:1' 'Hades' @(@('pausar', 'Pausar'), @('cancelar', 'Cancelar'))), (Modelo 'd:2' 'Celeste' @(, @('tirar', 'Tirar da fila')))) @((Modelo 'd:3' 'Dead Cells' @()))))
$com = $lista.Linhas['d:1']; $raiz = $com.Raiz; $pausar = $com.PorAcao['pausar']; $outra = $lista.Linhas['d:2']
$ordem2 = $lista.Aplicar((Secoes @((Modelo 'd:0' 'Novo' @()), (Modelo 'd:1' 'Hades 2' @(@('pausar', 'Pausando...'), @('cancelar', 'Cancelar')))) @((Modelo 'd:3' 'Dead Cells' @()), (Modelo 'd:2' 'Celeste' @(, @('tirar', 'Tirar da fila'))))))
$r = [ordered]@{
    ordem1 = $ordem1 -join ','
    ordem2 = $ordem2 -join ','
    mesmaLinha = [object]::ReferenceEquals($lista.Linhas['d:1'], $com) -and [object]::ReferenceEquals($lista.Linhas['d:1'].Raiz, $raiz)
    mesmoBotao = [object]::ReferenceEquals($lista.Linhas['d:1'].PorAcao['pausar'], $pausar)
    textoNovo = $com.Nome.Text -eq 'Hades 2' -and $pausar.Content -eq 'Pausando...'
    movidaNaoRefeita = [object]::ReferenceEquals($lista.Linhas['d:2'], $outra) -and [object]::ReferenceEquals($p2.Children[1], $outra.Raiz)
    painel1 = [object]::ReferenceEquals($p1.Children[0], $lista.Linhas['d:0'].Raiz) -and [object]::ReferenceEquals($p1.Children[1], $raiz) -and $p1.Children.Count -eq 2
    semBotaoFocavel = $lista.Linhas['d:0'].Raiz.Focusable -and -not $raiz.Focusable
}
$ordem3 = $lista.Aplicar((Secoes @((Modelo 'd:1' 'Hades 2' @())) @()))
$r.instalandoSemBotao = $com.Botoes.Children.Count -eq 0 -and $raiz.Focusable -and [object]::ReferenceEquals($lista.Linhas['d:1'], $com)
$r.sairam = $ordem3 -join ','
$S = [JogosPc.ListaViva]
function Lst { $l = New-Object 'Collections.Generic.List[string]'; foreach ($x in $args) { $l.Add($x) }; , $l }
$r.substitutaDeBaixo = $S::Substituta((Lst 'a' 'b' 'c'), 'b', (Lst 'a' 'c'))
$r.substitutaDeCima = $S::Substituta((Lst 'a' 'b' 'c'), 'c', (Lst 'a' 'b'))
$r.continua = $S::Substituta((Lst 'a' 'b'), 'b', (Lst 'x' 'b'))
$r | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\lista.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\lista.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.ordem1 | Should -Be 'd:1,d:2,d:3'
        $r.ordem2 | Should -Be 'd:0,d:1,d:3,d:2'
        $r.mesmaLinha | Should -BeTrue
        $r.mesmoBotao | Should -BeTrue
        $r.textoNovo | Should -BeTrue
        $r.movidaNaoRefeita | Should -BeTrue
        $r.painel1 | Should -BeTrue
        $r.semBotaoFocavel | Should -BeTrue
        $r.instalandoSemBotao | Should -BeTrue
        $r.sairam | Should -Be 'd:1'
        $r.substitutaDeBaixo | Should -Be 'c'
        $r.substitutaDeCima | Should -Be 'b'
        $r.continua | Should -Be 'b'
    }

    It 'descartar: so a pasta do jogo em _baixando ou o .parcial ao lado do destino, nunca a ROM completa' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll, $Pasta)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$D = [JogosPc.Descarte]
$r = [ordered]@{
    pasta = $D::PastaPc('C:\Jogos\JogosPC', 'hades-2')
    pontos = $D::PastaPc('C:\Jogos\JogosPC', '..')
    subindo = $D::PastaPc('C:\Jogos\JogosPC', '..\Windows')
    barra = $D::PastaPc('C:\Jogos\JogosPC', 'a/b')
    vazio = $D::PastaPc('C:\Jogos\JogosPC', '')
    raizRelativa = $D::PastaPc('JogosPC', 'hades')
    parcialCerto = $D::ParcialValido('D:\Roms\GBA\Jogo [b]\Jogo [b].gba.parcial', 'D:\Roms\GBA\Jogo [b]\Jogo [b].gba')
    romCompleta = $D::ParcialValido('D:\Roms\GBA\Jogo.gba', 'D:\Roms\GBA\Jogo.gba')
    outroJogo = $D::ParcialValido('D:\Roms\GBA\Outro.gba.parcial', 'D:\Roms\GBA\Jogo.gba')
    comPontos = $D::ParcialValido('D:\Roms\GBA\..\Jogo.gba.parcial', 'D:\Roms\Jogo.gba')
    relativo = $D::ParcialValido('Jogo.gba.parcial', 'Jogo.gba')
    sufixoDepois = $D::ParcialValido('D:\Roms\Jogo.gba.parcial.zip', 'D:\Roms\Jogo.gba')
    destino = $D::DestinoDe('D:\Roms\Jogo.gba.parcial')
    semParcial = $null -eq $D::DestinoDe('D:\Roms\Jogo.gba')
}
# De verdade, numa pasta de teste: a ROM completa ao lado do .parcial.
$rom = Join-Path $Pasta 'Jogo [b].gba'; $parcial = "$rom.parcial"
[IO.File]::WriteAllText($rom, 'rom'); [IO.File]::WriteAllText($parcial, 'pela metade')
function Item($p) { $i = New-Object JogosPc.ItemFila; $i.jogo = [guid]::NewGuid(); $i.tipo = 'rom'; $i.nome = 'Jogo'; $i.parcial = $p; $i }
$r.recusaARom = -not $D::Apagar((Item $rom))
$aberto = [IO.File]::Open($parcial, 'Open', 'Write', 'Read')
$r.recusaEmUso = -not $D::Apagar((Item $parcial))
$aberto.Close()
$r.apagaParcial = $D::Apagar((Item $parcial))
$r.romFicou = [IO.File]::Exists($rom) -and -not [IO.File]::Exists($parcial)
$r.semArquivo = -not $D::Apagar((Item $parcial))
$r | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\descarte.ps1" $script
        New-Item "$TestDrive\roms" -ItemType Directory -Force | Out-Null
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\descarte.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll" "$TestDrive\roms"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.pasta | Should -Be 'C:\Jogos\JogosPC\_baixando\hades-2'
        foreach ($k in 'pontos', 'subindo', 'barra', 'vazio', 'raizRelativa') { $r.$k | Should -BeNullOrEmpty -Because $k }
        $r.parcialCerto | Should -BeTrue
        foreach ($k in 'romCompleta', 'outroJogo', 'comPontos', 'relativo', 'sufixoDepois') { $r.$k | Should -BeFalse -Because $k }
        $r.destino | Should -Be 'D:\Roms\Jogo.gba'
        $r.semParcial | Should -BeTrue
        $r.recusaARom | Should -BeTrue
        $r.recusaEmUso | Should -BeTrue
        $r.apagaParcial | Should -BeTrue
        $r.romFicou | Should -BeTrue
        $r.semArquivo | Should -BeTrue
    }

    It 'downloads-fila.json: ida e volta em UTF-8 sem BOM; arquivo estragado vira lista vazia' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll, $Arq)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$l = New-Object 'Collections.Generic.List[JogosPc.ItemFila]'
$a = New-Object JogosPc.ItemFila; $a.jogo = [guid]'11111111-2222-3333-4444-555555555555'; $a.tipo = 'rom'; $a.nome = 'Pok' + [char]0xE9 + 'mon [Emerald]'; $a.situacao = 'pausado'; $a.parcial = 'D:\Roms\GBA\Pokemon [Emerald].gba.parcial'
$b = New-Object JogosPc.ItemFila; $b.jogo = [guid]::NewGuid(); $b.tipo = 'pc'; $b.nome = 'Hades'; $b.situacao = 'instalando'; $b.id = 'hades'
$l.Add($a); $l.Add($b)
[JogosPc.FilaSalva]::Gravar($Arq, $l)
[JogosPc.FilaSalva]::Gravar($Arq, $l)
$volta = [JogosPc.FilaSalva]::Ler($Arq)
$bytes = [IO.File]::ReadAllBytes($Arq)
[IO.File]::WriteAllText("$Arq.ruim", '{ isto nao e json')
$r = [ordered]@{
    quantos = $volta.Count
    a = ($volta[0].jogo -eq $a.jogo) -and $volta[0].tipo -eq 'rom' -and $volta[0].nome -eq $a.nome -and $volta[0].situacao -eq 'pausado' -and $volta[0].parcial -eq $a.parcial -and $null -eq $volta[0].id
    b = ($volta[1].jogo -eq $b.jogo) -and $volta[1].situacao -eq 'instalando' -and $volta[1].id -eq 'hades' -and $null -eq $volta[1].parcial
    semBom = -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)
    semTmp = -not (Test-Path -LiteralPath "$Arq.tmp")
    estragado = [JogosPc.FilaSalva]::Ler("$Arq.ruim").Count
    ausente = [JogosPc.FilaSalva]::Ler("$Arq.nao-existe").Count
}
$r | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\fila-salva.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\fila-salva.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll" "$TestDrive\downloads-fila.json"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.quantos | Should -Be 2
        $r.a | Should -BeTrue
        $r.b | Should -BeTrue
        $r.semBom | Should -BeTrue
        $r.semTmp | Should -BeTrue
        $r.estragado | Should -Be 0
        $r.ausente | Should -Be 0
    }

    It 'filtro Instalados: criado uma vez so, sem reaproveitar o Installed da Colecao; a ordem nunca perde filtro' {
        if (-not $Playnite) { Set-ItResult -Skipped -Because 'Playnite nao encontrado (defina PLAYNITE_DIR)'; return }
        $script = @'
param($Sdk, $Dll)
Add-Type -AssemblyName PresentationFramework
Add-Type -Path $Sdk; Add-Type -Path $Dll
$F = [JogosPc.FiltroInstalados]
function Preset($nome, $aba, [scriptblock]$ajuste) {
    $p = New-Object Playnite.SDK.Models.FilterPreset
    $p.Name = $nome; $p.ShowInFullscreeQuickSelection = $aba
    $p.Settings = New-Object Playnite.SDK.Models.FilterPresetSettings
    $p.Settings.IsInstalled = $true
    if ($ajuste) { & $ajuste $p.Settings }
    $p
}
function Lista { $l = New-Object 'Collections.Generic.List[Playnite.SDK.Models.FilterPreset]'; foreach ($p in $args) { $l.Add($p) }; , $l }
function Guids { $l = New-Object 'Collections.Generic.List[guid]'; foreach ($x in $args) { $l.Add($x) }; , $l }
$novo = $F::Novo()
$colecao = Preset 'Installed' $false
$comPlataforma = Preset 'Meus GBA' $true { param($s) $s.Platform = New-Object Playnite.SDK.Models.IdItemFilterItemProperties ([guid]::NewGuid()) }
$equivalente = Preset 'Prontos' $true
$caixa = Preset 'INSTALADOS' $false { param($s) $s.IsInstalled = $false }
$g = @(1..4 | ForEach-Object { [guid]::NewGuid() })
$ordem = $F::NovaOrdem((Guids $g[0] $g[1] $g[2]), $g[3], $g[0])
$jaTinha = $F::NovaOrdem((Guids $g[0] $g[1] $g[3] $g[2]), $g[3], $g[0])
$semAll = $F::NovaOrdem((Guids $g[0] $g[1]), $g[3], [guid]::Empty)
$r = [ordered]@{
    novo = $novo.Name -eq 'Instalados' -and $novo.Settings.IsInstalled -and $novo.ShowInFullscreeQuickSelection -and "$($novo.SortingOrder)" -eq 'Name' -and "$($novo.SortingOrderDirection)" -eq 'Ascending'
    criaSemNada = $F::Existente((Lista)) -eq [guid]::Empty
    naoCriaDeNovo = $F::Existente((Lista $colecao $novo)) -eq $novo.Id
    colecaoNaoServe = $F::Existente((Lista $colecao)) -eq [guid]::Empty
    plataformaNaoServe = $F::Existente((Lista $comPlataforma)) -eq [guid]::Empty
    equivalenteServe = $F::Existente((Lista $comPlataforma $equivalente)) -eq $equivalente.Id
    nomeServe = $F::Existente((Lista $caixa)) -eq $caixa.Id
    ordem = (@($ordem) | ForEach-Object { [array]::IndexOf($g, $_) }) -join ','
    jaTinha = (@($jaTinha) | ForEach-Object { [array]::IndexOf($g, $_) }) -join ','
    semAll = (@($semAll) | ForEach-Object { [array]::IndexOf($g, $_) }) -join ','
}
$r | ConvertTo-Json -Compress
'@
        Write-Utf8 "$TestDrive\filtro.ps1" $script
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TestDrive\filtro.ps1" "$Playnite\Playnite.SDK.dll" "$TestDrive\JogosPc.dll"
        $r = ($saida -join '') | ConvertFrom-Json
        $r.novo | Should -BeTrue
        $r.criaSemNada | Should -BeTrue
        $r.naoCriaDeNovo | Should -BeTrue
        $r.colecaoNaoServe | Should -BeTrue
        $r.plataformaNaoServe | Should -BeTrue
        $r.equivalenteServe | Should -BeTrue
        $r.nomeServe | Should -BeTrue
        $r.ordem | Should -Be '0,3,1,2'
        $r.jaTinha | Should -Be '0,3,1,2'
        $r.semAll | Should -Be '3,0,1'
    }

    It 'o Id do plugin e o mesmo que o launcher registra' {
        $fonte = Get-Content (Join-Path $Raiz 'ferramentas\plugin\JogosPc.cs') -Raw
        $fonte | Should -Match 'c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3'
    }

    It 'chama os workers que existem no pacote do instalador' {
        $fonte = Get-Content (Join-Path $Raiz 'ferramentas\plugin\JogosPc.cs') -Raw
        foreach ($w in [regex]::Matches($fonte, '"([a-z-]+-worker\.ps1)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) {
            Test-Path (Join-Path $Arquivos $w) | Should -BeTrue -Because $w
        }
    }
}
