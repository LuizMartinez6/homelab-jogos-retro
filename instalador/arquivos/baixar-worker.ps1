#Requires -Version 5.1
# Baixa um jogo do RomM continuando de onde parou: grava em <arquivo>.parcial e,
# se a conexao cair ou travar, reconecta pedindo so os bytes que faltam (Range).
# Recebe tudo pela variavel JOGOSRETRO_DOWNLOAD (JSON: url, auth, destino, total,
# progresso) e escreve o andamento em JSON no arquivo "progresso".
# SHA-1 porque e o hash que o RomM publica de cada ROM (integridade, nao seguranca).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '')]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$J = $env:JOGOSRETRO_DOWNLOAD | ConvertFrom-Json
$parcial = "$($J.destino).parcial"
$TravaSeg = 60          # sem receber nada por 1 minuto = conexao travada, reconecta
$MaxFalhasSeguidas = 40 # sem avancar nada em 40 tentativas (~15 min), desiste
# Avisa o painel do dono (relato.ps1). Sem launcher.json na instalacao, nao avisa.
$Relato = $null
try { . (Join-Path $PSScriptRoot 'relato.ps1'); $Relato = Get-DestinoRelato (Split-Path $PSScriptRoot -Parent) } catch { }

function Set-Progresso($estado, $baixado, $velocidade = 0, $msg = '') {
    $tmp = "$($J.progresso).tmp"
    [IO.File]::WriteAllText($tmp, (@{ estado = $estado; baixado = $baixado; total = [long]$J.total; velocidade = $velocidade; msg = $msg } | ConvertTo-Json -Compress))
    Move-Item $tmp $J.progresso -Force
    if ($Relato) {
        try {
            [void](Send-Relato $Relato @{ tipo = 'rom'; jogo = [IO.Path]::GetFileNameWithoutExtension($J.destino); console = (Get-ConsoleRelato $J.destino)
                estado = $estado; baixado = [long]$baixado; total = [long]$J.total; velocidade = [long]$velocidade; msg = $msg })
        } catch { }
    }
}

New-Item ([IO.Path]::GetDirectoryName($J.destino)) -ItemType Directory -Force | Out-Null
$falhas = 0
while ($true) {
    $tem = if (Test-Path -LiteralPath $parcial) { (Get-Item -LiteralPath $parcial).Length } else { 0 }
    # Maior que o jogo nao tem conserto: comeca de novo.
    if ($tem -gt [long]$J.total) { Remove-Item -LiteralPath $parcial -Force; $tem = 0 }
    if ($tem -eq [long]$J.total) { break }
    $antes = $tem
    try {
        $req = [Net.HttpWebRequest]::Create($J.url)
        $req.Headers['Authorization'] = $J.auth
        $req.Timeout = 30000; $req.ReadWriteTimeout = $TravaSeg * 1000
        if ($tem -gt 0) { $req.AddRange([long]$tem) }
        $resp = $req.GetResponse()
        try {
            $modo = 'Append'
            if ($tem -gt 0 -and [int]$resp.StatusCode -ne 206) { $modo = 'Create'; $tem = 0 }  # servidor ignorou a retomada
            if ($tem -gt 0 -and $resp.Headers['Content-Range'] -notmatch "^bytes $tem-") { throw 'retomada fora de posicao' }
            $entrada = $resp.GetResponseStream()
            $saida = New-Object IO.FileStream($parcial, $modo, 'Write', 'Read')
            try {
                $buf = New-Object byte[] (1MB); $marca = Get-Date; $desdeMarca = 0
                Set-Progresso 'baixando' $tem
                # Nunca grava alem do tamanho do jogo.
                while ($tem -lt [long]$J.total -and ($n = $entrada.Read($buf, 0, [math]::Min([long]$buf.Length, [long]$J.total - $tem))) -gt 0) {
                    $saida.Write($buf, 0, $n); $tem += $n; $desdeMarca += $n
                    $seg = ((Get-Date) - $marca).TotalSeconds
                    if ($seg -ge 1) { Set-Progresso 'baixando' $tem ([long]($desdeMarca / $seg)); $marca = Get-Date; $desdeMarca = 0; $falhas = 0 }
                }
            } finally { $saida.Close() }
            # Conexao fechada "educadamente" antes do fim tambem e queda: retoma pelo catch.
            if ($tem -lt [long]$J.total) { throw 'conexao encerrada antes do fim' }
        } finally { $resp.Close() }
    } catch {
        # Resposta de erro do servidor nao e queda de conexao: tentar de novo nao adianta.
        $status = 0; $ex = $_.Exception
        while ($ex) { if ($ex.Response) { $status = [int]$ex.Response.StatusCode; break }; $ex = $ex.InnerException }
        if ($status -in 401, 403, 404) { Set-Progresso 'erro' $antes 0 "O servidor recusou este jogo (erro $status). Avise o Neto."; exit 1 }
        $tem = if (Test-Path -LiteralPath $parcial) { (Get-Item -LiteralPath $parcial).Length } else { 0 }
        if ($tem -gt $antes) { $falhas = 0 }
        $falhas++
        if ($falhas -gt $MaxFalhasSeguidas) { Set-Progresso 'erro' $tem 0 "A conexao com o servidor caiu e nao voltou. O que ja baixou ficou guardado: abra o Baixar Jogo de novo para continuar."; exit 1 }
        $espera = [math]::Min(5 * $falhas, 30)
        Set-Progresso 'reconectando' $tem 0 "Conexao caiu, tentando de novo em $espera s (tentativa $falhas)"
        Start-Sleep $espera
    }
}
$tem = (Get-Item -LiteralPath $parcial).Length
if ($tem -ne [long]$J.total) { Set-Progresso 'erro' $tem 0 "O arquivo veio com tamanho diferente do esperado. Apague-o e baixe de novo."; exit 1 }
if ($J.sha1) {
    Set-Progresso 'verificando' $tem 0 'Conferindo o arquivo'
    if ((Get-FileHash -LiteralPath $parcial -Algorithm SHA1).Hash -ne $J.sha1.ToUpperInvariant()) {
        Remove-Item -LiteralPath $parcial -Force
        Set-Progresso 'erro' 0 0 'O arquivo veio corrompido e foi descartado. Clique em Instalar para baixar de novo.'
        exit 1
    }
}
Move-Item -LiteralPath $parcial -Destination $J.destino -Force
Set-Progresso 'ok' $tem
