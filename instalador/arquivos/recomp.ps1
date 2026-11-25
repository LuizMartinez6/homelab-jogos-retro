# Instala e desinstala os recomps do catalogo (recomps.json). Chamado pelo plugin Recomps do Playnite,
# que passa o catalogo ja juntado com o recomps-local.json e com os caminhos resolvidos (-Config, um JSON
# no %TEMP%) e a pasta da instalacao (-Base).
# Cada linha "ETAPA: ..." vira o texto da barra de progresso; a ultima linha e "OK: ..." ou "ERRO: ...".
# Ao instalar, a ETAPA comeca com a palavra que o card mostra (baixando, extraindo, instalando, compilando,
# conferindo ou preparando) e "PROGRESSO: <feito> <total>" (bytes) da a porcentagem da etapa. "compilando" traz
# "etapa N de M" logo depois (o card mostra os dois numeros). "AVISO: shaders" antes do OK: instalou, mas os
# shaders ficam para a 1a vez que o jogo abrir (o card final muda e vem uma notificacao).
# -Acao verificar nao baixa nada: diz o que falta, uma linha "FALTA: <codigo>" por item (keys, rpcs3,
# python, bios, firmware, formato, arquivo, espaco, servidor, mudou, varios, nup), e "ESPACO: <precisa> <livre> <drive>" (bytes).
# O arquivo do jogo fica em <Recomps>\_origem\<id>, nunca na
# pasta de ROMs do emulador: a ROM ja baixada vira um hardlink (ou copia, em outro drive), senao baixa
# do RomM. O _origem nao e apagado: reinstalar nao baixa de novo.
# Desinstalar guarda os saves e configuracoes em <salvos>\<id>; instalar devolve eles.
param(
    [Parameter(Mandatory = $true)][ValidateSet('instalar', 'desinstalar', 'verificar')][string]$Acao,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Base
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$GitHubApi = 'https://api.github.com'
# Endereco aceito para os arquivos da versao fixa (os testes trocam para aceitar o http do servidor de teste).
$UrlFixa = '^https://'
# NSTool (extrai os NSP do Switch): do GitHub oficial, conferido pelo SHA-256 do zip.
$Nstool = @{ Url = 'https://github.com/jakcron/nstool/releases/download/v1.9.2/nstool-v1.9.2-win_x64.zip'; Sha = '34659DC47249A3C00F7FC88A11F4E5BA14DFBEC0A6A96B4F3F71368A7E1C9374'; Pasta = 'nstool-v1.9.2' }
$FormatosOrigem = @{
    n64 = @('.z64', '.n64', '.v64')
    ngc = @('.iso', '.rvz', '.gcm', '.wbfs')
    wii = @('.iso', '.rvz', '.gcm', '.wbfs')
    ps2 = @('.iso', '.chd')
    ps3 = @('.iso')
    xbox360 = @('.xex', '.iso')
    switch = @('.nsp', '.xci')
}
$RequisitosAceitos = @('keys', 'rpcs3', 'python', 'bios', 'firmware')

# Direto no stdout: a saida de uma funcao (como a do Get-Release) e capturada e nao chegaria ao plugin.
function Etapa($texto) { [Console]::Out.WriteLine("ETAPA: $texto") }
function Progresso([long]$feito, [long]$total) { [Console]::Out.WriteLine("PROGRESSO: $feito $total") }

# Bytes dos arquivos da pasta (0 se nao existe). Arquivo sumindo no meio da conta nao e erro.
function Get-Tamanho($pasta) {
    $t = 0L
    try { foreach ($f in (New-Object IO.DirectoryInfo $pasta).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $t += $f.Length } } catch { }
    $t
}

# Processos abertos pelo processo $raiz e pelos filhos deles, mesmo depois que o $raiz saiu (o
# Windows guarda o pid do pai). So conta como filho quem foi criado depois do pai: um pid de pai
# reaproveitado nao puxa processos de outro programa. Sem modulo do PowerShell: o System.Management
# sempre carrega.
function Get-Descendentes([int]$raiz, [datetime]$inicio) {
    Add-Type -AssemblyName System.Management
    $pais = @{}; $criados = @{}
    $busca = New-Object Management.ManagementObjectSearcher 'SELECT ProcessId, ParentProcessId, CreationDate FROM Win32_Process'
    try {
        foreach ($p in $busca.Get()) {
            if (-not $p['CreationDate']) { continue }
            $pais[[int]$p['ProcessId']] = [int]$p['ParentProcessId']
            $criados[[int]$p['ProcessId']] = [Management.ManagementDateTimeConverter]::ToDateTime($p['CreationDate'])
        }
    } finally { $busca.Dispose() }
    $achados = @{}
    $fila = New-Object Collections.Queue
    $fila.Enqueue(@($raiz, $inicio))
    while ($fila.Count -gt 0) {
        $pai, $criadoPai = $fila.Dequeue()
        foreach ($filho in @($pais.Keys)) {
            if ($pais[$filho] -eq $pai -and $filho -ne $raiz -and -not $achados.ContainsKey($filho) -and $criados[$filho] -ge $criadoPai) {
                $achados[$filho] = $true
                $fila.Enqueue(@($filho, $criados[$filho]))
            }
        }
    }
    @($achados.Keys)
}

# Espera o processo mandando o andamento a cada 2 s: quanto a pasta cresceu desde $base, ate $total.
# $antes soma ao feito quando a etapa tem duas partes (extrair e copiar). Com -esperarFilhos, espera
# tambem os processos que ele abriu, como o Start-Process -Wait fazia, mas desiste se a pasta parar
# de crescer por $semCrescer s ou se essa espera passar de $limite s (quem decide o resultado e o
# arquivo "pronto" do recomp).
function Wait-Medindo($proc, $pasta, [long]$base, [long]$total, [long]$antes = 0, [long]$totalEtapa = 0, [switch]$esperarFilhos,
    [int]$semCrescer = 600, [int]$limite = 7200) {
    if ($totalEtapa -le 0) { $totalEtapa = $total }
    $raiz = $proc.Id
    $inicio = [datetime]::MinValue
    if ($esperarFilhos) { try { $inicio = $proc.StartTime } catch { Etapa "instalando: aviso: sem a hora de inicio do instalador ($($_.Exception.Message))" } }
    Progresso $antes $totalEtapa
    while (-not $proc.WaitForExit(2000)) { Progresso ($antes + [math]::Min([math]::Max((Get-Tamanho $pasta) - $base, 0), $total)) $totalEtapa }
    if ($esperarFilhos) {
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        $maior = Get-Tamanho $pasta
        $cresceu = 0L
        while (@(Get-Descendentes $raiz $inicio).Count -gt 0) {
            $tam = Get-Tamanho $pasta
            if ($tam -gt $maior) { $maior = $tam; $cresceu = $relogio.ElapsedMilliseconds }
            Progresso ($antes + [math]::Min([math]::Max($tam - $base, 0), $total)) $totalEtapa
            if ($relogio.ElapsedMilliseconds - $cresceu -gt $semCrescer * 1000L -or $relogio.ElapsedMilliseconds -gt $limite * 1000L) {
                Etapa "instalando: aviso: parei de esperar os processos abertos pelo instalador (a pasta parou de crescer ou passou do limite)"
                break
            }
            [Threading.Thread]::Sleep(2000)
        }
    }
    Progresso ($antes + $total) $totalEtapa
}

# Um argumento na linha de comando, com as regras do CommandLineToArgvW: entre aspas quando tem espaco ou aspas;
# barras antes de uma aspa (ou do fim) dobram e a aspa vira \".
function Format-Argumento([string]$s) {
    if ($s -and $s -notmatch '[\s"]') { return $s }
    '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# robocopy em outro processo, para medir o destino enquanto copia. Devolve o codigo de saida.
function Copy-Medindo($origem, $destino, [long]$antes = 0, [long]$totalEtapa = 0) {
    $total = Get-Tamanho $origem
    $base = Get-Tamanho $destino
    $argumentos = (Format-Argumento $origem), (Format-Argumento $destino), '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    $p = Start-Process robocopy -ArgumentList $argumentos -WindowStyle Hidden -PassThru
    $null = $p.Handle   # (sem isto o ExitCode do Start-Process volta vazio)
    Wait-Medindo $p $destino $base $total $antes $totalEtapa
    $p.ExitCode
}

# Baixa em blocos de 1 MB, com o andamento a cada segundo. Grava em .parcial e so troca no fim.
function Save-Download($url, $destino, [long]$total) {
    $parcial = "$destino.parcial"
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = 'recomp.ps1'
    $resp = $req.GetResponse()
    try {
        if ($total -le 0) { $total = $resp.ContentLength }
        $entrada = $resp.GetResponseStream()
        $saida = [IO.File]::Create($parcial)
        try {
            $buffer = New-Object byte[] 1048576
            $feito = 0L
            $relogio = [Diagnostics.Stopwatch]::StartNew()
            Progresso 0 $total
            while (($n = $entrada.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $saida.Write($buffer, 0, $n)
                $feito += $n
                if ($relogio.ElapsedMilliseconds -ge 1000) { $relogio.Restart(); Progresso $feito $total }
            }
            Progresso $feito $total
        } finally { $saida.Dispose(); $entrada.Dispose() }
    } finally { $resp.Close() }
    if ($total -gt 0 -and $feito -ne $total) { throw "o download parou no meio ($feito de $total bytes); a conexao caiu, tente de novo" }
    if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Force }
    [IO.File]::Move($parcial, $destino)
}

# Baixa do RomM com o baixar-worker.ps1, o mesmo dos jogos do emulador: .parcial,
# retomada por Range e SHA-1 do RomM. O andamento dele (progresso.json) vira PROGRESSO aqui. Cancelar
# mata a arvore toda e o .parcial fica para a proxima vez.
function Invoke-Baixar($url, $auth, $destino, [long]$total, $sha1, $nome) {
    $arqProgresso = Join-Path ([IO.Path]::GetTempPath()) ('recomp-' + [guid]::NewGuid().ToString('N') + '.json')
    $trabalho = @{ url = $url; auth = $auth; destino = $destino; total = $total; progresso = $arqProgresso; sha1 = $sha1 } | ConvertTo-Json -Compress
    Etapa "baixando: $nome ($([math]::Round($total / 1MB)) MB)"
    $psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'baixar-worker.ps1')`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    # (a saida do worker nao pode cair no stdout que o plugin le)
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['JOGOSRETRO_DOWNLOAD'] = $trabalho
    $p = [Diagnostics.Process]::Start($psi)
    [void]$p.StandardOutput.ReadToEndAsync(); [void]$p.StandardError.ReadToEndAsync()
    $estado = $null
    Progresso 0 $total
    while ($true) {
        $saiu = $p.WaitForExit(1000)
        try { $estado = Get-Content -LiteralPath $arqProgresso -Raw | ConvertFrom-Json; Progresso ([long]$estado.baixado) $total } catch { }
        if ($saiu) { break }
    }
    Remove-Item -LiteralPath $arqProgresso -Force -ErrorAction SilentlyContinue
    if (-not $estado -or $estado.estado -ne 'ok' -or -not (Test-Path -LiteralPath $destino)) {
        throw $(if ($estado -and $estado.msg) { "$nome`: $($estado.msg)" } else { "o download de $nome parou no meio; tente de novo" })
    }
}

# Copia um arquivo grande com o andamento, em .parcial ate o fim.
function Copy-Arquivo($origem, $destino) {
    $parcial = "$destino.parcial"
    $entrada = [IO.File]::OpenRead($origem)
    try {
        $total = $entrada.Length
        $saida = [IO.File]::Create($parcial)
        try {
            $buffer = New-Object byte[] 1048576
            $feito = 0L
            $relogio = [Diagnostics.Stopwatch]::StartNew()
            Progresso 0 $total
            while (($n = $entrada.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $saida.Write($buffer, 0, $n)
                $feito += $n
                if ($relogio.ElapsedMilliseconds -ge 1000) { $relogio.Restart(); Progresso $feito $total }
            }
            Progresso $feito $total
        } finally { $saida.Dispose() }
    } finally { $entrada.Dispose() }
    if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Force }
    [IO.File]::Move($parcial, $destino)
}

# Hardlink no mesmo volume NTFS (nao ocupa espaco e apagar a ROM do emulador depois nao apaga este);
# em outro drive, copia.
function Test-PodeLinkar($origem, $destino) {
    $a = [IO.Path]::GetPathRoot($origem); $b = [IO.Path]::GetPathRoot($destino)
    if (-not $a -or $a -ne $b) { return $false }
    try { (New-Object IO.DriveInfo $a).DriveFormat -eq 'NTFS' } catch { $false }
}

function New-LinkOuCopia($origem, $destino) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destino))
    if (Test-PodeLinkar $origem $destino) {
        if (-not ('RecompLink.Kernel' -as [type])) {
            Add-Type -Namespace RecompLink -Name Kernel -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateHardLink(string novo, string existente, IntPtr seguranca);'
        }
        if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Force }
        Etapa 'preparando: usando o jogo que ja esta no emulador'
        if ([RecompLink.Kernel]::CreateHardLink($destino, $origem, [IntPtr]::Zero)) { return 'link' }
    }
    Etapa "baixando: copiando o jogo que ja esta no emulador ($([math]::Round((Get-Item -LiteralPath $origem).Length / 1MB)) MB)"
    Copy-Arquivo $origem $destino
    'copia'
}

# Ate onde algo pode ser apagado, por mais errado que esteja o catalogo: subpasta da pasta dos Recomps
# (ou de uma raiz extra do recomps-local.json), ou a pasta / copia do disco de um jogo do catalogo.
# Nunca a raiz de um drive, o programa, os emuladores, as pastas de ROMs nem _saves, _gerenciador,
# _downloads e _origem.
function Set-Seguranca($cfg, $base) {
    $script:Raizes = @(@($cfg.recomps) + @($cfg.raizes) | Where-Object { $_ })
    $script:PastasJogos = @(foreach ($j in @($cfg.jogos)) { $j.pasta; $j.disco }) | Where-Object { $_ }
    $script:Mapas = @()
    try {
        $L = Get-Content -LiteralPath ([IO.Path]::Combine($base, 'launcher.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Mapas = @(@($L.mapas | ForEach-Object { $_.destino }) | Where-Object { $_ })
        if ($L.rommConfig) { $script:Mapas += @((Get-Content -LiteralPath $L.rommConfig -Raw -Encoding UTF8 | ConvertFrom-Json).Mappings | ForEach-Object { $_.DestinationPath } | Where-Object { $_ }) }
    } catch { }
    $script:Proibidas = @(@([IO.Path]::Combine($base, 'programa'), [IO.Path]::Combine($base, 'Emuladores'), $cfg.salvos, $cfg.downloads) + $script:Mapas | Where-Object { $_ })
}

function Test-Dentro([string]$caminho, [string]$pasta, [switch]$OuIgual) {
    $p = [IO.Path]::GetFullPath($pasta).TrimEnd('\')
    $c = [IO.Path]::GetFullPath($caminho).TrimEnd('\')
    ($OuIgual -and $c -eq $p) -or $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-PodeApagar([string]$cheio) {
    $cheio = [IO.Path]::GetFullPath($cheio).TrimEnd('\')
    if ($cheio -match '^[A-Za-z]:$' -or $cheio -match '^\\\\[^\\]+\\[^\\]+$') { return $false }
    if (@($cheio -split '\\' | Where-Object { $_ -match '^_(gerenciador|saves|downloads|origem)$' }).Count) { return $false }
    foreach ($p in $script:Proibidas) { if ((Test-Dentro $cheio $p -OuIgual) -or (Test-Dentro $p $cheio)) { return $false } }
    foreach ($r in $script:Raizes) { if (Test-Dentro $cheio $r) { return $true } }
    foreach ($r in $script:PastasJogos) { if (Test-Dentro $cheio $r -OuIgual) { return $true } }
    $false
}

function Remove-Seguro($caminho) {
    if (-not (Test-Path -LiteralPath $caminho)) { return }
    # (sem tirar a "\" antes: "C:" sozinho seria a pasta atual do drive)
    $cheio = (Resolve-Path -LiteralPath $caminho).ProviderPath
    if (-not (Test-PodeApagar $cheio)) { throw "recusei apagar $($cheio.TrimEnd('\'))" }
    Remove-Item -LiteralPath $cheio -Recurse -Force
}

function Copy-Itens($de, $para, $itens) {
    foreach ($i in $itens) {
        $origem = Join-Path $de $i
        if (-not (Test-Path -LiteralPath $origem)) { continue }
        $destino = Join-Path $para $i
        if ((Get-Item -LiteralPath $origem).PSIsContainer) {
            robocopy $origem $destino /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "falha ao copiar $origem (robocopy $LASTEXITCODE)" }
        } else {
            New-Item -ItemType Directory -Force (Split-Path $destino) | Out-Null
            Copy-Item -LiteralPath $origem $destino -Force
        }
    }
}

# (sem Get-FileHash: o modulo dele nem sempre carrega no PowerShell 5.1 aberto por outro processo)
function Get-Sha256($arquivo) {
    $s = [IO.File]::OpenRead($arquivo)
    try { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('X2') }) } finally { $s.Dispose() }
}

function Find-Asset($jogo) {
    # /releases/latest ignora pre-releases (ha Recomps que so tem alphas): pega a mais nova da lista.
    $lista = Invoke-RestMethod "$GitHubApi/repos/$($jogo.repo)/releases?per_page=10" -UseBasicParsing
    $rel = $lista | Where-Object { -not $_.draft } | Select-Object -First 1
    if (-not $rel) { throw "$($jogo.repo) nao tem release publicada" }
    $asset = $rel.assets | Where-Object { $_.name -match $jogo.asset } | Select-Object -First 1
    if (-not $asset) { throw "release $($rel.tag_name) de $($jogo.repo) sem arquivo para Windows" }
    [pscustomobject]@{ Rel = $rel; Asset = $asset }
}

function Get-Release($jogo, $pastaDownloads) {
    $a = Find-Asset $jogo
    $rel = $a.Rel; $asset = $a.Asset
    New-Item -ItemType Directory -Force $pastaDownloads | Out-Null
    $zip = Join-Path $pastaDownloads $asset.name
    $esperado = if ($asset.digest) { ($asset.digest -replace '^sha256:', '').ToUpper() } else { $null }
    if (-not ((Test-Path -LiteralPath $zip) -and $esperado -and (Get-Sha256 $zip) -eq $esperado)) {
        Etapa "baixando: $($asset.name) ($([math]::Round($asset.size / 1MB)) MB)"
        Save-Download $asset.browser_download_url $zip ([long]$asset.size)
    }
    if ($esperado -and (Get-Sha256 $zip) -ne $esperado) { Remove-Item -LiteralPath $zip; throw "o arquivo baixado nao confere com o SHA-256 do GitHub" }
    if (-not $esperado) { throw "o GitHub nao informou o SHA-256 de $($asset.name); nao instalei sem conferir" }
    [pscustomobject]@{ Zip = $zip; Versao = $rel.tag_name }
}

# Release FIXADA no catalogo (campo "fixa", hoje so o Triforce, que nao publica SHA-256): a versao e o SHA-256 de cada
# arquivo ficam no recomps.json, conferidos por nos. Nunca pega a mais nova sozinho: trocar a versao e trocar o catalogo.
# Os arquivos ficam em <downloads>\<tipo>-<versao>.
function Get-PastaFixa($jogo, $pastaDownloads) { Join-Path $pastaDownloads "$($jogo.tipo)-$($jogo.fixa.versao)" }

# Catalogo errado para antes de baixar: versao e nomes sem caminho (nem "." ou ".."), endereco https, SHA-256 com 64 digitos.
function Test-Fixa($jogo) {
    $f = $jogo.fixa
    if (-not $f -or "$($f.versao)" -notmatch '^[\w.-]+$' -or "$($f.versao)" -match '^\.+$' -or -not @($f.arquivos | Where-Object { $_ }).Count) { throw 'catalogo sem a versao fixa deste Recomp; avise o Neto' }
    foreach ($a in @($f.arquivos)) {
        if ("$($a.nome)" -notmatch '^[\w.-]+$' -or "$($a.nome)" -match '^\.+$' -or "$($a.url)" -notmatch $UrlFixa -or "$($a.sha256)" -notmatch '^[0-9A-Fa-f]{64}$') {
            throw 'catalogo com um arquivo da versao fixa sem nome, endereco https ou SHA-256; avise o Neto'
        }
    }
}

# O make_game apaga subpastas dentro do --out e do --work: a pasta do jogo tem de ser uma que o Remove-Seguro aceitaria
# apagar, e o id (que entra no nome da pasta de trabalho) nao pode ter caminho.
function Test-PastasTriforce($jogo) {
    if ("$($jogo.id)" -notmatch '^[\w.-]+$' -or "$($jogo.id)".Contains('..')) { throw "catalogo com um id que nao serve para nome de pasta ($($jogo.id)); avise o Neto" }
    if (-not $jogo.pasta -or -not (Test-PodeApagar $jogo.pasta)) { throw "a pasta do Recomp ($($jogo.pasta)) esta fora da area dos Recomps; nada foi montado. Avise o Neto" }
}

# Baixa cada arquivo da versao fixa (o que ja esta la com o SHA-256 certo e reaproveitado) e confere o SHA-256.
# Devolve o mesmo que o Get-Release (Zip, Versao), mais a pasta e o SHA-256 do zip.
function Get-ReleaseFixa($jogo, $pastaDownloads) {
    Test-Fixa $jogo
    $pasta = Get-PastaFixa $jogo $pastaDownloads
    New-Item -ItemType Directory -Force $pasta | Out-Null
    $zip = $null; $sha = $null
    foreach ($a in @($jogo.fixa.arquivos)) {
        $arq = Join-Path $pasta $a.nome
        $esperado = ([string]$a.sha256).ToUpper()
        $ok = $false
        if (Test-Path -LiteralPath $arq) { Etapa "preparando: conferindo $($a.nome)"; $ok = (Get-Sha256 $arq) -eq $esperado }
        if (-not $ok) {
            Etapa "baixando: $($a.nome) ($([math]::Round([long]$a.tamanho / 1MB)) MB)"
            Save-Download $a.url $arq ([long]$a.tamanho)
            Etapa "preparando: conferindo $($a.nome)"
            if ((Get-Sha256 $arq) -ne $esperado) {
                Remove-Item -LiteralPath $arq -Force
                throw "o $($a.nome) baixado nao confere com o SHA-256 fixado no recomps.json; apaguei o arquivo e nao instalei. Avise o Neto."
            }
        }
        if (-not $zip -and $a.nome -like '*.zip') { $zip = $arq; $sha = $esperado }
    }
    if (-not $zip) { throw 'a versao fixa deste Recomp nao tem um .zip; avise o Neto' }
    [pscustomobject]@{ Zip = $zip; Versao = $jogo.fixa.versao; Pasta = $pasta; Sha = $sha }
}

# O .nup no servidor (\\servidor\...): antes de olhar o arquivo, a porta 445 com limite de 3 s (com o servidor
# desligado o Windows esperaria de 20 a 60 s). Diz se o arquivo existe.
function Test-Nup([string]$nup) {
    if (-not $nup) { return $false }
    if ($nup -match '^\\\\([^\\]+)\\') {
        $c = New-Object Net.Sockets.TcpClient
        try {
            $r = $c.BeginConnect($Matches[1], 445, $null, $null)
            if (-not $r.AsyncWaitHandle.WaitOne(3000)) { return $false }
            $c.EndConnect($r)
        } catch { return $false } finally { $c.Close() }
    }
    Test-Path -LiteralPath $nup -PathType Leaf
}

function Get-MotivoNup($nup) { "arquivo do jogo (.nup) nao encontrado: $nup. Confira se o servidor esta ligado." }

# Pre-checagem barata, antes de baixar: o nome do .nup traz o titulo e a versao que o Triforce aceita.
function Test-NomeNup($jogo) {
    $f = $jogo.fixa
    if (-not $jogo.nup -or -not $f.titulo -or -not $f.versaoJogo) { throw 'catalogo sem o .nup, o titulo ou a versao do jogo; avise o Neto' }
    $nome = [IO.Path]::GetFileName($jogo.nup)
    if ($nome.IndexOf("[$($f.titulo)][$($f.versaoJogo)]", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $achado = if ($nome -match '\[[0-9A-Fa-f]{16}\]\[v\d+\]') { $Matches[0] } else { $nome }
        throw "o arquivo do jogo nao e a versao que o Triforce aceita. Precisa: $($f.versaoJogoTexto) [$($f.titulo)][$($f.versaoJogo)]. Encontrado: $achado. Nada foi montado e o arquivo do jogo nao foi alterado."
    }
}

# O .nup nunca muda (regra 16): o mesmo tamanho e a mesma data de antes da montagem.
function Assert-NupIgual($nup, [long]$tamanho, [datetime]$data) {
    if (-not (Test-Path -LiteralPath $nup -PathType Leaf)) { throw (Get-MotivoNup $nup) }
    $i = Get-Item -LiteralPath $nup
    if ($i.Length -ne $tamanho -or $i.LastWriteTimeUtc -ne $data) { throw 'o arquivo do jogo (.nup) mudou durante a montagem (tamanho ou data). Nada foi marcado como instalado. Avise o Neto.' }
}

# Texto do Triforce dentro de uma mensagem nossa: uma linha, ate 300 caracteres e sem "closing", "exiting" ou
# "shutting" inteiros (regra 17).
function Format-TextoExterno([string]$t) {
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt 300) { $t = $t.Substring(0, 299) + '...' }
    [regex]::Replace($t, '(?<=clos)(?=ing)|(?<=exit)(?=ing)|(?<=shut)(?=ting)', [string][char]0x200B, 'IgnoreCase')
}

# NSTool em <downloads>\nstool-v...: baixa uma vez, do GitHub, e confere o SHA-256.
function Get-Nstool($pastaDownloads) {
    $exe = [IO.Path]::Combine($pastaDownloads, $Nstool.Pasta, 'nstool.exe')
    if (Test-Path -LiteralPath $exe) { return $exe }
    New-Item -ItemType Directory -Force $pastaDownloads | Out-Null
    $zip = Join-Path $pastaDownloads ($Nstool.Url -replace '^.*/', '')
    if (-not ((Test-Path -LiteralPath $zip) -and (Get-Sha256 $zip) -eq $Nstool.Sha)) {
        Etapa 'preparando: baixando o NSTool'
        Save-Download $Nstool.Url $zip 0
    }
    if ((Get-Sha256 $zip) -ne $Nstool.Sha) { Remove-Item -LiteralPath $zip; throw 'o NSTool baixado nao confere com o SHA-256 esperado' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $e = $z.Entries | Where-Object { $_.Name -eq 'nstool.exe' } | Select-Object -First 1
        if (-not $e) { throw 'o zip do NSTool nao tem o nstool.exe' }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($exe))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $exe, $true)
    } finally { $z.Dispose() }
    $exe
}

# Extrai o zip entrada por entrada em $destino, recusando caminho para fora dela (zip-slip). Com $fator > 0,
# manda o andamento como PROGRESSO <feito> <total * fator>. Devolve o total descompactado (bytes).
function Expand-ZipSeguro($zip, $destino, [int]$fator = 0) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $raiz = [IO.Directory]::CreateDirectory($destino).FullName.TrimEnd('\') + '\'
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $total = 0L
        foreach ($e in $z.Entries) { $total += $e.Length }
        $feito = 0L
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        if ($fator -gt 0) { Progresso 0 ($total * $fator) }
        foreach ($e in $z.Entries) {
            $alvo = [IO.Path]::GetFullPath([IO.Path]::Combine($raiz, $e.FullName))
            if (-not $alvo.StartsWith($raiz, [StringComparison]::OrdinalIgnoreCase)) { throw "o zip tem um caminho fora da pasta: $($e.FullName)" }
            if ($e.Name -eq '') { [void][IO.Directory]::CreateDirectory($alvo); continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($alvo))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $alvo, $true)
            $feito += $e.Length
            if ($fator -gt 0 -and $relogio.ElapsedMilliseconds -ge 1000) { $relogio.Restart(); Progresso $feito ($total * $fator) }
        }
    } finally { $z.Dispose() }
    $total
}

# Extrai entrada por entrada (para dar a porcentagem) e copia para a pasta; as duas partes
# contam como uma etapa so: metade extraindo, metade copiando. $tmp e <pasta dos Recomps>\_tmp\<id>: nunca
# "<pasta>.tmp", que poderia ser a pasta de outro Recomp (e seria apagada). O robocopy copia entre drives.
function Expand-Recomp($zip, $pasta, [bool]$achatar, [string]$tmp) {
    Remove-Seguro $tmp
    try {
        $total = Expand-ZipSeguro $zip $tmp 2
        $raiz = Get-ChildItem -LiteralPath $tmp
        $origem = if ($achatar -and $raiz.Count -eq 1 -and $raiz[0].PSIsContainer) { $raiz[0].FullName } else { $tmp }
        $codigo = Copy-Medindo $origem $pasta $total ($total * 2)
        if ($codigo -ge 8) { throw "falha ao extrair (robocopy $codigo)" }
    } finally {
        # (tambem na falha: nao sobram GBs no _tmp; um erro aqui nao esconde o erro de cima)
        try { Remove-Seguro $tmp } catch { Etapa "extraindo: aviso: nao apaguei $tmp ($($_.Exception.Message))" }
    }
}

# Linha do setup.log do Weeping of the Empire (TotK) -> Passo (1 a 5) e, quando a linha diz, Feito e Total; outra
# linha -> $null. Passos nossos: 1 ferramentas ("step 0/N tools"), 2 extrair e conferir o jogo (steps antes do build),
# 3 gerar o codigo (o "step N/M build" ate o "gen main:"), 4 compilar (as linhas "[n/total]" do ninja) e 5 montar
# (os steps depois do build). $estado guarda se o build ja comecou.
function Read-PassoTotk([string]$linha, $estado) {
    if ($linha -match '^\[Builder\] step \d+/\d+ (\w+)') {
        $nome = $Matches[1]
        if ($nome -eq 'build') { $estado.Build = $true; return [pscustomobject]@{ Passo = 3; Feito = 0; Total = 0 } }
        $passo = if ($nome -eq 'tools') { 1 } elseif ($estado.Build) { 5 } else { 2 }
        return [pscustomobject]@{ Passo = $passo; Feito = 0; Total = 0 }
    }
    if ($estado.Build -and $linha -match '\] gen main: ') { return [pscustomobject]@{ Passo = 4; Feito = 0; Total = 0 } }
    if ($estado.Build -and $linha -match '^\[(\d+)/(\d+)\] ') { return [pscustomobject]@{ Passo = 4; Feito = [long]$Matches[1]; Total = [long]$Matches[2] } }
    # (download das ferramentas e extracao do jogo: "...: 45% (35/77 MB, ...)")
    if ($linha -match '^\[Builder\] (download|extract)[^:]*: (\d+)%') {
        $passo = if ($Matches[1] -eq 'extract') { 2 } elseif ($estado.Passo) { $estado.Passo } else { 1 }
        return [pscustomobject]@{ Passo = $passo; Feito = [long]$Matches[2]; Total = 100 }
    }
    $null
}

# Linha do stdout do make_game.py (Triforce) -> Passo (1 a 5, so quando a etapa muda) ou Feito (0 a 1000, da etapa
# atual, com Passo 0); outra linha -> $null. Etapas do Triforce: read, lift, compile, finish e shaders (o texto dele
# nunca vai para o card). "@@error", "@@done" e o aviso dos shaders nao preparados ficam em $estado (Erro, Pronto,
# SemShaders).
function Read-PassoTriforce([string]$linha, $estado) {
    if ($linha -match '^@@stage\s+(\w+)') {
        $n = @('read', 'lift', 'compile', 'finish', 'shaders').IndexOf($Matches[1].ToLowerInvariant()) + 1
        if ($n -gt 0 -and $n -ne $estado.Passo) { $estado.Passo = $n; return [pscustomobject]@{ Passo = $n; Feito = 0 } }
        return $null
    }
    if ($linha -match '^@@progress\s+(\S+)') {
        $x = 0.0
        if (-not [double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $null }
        return [pscustomobject]@{ Passo = 0; Feito = [long][math]::Round([math]::Min([math]::Max($x, 0), 1) * 1000) }
    }
    if ($linha -match '^@@error\s*(.*)$') { $estado.Erro = $Matches[1]; return $null }
    if ($linha -match '^@@done\b') { $estado.Pronto = $true; return $null }
    if ($linha -match 'the shaders were not prepared now') { $estado.SemShaders = $true }
    $null
}

# Ferramentas do Triforce (Python embutido, make_game.py, compilador) em <downloads>\triforce-<versao>\tools: fora da
# pasta do jogo e no drive dos downloads (o D: tem pouco espaco; o _tmp da extracao e apagado no fim). Extrai uma vez
# por versao; a marca .extraido (o SHA-256 do zip) so e gravada depois de extrair tudo.
function Get-FerramentasFixa($cfg, $jogo, $rel) {
    $tools = Join-Path $rel.Pasta 'tools'
    $marca = Join-Path $rel.Pasta '.extraido'
    $py = Join-Path $tools 'python\python.exe'
    $mg = Join-Path $tools 'nx2\make_game.py'
    if ((Test-Path -LiteralPath $marca) -and [IO.File]::ReadAllText($marca).Trim() -eq $rel.Sha -and (Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $mg)) { return $tools }
    if (Test-Path -LiteralPath $marca) { Remove-Item -LiteralPath $marca -Force }
    Etapa "extraindo: Triforce $($rel.Versao)"
    Expand-Recomp $rel.Zip $tools $true ([IO.Path]::Combine($cfg.recomps, '_tmp', $jogo.id))
    if (-not ((Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $mg))) { throw "o $([IO.Path]::GetFileName($rel.Zip)) nao trouxe o python\python.exe e o nx2\make_game.py; avise o Neto" }
    [IO.File]::WriteAllText($marca, $rel.Sha)
    $tools
}

# Roda o make_game.py com o Python que vem no zip (-I: nada do Python do PC), na pasta tools, sem tela, com a entrada
# fechada (se perguntar algo, recebe fim de entrada e nao trava) e a saida lida linha a linha: cada linha vai para
# $cadaLinha. A saida dele nunca cai no stdout que o plugin le. Devolve o codigo de saida.
function Invoke-MakeGame($tools, [string[]]$argumentos, [scriptblock]$cadaLinha) {
    $linha = @(@('-I', '-u', 'nx2\make_game.py') + $argumentos | ForEach-Object { Format-Argumento $_ }) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $tools 'python\python.exe'), $linha
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $tools
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    [void]$p.StandardError.ReadToEndAsync()
    while ($null -ne ($l = $p.StandardOutput.ReadLine())) { & $cadaLinha $l }
    $p.WaitForExit()
    $p.ExitCode
}

function Test-Arquivo($caminho, $oque) { if (-not (Test-Path -LiteralPath $caminho)) { throw "$oque nao encontrado: $caminho" } }

# Python 3 de verdade (o python.exe da Microsoft Store que so abre a loja nao conta).
function Find-Python {
    foreach ($c in @(Get-Command python.exe, py.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        $v = try { $null | & $c.Source -c 'import sys; print(sys.version_info[0])' 2>$null } catch { $null }
        if ("$v".Trim() -eq '3') { return $c }
    }
    $null
}

function Set-Campo($jogo, $nome, $valor) { $jogo | Add-Member -NotePropertyName $nome -NotePropertyValue $valor -Force }

# Sem plataforma, apenas os dois formatos do catalogo anterior tem significado.
function Get-ModoOrigem($jogo) {
    if ($jogo.origem -ne 'rom') { return $null }
    $ext = [IO.Path]::GetExtension([string]$jogo.romm.arquivo)
    $plataforma = $jogo.plataforma
    if (-not $plataforma) {
        $plataforma = switch ($ext) { '.iso' { 'ps3' } '.nsp' { 'switch' } }
    }
    if (-not $plataforma -or $ext -notin $FormatosOrigem[$plataforma]) { return $null }
    $campo = switch ($ext) { '.iso' { 'iso' } '.nsp' { 'nsp' } default { 'dump' } }
    [pscustomobject]@{ Plataforma = $plataforma; Ext = $ext; Campo = $campo }
}

function Sync-CampoDump($jogo, $modo) {
    if (-not $modo -or $modo.Campo -eq 'dump') { return }
    if ($jogo.($modo.Campo)) { Set-Campo $jogo 'dump' $jogo.($modo.Campo) }
    elseif ($jogo.dump) { Set-Campo $jogo $modo.Campo $jogo.dump }
}

function Test-Entrada47a($jogo) {
    $ext = [IO.Path]::GetExtension([string]$jogo.romm.arquivo)
    $modoLegado = ($ext -eq '.nsp' -and $jogo.plataforma -in '', $null, 'switch') -or
        ($ext -eq '.iso' -and $jogo.plataforma -in '', $null, 'ps3')
    ($jogo.origem -eq 'rom' -and -not $modoLegado) -or $jogo.dump -or
        @($jogo.precisa | Where-Object { $_ -in 'bios', 'firmware' }).Count -gt 0 -or
        ($jogo.plataforma -and $jogo.args -match '\{pasta\}' -and -not $jogo.args.Contains('"')) -or
        (@($jogo.preparo.args) + @($jogo.args)) -match '\{(dump|bios|firmware|rpcs3)\}'
}

function Test-ContratoPlugin($cfg, $jogo) {
    if ($cfg.contrato -ge 2) { return }
    $entradaNova = Test-Entrada47a $jogo
    $catalogo = Join-Path $PSScriptRoot 'recomps.json'
    if (-not $entradaNova -and (Test-Path -LiteralPath $catalogo -PathType Leaf)) {
        # O plugin antigo descarta os campos novos ao regravar o catalogo.
        # (catalogo em atualizacao ou estragado: vale so a entrada recebida, como antes da v47a)
        try {
            $pacote = Get-Content -LiteralPath $catalogo -Raw -Encoding UTF8 | ConvertFrom-Json
            $original = $pacote.jogos | Where-Object id -eq $jogo.id | Select-Object -First 1
            if ($original) { $entradaNova = Test-Entrada47a $original }
        } catch { }
    }
    if ($entradaNova) {
        throw ('O Jogos Retro deste PC ainda n{0}o terminou de se atualizar. Feche o Playnite e abra de novo pelo atalho "Jogos Retro": ele termina a atualiza{1}{0}o sozinho. Se continuar, avise o Neto.' -f [char]0xE3, [char]0xE7)
    }
}

function Find-BiosPs2($Base) {
    $pcsx2 = Join-Path $Base 'Emuladores\PCSX2'
    $pasta = Join-Path $pcsx2 'bios'
    $ini = Join-Path $pcsx2 'inis\PCSX2.ini'
    if (Test-Path -LiteralPath $ini -PathType Leaf) {
        $nomes = $false
        foreach ($linha in Get-Content -LiteralPath $ini -Encoding UTF8) {
            if ($linha -match '^\s*\[(.+)\]\s*$') { $nomes = $Matches[1] -eq 'Filenames' }
            elseif ($nomes -and $linha -match '^\s*BIOS\s*=\s*(.*)$') {
                $nome = $Matches[1].Trim()
                if ($nome -and [IO.Path]::GetFileName($nome) -eq $nome) {
                    $arquivo = Join-Path $pasta $nome
                    if ([IO.Path]::GetExtension($arquivo) -eq '.bin' -and (Test-Path -LiteralPath $arquivo -PathType Leaf)) { return $arquivo }
                }
                break
            }
        }
    }
    if (Test-Path -LiteralPath $pasta -PathType Container) {
        $bins = @(Get-ChildItem -LiteralPath $pasta -Filter '*.bin' -File)
        if ($bins.Count -eq 1) { return $bins[0].FullName }
    }
}

function Resolve-Requisitos($jogo, $Base) {
    $precisa = @($jogo.precisa)
    if ($precisa -contains 'keys' -and -not $jogo.keys) { Set-Campo $jogo 'keys' ([IO.Path]::Combine($Base, 'Emuladores\Eden\user\keys\prod.keys')) }
    if ($precisa -contains 'rpcs3' -and -not $jogo.rpcs3) { Set-Campo $jogo 'rpcs3' ([IO.Path]::Combine($Base, 'Emuladores\RPCS3')) }
    if ($precisa -contains 'bios' -and -not $jogo.bios -and $jogo.plataforma -eq 'ps2') {
        Set-Campo $jogo 'bios' (Find-BiosPs2 $Base)
    }
    if ($precisa -contains 'firmware' -and -not $jogo.firmware) {
        if ($jogo.plataforma -eq 'switch') { Set-Campo $jogo 'firmware' (Join-Path $Base 'Emuladores\Eden\user\nand\system\Contents\registered') }
        elseif ($jogo.plataforma -eq 'ps3') {
            $rpcs3 = if ($jogo.rpcs3) { $jogo.rpcs3 } else { Join-Path $Base 'Emuladores\RPCS3' }
            Set-Campo $jogo 'firmware' (Join-Path $rpcs3 'dev_flash')
        }
    }
}

function Test-Firmware($jogo) {
    if (-not $jogo.firmware -or -not (Test-Path -LiteralPath $jogo.firmware -PathType Container)) { return $false }
    switch ($jogo.plataforma) {
        'switch' { return [bool](Get-ChildItem -LiteralPath $jogo.firmware -Filter '*.nca' -File | Select-Object -First 1) }
        'ps3' { return Test-Path -LiteralPath (Join-Path $jogo.firmware 'vsh\etc\version.txt') -PathType Leaf }
    }
    $false
}

# O original nao faz parte da instalacao: se o preparo o alterar, nao marcamos o Recomp como pronto.
function Assert-OrigemIgual($origem, [bool]$doDono) {
    if (-not $origem) { return }
    $atual = Get-Item -LiteralPath $origem.Caminho -ErrorAction SilentlyContinue
    if ($atual -and -not $atual.PSIsContainer -and $atual.Length -eq $origem.Tamanho -and $atual.LastWriteTimeUtc -eq $origem.Data) { return }
    if ($doDono) {
        throw ('O arquivo do jogo mudou durante a prepara{0}{1}o ({2}): tamanho ou data diferente. Nada foi instalado. Confira esse arquivo no servidor; o comando desse Recomp n{1}o pode mexer no arquivo do jogo.' -f [char]0xE7, [char]0xE3, $origem.Caminho)
    }
    throw ('O arquivo do jogo mudou durante a prepara{0}{1}o, e o Recomp n{1}o pode mexer nele. Nada foi instalado. Se o jogo no emulador n{1}o abrir mais, desinstale a ROM e instale de novo. Avise o Neto.' -f [char]0xE7, [char]0xE3)
}

function Get-PastaOrigem($cfg, $jogo) { [IO.Path]::Combine($cfg.pastaOrigem, $jogo.id) }

# O romm.arquivo (fs_name do RomM) vira nome de arquivo no _origem\<id>: so nome simples, sem pasta, sem "." ou ".."
# e sem caractere que o Windows recusa (esse faria o GetExtension/GetFileName lancar excecao).
function Test-NomeSimples([string]$nome) {
    $nome -and $nome -ne '.' -and $nome -ne '..' -and $nome.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and
        [IO.Path]::GetFileName($nome) -eq $nome
}

function Assert-ArquivoRomm($jogo) {
    $nome = [string]$jogo.romm.arquivo
    if (-not (Test-NomeSimples $nome)) { throw "catalogo com um arquivo do RomM que nao serve para nome de arquivo ($nome); nada foi baixado, avise o Neto" }
}

# A ROM que o RomM baixou para o emulador, inteira (mesmo tamanho do RomM), ou nada.
function Find-RomLocal($con, $rom) {
    $m = @($con.Mappings) | Where-Object { "$($_.RomMPlatformId)" -eq "$($rom.platform_id)" } | Select-Object -First 1
    if (-not $m) { return $null }
    $c = Get-CaminhoJogo $m $rom.fs_name
    if ((Test-Path -LiteralPath $c) -and (Get-Item -LiteralPath $c).Length -eq [long]$rom.fs_size_bytes) { return $c }
    $null
}

function Get-RomRomm($jogo) {
    $con = Get-RommConexao $Base
    # Le como UTF-8: o PowerShell 5.1 decodifica como Latin-1 quando o servidor nao manda charset, e
    # "Metroid(TM)" deixava de bater com o romm.arquivo do catalogo (FALTA: mudou).
    $r = Invoke-WebRequest "$($con.Api)/roms/$($jogo.romm.id)" -Headers @{ Authorization = $con.Auth } -UseBasicParsing -TimeoutSec 30
    $rom = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    [pscustomobject]@{ Con = $con; Rom = $rom }
}

# Exe do preparo (tipo "comando"): relativo e dentro da pasta do Recomp, nunca um programa do PC. Devolve o caminho cheio.
# Test-NomePreparo confere so o nome (antes de baixar qualquer coisa): .exe, relativo, sem "..", sem ":" (nem drive
# nem fluxo alternativo do NTFS).
function Test-NomePreparo([string]$exe) {
    if (-not $exe -or $exe -notmatch '(?i)\.exe$' -or $exe.Contains(':') -or [IO.Path]::IsPathRooted($exe) -or $exe -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "o preparo aponta para fora da pasta do Recomp ($exe); avise o Neto"
    }
}

function Get-ExePreparo([string]$pasta, [string]$exe) {
    Test-NomePreparo $exe
    $cheio = [IO.Path]::GetFullPath([IO.Path]::Combine($pasta, $exe))
    if (-not (Test-Dentro $cheio $pasta)) { throw "o preparo aponta para fora da pasta do Recomp ($exe); avise o Neto" }
    if (-not (Test-Path -LiteralPath $cheio -PathType Leaf)) { throw "o Recomp nao trouxe o $exe; avise o Neto" }
    $cheio
}

# Argumento do preparo com os campos {pasta} {nsp} {iso} {keys} trocados pelos caminhos deste PC.
# Campo desconhecido ou sem valor e erro: o comando nunca roda com um caminho pela metade.
function Format-Campos([string]$texto, $jogo) {
    foreach ($m in [regex]::Matches($texto, '\{(\w+)\}')) {
        $campo = $m.Groups[1].Value
        if ($campo -notin 'pasta', 'nsp', 'iso', 'keys', 'dump', 'bios', 'firmware', 'rpcs3') { throw "o preparo usa um campo desconhecido: {$campo}; avise o Neto" }
        if (-not $jogo.$campo) { throw "o preparo usa {$campo}, mas esse arquivo nao foi preparado; avise o Neto" }
    }
    [regex]::Replace($texto, '\{(\w+)\}', { param($m) [string]$jogo.($m.Groups[1].Value) })
}

# Marcador nosso: so existe depois que a instalacao terminou com sucesso (e o "pronto" do recomps.json).
function Set-MarcaPronto($jogo) { Set-Content -LiteralPath (Join-Path $jogo.pasta '.recomp-pronto') -Value (Get-Date -Format s) -Encoding ASCII }

# O que falta para instalar, sem baixar nada (R9): Faltas (codigos), Precisa e Livre (bytes), Drive.
# Guarda o jogo do RomM para a instalacao nao perguntar de novo.
function Get-Verificacao($cfg, $jogo) {
    $faltas = New-Object Collections.Generic.List[string]
    $precisa = 0L
    $precisaDe = @($jogo.precisa)
    if ($precisaDe -contains 'keys' -and -not ($jogo.keys -and (Test-Path -LiteralPath $jogo.keys))) { $faltas.Add('keys') }
    if ($precisaDe -contains 'rpcs3' -and -not ($jogo.rpcs3 -and (Test-Path -LiteralPath $jogo.rpcs3))) { $faltas.Add('rpcs3') }
    if ($precisaDe -contains 'python' -and -not (Find-Python)) { $faltas.Add('python') }
    if ($precisaDe -contains 'bios' -and -not ($jogo.bios -and $jogo.plataforma -eq 'ps2' -and [IO.Path]::GetExtension($jogo.bios) -eq '.bin' -and (Test-Path -LiteralPath $jogo.bios -PathType Leaf))) { $faltas.Add('bios') }
    if ($precisaDe -contains 'firmware' -and -not (Test-Firmware $jogo)) { $faltas.Add('firmware') }
    foreach ($requisito in $precisaDe) {
        if ($requisito -and $requisito -notin $RequisitosAceitos) { $faltas.Add([string]$requisito) }
    }

    $script:Romm = $null
    $modo = Get-ModoOrigem $jogo
    $campo = $modo.Campo
    if ($jogo.origem -eq 'rom' -and -not $modo) { $faltas.Add('formato') }
    elseif ($campo -and $script:Dados[$campo] -and ($jogo.plataforma -or $campo -eq 'dump')) {
        if ([IO.Path]::GetExtension($jogo.$campo) -ne $modo.Ext) { $faltas.Add('formato') }
        elseif (-not (Test-Path -LiteralPath $jogo.$campo -PathType Leaf)) { $faltas.Add('arquivo') }
    }
    elseif ($campo -and -not $script:Dados[$campo] -and -not (Test-Path -LiteralPath (Join-Path (Get-PastaOrigem $cfg $jogo) $jogo.romm.arquivo))) {
        $r = $null
        try { $r = Get-RomRomm $jogo } catch { }
        if (-not $r -or -not $r.Rom) { $faltas.Add('servidor') }
        elseif (-not $r.Rom.has_simple_single_file -or $r.Rom.missing_from_fs) { $faltas.Add('varios') }
        elseif ($r.Rom.fs_name -ne $jogo.romm.arquivo) { $faltas.Add('mudou') }
        else {
            $script:Romm = $r
            $local = Find-RomLocal $r.Con $r.Rom
            if (-not ($local -and (Test-PodeLinkar $local (Get-PastaOrigem $cfg $jogo)))) { $precisa += [long]$r.Rom.fs_size_bytes }
        }
    }

    # (o tamanho do zip e so uma parte; sem o GitHub agora, o download dele diz o erro depois)
    if ($jogo.fixa) {
        # (versao fixa: os tamanhos estao no catalogo, sem perguntar a ninguem)
        foreach ($a in @($jogo.fixa.arquivos | Where-Object { $_ })) {
            if (-not ($a.nome -and (Test-Path -LiteralPath (Join-Path (Get-PastaFixa $jogo $cfg.downloads) $a.nome)))) { $precisa += [long]$a.tamanho }
        }
    } else {
        try {
            $a = Find-Asset $jogo
            if (-not (Test-Path -LiteralPath (Join-Path $cfg.downloads $a.Asset.name))) { $precisa += [long]$a.Asset.size }
        } catch { }
    }
    if ($jogo.nup -and -not (Test-Nup $jogo.nup)) { $faltas.Add('nup') }
    if ($jogo.espacoGb) { $precisa += [long]([double]$jogo.espacoGb * 1GB) }

    $drive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($jogo.pasta)).TrimEnd('\')
    $livre = [long]::MaxValue
    try { $livre = (New-Object IO.DriveInfo ($drive + '\')).AvailableFreeSpace } catch { }
    if ($precisa -gt $livre) { $faltas.Add('espaco') }
    [pscustomobject]@{ Faltas = @($faltas); Precisa = $precisa; Livre = $livre; Drive = $drive }
}

# O jogo original em <Recomps>\_origem\<id>: hardlink/copia da ROM do emulador, ou download do RomM.
function Get-Origem($cfg, $jogo) {
    $modo = Get-ModoOrigem $jogo
    $campo = $modo.Campo
    if (-not $campo -or $script:Dados[$campo]) { return }
    Assert-ArquivoRomm $jogo
    $destino = Join-Path (Get-PastaOrigem $cfg $jogo) $jogo.romm.arquivo
    # (R8: o _origem nunca dentro da pasta de ROMs do emulador, que o Eden e o RomM varrem)
    foreach ($m in $script:Mapas) { if (Test-Dentro $destino $m) { throw "a pasta dos Recomps esta dentro da pasta de jogos do emulador ($m)" } }
    if (-not (Test-Path -LiteralPath $destino)) {
        $r = $script:Romm
        if (-not $r) { $r = Get-RomRomm $jogo }
        $local = Find-RomLocal $r.Con $r.Rom
        if ($local) { [void](New-LinkOuCopia $local $destino) }
        else {
            $url = $r.Con.Api + "/roms/$($r.Rom.id)/content/" + [uri]::EscapeDataString($r.Rom.fs_name)
            Invoke-Baixar $url $r.Con.Auth $destino ([long]$r.Rom.fs_size_bytes) $r.Rom.sha1_hash $r.Rom.fs_name
        }
    }
    Set-Campo $jogo $campo $destino
    Sync-CampoDump $jogo $modo
}

try {
    . (Join-Path $PSScriptRoot 'instalacao.ps1')
    $cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $jogo = $cfg.jogos | Where-Object id -eq $Id
    if (-not $jogo) { throw "Recomp '$Id' nao esta no recomps.json" }
    Set-Seguranca $cfg $Base
    $salvos = Join-Path $cfg.salvos $jogo.id
    $pronto = Join-Path $jogo.pasta $jogo.pronto

    if ($Acao -eq 'desinstalar') {
        if (Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($jogo.pasta + '\', 'OrdinalIgnoreCase') }) { throw "$($jogo.nome) esta aberto; feche o jogo antes" }
        Etapa 'Guardando saves e configuracoes'
        Copy-Itens $jogo.pasta $salvos $jogo.manter
        Etapa "Apagando $($jogo.pasta)"
        Remove-Seguro $jogo.pasta
        if ($jogo.disco) { Etapa 'Apagando a copia do disco'; Remove-Seguro $jogo.disco }
        "OK: Recomp de $($jogo.nome) desinstalado. Saves guardados em $salvos"
        exit 0
    }

    # (antes de tudo que le o nome: um caractere invalido faria o GetExtension lancar uma excecao sem explicacao)
    # (vazio continua sendo FALTA: formato, como antes)
    if ($jogo.origem -eq 'rom' -and $jogo.romm.arquivo) { Assert-ArquivoRomm $jogo }
    Test-ContratoPlugin $cfg $jogo
    Sync-CampoDump $jogo (Get-ModoOrigem $jogo)
    # Caminhos dados no recomps-local.json (o PC do dono) valem como estao; o resto vem do servidor.
    $script:Dados = @{}
    foreach ($k in 'iso', 'nsp', 'dump') { $script:Dados[$k] = [bool](@($jogo.$k | Where-Object { $_ }).Count) }
    Resolve-Requisitos $jogo $Base

    if ($Acao -eq 'verificar') {
        $v = Get-Verificacao $cfg $jogo
        foreach ($f in $v.Faltas) { "FALTA: $f" }
        "ESPACO: $($v.Precisa) $($v.Livre) $($v.Drive)"
        'OK: verificado'
        exit 0
    }

    if (Test-Path -LiteralPath $pronto) { "OK: o Recomp de $($jogo.nome) ja esta instalado"; exit 0 }
    # (catalogo errado no "comando" para antes de baixar qualquer coisa)
    if ($jogo.tipo -eq 'comando') {
        if (-not $jogo.preparo -or -not $jogo.preparo.exe) { throw 'catalogo sem o preparo deste Recomp; avise o Neto' }
        Test-NomePreparo $jogo.preparo.exe
    }
    # (Triforce: catalogo e nome do .nup conferidos antes de baixar qualquer coisa)
    if ($jogo.tipo -eq 'triforce') { Test-Fixa $jogo; Test-PastasTriforce $jogo; Test-NomeNup $jogo }
    # (R9: o que falta e conferido antes de baixar qualquer coisa)
    Etapa 'preparando: conferindo o que o Recomp precisa'
    $v = Get-Verificacao $cfg $jogo
    if ($v.Faltas.Count) { throw "falta: $($v.Faltas -join ', ')" }
    Get-Origem $cfg $jogo
    foreach ($k in 'iso', 'nsp', 'keys', 'dump') { if ($jogo.$k) { Test-Arquivo $jogo.$k $k } }
    $origemInicial = if ($jogo.tipo -in 'comando', 'pronto' -and $jogo.dump) {
        $item = Get-Item -LiteralPath $jogo.dump
        [pscustomobject]@{ Caminho = $item.FullName; Tamanho = $item.Length; Data = $item.LastWriteTimeUtc }
    }
    if ($jogo.nup -and -not (Test-Nup $jogo.nup)) { throw (Get-MotivoNup $jogo.nup) }

    $rel = if ($jogo.fixa) { Get-ReleaseFixa $jogo $cfg.downloads } else { Get-Release $jogo $cfg.downloads }
    if ($jogo.tipo -eq 'triforce') {
        # (o zip so traz as ferramentas: elas sao extraidas fora da pasta do jogo, no bloco 'triforce' abaixo)
    } elseif ($rel.Zip -like '*.exe') {
        # (o TotK publica so o Setup.exe, que baixa e monta o resto)
        New-Item -ItemType Directory -Force $jogo.pasta | Out-Null
        Copy-Item -LiteralPath $rel.Zip (Join-Path $jogo.pasta 'Setup.exe') -Force
    } else {
        Etapa "extraindo: $($rel.Versao)"
        Expand-Recomp $rel.Zip $jogo.pasta ([bool]$jogo.achatar) ([IO.Path]::Combine($cfg.recomps, '_tmp', $jogo.id))
    }
    # (Triforce: a pasta do jogo so existe depois da montagem; os saves voltam no fim do bloco dele)
    if ($jogo.tipo -ne 'triforce' -and (Test-Path -LiteralPath $salvos)) { Etapa 'preparando: devolvendo saves e configuracoes'; Copy-Itens $salvos $jogo.pasta $jogo.manter }

    switch ($jogo.tipo) {
        'mpr' {
            Etapa 'preparando: o jogo (confere o dump e converte texturas, uns 10 minutos)'
            $cli = Join-Path $jogo.pasta 'mpr_setup_cli.exe'
            & $cli --input $jogo.nsp --out $jogo.pasta --keys $jogo.keys 2>&1 | Out-Null
            if ($LASTEXITCODE) { throw "mpr_setup_cli terminou com codigo $LASTEXITCODE (veja setup.log na pasta)" }
        }
        'smo' {
            $ErrorActionPreference = 'Continue'   # (stderr de programa nativo nao e erro do script)
            # Sem a tela do instalador do Recomp: o exefs + romfs vao direto para <data root>\extracted, o --build-romfs
            # gera o romfs.bin e o --prepare-shaders compila o jogo (odyssey_game.dll) e os shaders.
            $exe = Join-Path $jogo.pasta $jogo.exe
            $raiz = Split-Path $exe
            $py = Join-Path $raiz 'odysseygen\python.exe'
            $nstoolExe = Get-Nstool $cfg.downloads
            Etapa 'preparando: extraindo o jogo (uns 6 GB, ate 10 minutos)'
            $null | & $py -I -W ignore (Join-Path $PSScriptRoot 'extrair_switch.py') $nstoolExe $jogo.keys $jogo.nsp (Join-Path $raiz 'extracted') 2>&1 | Out-Null
            if ($LASTEXITCODE) { throw "a extracao do jogo falhou (codigo $LASTEXITCODE)" }
            # (instalando: os dois passos sao externos e nao podem ser cancelados no meio)
            Etapa 'instalando: montando os dados do jogo (uns 2 minutos)'
            $p = Start-Process $exe -ArgumentList '--data-root', "`"$raiz`"", '--build-romfs' -WorkingDirectory $raiz -WindowStyle Hidden -Wait -PassThru
            if ($p.ExitCode) { throw "o --build-romfs terminou com codigo $($p.ExitCode) (veja SuperOdysseyRecomp.log na pasta do Recomp)" }
            # (testado no 0.4.2: compila o odyssey_game.dll sem janela e sai com 0; os shaders que faltarem ficam para a 1a vez que joga)
            Etapa 'instalando: compilando o jogo (uns 15 a 30 minutos)'
            $p = Start-Process $exe -ArgumentList '--data-root', "`"$raiz`"", '--prepare-shaders' -WorkingDirectory $raiz -WindowStyle Hidden -Wait -PassThru
            if ($p.ExitCode) { throw "o --prepare-shaders terminou com codigo $($p.ExitCode) (veja SuperOdysseyRecomp.log na pasta do Recomp)" }
            if (-not (Test-Path -LiteralPath (Join-Path $raiz 'extracted\odyssey_game.dll'))) { throw 'o Recomp nao gerou o odyssey_game.dll (veja SuperOdysseyRecomp.log na pasta do Recomp)' }
        }
        'infamous2' {
            if (-not (Test-Path -LiteralPath (Join-Path $jogo.disco 'PS3_GAME'))) {
                # (etapa "instalando", e nao "extraindo": nao pode ser cancelada no meio, senao a ISO
                # ficaria montada e a copia pela metade pareceria pronta na proxima vez)
                Etapa 'instalando: extraindo o disco da ISO (14 GB, uns 3 minutos)'
                try { $m = Mount-DiskImage -ImagePath $jogo.iso -Access ReadOnly -PassThru }
                catch { throw "o Windows nao deixou montar a ISO do jogo ($($_.Exception.Message)); pode precisar de administrador" }
                try {
                    $letra = ($m | Get-Volume).DriveLetter
                    $codigo = Copy-Medindo "$($letra):\" $jogo.disco
                    if ($codigo -ge 8) { throw "falha ao extrair o disco (robocopy $codigo)" }
                } finally { Dismount-DiskImage -ImagePath $jogo.iso | Out-Null }
            }
            # (--prepare: o modo dos lancadores, sem janela nem pergunta; 71 = sem PS3_GAME, 79 = a compilacao falhou)
            Etapa 'instalando: compilando o jogo (30 a 80 minutos; o Windows pode pedir permissao para as ferramentas)'
            $p = Start-Process (Join-Path $jogo.pasta 'Setup.exe') -ArgumentList '--prepare', '--disc', "`"$($jogo.disco)`"" -WorkingDirectory $jogo.pasta -Wait -PassThru
            if ($p.ExitCode -eq 71) { throw "o Setup nao achou a pasta PS3_GAME em $($jogo.disco)" }
            if ($p.ExitCode) { throw "o Setup --prepare terminou com codigo $($p.ExitCode) (veja play\setup.log na pasta do Recomp)" }
        }
        'totk' {
            # Sem a tela: o jogo e o prod.keys vao como arquivos soltos (o Setup poe cada um na linha dele), --auto aperta
            # Install e --hidden nao mostra janela e sai com 0 (pronto), 1 (falhou) ou 2 (faltou jogo ou keys).
            # (compilando: o Setup baixa as ferramentas e compila, uns 30 a 60 minutos; nao pode ser cancelado no meio.
            # O andamento vem do setup.log da pasta: cada passo vira "etapa N de 5" no card)
            $passos = @('compilando: etapa 1 de 5: baixando as ferramentas (Python, Git e LLVM)',
                'compilando: etapa 2 de 5: extraindo e conferindo o jogo (uns 17 GB)',
                'compilando: etapa 3 de 5: gerando o codigo do jogo',
                'compilando: etapa 4 de 5: compilando o jogo (a etapa mais longa, uns 25 a 45 minutos)',
                'compilando: etapa 5 de 5: montando o jogo')
            $log = Join-Path $jogo.pasta 'setup.log'
            # (o setup.log de uma tentativa anterior fica: le so o que o Setup escrever desta vez)
            $pos = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }
            $estado = @{ Passo = 1; Build = $false }
            Etapa $passos[0]
            $p = Start-Process (Join-Path $jogo.pasta 'Setup.exe') -ArgumentList "`"--install-to=$($jogo.pasta)`"", '--accept-terms', '--auto', '--hidden', '--no-shortcut', "`"$($jogo.nsp)`"", "`"$($jogo.keys)`"" -WorkingDirectory $jogo.pasta -PassThru
            $null = $p.Handle   # (sem isso o ExitCode some depois que o processo sai)
            do {
                $acabou = $p.HasExited
                if (Test-Path -LiteralPath $log) {
                    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite, Delete')
                    try {
                        if ($fs.Length -lt $pos) { $pos = 0 }
                        $fs.Position = $pos
                        $buf = New-Object byte[] ([int][math]::Min($fs.Length - $pos, 64MB))
                        $n = $fs.Read($buf, 0, $buf.Length)
                    } finally { $fs.Dispose() }
                    # (so ate a ultima linha completa: o resto fica para a proxima leitura)
                    $fimLinha = if ($n -gt 0) { [Array]::LastIndexOf($buf, [byte]10, $n - 1, $n) } else { -1 }
                    if ($fimLinha -ge 0) {
                        $pos += $fimLinha + 1
                        foreach ($l in ([Text.Encoding]::UTF8.GetString($buf, 0, $fimLinha + 1) -split "`r?`n")) {
                            $pr = Read-PassoTotk $l $estado
                            if (-not $pr) { continue }
                            if ($pr.Passo -ne $estado.Passo) { $estado.Passo = $pr.Passo; Etapa $passos[$pr.Passo - 1] }
                            if ($pr.Total) { Progresso $pr.Feito $pr.Total }
                        }
                    }
                }
                if (-not $acabou) { Start-Sleep -Seconds 2 }
            } while (-not $acabou)
            if ($p.ExitCode -eq 2) { throw 'o Setup nao aceitou o jogo ou o prod.keys (precisa do NSP 1.0.0 e de um arquivo .keys)' }
            if ($p.ExitCode) { throw "o Setup terminou com codigo $($p.ExitCode) (veja setup.log na pasta do Recomp)" }
        }
        'triforce' {
            # Ocarina of Time (Switch 2): o make_game.py do Triforce monta o jogo direto do .nup do servidor, sem tela.
            # O .nup so e lido; tamanho e data sao conferidos antes e depois. --no-renodx e obrigatorio (sem ele o
            # Triforce baixa ~60 MB sem conferencia); nunca --fsr nem --fetch-ngx-sdk (tambem baixam coisas).
            # (de novo logo antes do make_game, que apaga subpastas do --out e do --work)
            Test-PastasTriforce $jogo
            $tools = Get-FerramentasFixa $cfg $jogo $rel
            # (pasta de trabalho e log junto das ferramentas: fora do C: e da pasta do .nup, no drive dos downloads, e a
            # pasta de trabalho fica para a proxima montagem; o Remove-Seguro nunca apaga dentro de _downloads)
            $work = Join-Path $rel.Pasta "work-$($jogo.id)"
            $log = Join-Path $rel.Pasta "make_game-$($jogo.id).log"
            [void][IO.Directory]::CreateDirectory($work)
            if (-not (Test-Path -LiteralPath $jogo.nup -PathType Leaf)) { throw (Get-MotivoNup $jogo.nup) }
            $nup = Get-Item -LiteralPath $jogo.nup
            $tamanho = $nup.Length; $data = $nup.LastWriteTimeUtc
            # (conferindo: o --check le o .nup e diz se e a versao que o Triforce aceita, antes de montar)
            Etapa 'conferindo: a versao do jogo'
            $chk = @{ Res = $null; Texto = '' }
            $codigo = Invoke-MakeGame $tools @('--check', '--nup', $jogo.nup, '--work', $work) {
                param($l)
                if ($l -match '^@@check\s+(ok|bad)\b\s*(.*)$') { $chk.Res = $Matches[1]; $chk.Texto = $Matches[2] }
            }
            Assert-NupIgual $jogo.nup $tamanho $data
            if ($chk.Res -ne 'ok') {
                $resposta = if ($chk.Res) { Format-TextoExterno $chk.Texto } else { "nenhuma (saiu com codigo $codigo)" }
                throw "o arquivo do jogo nao e a versao que o Triforce aceita. Precisa: $($jogo.fixa.versaoJogoTexto). Resposta do Triforce: $resposta. Nada foi montado e o arquivo do jogo nao foi alterado."
            }
            # (compilando: o make_game e externo e nao pode ser cancelado no meio; cada etapa dele vira "etapa N de 5")
            $passos = @('lendo os arquivos do jogo', 'traduzindo o jogo para codigo de PC', 'compilando o jogo (a etapa mais longa, uns 35 minutos)',
                'montando a pasta do jogo', 'preparando os shaders (de minutos a mais de 1 hora)')
            $nomes = @('lendo os arquivos do jogo', 'traduzindo o jogo para codigo de PC', 'compilando o jogo', 'montando a pasta do jogo', 'preparando os shaders')
            $estado = @{ Passo = 1; Erro = $null; Pronto = $false; SemShaders = $false }
            Etapa "compilando: etapa 1 de 5: $($passos[0])"
            $codigo = Invoke-MakeGame $tools @('--nup', $jogo.nup, '--out', $jogo.pasta, '--work', $work, '--no-renodx', '--log', $log) {
                param($l)
                $pr = Read-PassoTriforce $l $estado
                if (-not $pr) { return }
                if ($pr.Passo) { Etapa "compilando: etapa $($pr.Passo) de 5: $($passos[$pr.Passo - 1])" } else { Progresso $pr.Feito 1000 }
            }
            Assert-NupIgual $jogo.nup $tamanho $data
            if ($null -ne $estado.Erro) {
                throw "a montagem do jogo parou na etapa $($estado.Passo) de 5 ($($nomes[$estado.Passo - 1])). O Triforce disse: $(Format-TextoExterno $estado.Erro). Detalhes em $log"
            }
            if ($codigo -or -not $estado.Pronto) { throw "o Triforce terminou com codigo $codigo sem dizer o motivo. Detalhes em $log" }
            if (Test-Path -LiteralPath $salvos) { Etapa 'preparando: devolvendo saves e configuracoes'; Copy-Itens $salvos $jogo.pasta $jogo.manter }
            Set-MarcaPronto $jogo
            # (os shaders que nao foram preparados agora ficam para a 1a vez que o jogo abrir: aviso, nao erro)
            if ($estado.SemShaders) { [Console]::Out.WriteLine('AVISO: shaders') }
        }
        # Tipos genericos.
        'pronto' {
            # O zip ja traz o jogo: o Expand-Recomp acima basta.
            Assert-OrigemIgual $origemInicial $script:Dados.dump
            Set-MarcaPronto $jogo
        }
        'comando' {
            # O preparo do catalogo gera o jogo a partir da ROM: um exe de dentro da pasta do Recomp, com os campos
            # trocados. (instalando: o comando e externo e nao pode ser cancelado no meio)
            $preparo = $jogo.preparo
            if (-not $preparo -or -not $preparo.exe) { throw 'catalogo sem o preparo deste Recomp; avise o Neto' }
            $exe = Get-ExePreparo $jogo.pasta $preparo.exe
            $argumentos = @(foreach ($a in @($preparo.args | Where-Object { $null -ne $_ })) { Format-Argumento (Format-Campos ([string]$a) $jogo) })
            $texto = if ($preparo.etapa) { [string]$preparo.etapa } else { 'preparando o jogo' }
            if ($preparo.minutos) { $texto += " (uns $($preparo.minutos) minutos)" }
            Etapa "instalando: $texto"
            # (sem o andamento do comando: a pasta cresce ate perto do espacoGb, entao a porcentagem e estimada)
            $base = Get-Tamanho $jogo.pasta
            $total = if ($jogo.espacoGb) { [long]([double]$jogo.espacoGb * 1GB) } else { 0L }
            # (sem ShellExecute: so roda o exe, nunca uma associacao de arquivo; a saida dele nao pode cair no stdout que
            # o plugin le, senao uma linha "OK: ..." do comando passaria pela nossa)
            $psi = New-Object Diagnostics.ProcessStartInfo $exe, ($argumentos -join ' ')
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $jogo.pasta
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [Diagnostics.Process]::Start($psi)
            [void]$p.StandardOutput.ReadToEndAsync(); [void]$p.StandardError.ReadToEndAsync()
            Wait-Medindo $p $jogo.pasta $base $total -esperarFilhos
            Assert-OrigemIgual $origemInicial $script:Dados.dump
            if ($p.ExitCode) { throw "o preparo ($($preparo.exe)) terminou com codigo $($p.ExitCode); veja a pasta do Recomp" }
            Set-MarcaPronto $jogo
        }
        default { throw "tipo desconhecido no catalogo: $($jogo.tipo); avise o Neto" }
    }

    if (-not (Test-Path -LiteralPath $pronto)) { throw "a instalacao nao terminou ($($jogo.pronto) nao existe). Rode Instalar de novo para continuar" }
    "OK: Recomp de $($jogo.nome) ($($rel.Versao)) instalado"
} catch {
    "ERRO: $($_.Exception.Message)"
    exit 1
}
