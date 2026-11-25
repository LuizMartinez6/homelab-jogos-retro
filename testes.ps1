# Roda o lint e todos os testes. Uso: pwsh -File testes.ps1 [-SoLint] [-SemLint]
# Precisa de: Pester 5.5+ e PSScriptAnalyzer (Install-Module -Scope CurrentUser),
# Python com ruff e pytest (pip install ruff pytest). Docker e Playnite sao opcionais:
# sem eles, os testes que dependem deles sao pulados.
param([switch]$SoLint, [switch]$SemLint)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$falhou = New-Object Collections.Generic.List[string]

function Invoke-Etapa([string]$Nome, [scriptblock]$Bloco) {
    Write-Host "`n=== $Nome ===" -ForegroundColor Cyan
    & $Bloco
    if ($LASTEXITCODE) { $falhou.Add($Nome) }
}

if (-not $SemLint) {
    Invoke-Etapa 'Lint PowerShell (PSScriptAnalyzer)' {
        # Nos testes: variavel do BeforeAll e usada nos It (o analisador nao enxerga) e o SHA-1 e o do RomM.
        $soNoCodigo = 'PSUseDeclaredVarsMoreThanAssignments', 'PSAvoidUsingBrokenHashAlgorithms'
        $r = @(Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1 |
            Where-Object { -not ($_.ScriptPath -like (Join-Path $PSScriptRoot 'testes\*') -and $_.RuleName -in $soNoCodigo) })
        $r | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-Host
        $global:LASTEXITCODE = [int]($r.Count -gt 0)
    }
    Invoke-Etapa 'Lint Python (ruff)' { python -m ruff check . }
}

if (-not $SoLint) {
    Invoke-Etapa 'Testes do servidor (pytest)' { python -m pytest -rs }
    # Os testes do instalador rodam no Windows PowerShell 5.1, o mesmo do PC dos amigos.
    Invoke-Etapa 'Testes do instalador e das ferramentas (Pester no PowerShell 5.1)' {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\testes\Executar-Pester.ps1
    }
}

Write-Host ''
if ($falhou.Count) { Write-Host "FALHOU: $($falhou -join '; ')" -ForegroundColor Red; exit 1 }
Write-Host 'Tudo certo.' -ForegroundColor Green
