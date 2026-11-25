#Requires -Version 5.1
# Baixar Jogo: escolhe um jogo do RomM e baixa continuando de onde parou se a
# conexao cair. O arquivo vai para a pasta onde o Playnite procura, entao o jogo
# aparece como instalado na proxima vez que a biblioteca atualizar.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'instalacao.ps1')

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Baixar Jogo" Width="720" Height="640" ResizeMode="CanMinimize"
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
      <TextBlock Text="Baixar Jogo" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock TextWrapping="Wrap" Foreground="#8C92A4" FontSize="13" Margin="0,6,0,14"
                 Text="Para jogos grandes: se a internet cair no meio, o download continua de onde parou. Quando terminar, abra o Playnite e o jogo já aparece instalado."/>
    </StackPanel>
    <TextBox x:Name="Busca" Grid.Row="1" FontSize="14" Padding="10,8" Margin="0,0,0,10"
             Background="#1D2029" Foreground="#ECEEF4" BorderBrush="#2C3040" CaretBrush="#ECEEF4"/>
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
      <Button x:Name="Botao" Style="{StaticResource Botao}" Content="Baixar" HorizontalAlignment="Right" IsEnabled="False"/>
    </StackPanel>
  </Grid>
</Window>
'@
$W = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}; foreach ($n in 'Busca', 'Lista', 'Status', 'Porcento', 'Barra', 'Botao') { $ui[$n] = $W.FindName($n) }

function Format-Tamanho($bytes) { if ($bytes -ge 1GB) { '{0:N1} GB' -f ($bytes / 1GB) } else { '{0:N0} MB' -f ($bytes / 1MB) } }
function Get-Estado($j) {
    if (Test-Path -LiteralPath $j.Caminho) { return 'Já instalado' }
    if (Test-Path -LiteralPath "$($j.Caminho).parcial") { return 'Baixado pela metade: clique em Baixar para continuar' }
    ''
}
function Update-Lista {
    $q = $ui.Busca.Text.Trim()
    $itens = @($script:Jogos | Where-Object { -not $q -or $_.Titulo -like "*$q*" -or $_.Console -like "*$q*" } | ForEach-Object {
        $e = Get-Estado $_
        $_.Detalhe = "$($_.Console) · $(Format-Tamanho $_.Tamanho)" + $(if ($e) { " · $e" } else { '' }); $_ })
    $ui.Lista.ItemsSource = $null; $ui.Lista.ItemsSource = $itens
}

$script:Jogos = @(); $script:Proc = $null; $script:Atual = $null
$Trab = Join-Path $env:TEMP ('JogosRetroDownload_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $Trab -Force | Out-Null
$ProgFile = Join-Path $Trab 'progresso.json'

$W.Add_ContentRendered({
    $ui.Status.Text = 'Carregando a lista de jogos...'
    $W.Dispatcher.Invoke([Action] {}, 'Render')
    try {
        $base = Find-Instalacao
        if (-not $base) { throw 'Não encontrei a instalação dos Jogos Retro neste PC.' }
        $script:Base = $base
        # Acerta no Playnite downloads feitos antes (ex.: janela fechada antes de terminar o passo final).
        if (-not (Test-PlayniteAberto $base)) { try { [void](Sync-JogosInstalados $base) } catch { } }
        $script:Con = Get-RommConexao $base
        $h = @{ Authorization = $script:Con.Auth }
        $lista = @()
        foreach ($m in $script:Con.Mappings) {
            $offset = 0
            do {
                $r = Invoke-RestMethod -Uri "$($script:Con.Api)/roms?platform_ids=$($m.RomMPlatformId)&limit=200&offset=$offset" -Headers $h -UseBasicParsing -TimeoutSec 30
                foreach ($rom in @($r.items)) {
                    if (-not $rom.has_simple_single_file -or $rom.missing_from_fs) { continue }
                    $lista += [pscustomobject]@{ Titulo = $rom.name; Console = $m.RomMPlatform.name; Tamanho = [long]$rom.fs_size_bytes
                        Id = $rom.id; FsName = $rom.fs_name; Caminho = (Get-CaminhoJogo $m $rom.fs_name); Detalhe = '' }
                }
                $offset += 200
            } while ($offset -lt [int]$r.total)
        }
        $script:Jogos = @($lista | Sort-Object Titulo)
        Update-Lista
        $ui.Status.Text = "$($script:Jogos.Count) jogos. Escolha um e clique em Baixar."
    } catch {
        $ui.Status.Text = "Não consegui carregar os jogos: $($_.Exception.Message)  Fora da casa do servidor, confira se o NetBird está ligado."
    }
})
$ui.Busca.Add_TextChanged({ Update-Lista })
$ui.Lista.Add_SelectionChanged({ if (-not $script:Proc) { $ui.Botao.IsEnabled = [bool]$ui.Lista.SelectedItem -and -not (Test-Path -LiteralPath $ui.Lista.SelectedItem.Caminho) } })

$Timer = New-Object Windows.Threading.DispatcherTimer; $Timer.Interval = [TimeSpan]::FromMilliseconds(500)
$Timer.Add_Tick({
    if ($script:Concluir) {
        # Download pronto; falta marcar o jogo como instalado, o que exige o Playnite fechado.
        if (Test-PlayniteAberto $script:Base) {
            $ui.Status.Text = "$($script:Atual.Titulo) baixado! Falta um passo: feche o Playnite para o jogo aparecer como instalado. Esta janela termina sozinha quando ele fechar."
            return
        }
        try {
            [void](Sync-JogosInstalados $script:Base)
            $ui.Status.Text = "Pronto! Abra o Playnite pelo atalho Jogos Retro: $($script:Atual.Titulo) já aparece instalado."
        } catch { $ui.Status.Text = "Baixado, mas não consegui marcar no Playnite: $($_.Exception.Message)" }
        $script:Concluir = $false; $Timer.Stop(); Update-Lista
        return
    }
    $p = $null
    if (Test-Path $ProgFile) { try { $p = Get-Content $ProgFile -Raw | ConvertFrom-Json } catch { } }
    if ($p -and $p.total -gt 0) {
        $pct = [math]::Floor($p.baixado * 100 / $p.total); $ui.Barra.Value = $pct; $ui.Porcento.Text = "$pct%"
        $ui.Status.Text = switch ($p.estado) {
            'baixando'     { "Baixando $($script:Atual.Titulo): $(Format-Tamanho $p.baixado) de $(Format-Tamanho $p.total)" + $(if ($p.velocidade -gt 0) { " · $([math]::Round($p.velocidade / 1MB, 1)) MB/s" } else { '' }) }
            'reconectando' { "A internet piscou. $($p.msg)" }
            'ok'           { "$($script:Atual.Titulo) baixado! Terminando..." }
            'erro'         { $p.msg }
            default        { $ui.Status.Text }
        }
    }
    if ($script:Proc -and $script:Proc.HasExited) {
        $script:Proc = $null
        $ui.Botao.Content = 'Baixar'; $ui.Lista.IsEnabled = $true; $ui.Busca.IsEnabled = $true
        if ($p -and $p.estado -eq 'ok') { $script:Concluir = $true } else { $Timer.Stop() }
        if (-not $p -or $p.estado -notin 'ok', 'erro') { $ui.Status.Text = 'O download parou. O que já veio ficou guardado: clique em Baixar para continuar.' }
        Update-Lista
    }
})

function Stop-Download {
    if ($script:Proc -and -not $script:Proc.HasExited) { & taskkill.exe /T /F /PID $script:Proc.Id | Out-Null }
}
$ui.Botao.Add_Click({
    if ($script:Proc) {  # botao virou "Pausar"
        Stop-Download; return
    }
    $j = $ui.Lista.SelectedItem; if (-not $j) { return }
    $script:Atual = $j
    Remove-Item $ProgFile -Force -ErrorAction SilentlyContinue
    $env:JOGOSRETRO_DOWNLOAD = @{ url = "$($script:Con.Api)/roms/$($j.Id)/content/$([uri]::EscapeDataString($j.FsName))"; auth = $script:Con.Auth
        destino = $j.Caminho; total = $j.Tamanho; progresso = $ProgFile } | ConvertTo-Json -Compress
    $script:Proc = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Here 'baixar-worker.ps1')`"" -WindowStyle Hidden -PassThru
    $env:JOGOSRETRO_DOWNLOAD = $null
    $ui.Botao.Content = 'Pausar'; $ui.Lista.IsEnabled = $false; $ui.Busca.IsEnabled = $false
    $ui.Status.Text = "Começando $($j.Titulo)..."; $Timer.Start()
})
$W.Add_Closing({
    param($s, $e)
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $r = [Windows.MessageBox]::Show('O download ainda está rodando. Fechar agora pausa o download (o que já veio fica guardado e continua da próxima vez). Fechar?', 'Baixar Jogo', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Download
    }
})
try { [void]$W.ShowDialog() } finally { Remove-Item $Trab -Recurse -Force -ErrorAction SilentlyContinue }
