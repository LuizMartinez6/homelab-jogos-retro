// Instalador de Jogos Retro em um arquivo so: leva o pacote do instalador (pacote.zip)
// dentro do .exe, extrai em %LOCALAPPDATA%\JogosRetro\instalador e abre a interface.
// Compilado por gerar-zips.ps1 (csc do .NET Framework, C# 5).

using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Instalador de Jogos Retro")]
[assembly: AssemblyProduct("Jogos Retro")]
[assembly: AssemblyCompany("Neto")]
[assembly: AssemblyDescription("Instala os emuladores e a biblioteca de jogos do Neto")]
[assembly: AssemblyCopyright("Neto")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Instalador
{
    [STAThread]
    static int Main()
    {
        try
        {
            var destino = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"JogosRetro\instalador");
            // Sempre limpo: um .exe mais novo nao herda arquivos de um antigo.
            if (Directory.Exists(destino)) { Directory.Delete(destino, true); }
            Directory.CreateDirectory(destino);
            using (var recurso = Assembly.GetExecutingAssembly().GetManifestResourceStream("pacote.zip"))
            using (var zip = new ZipArchive(recurso, ZipArchiveMode.Read))
            {
                zip.ExtractToDirectory(destino);
            }

            var ui = Path.Combine(destino, @"arquivos\instalador-ui.ps1");
            var ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var info = new ProcessStartInfo(ps, "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ui + "\"");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = destino;
            Process.Start(info);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("Não consegui abrir o instalador.\n\n" + e.Message + "\n\nTire uma foto desta tela e mande para o Neto.", "Jogos Retro", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
