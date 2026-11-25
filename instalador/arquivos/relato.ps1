# Avisa o painel do dono como vai um download (jogo, %, velocidade, estado) pelo servidor de
# jogos: o nginx confere o login do amigo e repassa ao painel. Nunca atrasa nem derruba o
# download: o envio e em segundo plano e qualquer falha e ignorada.
# Usado pelo baixar-worker.ps1 (ROMs) e pelo jogos-pc-worker.ps1 (jogos de PC). Send-Erro avisa
# as falhas do launcher.ps1 e do ao-abrir.ps1 (aba Erros do painel).

$RelatoIntervaloSeg = 10
$RelatoUltimoEstado = $null
$RelatoUltimoEnvio = [datetime]::MinValue
$RelatoEnvios = New-Object System.Collections.ArrayList

function Get-DestinoRelato($base) {
    # Servidor(es) de jogos e login do amigo, do launcher.json da instalacao.
    try { $j = (Get-Content -LiteralPath (Join-Path $base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json).jogos } catch { return $null }
    if (-not $j -or -not $j.usuario) { return $null }
    $urls = @(@($j.lan, $j.netbird, $j.tailscale) | Where-Object { $_ })
    if (-not $urls.Count) { return $null }
    [pscustomobject]@{ urls = $urls; auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($j.usuario):$($j.senha)")) }
}

function Get-ConsoleRelato($destino) {
    # <instalacao>\Jogos\<console>\... -> console (vazio se o caminho for outro).
    if ([string]$destino -match '\\Jogos\\([^\\]+)\\') { return $Matches[1] }
    ''
}

function Send-Relato($destino, $dados) {
    # Manda quando o estado muda ou a cada $RelatoIntervaloSeg; devolve $true se mandou.
    if (-not $destino) { return $false }
    $agora = Get-Date
    if ($dados.estado -eq $script:RelatoUltimoEstado -and ($agora - $script:RelatoUltimoEnvio).TotalSeconds -lt $RelatoIntervaloSeg) { return $false }
    $script:RelatoUltimoEstado = $dados.estado; $script:RelatoUltimoEnvio = $agora
    Send-RelatoJson $destino ($dados | ConvertTo-Json -Compress)
    # No fim o processo termina logo depois: espera o aviso sair (no maximo 4 s).
    if ($dados.estado -in 'ok', 'erro') { Wait-Relato }
    $true
}

function Send-RelatoJson($destino, $json) {
    # Cada caminho (rede local, NetBird, Tailscale) recebe; o painel junta repetidos.
    foreach ($u in $destino.urls) {
        try {
            $wc = New-Object Net.WebClient
            $wc.Encoding = [Text.Encoding]::UTF8
            $wc.Headers['Authorization'] = $destino.auth
            $wc.Headers['Content-Type'] = 'application/json'
            [void]$script:RelatoEnvios.Add($wc.UploadStringTaskAsync([uri]($u.TrimEnd('/') + '/relato'), 'POST', $json))
        } catch { }
    }
}

function Wait-Relato {
    try { [void][Threading.Tasks.Task]::WaitAll($script:RelatoEnvios.ToArray(), 4000) } catch { }
}

function Send-Erro($base, $etapa, $erro) {
    # Avisa o painel que uma etapa do programa falhou no PC do amigo (atualizacao, multiplayer...),
    # com a versao instalada. Usado pelo launcher.ps1 e pelo ao-abrir.ps1. Nunca da erro.
    try {
        $destino = Get-DestinoRelato $base
        if (-not $destino) { return $false }
        $versao = 0
        try { $versao = [int](Get-Content -LiteralPath (Join-Path $base 'programa\versao.txt') -TotalCount 1) } catch { }
        $msg = if ($erro -is [Management.Automation.ErrorRecord]) { $erro.Exception.Message } else { [string]$erro }
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
        Send-RelatoJson $destino (@{ tipo = 'erro'; etapa = $etapa; msg = $msg; versao = $versao } | ConvertTo-Json -Compress)
        Wait-Relato
        $true
    } catch { $false }
}
