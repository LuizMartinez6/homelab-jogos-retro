#Requires -Version 5.1
# Baixa um jogo de PC continuando de onde parou, confere cada arquivo, instala sem
# perguntas e so apaga o instalador depois que deu certo. Recebe em JOGOSPC_JOB_ARQ o
# caminho de um JSON (url, auth, jogo, raiz, base, progresso), porque a lista de arquivos
# nao cabe numa variavel de ambiente, e escreve o andamento no arquivo "progresso".

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$J = Get-Content -LiteralPath $env:JOGOSPC_JOB_ARQ -Raw -Encoding UTF8 | ConvertFrom-Json
$Jogo = $J.jogo
$TravaSeg = 60          # sem receber nada por 1 minuto = conexao travada, reconecta
$MaxFalhasSeguidas = 40 # sem avancar nada em 40 tentativas, desiste
$Total = [long]$Jogo.tamanho
$Trab = Join-Path $J.raiz "_baixando\$($Jogo.id)"
$NomePasta = ($Jogo.nome -replace '[\\/:*?"<>|]', '').Trim()
$Destino = Join-Path $J.raiz $NomePasta

# Avisa o painel do dono (relato.ps1) pelo mesmo servidor e login deste download.
$Relato = $null
try { . (Join-Path $PSScriptRoot 'relato.ps1'); $Relato = [pscustomobject]@{ urls = @($J.url); auth = $J.auth } } catch { }

function Set-Progresso($estado, $baixado, $velocidade = 0, $msg = '') {
    $tmp = "$($J.progresso).tmp"
    [IO.File]::WriteAllText($tmp, (@{ estado = $estado; baixado = $baixado; total = $Total; velocidade = $velocidade; msg = $msg } | ConvertTo-Json -Compress))
    Move-Item $tmp $J.progresso -Force
    if ($Relato) {
        try {
            [void](Send-Relato $Relato @{ tipo = 'pc'; jogo = [string]$Jogo.nome; console = ''
                estado = $estado; baixado = [long]$baixado; total = [long]$Total; velocidade = [long]$velocidade; msg = $msg })
        } catch { }
    }
}
function Stop-Trabalho($msg) { Set-Progresso 'erro' 0 0 $msg; exit 1 }

function Get-Url($rel) {
    $partes = @($Jogo.pasta -split '/') + @($rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }
    "$($J.url)/jogos/$($partes -join '/')"
}

function Get-StatusHttp($erro) {
    $e = $erro.Exception
    while ($e) { if ($e.Response) { return [int]$e.Response.StatusCode }; $e = $e.InnerException }
    0
}

function Save-Arquivo($arq, $jaFeito) {
    # Baixa um arquivo em <destino>.parcial; o nome final so aparece depois de conferido.
    $destino = Join-Path $Trab ($arq.caminho -replace '/', '\')
    if ((Test-Path -LiteralPath $destino) -and (Get-Item -LiteralPath $destino).Length -eq [long]$arq.tamanho) { return }
    New-Item (Split-Path $destino -Parent) -ItemType Directory -Force | Out-Null
    $parcial = "$destino.parcial"
    $falhas = 0
    for ($conferencia = 0; $conferencia -lt 2; $conferencia++) {
        while ($true) {
            $tem = if (Test-Path -LiteralPath $parcial) { (Get-Item -LiteralPath $parcial).Length } else { 0 }
            if ($tem -ge [long]$arq.tamanho) { break }
            $antes = $tem
            try {
                $req = [Net.HttpWebRequest]::Create((Get-Url $arq.caminho))
                $req.Headers['Authorization'] = $J.auth
                $req.Timeout = 30000; $req.ReadWriteTimeout = $TravaSeg * 1000
                if ($tem -gt 0) { $req.AddRange([long]$tem) }
                $resp = $req.GetResponse()
                try {
                    $modo = 'Append'
                    if ($tem -gt 0 -and [int]$resp.StatusCode -ne 206) { $modo = 'Create'; $tem = 0 }
                    $entrada = $resp.GetResponseStream()
                    $saida = New-Object IO.FileStream($parcial, $modo, 'Write', 'Read')
                    try {
                        $buf = New-Object byte[] (1MB); $marca = Get-Date; $desdeMarca = 0
                        Set-Progresso 'baixando' ($jaFeito + $tem)
                        while (($n = $entrada.Read($buf, 0, $buf.Length)) -gt 0) {
                            $saida.Write($buf, 0, $n); $tem += $n; $desdeMarca += $n
                            $seg = ((Get-Date) - $marca).TotalSeconds
                            if ($seg -ge 1) { Set-Progresso 'baixando' ($jaFeito + $tem) ([long]($desdeMarca / $seg)); $marca = Get-Date; $desdeMarca = 0; $falhas = 0 }
                        }
                    } finally { $saida.Close() }
                    if ($tem -lt [long]$arq.tamanho) { throw 'conexao encerrada antes do fim' }
                } finally { $resp.Close() }
            } catch {
                if ((Get-StatusHttp $_) -eq 503) {
                    # Outro amigo esta baixando; o servidor atende um por vez.
                    Set-Progresso 'fila' ($jaFeito + $antes) 0 'Outra pessoa esta baixando. Seu download comeca sozinho assim que liberar.'
                    Start-Sleep 20
                    continue
                }
                $tem = if (Test-Path -LiteralPath $parcial) { (Get-Item -LiteralPath $parcial).Length } else { 0 }
                if ($tem -gt $antes) { $falhas = 0 }
                $falhas++
                if ($falhas -gt $MaxFalhasSeguidas) { Stop-Trabalho 'A conexao com o servidor caiu e nao voltou. O que ja baixou ficou guardado: clique em Instalar para continuar.' }
                $espera = [math]::Min(5 * $falhas, 30)
                Set-Progresso 'reconectando' ($jaFeito + $tem) 0 "Conexao caiu, tentando de novo em $espera s (tentativa $falhas)"
                Start-Sleep $espera
            }
        }
        Set-Progresso 'verificando' ($jaFeito + [long]$arq.tamanho) 0 "Conferindo $([IO.Path]::GetFileName($arq.caminho))"
        if ((Get-FileHash -LiteralPath $parcial -Algorithm SHA256).Hash -eq $arq.sha256.ToUpperInvariant()) {
            Move-Item -LiteralPath $parcial -Destination $destino -Force
            return
        }
        Remove-Item -LiteralPath $parcial -Force
    }
    Stop-Trabalho "O arquivo $([IO.Path]::GetFileName($arq.caminho)) veio corrompido duas vezes. Tente de novo mais tarde."
}

function Get-ExecutavelGog($pasta) {
    # O proprio instalador da GOG deixa um .info dizendo qual programa abre o jogo.
    foreach ($f in @(Get-ChildItem -LiteralPath $pasta -Filter 'goggame-*.info' -File)) {
        $info = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $t = @($info.playTasks | Where-Object { $_.isPrimary -and $_.type -eq 'FileTask' }) | Select-Object -First 1
        if ($t) { return $t.path }
    }
    $null
}

# Espaco: o instalador e o jogo instalado ocupam o disco ao mesmo tempo.
New-Item $Trab -ItemType Directory -Force | Out-Null
# Enquanto este arquivo estiver aberto, o Playnite sabe que o download nao parou.
$TravaArq = "$Trab.lock"
$Trava = [IO.File]::Open($TravaArq, 'OpenOrCreate', 'ReadWrite', 'None')
$jaTem = (@(Get-ChildItem -LiteralPath $Trab -Recurse -File -Force) | Measure-Object Length -Sum).Sum
$fator = if ($Jogo.tipo -eq 'gog') { 2.2 } else { 1.05 }
$precisa = [long]($Total * $fator) - [long]$jaTem
$livre = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($J.raiz))).AvailableFreeSpace
if ($livre -lt $precisa) { Stop-Trabalho ("Espaco insuficiente: precisa de {0:N0} GB livres e so tem {1:N0} GB." -f ($precisa / 1GB), ($livre / 1GB)) }

$feito = 0L
foreach ($a in $Jogo.arquivos) { Save-Arquivo $a $feito; $feito += [long]$a.tamanho }

if ($Jogo.tipo -eq 'gog') {
    # Uma tentativa anterior pode ter perdido o acompanhamento com o instalador ainda rodando:
    # espera por ele e, se concluiu, so falta registrar o jogo.
    $instaladores = @($Jogo.instaladores)
    if ($instaladores.Count -eq 1) {
        $logAnterior = Join-Path $Trab 'instalacao.log'
        $nomeSetup = [IO.Path]::GetFileNameWithoutExtension($instaladores[0])
        $concluiuAntes = { (Test-Path -LiteralPath $logAnterior) -and (Select-String -LiteralPath $logAnterior -SimpleMatch 'Installation process succeeded' -Quiet) }
        while ((Get-Process | Where-Object { $_.ProcessName -eq $nomeSetup }) -and -not (& $concluiuAntes)) {
            Set-Progresso 'instalando' $Total 0 'Terminando a instalacao anterior'
            Start-Sleep 3
        }
        if ((& $concluiuAntes) -and (Test-Path -LiteralPath $Destino)) {
            $exeAnterior = Get-ExecutavelGog $Destino
            if ($exeAnterior -and (Test-Path -LiteralPath (Join-Path $Destino ($exeAnterior -replace '/', '\')))) { $instaladores = @() }
        }
    }
    foreach ($rel in $instaladores) {
        Set-Progresso 'instalando' $Total 0 "Instalando $([IO.Path]::GetFileName($rel))"
        $exe = Join-Path $Trab ($rel -replace '/', '\')
        $log = Join-Path $Trab 'instalacao.log'
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        try {
            $p = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$Destino`"", "/LOG=`"$log`"") -Verb RunAs -PassThru -Wait
        } catch { Stop-Trabalho 'A permissao de administrador foi negada. Clique em Instalar e aceite o aviso do Windows.' }
        # Alguns instaladores da GOG terminam tudo e travam ao fechar; o log diz se a instalacao concluiu.
        $concluiu = (Test-Path -LiteralPath $log) -and (Select-String -LiteralPath $log -SimpleMatch 'Installation process succeeded' -Quiet)
        if ($p.ExitCode -ne 0 -and -not $concluiu) { Stop-Trabalho "O instalador terminou com erro (codigo $($p.ExitCode)). O download ficou guardado: clique em Instalar para tentar de novo." }
    }
    $executavel = Get-ExecutavelGog $Destino
} else {
    Set-Progresso 'instalando' $Total 0 'Copiando o jogo'
    if (Test-Path -LiteralPath $Destino) { Stop-Trabalho "Ja existe a pasta $Destino. Remova-a e tente de novo." }
    Move-Item -LiteralPath $Trab -Destination $Destino
    $executavel = $Jogo.executavel
}

if (-not $executavel -or -not (Test-Path -LiteralPath (Join-Path $Destino ($executavel -replace '/', '\')))) {
    Stop-Trabalho 'A instalacao terminou, mas nao encontrei o programa do jogo. O instalador ficou guardado.'
}

# Registra e so entao libera o espaco do instalador.
$arqEstado = Join-Path $J.base 'jogos-pc.json'
$estado = @{}
if (Test-Path $arqEstado) { (Get-Content $arqEstado -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $estado[$_.Name] = $_.Value } }
$estado[$Jogo.id] = @{ nome = $Jogo.nome; pasta = $Destino; executavel = $executavel }
[IO.File]::WriteAllText($arqEstado, ($estado | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
if (Test-Path -LiteralPath $Trab) { Remove-Item -LiteralPath $Trab -Recurse -Force }
$Trava.Close(); Remove-Item -LiteralPath $TravaArq -Force
$pai = Join-Path $J.raiz '_baixando'
if ((Test-Path -LiteralPath $pai) -and -not @(Get-ChildItem -LiteralPath $pai -Force).Count) { Remove-Item -LiteralPath $pai -Force }
Set-Progresso 'ok' $Total
