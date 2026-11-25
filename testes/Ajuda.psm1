# Ajuda comum dos testes Pester (rodam no Windows PowerShell 5.1, igual ao PC dos amigos).

$Raiz = Split-Path $PSScriptRoot -Parent
$Arquivos = Join-Path $Raiz 'instalador\arquivos'

function Get-Funcao {
    # Devolve um scriptblock com as funcoes pedidas de um script que nao pode ser
    # carregado inteiro (abre janela, instala coisas). Uso: . (Get-Funcao arquivo.ps1 Nome1, Nome2)
    param([string]$Arquivo, [string[]]$Nome)
    $ast = [Management.Automation.Language.Parser]::ParseFile($Arquivo, [ref]$null, [ref]$null)
    $achadas = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $Nome })
    $faltam = @($Nome | Where-Object { $_ -notin $achadas.Name })
    if ($faltam) { throw "Funcao nao encontrada em ${Arquivo}: $($faltam -join ', ')" }
    [scriptblock]::Create(($achadas | ForEach-Object { $_.Extent.Text }) -join "`n")
}

function Get-Atribuicao {
    # Valor de uma atribuicao literal no topo de um script (ex.: $Downloads = @{...}).
    param([string]$Arquivo, [string]$Variavel)
    $ast = [Management.Automation.Language.Parser]::ParseFile($Arquivo, [ref]$null, [ref]$null)
    $a = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq "`$$Variavel" } | Select-Object -First 1
    if (-not $a) { throw "Atribuicao de `$$Variavel nao encontrada em $Arquivo" }
    & ([scriptblock]::Create($a.Right.Extent.Text))
}

function Start-ServidorTeste {
    # Sobe testes\ajuda\servidor_http.py; devolve Url, Log e o processo.
    param([string]$Pasta, [string]$Usuario, [string]$Senha, [int]$CairApos, [switch]$IgnorarRange, [int]$Status)
    $log = Join-Path ([IO.Path]::GetTempPath()) "servidor-teste-$([guid]::NewGuid()).log"
    $argumentos = @("`"$(Join-Path $PSScriptRoot 'ajuda\servidor_http.py')`"", '--raiz', "`"$Pasta`"", '--log', "`"$log`"")
    if ($Usuario) { $argumentos += '--usuario', $Usuario, '--senha', $Senha }
    if ($CairApos) { $argumentos += '--cair-apos', $CairApos }
    if ($IgnorarRange) { $argumentos += '--ignorar-range' }
    if ($Status) { $argumentos += '--status', $Status }
    $psi = New-Object Diagnostics.ProcessStartInfo 'python', ($argumentos -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    # Conexao fechada pelo cliente no meio vira traceback no stderr do Python: so ruido.
    [void]$p.StandardError.ReadToEndAsync()
    $porta = $p.StandardOutput.ReadLine()
    if (-not $porta) { throw 'O servidor de teste nao subiu (python esta no PATH?).' }
    [pscustomobject]@{ Url = "http://127.0.0.1:$porta"; Log = $log; Processo = $p }
}

function Stop-ServidorTeste($Servidor) {
    if ($Servidor -and -not $Servidor.Processo.HasExited) { $Servidor.Processo.Kill(); $Servidor.Processo.WaitForExit() }
    if ($Servidor) { Remove-Item $Servidor.Log -Force -ErrorAction SilentlyContinue }
}

function Get-PedidoTeste($Servidor) {
    if (Test-Path $Servidor.Log) { @(Get-Content $Servidor.Log) } else { @() }
}

function Get-PortaFechada {
    # Porta que acabou de ser liberada: conectar nela falha na hora.
    $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
    $l.Start(); $porta = $l.LocalEndpoint.Port; $l.Stop()
    $porta
}

function Invoke-Worker {
    # Roda um worker num processo separado do Windows PowerShell 5.1, como o plugin faz.
    param([string]$Script, [hashtable]$Ambiente, [int]$TimeoutSeg = 120)
    $psi = New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
    foreach ($k in $Ambiente.Keys) { $psi.EnvironmentVariables[$k] = $Ambiente[$k] }
    $p = [Diagnostics.Process]::Start($psi)
    $erro = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeg * 1000)) { $p.Kill(); throw "Worker passou de $TimeoutSeg s" }
    [pscustomobject]@{ Codigo = $p.ExitCode; Erro = $erro.Result }
}

function Find-Playnite {
    # Playnite real (para o SDK e as definicoes de emuladores). $env:PLAYNITE_DIR tem preferencia.
    foreach ($d in @($env:PLAYNITE_DIR, 'C:\Playnite', 'D:\Playnite', 'E:\Playnite', "$env:LOCALAPPDATA\Playnite")) {
        # [IO.Path]::Combine e nao Join-Path: no 5.1 o Join-Path da erro se a unidade (E:) nao existe.
        if ($d -and (Test-Path -LiteralPath ([IO.Path]::Combine($d, 'Playnite.SDK.dll')))) { return $d }
    }
    $null
}

function New-ChaveRsa {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 2048
    try { [pscustomobject]@{ Privada = $rsa.ToXmlString($true); Publica = $rsa.ToXmlString($false) } } finally { $rsa.Dispose() }
}

function Get-AssinaturaTeste($Privada, $Texto) {
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.FromXmlString($Privada); [Convert]::ToBase64String($rsa.SignData([Text.Encoding]::UTF8.GetBytes($Texto), 'SHA256')) } finally { $rsa.Dispose() }
}

function New-ExeFalso {
    # Compila um .exe que so registra como foi chamado (no arquivo de $env:EXE_FALSO_LOG) e,
    # imitando o scp, copia os arquivos locais citados para $env:EXE_FALSO_COPIA.
    # Serve de Playnite, scp e ssh sem tocar no Playnite real nem no servidor.
    # -Console para imitar scp/ssh: o PowerShell so espera programa de console terminar.
    param([string]$Caminho, [switch]$Console)
    $fonte = @'
using System; using System.IO; using System.Collections.Generic;
static class Falso {
    static int Main(string[] a) {
        string log = Environment.GetEnvironmentVariable("EXE_FALSO_LOG");
        if (!string.IsNullOrEmpty(log)) File.AppendAllText(log, Path.GetFileName(Environment.GetCommandLineArgs()[0]) + "|" + string.Join("|", a) + Environment.NewLine);
        string copia = Environment.GetEnvironmentVariable("EXE_FALSO_COPIA");
        if (string.IsNullOrEmpty(copia) || a.Length < 2) return 0;
        var origens = new List<string>();
        for (int i = 0; i < a.Length - 1; i++) {
            if (a[i] == "-i" || a[i] == "-o") { i++; continue; }
            if (File.Exists(a[i])) origens.Add(a[i]);
        }
        string destino = a[a.Length - 1];
        Directory.CreateDirectory(copia);
        foreach (string o in origens) {
            string nome = (destino.EndsWith("/") || origens.Count > 1) ? Path.GetFileName(o) : destino.Substring(destino.LastIndexOf('/') + 1);
            File.Copy(o, Path.Combine(copia, nome), true);
        }
        // Download (scp usuario@host:/caminho/arquivo destino-local): sai de $env:EXE_FALSO_COPIA.
        for (int i = 0; i < a.Length - 1 && origens.Count == 0; i++) {
            if (a[i] == "-i" || a[i] == "-o") { i++; continue; }
            if (a[i].Contains("@") && a[i].Contains(":/")) {
                string arq = Path.Combine(copia, a[i].Substring(a[i].LastIndexOf('/') + 1));
                if (!File.Exists(arq)) return 1;
                File.Copy(arq, destino, true);
                break;
            }
        }
        return 0;
    }
}
'@
    New-Item (Split-Path $Caminho -Parent) -ItemType Directory -Force | Out-Null
    $cs = "$Caminho.cs"; [IO.File]::WriteAllText($cs, $fonte)
    $saida = & "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo "/target:$(if ($Console) { 'exe' } else { 'winexe' })" "/out:$Caminho" $cs 2>&1
    if ($LASTEXITCODE) { throw "Falha ao compilar o exe falso: $saida" }
    Remove-Item $cs
}

function Copy-ScriptTrocado {
    # Copia um script trocando trechos (ex.: o caminho do scp pelo exe falso). Falha se
    # algum trecho sumiu do original, para o teste nao passar testando outra coisa.
    param([string]$Origem, [string]$Destino, [hashtable]$Trocas)
    $texto = [IO.File]::ReadAllText($Origem)
    foreach ($k in $Trocas.Keys) {
        if (-not $texto.Contains($k)) { throw "Trecho nao encontrado em ${Origem}: $k" }
        $texto = $texto.Replace($k, $Trocas[$k])
    }
    New-Item (Split-Path $Destino -Parent) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($Destino, $texto)
}

function Write-Utf8 ($Caminho, $Texto) {
    New-Item (Split-Path $Caminho -Parent) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($Caminho, $Texto, (New-Object Text.UTF8Encoding $false))
}

Export-ModuleMember -Function * -Variable Raiz, Arquivos
