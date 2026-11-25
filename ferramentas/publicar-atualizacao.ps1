# Publica no servidor uma nova versao dos scripts do instalador, assinada.
# Uso: pwsh -File publicar-atualizacao.ps1            (todo mundo recebe)
#      pwsh -File publicar-atualizacao.ps1 -Teste     (so instalacoes com "canal": "teste" no launcher.json)
#      pwsh -File publicar-atualizacao.ps1 -Liberar   (solta para todos a versao que estava em teste)
#      pwsh -File publicar-atualizacao.ps1 -Voltar 25 (republica o conteudo da versao 25 como versao nova)

param([switch]$Teste, [switch]$Liberar, [int]$Voltar)

$ErrorActionPreference = 'Stop'
$Pasta = $PSScriptRoot
$Origem = Join-Path (Split-Path $Pasta -Parent) 'instalador\arquivos'
$Chave = Join-Path $Pasta 'atualizacao-privada.xml'
$Controle = Join-Path $Pasta 'versao-publicada.txt'
$Ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$Scp = "$env:WINDIR\System32\OpenSSH\scp.exe"
$Opcoes = @('-i', "$env:USERPROFILE\.ssh\id_servidor", '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes')
$Host_ = 'usuario@192.168.0.10'
$Remoto = '/DATA/AppData/jogos-pc/instalador'

if ($Liberar) {
    # O manifesto de teste ja esta assinado: so vira o de todo mundo, de uma vez.
    & $Ssh @Opcoes $Host_ "cp $Remoto/versao-teste.json $Remoto/versao.json.tmp && chmod 644 $Remoto/versao.json.tmp && mv $Remoto/versao.json.tmp $Remoto/versao.json"
    if ($LASTEXITCODE) { throw 'Falha ao liberar (nao ha versao em teste?).' }
    Write-Host 'Versao em teste liberada para todos.'
    return
}

$versao = 1 + $(if (Test-Path $Controle) { [int](Get-Content $Controle -TotalCount 1) } else { 0 })
$temp = Join-Path $env:TEMP "publicar-jogos-$PID"
$etapa = Join-Path $temp 'pacote'
New-Item $etapa -ItemType Directory -Force | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ($Voltar) {
        # Os clientes nunca descem de versao: o conteudo antigo sobe com um numero novo.
        $antigo = Join-Path $temp "programa-$Voltar.zip"
        & $Scp -q @Opcoes "${Host_}:$Remoto/programa-$Voltar.zip" $antigo
        if ($LASTEXITCODE) { throw "Falha ao baixar a versao $Voltar." }
        [IO.Compression.ZipFile]::ExtractToDirectory($antigo, $etapa)
    } else {
        Get-ChildItem -LiteralPath $Origem -File | Where-Object { $_.Name -ne 'config.json' } | Copy-Item -Destination $etapa
    }
    [IO.File]::WriteAllText((Join-Path $etapa 'versao.txt'), "$versao`n")
    # A mesma conferencia que o atualizador dos amigos faz antes de instalar.
    . (Join-Path $Origem 'atualizador.ps1')
    Test-PacoteAtualizacao $etapa

    $nome = "programa-$versao.zip"
    $zip = Join-Path $temp $nome
    [IO.Compression.ZipFile]::CreateFromDirectory($etapa, $zip)
    $sha = (Get-FileHash $zip -Algorithm SHA256).Hash

    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString((Get-Content -LiteralPath $Chave -Raw))
    $assinatura = [Convert]::ToBase64String($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$versao|$sha"), 'SHA256'))
    $rsa.Dispose()

    $manifesto = Join-Path $temp 'versao.json'
    $json = @{ versao = $versao; arquivo = $nome; sha256 = $sha; assinatura = $assinatura } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($manifesto, $json, (New-Object Text.UTF8Encoding $false))

    # O pacote sobe antes, e o manifesto entra por ultimo e de uma vez.
    $destino = if ($Teste) { 'versao-teste.json' } else { 'versao.json' }
    & $Scp -q @Opcoes $zip "${Host_}:$Remoto/$nome"
    if ($LASTEXITCODE) { throw 'Falha ao enviar o pacote.' }
    & $Scp -q @Opcoes $manifesto "${Host_}:$Remoto/$destino.tmp"
    if ($LASTEXITCODE) { throw 'Falha ao enviar o manifesto.' }
    & $Ssh @Opcoes $Host_ "chmod 644 $Remoto/$nome $Remoto/$destino.tmp && mv $Remoto/$destino.tmp $Remoto/$destino"
    if ($LASTEXITCODE) { throw 'Falha ao ativar a versao.' }

    [IO.File]::WriteAllText($Controle, "$versao`n")
    Write-Host ("Versao $versao publicada" + $(if ($Teste) { ' so para o canal de teste (libere com -Liberar).' } else { '.' }))
} finally {
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
