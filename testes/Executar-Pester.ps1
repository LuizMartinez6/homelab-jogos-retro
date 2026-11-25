# Roda os testes Pester no Windows PowerShell 5.1 (o do PC dos amigos).
# Uso: powershell -File testes\Executar-Pester.ps1 [-Caminho testes\instalador\convite.Tests.ps1] [-Nome '*Convite*']
param([string[]]$Caminho = $PSScriptRoot, [string[]]$Nome, [string]$Saida)

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    # O Pester novo pode estar instalado so para o PowerShell 7.
    $pester = Get-ChildItem "$env:USERPROFILE\Documents\PowerShell\Modules\Pester\*\Pester.psd1" -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1
}
if (-not $pester) { throw 'Instale o Pester 5.5+: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck' }
Import-Module $(if ($pester.Path) { $pester.Path } else { $pester.FullName }) -Force

$cfg = New-PesterConfiguration
$cfg.Run.Path = @($Caminho -split ',' | Where-Object { $_ })  # -File nao separa listas sozinho
$cfg.Run.Exit = $true
$cfg.Output.Verbosity = 'Detailed'
if ($Nome) { $cfg.Filter.FullName = $Nome }
if ($Saida) { $cfg.TestResult.Enabled = $true; $cfg.TestResult.OutputPath = $Saida }
Invoke-Pester -Configuration $cfg
