#Requires -Version 5.1
# Interface do Instalador de Jogos Retro. Coleta as opcoes, roda o setup.ps1
# escondido e mostra o progresso lendo a saida dele.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg = Get-Content (Join-Path $Here 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
. (Join-Path $Here 'catalogo.ps1')
. (Join-Path $Here 'convite.ps1')

$Passos = @('Conexão com a biblioteca', 'Baixando os programas', 'Instalando os emuladores', 'Instalando o Playnite', 'Configurando a biblioteca', 'Criando o atalho')

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Instalador de Jogos Retro" Width="860" Height="750"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <LinearGradientBrush x:Key="Destaque" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#8B6CFF" Offset="0"/>
      <GradientStop Color="#4CC9F0" Offset="1"/>
    </LinearGradientBrush>
    <SolidColorBrush x:Key="Texto" Color="#ECEEF4"/>
    <SolidColorBrush x:Key="TextoFraco" Color="#8C92A4"/>
    <SolidColorBrush x:Key="Cartao" Color="#1D2029"/>
    <SolidColorBrush x:Key="Borda" Color="#2C3040"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Texto}"/>
    </Style>

    <Style x:Key="Primario" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="10" Background="{StaticResource Destaque}" Padding="30,11">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Secundario" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Texto}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="10" Background="#262A35" BorderBrush="#363B4A" BorderThickness="1" Padding="20,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2F3441"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Janela" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource TextoFraco}"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2E3A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CartaoConsole" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="b" CornerRadius="12" Background="{StaticResource Cartao}" BorderBrush="{StaticResource Borda}" BorderThickness="1.5" Padding="14,12">
              <Grid>
                <ContentPresenter VerticalAlignment="Center"/>
                <Border x:Name="marca" Width="22" Height="22" CornerRadius="11" Background="{StaticResource Destaque}"
                        HorizontalAlignment="Right" VerticalAlignment="Top" Visibility="Hidden">
                  <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="White"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#232733"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#8B6CFF"/>
                <Setter TargetName="b" Property="Background" Value="#221E38"/>
                <Setter TargetName="marca" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chave" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Texto}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="trilho" Width="42" Height="24" CornerRadius="12" Background="#2C3040">
                <Ellipse x:Name="bola" Width="18" Height="18" Fill="#C9CDD8" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
              <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="trilho" Property="Background" Value="{StaticResource Destaque}"/>
                <Setter TargetName="bola" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="bola" Property="Fill" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Campo" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Texto}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Texto}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="8" Background="{StaticResource Cartao}" BorderBrush="{StaticResource Borda}" BorderThickness="1" Padding="10,8">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="PasswordBox">
      <Setter Property="Foreground" Value="{StaticResource Texto}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Texto}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border CornerRadius="8" Background="{StaticResource Cartao}" BorderBrush="{StaticResource Borda}" BorderThickness="1" Padding="10,8">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="4" Background="#262A35"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" Background="{StaticResource Destaque}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="16" Background="#15171E" BorderBrush="#2A2E3A" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Cabecalho (arrasta a janela) -->
      <Grid x:Name="Cabecalho" Background="Transparent" Margin="28,22,16,0">
        <StackPanel Orientation="Horizontal">
          <Border Width="44" Height="44" CornerRadius="12" Background="{StaticResource Destaque}">
            <TextBlock Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="White"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Jogos Retro" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock x:Name="Subtitulo" FontSize="13" Foreground="{StaticResource TextoFraco}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
          <Button x:Name="BtnMinimizar" Style="{StaticResource Janela}" Content="&#xE921;"/>
          <Button x:Name="BtnFechar" Style="{StaticResource Janela}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <!-- Tela 0: codigo de convite (login e acesso ao servidor) -->
      <Grid x:Name="TelaRede" Grid.Row="1" Margin="36,20,36,28">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="Seu código de convite" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock x:Name="RedeTexto" FontSize="14" Foreground="{StaticResource TextoFraco}" Margin="0,6,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Margin="0,24,0,0">
          <TextBox x:Name="Convite" Style="{StaticResource Campo}" TextWrapping="Wrap" Height="76" VerticalContentAlignment="Top"/>
          <TextBlock x:Name="ConviteDica" FontSize="12" Foreground="{StaticResource TextoFraco}" Margin="2,8,0,0" TextWrapping="Wrap"
                     Text="Copie o código inteiro da mensagem (começa com JR1-) e cole aqui. Cada código vale para uma pessoa."/>
        </StackPanel>
        <Button x:Name="BtnRedeContinuar" Grid.Row="3" Style="{StaticResource Primario}" Content="Continuar" HorizontalAlignment="Right"/>
      </Grid>

      <!-- Tela 1: escolha -->
      <Grid x:Name="TelaEscolha" Grid.Row="1" Margin="36,20,36,28" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock x:Name="Ola" FontSize="24" FontWeight="SemiBold"/>
          <TextBlock Text="Escolha os consoles que você quer jogar. Dá para mudar depois rodando o instalador de novo."
                     FontSize="14" Foreground="{StaticResource TextoFraco}" Margin="0,6,0,0"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" Margin="0,20,0,0" MaxHeight="290" VerticalScrollBarVisibility="Auto">
          <WrapPanel x:Name="Cartoes"/>
        </ScrollViewer>
        <StackPanel Grid.Row="2" Margin="0,10,0,0">
          <TextBlock Text="Pasta de instalação" FontSize="13" Foreground="{StaticResource TextoFraco}" Margin="0,0,0,6"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="Pasta" Style="{StaticResource Campo}"/>
            <Button x:Name="BtnPasta" Grid.Column="1" Style="{StaticResource Secundario}" Content="Alterar..." Margin="10,0,0,0"/>
          </Grid>
          <TextBlock x:Name="Espaco" FontSize="12" Foreground="{StaticResource TextoFraco}" Margin="2,6,0,0"/>
        </StackPanel>
        <StackPanel Grid.Row="3" Margin="0,16,0,0">
          <CheckBox x:Name="OptTema" Style="{StaticResource Chave}" IsChecked="True" Content="Visual estilo console com música por jogo (baixa ~230 MB a mais)"/>
          <CheckBox x:Name="OptTelaCheia" Style="{StaticResource Chave}" IsChecked="False" Margin="0,12,0,0" Content="Abrir direto no modo console (ideal para jogar com controle)"/>
        </StackPanel>
        <Grid Grid.Row="5">
          <Button x:Name="BtnAvancado" Style="{StaticResource Secundario}" Content="Opções avançadas" HorizontalAlignment="Left"/>
          <Button x:Name="BtnInstalar" Style="{StaticResource Primario}" Content="Instalar" HorizontalAlignment="Right"/>
        </Grid>
      </Grid>

      <!-- Tela 2: progresso -->
      <Grid x:Name="TelaProgresso" Grid.Row="1" Margin="36,20,36,28" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="Instalando..." FontSize="24" FontWeight="SemiBold"/>
          <TextBlock Text="Pode levar de 10 a 20 minutos, depende da internet. Pode deixar rodando."
                     FontSize="14" Foreground="{StaticResource TextoFraco}" Margin="0,6,0,0"/>
        </StackPanel>
        <Border Grid.Row="1" CornerRadius="12" Background="{StaticResource Cartao}" Padding="22,18" Margin="0,20,0,0">
          <StackPanel x:Name="ListaPassos"/>
        </Border>
        <StackPanel Grid.Row="2" Margin="0,20,0,0">
          <Grid>
            <TextBlock x:Name="Acao" FontSize="13" Foreground="{StaticResource TextoFraco}" TextTrimming="CharacterEllipsis" Margin="0,0,60,0"/>
            <TextBlock x:Name="Porcento" FontSize="13" FontWeight="SemiBold" HorizontalAlignment="Right"/>
          </Grid>
          <ProgressBar x:Name="Barra" Minimum="0" Maximum="100" Margin="0,8,0,0"/>
        </StackPanel>
        <Grid Grid.Row="3" Margin="0,14,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Button x:Name="BtnDetalhes" Style="{StaticResource Janela}" Width="Auto" FontFamily="Segoe UI" FontSize="12"
                  Content="Mostrar detalhes" HorizontalAlignment="Left" Padding="0"/>
          <TextBox x:Name="Log" Grid.Row="1" Visibility="Collapsed" IsReadOnly="True" Margin="0,6,0,0"
                   FontFamily="Consolas" FontSize="12" Background="#101217" Foreground="#9AA0B2" BorderThickness="0"
                   Padding="10" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
        </Grid>
      </Grid>

      <!-- Tela 3: resultado (sucesso ou erro) -->
      <Grid x:Name="TelaFim" Grid.Row="1" Margin="36,10,36,28" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel VerticalAlignment="Center">
          <Border x:Name="FimIcone" Width="72" Height="72" CornerRadius="36" HorizontalAlignment="Center">
            <TextBlock x:Name="FimGlifo" FontFamily="Segoe MDL2 Assets" FontSize="30" Foreground="White"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="FimTitulo" FontSize="26" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,18,0,0"/>
          <TextBlock x:Name="FimTexto" FontSize="14" Foreground="{StaticResource TextoFraco}" HorizontalAlignment="Center"
                     TextAlignment="Center" TextWrapping="Wrap" MaxWidth="600" Margin="0,8,0,0"/>
          <StackPanel x:Name="FimCartoes" Margin="0,22,0,0" MaxWidth="640"/>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnFimSecundario" Style="{StaticResource Secundario}" Margin="0,0,10,0"/>
          <Button x:Name="BtnFimPrincipal" Style="{StaticResource Primario}"/>
        </StackPanel>
      </Grid>

      <!-- Opcoes avancadas (sobreposicao) -->
      <Grid x:Name="Avancado" Grid.RowSpan="2" Visibility="Collapsed">
        <Border CornerRadius="16" Background="#C0090A0E"/>
        <Border Width="600" CornerRadius="14" Background="#1A1D25" BorderBrush="{StaticResource Borda}" BorderThickness="1"
                Padding="26,22" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="Opções avançadas" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock Text="Tudo opcional. Só preencha se você tiver os arquivos." FontSize="13"
                       Foreground="{StaticResource TextoFraco}" Margin="0,4,0,16"/>
            <StackPanel x:Name="Arquivos"/>
            <TextBlock Text="RetroAchievements (conquistas nos jogos)" FontSize="13" Foreground="{StaticResource TextoFraco}" Margin="0,10,0,6"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="RaUsuario" Style="{StaticResource Campo}" ToolTip="Usuário"/>
              <PasswordBox x:Name="RaSenha" Grid.Column="2" ToolTip="Senha"/>
            </Grid>
            <Grid Margin="0,4,0,0">
              <TextBlock Text="usuário" FontSize="11" Foreground="{StaticResource TextoFraco}" Margin="2,0,0,0"/>
              <TextBlock Text="senha" FontSize="11" Foreground="{StaticResource TextoFraco}" HorizontalAlignment="Center" Margin="40,0,0,0"/>
            </Grid>
            <Button x:Name="BtnAvancadoOk" Style="{StaticResource Primario}" Content="Pronto" HorizontalAlignment="Right" Margin="0,18,0,0"/>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$W = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}
$Xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1; $ui[$n.Value] = $W.FindName($n.Value) }

function Brush($hex) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
function Txt($text, $size = 14, $color = '#ECEEF4', $weight = 'Normal') {
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.FontSize = $size; $t.Foreground = (Brush $color); $t.FontWeight = $weight; $t.TextWrapping = 'Wrap'; $t
}

$ui.Subtitulo.Text = "Biblioteca de jogos do $($Cfg.dono)"
$ui.Ola.Text = 'Olá! Vamos preparar tudo pra você jogar.'

# --- Janela -----------------------------------------------------------------
$ui.Cabecalho.Add_MouseLeftButtonDown({ $W.DragMove() })
$ui.BtnMinimizar.Add_Click({ $W.WindowState = 'Minimized' })
$ui.BtnFechar.Add_Click({ $W.Close() })
$W.Add_Closing({
    param($s, $e)
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $r = [Windows.MessageBox]::Show('A instalação ainda está rodando. Quer cancelar?', 'Jogos Retro', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        & taskkill.exe /T /F /PID $script:Proc.Id | Out-Null
    }
})

# --- Tela 0: conexao --------------------------------------------------------
function Test-Servidor($url) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { return ((Invoke-WebRequest -Uri ($url.TrimEnd('/') + '/api/heartbeat') -UseBasicParsing -TimeoutSec 6).StatusCode -eq 200) } catch { return $false }
}
$lanOk = try { $u = [Uri]$Cfg.servidor.lan; $c = New-Object Net.Sockets.TcpClient; $r = $c.ConnectAsync($u.Host, $u.Port).Wait(1200); $c.Close(); $r } catch { $false }
$ui.RedeTexto.Text = if ($lanOk) { "Encontrei o servidor na sua rede. Cole o código que o $($Cfg.dono) te mandou." }
                     elseif ($Cfg.servidor.netbird) { "Cole o código que o $($Cfg.dono) te mandou. O instalador já conecta este PC ao servidor (pelo NetBird) sozinho." }
                     else { "Cole o código que o $($Cfg.dono) te mandou. A conexão é pelo Tailscale: se ele ainda não estiver neste PC, o instalador instala e espera você entrar." }
# Zips antigos ja traziam o login; neles o codigo e opcional.
if ($Cfg.jogos.usuario) { $ui.ConviteDica.Text = 'Opcional nesta versão do instalador: pode deixar em branco.' }
$script:Convite = $null
$ui.BtnRedeContinuar.Add_Click({
    $texto = $ui.Convite.Text.Trim()
    $script:Convite = $null
    if ($texto) {
        $script:Convite = ConvertFrom-Convite $texto
        if (-not $script:Convite) { [Windows.MessageBox]::Show("Este código não está completo. Copie a mensagem inteira que o $($Cfg.dono) mandou (começa com JR1-) e cole de novo.", 'Jogos Retro') | Out-Null; return }
    } elseif (-not $Cfg.jogos.usuario) {
        [Windows.MessageBox]::Show("Cole o código de convite. Se você não tem um, peça ao $($Cfg.dono).", 'Jogos Retro') | Out-Null; return
    }
    if ($lanOk -and $script:Convite) {
        # Na rede local da para conferir o login antes de instalar qualquer coisa.
        $W.Cursor = 'Wait'; $login = Test-LoginJogos $Cfg.jogos.lan $script:Convite.u $script:Convite.s; $W.Cursor = $null
        if ($login -eq $false) { [Windows.MessageBox]::Show("Este código não confere. Peça um novo ao $($Cfg.dono).", 'Jogos Retro') | Out-Null; return }
    }
    if (-not $lanOk -and $script:Convite -and -not $script:Convite.k -and -not $Cfg.servidor.tailscale) {
        [Windows.MessageBox]::Show("Este código só funciona na casa do $($Cfg.dono). Peça a ele um convite com acesso de fora.", 'Jogos Retro') | Out-Null; return
    }
    $ui.TelaRede.Visibility = 'Collapsed'; $ui.TelaEscolha.Visibility = 'Visible'
})

# --- Tela 1: cartoes dos consoles -------------------------------------------
$Checks = [ordered]@{}
foreach ($k in $Consoles.Keys) {
    $c = $Consoles[$k]
    $tb = New-Object Windows.Controls.Primitives.ToggleButton
    $tb.Style = $W.FindResource('CartaoConsole'); $tb.Width = 182; $tb.Height = 84; $tb.Margin = '0,0,12,12'
    $sp = New-Object Windows.Controls.StackPanel
    $nome = Txt $c.Nome 15 '#ECEEF4' 'SemiBold'; $nome.Margin = '0,0,24,0'; [void]$sp.Children.Add($nome)
    if ($c.Aviso) { $av = Txt $c.Aviso 11 '#8C92A4'; $av.Margin = '0,3,0,0'; [void]$sp.Children.Add($av) }
    $tb.Content = $sp; $tb.IsChecked = -not $c.Desmarcado
    [void]$ui.Cartoes.Children.Add($tb); $Checks[$k] = $tb
}

function Update-Espaco {
    try {
        $root = [IO.Path]::GetPathRoot($ui.Pasta.Text)
        $gb = [math]::Round((New-Object IO.DriveInfo $root).AvailableFreeSpace / 1GB)
        $ui.Espaco.Text = "Espaço livre em ${root}: $gb GB  ·  os jogos baixados também ficam nesta pasta"
    } catch { $ui.Espaco.Text = '' }
}
$ui.Pasta.Text = "$env:SystemDrive\JogosRetro"; Update-Espaco
$ui.Pasta.Add_TextChanged({ Update-Espaco })
$ui.BtnPasta.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog; $d.Description = 'Onde instalar os Jogos Retro?'
    if ($d.ShowDialog() -eq 'OK') { $ui.Pasta.Text = Join-Path $d.SelectedPath 'JogosRetro' }
})

# --- Opcoes avancadas -------------------------------------------------------
$Arquivos = @{}
foreach ($item in @(@('Bios', 'BIOS do PS2', 'BIOS (*.bin)|*.bin'), @('Keys', 'prod.keys do Switch', 'prod.keys|*.keys'), @('Firm', 'Firmware do Switch (.zip)', 'Firmware (*.zip)|*.zip'))) {
    $g = New-Object Windows.Controls.Grid; $g.Margin = '0,0,0,10'
    foreach ($largura in @(170, '*', 'Auto')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = if ($largura -eq '*') { New-Object Windows.GridLength 1, 'Star' } elseif ($largura -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength $largura }
        $g.ColumnDefinitions.Add($cd)
    }
    $l = Txt $item[1] 14; $l.VerticalAlignment = 'Center'; [void]$g.Children.Add($l)
    $t = New-Object Windows.Controls.TextBox; $t.Style = $W.FindResource('Campo'); $t.IsReadOnly = $true; [Windows.Controls.Grid]::SetColumn($t, 1); [void]$g.Children.Add($t)
    $b = New-Object Windows.Controls.Button; $b.Style = $W.FindResource('Secundario'); $b.Content = 'Escolher...'; $b.Margin = '10,0,0,0'
    [Windows.Controls.Grid]::SetColumn($b, 2); $b.Tag = @($t, $item[2])
    $b.Add_Click({ $o = New-Object Microsoft.Win32.OpenFileDialog; $o.Filter = $this.Tag[1]; if ($o.ShowDialog()) { $this.Tag[0].Text = $o.FileName } })
    [void]$g.Children.Add($b); [void]$ui.Arquivos.Children.Add($g); $Arquivos[$item[0]] = $t
}
$ui.BtnAvancado.Add_Click({ $ui.Avancado.Visibility = 'Visible' })
$ui.BtnAvancadoOk.Add_Click({ $ui.Avancado.Visibility = 'Collapsed' })

# --- Tela 2: lista de passos ------------------------------------------------
$PassoUi = @()
for ($i = 0; $i -lt $Passos.Count; $i++) {
    $row = New-Object Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = $(if ($i -gt 0) { '0,12,0,0' } else { '0' })
    $circ = New-Object Windows.Controls.Border; $circ.Width = 26; $circ.Height = 26; $circ.CornerRadius = 13; $circ.Background = (Brush '#2C3040')
    $num = Txt "$($i + 1)" 12 '#8C92A4' 'SemiBold'; $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'; $circ.Child = $num
    $lab = Txt $Passos[$i] 15 '#8C92A4'; $lab.Margin = '14,0,0,0'; $lab.VerticalAlignment = 'Center'
    [void]$row.Children.Add($circ); [void]$row.Children.Add($lab); [void]$ui.ListaPassos.Children.Add($row)
    $PassoUi += @{ Circ = $circ; Num = $num; Lab = $lab }
}
function Set-Passo($n) {
    # n = passo atual (1..6); 7 = todos concluidos
    for ($i = 0; $i -lt $PassoUi.Count; $i++) {
        $p = $PassoUi[$i]
        if ($i + 1 -lt $n) {
            $p.Circ.Background = (Brush '#2BB673'); $p.Num.FontFamily = 'Segoe MDL2 Assets'; $p.Num.Text = [string][char]0xE73E; $p.Num.Foreground = (Brush '#FFFFFF')
            $p.Lab.Foreground = (Brush '#ECEEF4'); $p.Lab.FontWeight = 'Normal'
        } elseif ($i + 1 -eq $n) {
            $p.Circ.Background = $W.FindResource('Destaque'); $p.Num.Foreground = (Brush '#FFFFFF')
            $p.Lab.Foreground = (Brush '#ECEEF4'); $p.Lab.FontWeight = 'SemiBold'
        }
    }
}
$ui.BtnDetalhes.Add_Click({
    $vis = $ui.Log.Visibility -eq 'Visible'
    $ui.Log.Visibility = $(if ($vis) { 'Collapsed' } else { 'Visible' })
    $ui.BtnDetalhes.Content = $(if ($vis) { 'Mostrar detalhes' } else { 'Esconder detalhes' })
})

# --- Execucao do setup.ps1 --------------------------------------------------
$Trab = Join-Path $env:TEMP ('JogosRetro_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $Trab -Force | Out-Null
$LogFile = Join-Path $Trab 'saida.txt'; $ErrFile = Join-Path $Trab 'erros.txt'; $ResFile = Join-Path $Trab 'resultado.json'
$Oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$script:Pos = 0; $script:Resto = ''; $script:Passo = 0; $script:Acoes = 0; $script:Erro = $null

function Set-Progresso {
    $base = [math]::Max(0, $script:Passo - 1) / $Passos.Count
    $dentro = [math]::Min(0.9, $script:Acoes * 0.12) / $Passos.Count
    $v = [math]::Min(99, [math]::Round(($base + $dentro) * 100))
    if ($v -gt $ui.Barra.Value) { $ui.Barra.Value = $v; $ui.Porcento.Text = "$v%" }
}

function Read-Saida([switch]$Final) {
    if (-not (Test-Path $LogFile)) { return }
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
    try { [void]$fs.Seek($script:Pos, 'Begin'); $sr = New-Object IO.StreamReader($fs, $Oem); $txt = $sr.ReadToEnd(); $script:Pos = $fs.Position } finally { $fs.Close() }
    if ($Final) { $txt += "`n" }  # processa a ultima linha mesmo sem quebra no fim
    if (-not $txt) { return }
    $linhas = ($script:Resto + $txt) -split "`r?`n"
    $script:Resto = $linhas[-1]
    foreach ($l in $linhas[0..($linhas.Count - 2)]) {
        if ($l.Trim() -eq '' -or $l -match '^=+$') { continue }
        $ui.Log.AppendText("$l`n"); $ui.Log.ScrollToEnd()
        if ($l -match '^>> Passo (\d)/') { $script:Passo = [int]$Matches[1]; $script:Acoes = 0; Set-Passo $script:Passo; $ui.Acao.Text = $Passos[$script:Passo - 1] + '...' }
        elseif ($l -match '^ERRO: (.*)') { $script:Erro = $Matches[1] }
        elseif ($script:Erro) { $script:Erro += "`n" + $l.Trim() }
        elseif ($l -match '^\s{3}(.+)') { $script:Acoes++; $ui.Acao.Text = $Matches[1].Trim() }
        Set-Progresso
    }
}

function Show-Fim($ok, $res) {
    $ui.TelaProgresso.Visibility = 'Collapsed'; $ui.TelaFim.Visibility = 'Visible'; $ui.FimCartoes.Children.Clear()
    function Add-Cartao($titulo, $linhas, $cor) {
        $b = New-Object Windows.Controls.Border; $b.CornerRadius = 12; $b.Background = (Brush '#1D2029'); $b.Padding = '20,16'; $b.Margin = '0,0,0,12'
        $b.BorderBrush = (Brush $cor); $b.BorderThickness = '3,0,0,0'
        $sp = New-Object Windows.Controls.StackPanel
        [void]$sp.Children.Add((Txt $titulo 15 '#ECEEF4' 'SemiBold'))
        foreach ($l in $linhas) { $t = Txt $l 13 '#B4B9C7'; $t.Margin = '0,6,0,0'; [void]$sp.Children.Add($t) }
        $b.Child = $sp; [void]$ui.FimCartoes.Children.Add($b)
    }
    if ($ok) {
        $ui.FimIcone.Background = (Brush '#2BB673'); $ui.FimGlifo.Text = [string][char]0xE73E
        $ui.FimTitulo.Text = 'Tudo pronto!'
        $ui.FimTexto.Text = "Use o atalho 'Jogos Retro' na Área de Trabalho. Escolha um jogo, clique em Instalar (ele baixa) e depois em Jogar."
        if (-not $res.conectado) {
            if ($res.rede -eq 'tailscale') {
                Add-Cartao 'Falta um passo: entrar no Tailscale' @(
                    "Os jogos aparecem quando você se conectar ao servidor do $($Cfg.dono):",
                    '1.  Clique no ícone do Tailscale perto do relógio  >  Log in',
                    '2.  Entre com a sua conta do Tailscale',
                    "3.  Abra o atalho 'Jogos Retro'. A biblioteca se liga sozinha.") '#4CC9F0'
            } else {
                Add-Cartao 'Sem conexão com o servidor agora' @(
                    "Os jogos aparecem quando o servidor do $($Cfg.dono) responder.",
                    "Abra o atalho 'Jogos Retro' mais tarde. A biblioteca se liga sozinha.") '#4CC9F0'
            }
        }
        $falta = @($res.falta | Where-Object { $_ } | ForEach-Object { $_ -replace '^- ', '' })
        if ($falta) { Add-Cartao 'Arquivos que faltam para alguns consoles' $falta '#F4B740' }
        $ui.BtnFimSecundario.Content = 'Fechar'; $ui.BtnFimPrincipal.Content = 'Abrir Jogos Retro'
        $ui.BtnFimPrincipal.Tag = $res.launcher
    } else {
        $ui.FimIcone.Background = (Brush '#E5484D'); $ui.FimGlifo.Text = [string][char]0xE711
        $ui.FimTitulo.Text = 'Algo deu errado'
        $ui.FimTexto.Text = "Tire uma foto desta tela e mande para o $($Cfg.dono)."
        $ultimas = (@($ui.Log.Text -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 6) -join "`n"
        Add-Cartao 'O que aconteceu' @($(if ($script:Erro) { $script:Erro } else { "A instalação parou no meio. Últimas mensagens:`n$ultimas" })) '#E5484D'
        $ui.BtnFimSecundario.Content = 'Fechar'; $ui.BtnFimPrincipal.Content = 'Tentar de novo'; $ui.BtnFimPrincipal.Tag = $null
    }
}
$ui.BtnFimSecundario.Add_Click({ $W.Close() })
$ui.BtnFimPrincipal.Add_Click({
    if ($this.Tag) {
        Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($this.Tag)`""
        $W.Close()
    } else {
        $ui.TelaFim.Visibility = 'Collapsed'; $ui.TelaEscolha.Visibility = 'Visible'
    }
})

$Timer = New-Object Windows.Threading.DispatcherTimer; $Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$Timer.Add_Tick({
    Read-Saida
    if ($script:Proc.HasExited) {
        $Timer.Stop(); Read-Saida -Final
        $ok = ($script:Proc.ExitCode -eq 0) -and (Test-Path $ResFile)
        if (-not $ok -and -not $script:Erro -and (Test-Path $ErrFile)) { $e = (Get-Content $ErrFile -Raw); if ($e) { $script:Erro = $e.Trim() } }
        if ($ok) {
            Set-Passo 7; $ui.Barra.Value = 100; $ui.Porcento.Text = '100%'
            try { $res = Get-Content $ResFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $res = [pscustomobject]@{ conectado = $true; falta = @(); launcher = $null } }
            Show-Fim $true $res
        }
        else { Show-Fim $false $null }
    }
})

$ui.BtnInstalar.Add_Click({
    $sel = @($Checks.Keys | Where-Object { $Checks[$_].IsChecked })
    $base = $ui.Pasta.Text.Trim()
    if ($sel.Count -eq 0) { [Windows.MessageBox]::Show('Escolha pelo menos um console.', 'Jogos Retro') | Out-Null; return }
    if (-not $base -or -not [IO.Path]::IsPathRooted($base)) { [Windows.MessageBox]::Show('Escolha uma pasta de instalação válida.', 'Jogos Retro') | Out-Null; return }
    if ($base -like "$env:TEMP*" -or $base -match '\\Temp\\') { [Windows.MessageBox]::Show('Escolha uma pasta fora da pasta temporária do Windows (o emulador de PS3 não funciona lá).', 'Jogos Retro') | Out-Null; return }

    $env:JOGOSRETRO_OPCOES = [ordered]@{
        Base = $base; Convite = $script:Convite; Consoles = $sel; Tema = [bool]$ui.OptTema.IsChecked; Fullscreen = [bool]$ui.OptTelaCheia.IsChecked
        Bios = $Arquivos.Bios.Text; Keys = $Arquivos.Keys.Text; Firm = $Arquivos.Firm.Text
        RaUser = $ui.RaUsuario.Text.Trim(); RaPass = $ui.RaSenha.Password
    } | ConvertTo-Json -Compress
    $env:JOGOSRETRO_RESULTADO = $ResFile
    foreach ($f in $LogFile, $ErrFile, $ResFile) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    $script:Pos = 0; $script:Resto = ''; $script:Passo = 0; $script:Acoes = 0; $script:Erro = $null
    $ui.Log.Clear(); $ui.Barra.Value = 0; $ui.Porcento.Text = '0%'; $ui.Acao.Text = 'Começando...'

    $ui.TelaEscolha.Visibility = 'Collapsed'; $ui.TelaProgresso.Visibility = 'Visible'
    $script:Proc = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Here 'setup.ps1')`"" `
        -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError $ErrFile -PassThru
    [void]$script:Proc.Handle  # sem guardar o handle agora, o ExitCode volta vazio no fim
    $Timer.Start()
})

try { [void]$W.ShowDialog() }
finally { Remove-Item $Trab -Recurse -Force -ErrorAction SilentlyContinue }
