#Requires -Version 5.1
# Jogos de PC: lista o catalogo do servidor, instala o jogo escolhido (o trabalho
# pesado fica no jogos-pc-worker.ps1) e abre os que ja estao instalados.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'instalacao.ps1')
. (Join-Path $Here 'atualizador.ps1')

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Jogos de PC" Width="720" Height="640" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="#15171E" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#ECEEF4"/></Style>
    <Style x:Key="Botao" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="10" Padding="26,10">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#8B6CFF" Offset="0"/><GradientStop Color="#4CC9F0" Offset="1"/></LinearGradientBrush></Border.Background>
            <ContentPresenter HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid>
            <Border x:Name="PART_Track" CornerRadius="4" Background="#262A35"/>
            <Border x:Name="PART_Indicator" CornerRadius="4" HorizontalAlignment="Left">
              <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#8B6CFF" Offset="0"/><GradientStop Color="#4CC9F0" Offset="1"/></LinearGradientBrush></Border.Background>
            </Border>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="28,22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel>
      <TextBlock Text="Jogos de PC" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock TextWrapping="Wrap" Foreground="#8C92A4" FontSize="13" Margin="0,6,0,14"
                 Text="Escolha um jogo e clique em Instalar. O programa baixa, instala e apaga o instalador sozinho. Se a internet cair, continua de onde parou."/>
    </StackPanel>
    <Grid Grid.Row="1" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Pasta" VerticalAlignment="Center" Foreground="#8C92A4" FontSize="12" TextTrimming="CharacterEllipsis"/>
      <Button x:Name="BtnPasta" Grid.Column="1" Content="Alterar pasta..." Padding="10,4" Margin="10,0,0,0"/>
    </Grid>
    <ListBox x:Name="Lista" Grid.Row="2" Background="#1D2029" BorderBrush="#2C3040" Foreground="#ECEEF4"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <StackPanel Margin="4,5">
            <TextBlock Text="{Binding Titulo}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="{Binding Detalhe}" FontSize="12" Foreground="#8C92A4"/>
          </StackPanel>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
    <StackPanel Grid.Row="3" Margin="0,16,0,0">
      <Grid>
        <TextBlock x:Name="Status" FontSize="13" Foreground="#8C92A4" TextWrapping="Wrap" Margin="0,0,70,0"/>
        <TextBlock x:Name="Porcento" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
      </Grid>
      <ProgressBar x:Name="Barra" Minimum="0" Maximum="100" Margin="0,8,0,16"/>
      <Button x:Name="Botao" Style="{StaticResource Botao}" Content="Instalar" HorizontalAlignment="Right" IsEnabled="False"/>
    </StackPanel>
  </Grid>
</Window>
'@
$W = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}; foreach ($n in 'Pasta', 'BtnPasta', 'Lista', 'Status', 'Porcento', 'Barra', 'Botao') { $ui[$n] = $W.FindName($n) }

$script:Proc = $null; $script:Atual = $null; $script:Itens = @()
$script:Base = if (Test-Path (Join-Path (Split-Path $Here -Parent) 'launcher.json')) { Split-Path $Here -Parent } else { Find-Instalacao }
$ArqPasta = Join-Path $script:Base 'jogos-pc-pasta.txt'
$script:Raiz = if (Test-Path $ArqPasta) { (Get-Content $ArqPasta -TotalCount 1).Trim() } else { Join-Path $script:Base 'JogosPC' }
$Trab = Join-Path $env:TEMP ('JogosPC_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $Trab -Force | Out-Null
$ProgFile = Join-Path $Trab 'progresso.json'

function Format-Tamanho($bytes) { if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } else { '{0:N0} MB' -f ($bytes / 1MB) } }
function Get-Instalados {
    $f = Join-Path $script:Base 'jogos-pc.json'
    if (Test-Path $f) { Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
}
function Update-Pasta {
    $livre = try { Format-Tamanho (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:Raiz))).AvailableFreeSpace } catch { '?' }
    $ui.Pasta.Text = "Instalar em: $($script:Raiz)  ·  livre: $livre"
}
function Update-Botao {
    if ($script:Proc) { return }
    $j = $ui.Lista.SelectedItem
    $ui.Botao.IsEnabled = [bool]$j
    $ui.Botao.Content = if ($j -and $j.Instalado) { 'Jogar' } else { 'Instalar' }
}
function Update-Lista {
    $inst = Get-Instalados
    $sel = if ($ui.Lista.SelectedItem) { $ui.Lista.SelectedItem.Jogo.id }
    $script:Itens = @($script:Catalogo.jogos | ForEach-Object {
        $i = $inst.($_.id)
        $parte = Join-Path $script:Raiz "_baixando\$($_.id)"
        $est = if ($i) { ' · Instalado' } elseif (Test-Path -LiteralPath $parte) { ' · Baixado pela metade: clique em Instalar para continuar' } else { '' }
        [pscustomobject]@{ Titulo = $_.nome; Detalhe = "$(Format-Tamanho $_.tamanho)$est"; Jogo = $_; Instalado = $i }
    })
    $ui.Lista.ItemsSource = $null; $ui.Lista.ItemsSource = $script:Itens
    if ($sel) { $ui.Lista.SelectedItem = $script:Itens | Where-Object { $_.Jogo.id -eq $sel } | Select-Object -First 1 }
    Update-Botao
}

$W.Add_ContentRendered({
    Update-Pasta
    $ui.Status.Text = 'Carregando a lista de jogos...'
    $W.Dispatcher.Invoke([Action] {}, 'Render')
    try {
        if (-not $script:Base) { throw 'Não encontrei a instalação dos Jogos Retro neste PC.' }
        $J = (Get-Content (Join-Path $script:Base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json).jogos
        if (-not $J) { throw 'Este PC ainda não tem acesso aos jogos de PC.' }
        $script:Url = Find-ServidorJogos $J
        if (-not $script:Url) { throw 'Não consegui falar com o servidor.' }
        $script:Auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($J.usuario):$($J.senha)"))
        $script:Catalogo = Invoke-RestMethod -Uri "$($script:Url)/instalador/catalogo.json" -Headers @{ Authorization = $script:Auth } -UseBasicParsing -TimeoutSec 30
        Update-Lista
        $ui.Status.Text = "$(@($script:Catalogo.jogos).Count) jogos. Escolha um."
    } catch {
        $ui.Status.Text = "Não consegui carregar os jogos: $($_.Exception.Message)  Confira a conexão."
    }
})
$ui.Lista.Add_SelectionChanged({ Update-Botao })
$ui.BtnPasta.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog; $d.Description = 'Onde instalar os jogos de PC?'
    if ($d.ShowDialog() -eq 'OK') {
        $script:Raiz = $d.SelectedPath
        Set-Content $ArqPasta $script:Raiz -Encoding UTF8
        Update-Pasta; Update-Lista
    }
})

$Timer = New-Object Windows.Threading.DispatcherTimer; $Timer.Interval = [TimeSpan]::FromMilliseconds(500)
$Timer.Add_Tick({
    $p = $null
    if (Test-Path $ProgFile) { try { $p = Get-Content $ProgFile -Raw | ConvertFrom-Json } catch { } }
    if ($p -and $p.total -gt 0) {
        $pct = [math]::Floor($p.baixado * 100 / $p.total); $ui.Barra.Value = $pct; $ui.Porcento.Text = "$pct%"
        $ui.Status.Text = switch ($p.estado) {
            'baixando'     { "Baixando $($script:Atual.Titulo): $(Format-Tamanho $p.baixado) de $(Format-Tamanho $p.total)" + $(if ($p.velocidade -gt 0) { " · $([math]::Round($p.velocidade / 1MB, 1)) MB/s" } else { '' }) }
            'fila'         { 'Na fila: outra pessoa está baixando. Seu download começa sozinho assim que liberar.' }
            'reconectando' { "A internet piscou. $($p.msg)" }
            'verificando'  { "Verificando os arquivos... $($p.msg)" }
            'instalando'   { "Instalando $($script:Atual.Titulo)... se o Windows perguntar, clique em Sim." }
            'ok'           { "$($script:Atual.Titulo) instalado!" }
            'erro'         { $p.msg }
            default        { $ui.Status.Text }
        }
    }
    if ($script:Proc -and $script:Proc.HasExited) {
        $script:Proc = $null; $Timer.Stop()
        $ui.Lista.IsEnabled = $true; $ui.BtnPasta.IsEnabled = $true
        if (-not $p -or $p.estado -notin 'ok', 'erro') { $ui.Status.Text = 'Pausado. O que já veio ficou guardado: clique em Instalar para continuar.' }
        Update-Lista
    }
})

function Stop-Trabalho {
    if ($script:Proc -and -not $script:Proc.HasExited) { & taskkill.exe /T /F /PID $script:Proc.Id | Out-Null }
}
$ui.Botao.Add_Click({
    if ($script:Proc) { Stop-Trabalho; return }  # botao virou "Pausar"
    $j = $ui.Lista.SelectedItem; if (-not $j) { return }
    if ($j.Instalado) {
        $exe = Join-Path $j.Instalado.pasta ($j.Instalado.executavel -replace '/', '\')
        Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent)
        return
    }
    $script:Atual = $j
    Remove-Item $ProgFile -Force -ErrorAction SilentlyContinue
    New-Item $script:Raiz -ItemType Directory -Force | Out-Null
    $arqJob = Join-Path $Trab 'job.json'
    [IO.File]::WriteAllText($arqJob, (@{ url = $script:Url; auth = $script:Auth; jogo = $j.Jogo; raiz = $script:Raiz; base = $script:Base; progresso = $ProgFile } | ConvertTo-Json -Depth 6 -Compress))
    $env:JOGOSPC_JOB_ARQ = $arqJob
    $script:Proc = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Here 'jogos-pc-worker.ps1')`"" -WindowStyle Hidden -PassThru
    $env:JOGOSPC_JOB_ARQ = $null
    $ui.Botao.Content = 'Pausar'; $ui.Lista.IsEnabled = $false; $ui.BtnPasta.IsEnabled = $false
    $ui.Status.Text = "Começando $($j.Titulo)..."; $Timer.Start()
})
$W.Add_Closing({
    param($s, $e)
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $r = [Windows.MessageBox]::Show('A instalação ainda está rodando. Fechar agora pausa o download (o que já veio fica guardado). Fechar?', 'Jogos de PC', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Trabalho
    }
})
try { [void]$W.ShowDialog() } finally { Remove-Item $Trab -Recurse -Force -ErrorAction SilentlyContinue }
