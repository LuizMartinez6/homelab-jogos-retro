# Codigo de convite que o painel Amigos gera (servidor/amigos): "JR1-" + JSON em base64url
# com o login do servidor de jogos (u, s) e a chave de uso unico do NetBird (k).

function ConvertFrom-Convite([string]$Texto) {
    # Aceita a mensagem inteira colada: acha o JR1- e tolera quebras de linha no meio do codigo.
    $i = $Texto.IndexOf('JR1-')
    if ($i -lt 0) { return $null }
    $pedacos = @([regex]::Match($Texto.Substring($i + 4), '^[A-Za-z0-9_\-\s]*').Value -split '\s+' | Where-Object { $_ })
    for ($n = $pedacos.Count; $n -ge 1; $n--) {
        $b = (-join $pedacos[0..($n - 1)]).Replace('-', '+').Replace('_', '/')
        $b = $b.PadRight($b.Length + (4 - $b.Length % 4) % 4, '=')
        try { $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json } catch { continue }
        if ($c.u -and $c.s) { return [pscustomobject]@{ u = [string]$c.u; s = [string]$c.s; k = [string]$c.k } }
    }
    $null
}

function Test-LoginJogos($Url, $Usuario, $Senha) {
    # $true = login aceito, $false = recusado, $null = servidor nao respondeu.
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Usuario}:$Senha"))
    try {
        $r = Invoke-WebRequest -Uri ($Url.TrimEnd('/') + '/instalador/versao.json') -Headers @{ Authorization = $auth } -UseBasicParsing -TimeoutSec 8
        return ($r.StatusCode -eq 200)
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { return $false }
        return $null
    }
}
