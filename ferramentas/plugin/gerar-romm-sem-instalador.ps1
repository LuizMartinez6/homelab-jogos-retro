# Gera uma copia do RomM.dll 0.9.0 cujo GetInstallActions nao oferece instalador,
# para o Playnite usar direto o "Baixar para o emulador" do plugin Jogos de PC.
# Uso: powershell -File gerar-romm-sem-instalador.ps1 <pasta com Mono.Cecil.dll>

param([Parameter(Mandatory = $true)][string]$PastaCecil, [string]$Playnite = 'C:\Playnite')
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PastaCecil 'Mono.Cecil.dll')

$ext = Join-Path $Playnite 'Extensions\RomM_9700aa21-447d-41b4-a989-acd38f407d9f'
$origem = Join-Path $ext 'RomM.dll'
$backup = Join-Path $PSScriptRoot 'RomM-original-0.9.0.dll'
if (-not (Test-Path $backup)) { Copy-Item $origem $backup }
$saida = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'instalador\arquivos\RomMSemInstalador.dll'

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($ext)
$resolver.AddSearchDirectory($Playnite)
$leitura = New-Object Mono.Cecil.ReaderParameters
$leitura.AssemblyResolver = $resolver
$modulo = [Mono.Cecil.ModuleDefinition]::ReadModule($backup, $leitura)

$tipo = $modulo.Types | Where-Object { $_.FullName -eq 'RomM.RomM' }
$metodo = $tipo.Methods | Where-Object { $_.Name -eq 'GetInstallActions' }
$elemento = $metodo.ReturnType.GenericArguments[0]
$corpo = $metodo.Body
$corpo.Instructions.Clear(); $corpo.Variables.Clear(); $corpo.ExceptionHandlers.Clear()
$il = $corpo.GetILProcessor()
$il.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)
$il.Emit([Mono.Cecil.Cil.OpCodes]::Newarr, $elemento)
$il.Emit([Mono.Cecil.Cil.OpCodes]::Ret)
$modulo.Write($saida)
$modulo.Dispose()

"original: $((Get-FileHash $backup -Algorithm SHA256).Hash)"
"alterado: $((Get-FileHash $saida -Algorithm SHA256).Hash)"
