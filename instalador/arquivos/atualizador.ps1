# Atualiza os scripts em <instalacao>\programa a partir do servidor de jogos.
# So aceita pacote assinado com a chave privada que fica so no PC do dono do servidor.

$AtualizacaoChavePublica = 'COLE_AQUI_A_CHAVE_PUBLICA'  # gerada por ferramentas\gerar-chaves.ps1

function Find-ServidorJogos($J) {
    # Rede local primeiro; fora de casa, NetBird e depois Tailscale.
    foreach ($t in @(@($J.lan, 2), @($J.netbird, 4), @($J.tailscale, 5))) {
        if (-not $t[0]) { continue }
        try {
            $r = Invoke-WebRequest -Uri ($t[0].TrimEnd('/') + '/saude') -UseBasicParsing -TimeoutSec $t[1]
            if ($r.StatusCode -eq 200) { return $t[0].TrimEnd('/') }
        } catch { }
    }
    $null
}

function Test-AssinaturaAtualizacao($versao, $sha256, $assinatura) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($AtualizacaoChavePublica)
        $dados = [Text.Encoding]::UTF8.GetBytes("$versao|$sha256")
        return $rsa.VerifyData($dados, 'SHA256', [Convert]::FromBase64String($assinatura))
    } catch { return $false } finally { $rsa.Dispose() }
}

function Test-PacoteAtualizacao($pasta) {
    # Um script que nao abre no Windows PowerShell 5.1 (erro de digitacao, sintaxe so do PS 7)
    # ou um JSON quebrado derrubaria o launcher de todo mundo: assim o pacote nem e instalado.
    foreach ($s in @(Get-ChildItem -LiteralPath $pasta -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })) {
        $erros = $null
        [void][Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$erros)
        if ($erros) { throw "Pacote com erro em $($s.Name): $($erros[0].Message)" }
    }
    foreach ($s in @(Get-ChildItem -LiteralPath $pasta -Recurse -File -Filter '*.json')) {
        try { [void]([IO.File]::ReadAllText($s.FullName) | ConvertFrom-Json) } catch { throw "Pacote com JSON invalido: $($s.Name)" }
    }
}

function Update-JogosRetro($Base) {
    # Devolve $true se trocou o programa. Qualquer falha mantem a versao atual.
    $L = Get-Content (Join-Path $Base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $J = $L.jogos
    if (-not $J) { return $false }
    $url = Find-ServidorJogos $J
    if (-not $url) { return $false }
    $auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($J.usuario):$($J.senha)")) }

    $m = Invoke-RestMethod -Uri "$url/instalador/versao.json" -Headers $auth -UseBasicParsing -TimeoutSec 10
    # Canal de teste ("canal": "teste" no launcher.json, so na instalacao do dono): pega antes de
    # todo mundo a versao que publicar-atualizacao.ps1 -Teste deixou em versao-teste.json.
    if ($L.canal -eq 'teste') {
        try {
            $t = Invoke-RestMethod -Uri "$url/instalador/versao-teste.json" -Headers $auth -UseBasicParsing -TimeoutSec 10
            if ([int]$t.versao -gt [int]$m.versao) { $m = $t }
        } catch { }
    }
    $versao = [int]$m.versao
    $dest = Join-Path $Base 'programa'
    $marca = Join-Path $dest 'versao.txt'
    $atual = if (Test-Path $marca) { [int](Get-Content $marca -TotalCount 1) } else { 0 }
    if ($versao -le $atual) { return $false }
    if ($m.arquivo -notmatch '^programa-\d+\.zip$') { throw 'Nome de pacote invalido.' }
    if (-not (Test-AssinaturaAtualizacao $versao $m.sha256 $m.assinatura)) { throw 'Assinatura invalida.' }

    $zip = Join-Path $Base 'programa.novo.zip'
    $novo = Join-Path $Base 'programa.novo'
    $velho = Join-Path $Base 'programa.antigo'
    foreach ($p in @($zip, $novo, $velho)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }
    try {
        Invoke-WebRequest -Uri "$url/instalador/$($m.arquivo)" -Headers $auth -OutFile $zip -UseBasicParsing -TimeoutSec 120
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $m.sha256) { throw 'Pacote corrompido.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $novo)
        if ([int](Get-Content (Join-Path $novo 'versao.txt') -TotalCount 1) -ne $versao) { throw 'Versao do pacote nao confere.' }
        Test-PacoteAtualizacao $novo
        if (Test-Path $dest) { Move-Item $dest $velho }
        try { Move-Item $novo $dest } catch {
            if (Test-Path $velho) { Move-Item $velho $dest }
            throw
        }
        Copy-Item (Join-Path $dest 'launcher.ps1') (Join-Path $Base 'launcher.ps1') -Force
        return $true
    } finally {
        foreach ($p in @($zip, $novo, $velho)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}
