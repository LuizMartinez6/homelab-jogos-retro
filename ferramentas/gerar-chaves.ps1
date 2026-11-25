# Cria o par de chaves RSA que assina as atualizacoes automaticas do instalador.
#   atualizacao-privada.xml -> fica SO no seu PC (esta no .gitignore; nunca envie)
#   a chave publica          -> cole em instalador\arquivos\atualizador.ps1 ($AtualizacaoChavePublica)
# Uso: pwsh -File gerar-chaves.ps1

$ErrorActionPreference = 'Stop'
$Privada = Join-Path $PSScriptRoot 'atualizacao-privada.xml'
if (Test-Path $Privada) { throw "Ja existe $Privada. Apague antes se quiser trocar de chave (instalacoes antigas deixam de aceitar atualizacoes)." }

$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
try {
    [IO.File]::WriteAllText($Privada, $rsa.ToXmlString($true))
    Write-Host "Chave privada salva em $Privada"
    Write-Host ''
    Write-Host 'Chave publica (cole em atualizador.ps1):'
    Write-Host $rsa.ToXmlString($false)
} finally { $rsa.Dispose() }
