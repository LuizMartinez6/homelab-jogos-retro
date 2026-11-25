# Correcoes por jogo: ajustes de emulador que o dono descobriu para um jogo funcionar (tela
# preta, travamento...) e que passam a valer para todos os amigos. A lista e o correcoes.json,
# que vem dentro do pacote assinado do programa. Cada correcao e aplicada uma vez so: se o amigo
# mudar de volta na mao, fica como ele deixou. Emulador aberto fica para a proxima abertura.
# Chamado pelo launcher.ps1 e pelo ao-abrir.ps1. Por enquanto so o Eden (Switch), por Title ID;
# ferramentas\correcao-eden.ps1 monta a entrada a partir do Eden do dono.

. (Join-Path $PSScriptRoot 'multiplayer.ps1')

function Invoke-Correcoes($Base, $Arquivo = (Join-Path $PSScriptRoot 'correcoes.json')) {
    # Devolve os ids aplicados agora.
    if (-not (Test-Path -LiteralPath $Arquivo)) { return @() }
    $lista = @([IO.File]::ReadAllText($Arquivo) | ConvertFrom-Json)
    $marca = Join-Path $Base 'correcoes-aplicadas.txt'
    $feitas = @(if (Test-Path -LiteralPath $marca) { [IO.File]::ReadAllLines($marca) })
    $agora = @()
    foreach ($c in $lista) {
        if (-not $c.id -or $c.id -in $feitas -or $c.emulador -ne 'Eden' -or $c.titleId -notmatch '^[0-9A-Fa-f]{16}$') { continue }
        $d = Join-Path $Base 'Emuladores\Eden'
        if (-not (Test-Path -LiteralPath $d) -or (Test-EmuladorAberto $d)) { continue }
        # config\custom\<TitleID>.ini: sem "use_global=false" o Eden usa a configuracao geral.
        $ini = Join-Path $d "user\config\custom\$($c.titleId.ToUpper()).ini"
        foreach ($s in $c.valores.PSObject.Properties) {
            foreach ($v in $s.Value.PSObject.Properties) {
                Set-QtPares $ini $s.Name @(@("$($v.Name)\use_global", 'false'), @("$($v.Name)\default", 'false'), @($v.Name, [string]$v.Value))
            }
        }
        $agora += $c.id
    }
    if ($agora.Count) { [IO.File]::AppendAllText($marca, (($agora -join "`r`n") + "`r`n")) }
    $agora
}
