#Requires -Version 5.1
# Conectar Conquistas: um login do RetroAchievements vale para todos os
# emuladores ja instalados (RetroArch, PPSSPP, PCSX2 e Dolphin).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'conquistas.ps1')
. (Join-Path $Here 'instalacao.ps1')

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Conectar Conquistas" Width="520" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#15171E" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#ECEEF4"/></Style>
    <Style x:Key="Campo" TargetType="Control">
      <Setter Property="Foreground" Value="#ECEEF4"/><Setter Property="Background" Value="#1D2029"/>
      <Setter Property="BorderBrush" Value="#2C3040"/><Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="14"/><Setter Property="Margin" Value="0,4,0,14"/>
    </Style>
    <Style x:Key="Botao" TargetType="Button">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="10" Padding="26,10">
            <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#E2B04A" Offset="0"/><GradientStop Color="#C8862F" Offset="1"/></LinearGradientBrush></Border.Background>
            <ContentPresenter HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <StackPanel Margin="28,24">
    <TextBlock Text="Conectar Conquistas" FontSize="22" FontWeight="SemiBold"/>
    <TextBlock TextWrapping="Wrap" Foreground="#8C92A4" FontSize="13" Margin="0,6,0,18"
               Text="Entre uma vez com sua conta do RetroAchievements e todos os emuladores passam a contar suas conquistas. Sua senha não fica guardada."/>
    <TextBlock Text="Usuário" FontSize="13" Foreground="#8C92A4"/>
    <TextBox x:Name="Usuario" Style="{StaticResource Campo}" CaretBrush="#ECEEF4"/>
    <TextBlock Text="Senha" FontSize="13" Foreground="#8C92A4"/>
    <PasswordBox x:Name="Senha" Style="{StaticResource Campo}" CaretBrush="#ECEEF4"/>
    <TextBlock x:Name="Pasta" FontSize="12" Foreground="#8C92A4" TextWrapping="Wrap" Margin="0,0,0,14"/>
    <Border x:Name="Caixa" CornerRadius="10" Padding="16,12" Margin="0,0,0,16" Visibility="Collapsed" BorderThickness="3,0,0,0">
      <TextBlock x:Name="Mensagem" TextWrapping="Wrap" FontSize="13"/>
    </Border>
    <Button x:Name="Conectar" Style="{StaticResource Botao}" Content="Conectar" HorizontalAlignment="Right"/>
  </StackPanel>
</Window>
'@
$W = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}; foreach ($n in 'Usuario', 'Senha', 'Pasta', 'Caixa', 'Mensagem', 'Conectar') { $ui[$n] = $W.FindName($n) }

function Show-Msg($texto, $ok) {
    $cor = if ($ok) { '#2BB673' } else { '#E5484D' }
    $ui.Caixa.Background = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#1D2029')))
    $ui.Caixa.BorderBrush = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($cor)))
    $ui.Mensagem.Text = $texto; $ui.Caixa.Visibility = 'Visible'
}

$Base = Find-Instalacao
if ($Base) { $ui.Pasta.Text = "Instalação encontrada em $Base" }
else { $ui.Pasta.Text = 'Não encontrei a instalação dos Jogos Retro neste PC.'; $ui.Conectar.IsEnabled = $false }

$script:Pronto = $false
$ui.Conectar.Add_Click({
    if ($script:Pronto) { $W.Close(); return }
    $usuario = $ui.Usuario.Text.Trim(); $senha = $ui.Senha.Password
    if (-not $usuario -or -not $senha) { Show-Msg 'Preencha usuário e senha.' $false; return }
    # Emulador aberto regrava a configuracao ao fechar e apagaria o login.
    $abertos = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'retroarch', 'PPSSPPWindows64', 'pcsx2-qt', 'Dolphin' } | ForEach-Object Name | Select-Object -Unique)
    if ($abertos) { Show-Msg "Feche primeiro: $($abertos -join ', '). Depois clique em Conectar de novo." $false; return }
    $ui.Conectar.IsEnabled = $false; $ui.Conectar.Content = 'Conectando...'
    $W.Dispatcher.Invoke([Action] {}, 'Render')
    try {
        $login = Get-RaToken $usuario $senha
        $feito = @(Set-RaLogin (Join-Path $Base 'Emuladores') $login.Usuario $login.Token)
        if ($feito.Count) { Show-Msg ("Pronto, conectado como $($login.Usuario) em:`n• " + ($feito -join "`n• ")) $true; $ui.Conectar.Content = 'Fechar' }
        else { Show-Msg 'Login feito, mas não encontrei nenhum emulador com conquistas instalado.' $false; $ui.Conectar.Content = 'Fechar' }
        $ui.Conectar.IsEnabled = $true; $script:Pronto = $true
    } catch {
        Show-Msg "Não deu certo: $($_.Exception.Message)" $false
        $ui.Conectar.IsEnabled = $true; $ui.Conectar.Content = 'Conectar'
    }
})
[void]$W.ShowDialog()
