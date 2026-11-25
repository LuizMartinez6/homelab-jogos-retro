// Plugin "Recomps" do Playnite: para os jogos listados em recomps.json, oferece o recomp nativo
// como mais uma ação de jogar (o Playnite pergunta entre ele e o emulador) e põe no menu do jogo
// Instalar / Desinstalar / Abrir pasta. O trabalho de instalar fica no recomp.ps1.
// O catálogo vem no pacote (<Base>\programa\recomps.json, a Base lida de instalacao.txt na pasta da
// extensão, como o Jogos de PC) e o PC pode ter um <Base>\recomps-local.json que muda campos por id
// (o do dono aponta com "usar" para o recomps.json dele, com gameId e caminhos absolutos).
// Compilado com o csc do .NET Framework (C# 5).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using Playnite.SDK;
using Playnite.SDK.Data;
using Playnite.SDK.Events;
using Playnite.SDK.Models;
using Playnite.SDK.Plugins;

namespace Recomps
{
    public class RommRecomp
    {
        public long? Id { get; set; }
        public string Arquivo { get; set; }
    }

    // O comando do tipo "comando" do recomp.ps1: um exe de dentro da pasta do Recomp, com os argumentos (campos {pasta},
    // {nsp}, {iso}, {keys}), o texto da etapa e quanto tempo leva, só para mostrar.
    public class PreparoRecomp
    {
        public string Exe { get; set; }
        public List<string> Args { get; set; }
        public string Etapa { get; set; }
        public int? Minutos { get; set; }
    }

    // Um arquivo da versão fixa: o recomp.ps1 baixa da Url e confere o tamanho e o SHA-256 daqui.
    public class ArquivoFixo
    {
        public string Nome { get; set; }
        public string Url { get; set; }
        public long? Tamanho { get; set; }
        public string Sha256 { get; set; }
    }

    // Versão FIXADA no catálogo (o Triforce não publica SHA-256): nunca a mais nova automaticamente. Titulo e VersaoJogo
    // são os do .nup que essa versão aceita; VersaoJogoTexto vai na mensagem de versão errada.
    public class ReleaseFixa
    {
        public string Versao { get; set; }
        public string Titulo { get; set; }
        public string VersaoJogo { get; set; }
        public string VersaoJogoTexto { get; set; }
        public List<ArquivoFixo> Arquivos { get; set; }
    }

    // Tudo anulável: ao juntar com o recomps-local.json, só o que ele traz troca o do catálogo.
    public class JogoRecomp
    {
        public string Id { get; set; }
        public string Nome { get; set; }
        public Guid? GameId { get; set; }
        public RommRecomp Romm { get; set; }
        public string Pasta { get; set; }
        public string Exe { get; set; }
        public string Args { get; set; }
        public string Pronto { get; set; }
        public List<string> Manter { get; set; }
        public string Repo { get; set; }
        public string Asset { get; set; }
        public bool? Achatar { get; set; }
        public string Tipo { get; set; }
        public double? EspacoGb { get; set; }
        public List<string> Precisa { get; set; }
        public string Origem { get; set; }
        // (o catálogo é regravado para o recomp.ps1: campo que não está aqui some no caminho)
        public string Iso { get; set; }
        public string Nsp { get; set; }
        public string Plataforma { get; set; }
        public string Dump { get; set; }
        public string Bios { get; set; }
        public string Firmware { get; set; }
        public string Keys { get; set; }
        public string Disco { get; set; }
        public string Rpcs3 { get; set; }
        // Tipos genéricos: o comando do "comando", a tag testada da release e um aviso
        // opcional que vai no fim da confirmação de instalar.
        public PreparoRecomp Preparo { get; set; }
        public string Versao { get; set; }
        public string AvisoInstalar { get; set; }
        // Tipo "triforce" (Switch 2): o .nup no servidor, a versão fixa das ferramentas e "sem emulador" (a plataforma
        // não tem emulador: o menu não oferece baixar para ele).
        public string Nup { get; set; }
        public ReleaseFixa Fixa { get; set; }
        public bool? SemEmulador { get; set; }

        // Pastas que nunca podem ser a de instalação do jogo no Playnite (a dos Recomps, as de todos os
        // jogos do catálogo e o _origem): o Desinstalar do RomM apagaria o Recomp.
        [DontSerialize] public List<string> Protegidas { get; set; }
        // Onde o recomp.ps1 põe o jogo original.
        [DontSerialize] public string DumpMostrar { get; set; }

        [DontSerialize] public string CaminhoExe { get { return Path.Combine(Pasta, Exe); } }
        [DontSerialize] public bool Instalado
        {
            get { var p = Path.Combine(Pasta, Pronto); return File.Exists(p) || Directory.Exists(p); }
        }
    }

    public class Configuracao
    {
        public int? Contrato { get; set; }
        // Só no recomps-local.json: o arquivo que traz o resto (o recomps.json do dono).
        public string Usar { get; set; }
        public string Base { get; set; }
        public string Recomps { get; set; }
        public List<string> Raizes { get; set; }
        public string Salvos { get; set; }
        public string Downloads { get; set; }
        public string PastaOrigem { get; set; }
        public List<JogoRecomp> Jogos { get; set; }
    }

    // O mínimo do config.json do plugin do RomM (as mesmas classes do JogosPc.cs; o Recomps é outra DLL).
    public class MapeamentoRomm { public bool Enabled; public int RomMPlatformId; public string DestinationPath; public bool InstallFlat; }
    public class ConfigRomm { public List<MapeamentoRomm> Mappings; }

    // Onde está a ROM que o RomM baixou e se a pasta dela pode ser a pasta de instalação do jogo. O Desinstalar do
    // RomM 0.9.0 apaga a pasta de instalação inteira (sem "flat") ou cada Roms[].Path ("flat"): pasta errada aqui
    // apagaria o Recomp, a pasta do console ou a raiz do drive. Sem Playnite: os testes chamam por reflexão.
    public static class PastaRom
    {
        // Caminho absoluto com letra de drive, sem aspas nem "{", que não é a raiz do drive; senão null.
        public static string Normalizar(string caminho)
        {
            if (string.IsNullOrWhiteSpace(caminho) || caminho.IndexOf('"') >= 0 || caminho.Contains("{")) { return null; }
            try
            {
                if (!Regex.IsMatch(caminho, @"^[A-Za-z]:\\")) { return null; }
                var c = Path.GetFullPath(caminho).TrimEnd('\\');
                return c.Length <= 2 ? null : c;
            }
            catch (Exception) { return null; }
        }

        static bool Igual(string a, string b) { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }

        // a dentro de b (sem ser igual); os dois já normalizados.
        static bool Dentro(string a, string b) { return a.StartsWith(b + "\\", StringComparison.OrdinalIgnoreCase); }

        // As pastas de jogos do emulador (DestinationPath dos mapeamentos habilitados), normalizadas, uma vez cada. "Flat"
        // (true) só quando TODOS os mapeamentos habilitados daquela pasta são flat: em dúvida, a pasta do console nunca vale.
        static List<KeyValuePair<string, bool>> Destinos(List<MapeamentoRomm> mapas)
        {
            return (mapas ?? new List<MapeamentoRomm>()).Where(m => m != null && m.Enabled).Select(m => new KeyValuePair<string, bool>(Normalizar(m.DestinationPath), m.InstallFlat))
                .Where(x => x.Key != null).GroupBy(x => x.Key, StringComparer.OrdinalIgnoreCase)
                .Select(g => new KeyValuePair<string, bool>(g.First().Key, g.All(x => x.Value))).ToList();
        }

        // A pasta do Recomp, a dos Recomps deste PC, a de qualquer jogo do catálogo juntado ou o _origem (a pasta ou dentro dela).
        public static bool PastaDeRecomp(string dir, JogoRecomp r)
        {
            if (r == null) { return false; }
            var d = Path.GetFullPath(dir).TrimEnd('\\') + "\\";
            return new[] { r.Pasta }.Concat(r.Protegidas ?? new List<string>()).Where(x => !string.IsNullOrEmpty(x))
                .Any(x => d.StartsWith(Path.GetFullPath(x).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
        }

        // Alguma pasta protegida (Recomp, _origem...) dentro de p: apagar p apagaria ela junto.
        static bool TemProtegidaDentro(string p, JogoRecomp r)
        {
            if (r == null) { return false; }
            return new[] { r.Pasta }.Concat(r.Protegidas ?? new List<string>()).Select(Normalizar).Any(x => x != null && (Igual(x, p) || Dentro(x, p)));
        }

        // A pasta pode ser a de instalação do jogo, com a ROM dentro: existe e tem o arquivo; fica dentro de uma pasta
        // de jogos do emulador habilitada, com o nome do arquivo sem extensão (igual à pasta de jogos só se ela for
        // "flat" em todos os mapeamentos habilitados); não é nem contém pasta de Recomp.
        public static bool PastaRomSegura(string pasta, string arquivoRom, List<MapeamentoRomm> mapas, JogoRecomp r, out string motivo)
        {
            motivo = null;
            var p = Normalizar(pasta);
            var arq = Normalizar(arquivoRom);
            if (p == null) { motivo = "caminho inválido"; return false; }
            if (arq == null || !Igual(Path.GetDirectoryName(arq), p) || !Directory.Exists(p) || !File.Exists(arq)) { motivo = "a ROM não está nela"; return false; }
            var destinos = Destinos(mapas);
            var flat = destinos.Any(x => x.Value && Igual(p, x.Key));
            if (!flat && !destinos.Any(x => Dentro(p, x.Key))) { motivo = "fora das pastas de jogos do emulador"; return false; }
            if (!flat && !Igual(Path.GetFileName(p), Path.GetFileNameWithoutExtension(arq))) { motivo = "não é a pasta deste jogo"; return false; }
            if (PastaDeRecomp(p, r) || TemProtegidaDentro(p, r)) { motivo = "pasta de Recomp"; return false; }
            return true;
        }

        // Sem a ROM achada: a pasta só fica se é a deste jogo, logo abaixo de uma pasta de jogos do emulador habilitada
        // (nunca a do console), com o nome de um dos arquivos do jogo sem extensão (romm.arquivo ou Roms[].Path), algum
        // arquivo que não é .parcial, e não é nem contém pasta de Recomp. Em dúvida, não fica.
        public static bool PastaSemRomSegura(string pasta, List<MapeamentoRomm> mapas, JogoRecomp r, IEnumerable<string> arquivos)
        {
            var p = Normalizar(pasta);
            if (p == null || !Directory.Exists(p)) { return false; }
            if (!Destinos(mapas).Any(x => Igual(Path.GetDirectoryName(p), x.Key))) { return false; }
            var nomes = new List<string>();
            foreach (var a in arquivos ?? new List<string>())
            {
                if (string.IsNullOrWhiteSpace(a)) { continue; }
                try { var n = Path.GetFileNameWithoutExtension(a.Replace("{InstallDir}", "").Replace('/', '\\').Trim('"')); if (!string.IsNullOrEmpty(n)) { nomes.Add(n); } }
                catch (Exception) { }
            }
            if (!nomes.Any(n => Igual(n, Path.GetFileName(p)))) { return false; }
            if (PastaDeRecomp(p, r) || TemProtegidaDentro(p, r)) { return false; }
            try { return Directory.EnumerateFiles(p).Any(f => !f.EndsWith(".parcial", StringComparison.OrdinalIgnoreCase)); }
            catch (Exception) { return false; }
        }

        // Os arquivos que o jogo pode ter: o do RomM no catálogo e os da lista de ROMs.
        public static List<string> ArquivosDoJogo(Game jogo, JogoRecomp r)
        {
            var l = new List<string>();
            if (r != null && r.Romm != null && !string.IsNullOrEmpty(r.Romm.Arquivo)) { l.Add(r.Romm.Arquivo); }
            if (jogo != null && jogo.Roms != null) { l.AddRange(jogo.Roms.Where(x => x != null && !string.IsNullOrEmpty(x.Path)).Select(x => x.Path)); }
            return l;
        }

        // Conferência da pasta antes de o RomM agir, sem deixar passar falha: se conferir ou gravar der erro e fechar for
        // true (o caminho do Desinstalar), a pasta de instalação fica vazia (o RomM falha sem apagar nada). Devolve o erro.
        public static Exception Proteger(Game jogo, Func<bool> conferir, Action gravar, bool fechar)
        {
            try
            {
                if (conferir()) { gravar(); }
                return null;
            }
            catch (Exception e)
            {
                if (fechar)
                {
                    jogo.InstallDirectory = null;
                    try { gravar(); } catch (Exception) { }
                }
                return e;
            }
        }

        // Um caminho da lista de ROMs do jogo -> o arquivo absoluto que existe, ou null. Absoluto vale como está;
        // "{InstallDir}\..." só com uma pasta de instalação segura; senão procura pelo nome do arquivo em cada pasta
        // de jogos do emulador (<pasta>\<nome sem extensão>\<arquivo> e <pasta>\<arquivo>) e aceita um achado só.
        public static string ResolverCaminho(string caminho, string installDir, List<MapeamentoRomm> mapas, JogoRecomp r)
        {
            if (string.IsNullOrWhiteSpace(caminho)) { return null; }
            var abs = Normalizar(caminho);
            if (abs != null && File.Exists(abs)) { return abs; }
            if (caminho.Contains("{InstallDir}"))
            {
                var dir = Normalizar(installDir);
                var exp = dir == null ? null : Normalizar(caminho.Replace("{InstallDir}", dir));
                string motivo;
                if (exp != null && File.Exists(exp) && PastaRomSegura(Path.GetDirectoryName(exp), exp, mapas, r, out motivo)) { return exp; }
            }
            string nome;
            try { nome = Path.GetFileName(caminho.Replace("{InstallDir}", "").Replace('/', '\\').Trim('"')); }
            catch (Exception) { return null; }
            if (string.IsNullOrEmpty(nome) || nome.Contains("{")) { return null; }
            var achados = new List<string>();
            foreach (var d in Destinos(mapas).Select(x => x.Key).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                foreach (var c in new[] { Path.Combine(d, Path.GetFileNameWithoutExtension(nome), nome), Path.Combine(d, nome) })
                {
                    if (File.Exists(c) && !achados.Contains(c, StringComparer.OrdinalIgnoreCase)) { achados.Add(c); }
                }
            }
            return achados.Count == 1 ? achados[0] : null;
        }

        // A ROM do jogo (o arquivo absoluto da primeira da lista que se acha), ou null.
        public static string ResolverRom(Game jogo, JogoRecomp r, List<MapeamentoRomm> mapas)
        {
            if (jogo == null || jogo.Roms == null) { return null; }
            foreach (var x in jogo.Roms)
            {
                var c = x == null ? null : ResolverCaminho(x.Path, jogo.InstallDirectory, mapas, r);
                if (c != null) { return c; }
            }
            return null;
        }

        // Nome de jogo dentro de um texto: sem "closing", "exiting" e "shutting" (regra 17).
        public static string Nome(string nome)
        {
            return Regex.Replace(nome ?? "", "(?<=clos)(?=ing)|(?<=exit)(?=ing)|(?<=shut)(?=ting)", "​", RegexOptions.IgnoreCase);
        }
    }

    // Integração com o plugin Jogos de PC: o card do Recomp volta quando outra tarefa toma a vaga do
    // Selene, e o andamento aparece no topo da tela cheia e no menu. Por reflexão e em silêncio: sem o
    // Jogos de PC, ou com outra versão dele, tudo continua como antes.
    static class TarefasJogosPc
    {
        static readonly ILogger log = LogManager.GetLogger();
        static Type tipo;
        static int avisou;

        static object Chamar(string metodo, params object[] args)
        {
            try
            {
                if (tipo == null)
                {
                    var asm = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "JogosPc");
                    tipo = asm == null ? null : asm.GetType("JogosPc.Tarefas");
                    if (tipo == null) { return null; }
                }
                var m = tipo.GetMethod(metodo, BindingFlags.Public | BindingFlags.Static);
                return m == null ? null : m.Invoke(null, args);
            }
            catch (Exception e)
            {
                if (Interlocked.Exchange(ref avisou, 1) == 0) { log.Warn(e, "Jogos de PC: falha ao registrar a instalação do Recomp"); }
                return null;
            }
        }

        public static string Abrir(string nome, object argsDoCard) { return Chamar("Abrir", nome, argsDoCard) as string; }
        public static void Atualizar(string id, string etapa, long feito, long total) { if (id != null) { Chamar("Atualizar", id, etapa, feito, total); } }
        public static void PodeCancelar(string id, Action cancelar) { if (id != null) { Chamar("PodeCancelar", id, cancelar); } }
        public static void Fechar(string id) { if (id != null) { Chamar("Fechar", id); } }
        // Opcionais (Jogos de PC mais novo): como terminou, para "Terminados nesta sessão" na tela de Downloads, e
        // se o Jogos de PC está pedindo o Instalar só para continuar a ROM. Sem eles, nada muda.
        public static void Resultado(string id, string fim, string motivo) { if (id != null) { Chamar("Resultado", id, fim, motivo); } }
        public static bool SoEmulador(Guid jogo) { var r = Chamar("SoEmulador", jogo.ToString()); return r is bool && (bool)r; }
    }

    // A mesma conta do card do Jogos de PC (SeleneDialogs.Mine do SeleneCore 1.5.6): o Selene vai mostrar este progresso como
    // card, e não a janela modal do Playnite? Sem o Selene, ou se ele mudar, abre como antes (regra 14).
    static class CardSelene
    {
        static readonly object trava = new object();
        static bool procurou;
        static MethodInfo mine, usavel, ligado;

        public static bool PodeAbrir(GlobalProgressOptions opcoes)
        {
            try
            {
                if (!Achar()) { return true; }
                if (mine != null) { return (bool)mine.Invoke(null, new object[] { opcoes }); }
                return (bool)ligado.Invoke(null, new object[] { "dialogs" }) && (bool)ligado.Invoke(null, new object[] { "progresstoast" }) && (bool)usavel.Invoke(null, null);
            }
            catch (Exception) { return true; }
        }

        static bool Achar()
        {
            lock (trava)
            {
                if (procurou) { return mine != null || (usavel != null && ligado != null); }
                var asm = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "SeleneCore");
                if (asm == null) { return false; }
                procurou = true;
                const BindingFlags f = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
                var dialogos = asm.GetType("Selene.SeleneDialogs");
                var toast = asm.GetType("Selene.ProgressToast");
                var recursos = asm.GetType("Selene.Features");
                var m = dialogos == null ? null : dialogos.GetMethod("Mine", f, null, new[] { typeof(GlobalProgressOptions) }, null);
                mine = m != null && m.ReturnType == typeof(bool) ? m : null;
                var u = toast == null ? null : toast.GetMethod("Usable", f, null, Type.EmptyTypes, null);
                var on = recursos == null ? null : recursos.GetMethod("On", f, null, new[] { typeof(string) }, null);
                usavel = u != null && u.ReturnType == typeof(bool) ? u : null;
                ligado = on != null && on.ReturnType == typeof(bool) ? on : null;
                if (mine == null && (usavel == null || ligado == null)) { LogManager.GetLogger().Warn("Recomps: SeleneDialogs.Mine/ProgressToast.Usable não encontrados no Selene"); }
                return mine != null || (usavel != null && ligado != null);
            }
        }
    }

    // Botão "Instalar o Recomp" na página do jogo do Selene (só no Fullscreen), logo depois do Jogar e antes de Opções: quem
    // já tem a ROM e ainda não tem o Recomp fica sabendo que ele existe. É do mesmo tipo e estilo do Jogar (SeleneDetailsButton,
    // dos recursos do GameDetails.xaml). Sem a parte, o estilo ou o tipo, não faz nada e avisa uma vez no log (regra 14).
    // Colapsado quando não se aplica (não recebe foco). Só roda na thread da UI. A conta (ROM no disco etc.) fica guardada:
    // refaz ao trocar de jogo, quando avisam que algo mudou (Invalidar) e a cada 5 s com o botão visível.
    public static class BotaoRecompSelene
    {
        public const string Texto = "Instalar o Recomp";
        static readonly HashSet<string> avisos = new HashSet<string>();
        static System.Windows.Controls.Primitives.ButtonBase botao;
        static FrameworkElement jogar;
        static System.Windows.Threading.DispatcherTimer relogio;
        static IPlayniteAPI playnite;
        static Func<Game, bool> aplica;
        static Func<Game, Action, bool> instalar;
        static Game jogoAtual;
        static bool mostrar;
        static DateTime calculado;
        static volatile bool recalcular, procurar = true;
        static DateTime procurado;
        static int calculando;
        static bool ocupado, confirmado;

        // Mostra o botão? Tela cheia, Recomp no catálogo, ROM completa, Recomp não instalado nem instalando, não dispensado.
        public static bool Visivel(bool telaCheia, bool temRecomp, bool romInstalada, bool recompInstalado, bool instalando, bool dispensado)
        {
            return telaCheia && temRecomp && romInstalada && !recompInstalado && !instalando && !dispensado;
        }

        public static void Iniciar(IPlayniteAPI api, Func<Game, bool> condicao, Func<Game, Action, bool> acao)
        {
            playnite = api; aplica = condicao; instalar = acao;
            if (relogio != null) { return; }
            relogio = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            relogio.Tick += (s, e) => Tentar("vigiar", Vigiar);
            relogio.Start();
        }

        // Algo mudou (jogo instalado, removido, instalação no fim, dispensado): refaz a conta no próximo tick.
        public static void Invalidar() { recalcular = true; procurar = true; }

        static void Avisar(string oque, Exception e)
        {
            bool primeira;
            lock (avisos) { primeira = avisos.Add(oque); }
            if (!primeira) { return; }
            if (e == null) { LogManager.GetLogger().Warn("Botão do Recomp: " + oque + "; o botão não aparece"); }
            else { LogManager.GetLogger().Error(e, "Botão do Recomp: falha ao " + oque); }
        }

        static void Tentar(string oque, Action acao)
        {
            try { acao(); }
            catch (Exception e) { Avisar(oque, e); }
        }

        static void Vigiar()
        {
            // O Jogar guardado vale enquanto continua na tela e visível. Senão procura de novo na árvore visual, mas só
            // depois de um aviso (jogo selecionado, Invalidar) ou a cada 2,5 s: a árvore inteira não é varrida a cada tick.
            if (jogar == null || PresentationSource.FromVisual(jogar) == null || !jogar.IsVisible)
            {
                if (!procurar && (DateTime.Now - procurado).TotalSeconds < 2.5) { Esconder(); return; }
                procurar = false;
                procurado = DateTime.Now;
                var janela = Application.Current == null ? null : Application.Current.MainWindow;
                jogar = janela == null ? null : Achar(janela, "PART_ButtonContext");
            }
            if (jogar == null || !jogar.IsVisible || !EncaixarJunto(jogar)) { Esconder(); return; }
            var jogo = JogoDaPagina(jogar);
            if (jogo == null) { Esconder(); return; }
            if (jogoAtual == null || jogoAtual.Id != jogo.Id) { jogoAtual = jogo; mostrar = false; recalcular = true; }
            var visivel = botao.Visibility == Visibility.Visible;
            // A conta (catálogo, mapeamentos do RomM, arquivos no disco) roda fora da thread da UI; o resultado volta
            // pelo dispatcher e só vale se ainda é o mesmo jogo.
            // (verificando, a conta daria "instalando": espera o fim do clique, que pede outra)
            if (!ocupado && (recalcular || (visivel && (DateTime.Now - calculado).TotalSeconds >= 5)) && Interlocked.CompareExchange(ref calculando, 1, 0) == 0)
            {
                recalcular = false;
                calculado = DateTime.Now;
                var g = jogo;
                var f = aplica;
                var ui = System.Windows.Threading.Dispatcher.CurrentDispatcher;
                System.Threading.Tasks.Task.Factory.StartNew(() =>
                {
                    var r = false;
                    try { r = f != null && f(g); } catch (Exception e) { Avisar("calcular", e); }
                    ui.BeginInvoke(new Action(() =>
                    {
                        Interlocked.Exchange(ref calculando, 0);
                        if (!ocupado && jogoAtual != null && jogoAtual.Id == g.Id) { mostrar = r; Aplicar(); }
                    }));
                });
            }
            Aplicar();
        }

        static void Aplicar()
        {
            if (botao == null) { return; }
            // (verificando: continua visível, só desabilitado, para o foco voltar a ele depois do Não; depois do Sim some)
            if (ocupado ? !confirmado : mostrar) { botao.Visibility = Visibility.Visible; } else { Esconder(); }
        }

        static void Esconder()
        {
            if (botao == null || botao.Visibility == Visibility.Collapsed) { return; }
            // (o foco não pode sumir junto com o botão)
            var tinhaFoco = botao.IsKeyboardFocusWithin;
            botao.Visibility = Visibility.Collapsed;
            if (tinhaFoco && jogar != null) { jogar.Focus(); }
        }

        // O jogo da página: o do Jogar (DataContext Game ou com uma propriedade Game), senão o selecionado.
        static Game JogoDaPagina(FrameworkElement b)
        {
            var dc = b.DataContext;
            var jogo = dc as Game;
            if (jogo == null && dc != null)
            {
                var p = dc.GetType().GetProperty("Game", BindingFlags.Public | BindingFlags.Instance);
                if (p != null && p.GetIndexParameters().Length == 0 && typeof(Game).IsAssignableFrom(p.PropertyType)) { jogo = p.GetValue(dc, null) as Game; }
            }
            if (jogo != null || playnite == null) { return jogo; }
            var sel = playnite.MainView.SelectedGames;
            return sel == null ? null : sel.FirstOrDefault();
        }

        // Põe o botão logo depois do PART_ButtonContext, no mesmo painel. Pública para o teste: sem a parte, não encaixa.
        public static bool Encaixar(DependencyObject raiz)
        {
            var b = Achar(raiz, "PART_ButtonContext");
            return b != null && EncaixarJunto(b);
        }

        static bool EncaixarJunto(FrameworkElement b)
        {
            var fila = VisualTreeHelper.GetParent(b) as System.Windows.Controls.Panel;
            if (fila == null || fila.Children.IndexOf(b) < 0) { Avisar("sem o painel do Jogar", null); return false; }
            if (botao == null)
            {
                var estilo = b.TryFindResource("SeleneDetailsButton") as Style;
                if (estilo == null) { Avisar("sem o estilo SeleneDetailsButton", null); return false; }
                System.Windows.Controls.Primitives.ButtonBase novo = null;
                try { novo = Activator.CreateInstance(b.GetType()) as System.Windows.Controls.Primitives.ButtonBase; }
                catch (Exception) { novo = null; }
                if (novo == null || (estilo.TargetType != null && !estilo.TargetType.IsInstanceOfType(novo))) { Avisar("sem o tipo do Jogar", null); return false; }
                novo.Style = estilo;
                novo.Content = Texto;
                novo.Visibility = Visibility.Collapsed;
                novo.Click += (s, e) => Tentar("instalar", Clicar);
                botao = novo;
            }
            var pai = botao.Parent as System.Windows.Controls.Panel;
            var i = fila.Children.IndexOf(b);
            if (pai == fila && fila.Children.IndexOf(botao) == i + 1) { return true; }
            // Saiu do lugar (o tema refez a página): tira do lugar antigo e põe de novo.
            if (pai != null) { pai.Children.Remove(botao); }
            fila.Children.Insert(fila.Children.IndexOf(b) + 1, botao);
            return true;
        }

        static void Clicar()
        {
            var jogo = jogoAtual;
            var b = jogar;
            // (a verificação roda com a interface viva: um segundo clique no meio não abre outra)
            if (jogo == null || instalar == null || ocupado) { return; }
            ocupado = true;
            confirmado = false;
            botao.IsEnabled = false;
            var sim = false;
            try
            {
                instalar(jogo, () =>
                {
                    // Depois do Sim: o botão some e o foco vai para o Jogar.
                    sim = true;
                    confirmado = true;
                    mostrar = false;
                    Esconder();
                    botao.Visibility = Visibility.Collapsed;
                    if (b != null) { b.Focus(); }
                });
            }
            finally
            {
                ocupado = false;
                botao.IsEnabled = true;
                Invalidar();
            }
            // Depois do Não (ou do que falta): nada muda e o foco volta ao botão, senão ao Jogar.
            if (!sim)
            {
                if (botao.IsVisible) { botao.Focus(); } else if (b != null) { b.Focus(); }
            }
        }

        // Como o Achar do indicador do topo (JogosPc.cs), sem descer em partes escondidas.
        static FrameworkElement Achar(DependencyObject no, string nome)
        {
            if (!(no is Visual) && !(no is System.Windows.Media.Media3D.Visual3D)) { return null; }
            var ui = no as UIElement;
            if (ui != null && ui.Visibility != Visibility.Visible) { return null; }
            var fe = no as FrameworkElement;
            if (fe != null && fe.Name == nome) { return fe; }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(no); i++)
            {
                var r = Achar(VisualTreeHelper.GetChild(no, i), nome);
                if (r != null) { return r; }
            }
            return null;
        }

        // aviso-recomp-dispensado.json: uma lista de Guids. Ilegível vale como vazio (o botão volta a aparecer).
        public static HashSet<Guid> LerDispensados(string arquivo)
        {
            var lista = new HashSet<Guid>();
            try
            {
                if (!File.Exists(arquivo)) { return lista; }
                foreach (Match m in Regex.Matches(File.ReadAllText(arquivo, Encoding.UTF8), @"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"))
                {
                    lista.Add(Guid.Parse(m.Value));
                }
            }
            catch (Exception e) { Avisar("ler " + Path.GetFileName(arquivo), e); }
            return lista;
        }

        // UTF-8 sem BOM, troca atômica (um .tmp ao lado e depois a troca).
        public static void GravarDispensados(string arquivo, IEnumerable<Guid> lista)
        {
            var texto = "[" + string.Join(", ", lista.Distinct().Select(x => x.ToString()).OrderBy(x => x, StringComparer.Ordinal).Select(x => "\"" + x + "\"")) + "]";
            Directory.CreateDirectory(Path.GetDirectoryName(arquivo));
            var tmp = arquivo + ".tmp";
            File.WriteAllText(tmp, texto, new UTF8Encoding(false));
            if (File.Exists(arquivo)) { File.Replace(tmp, arquivo, null); } else { File.Move(tmp, arquivo); }
        }
    }

    public static class TextosRecomp
    {
        static readonly string[][] TextosFalta =
        {
            new[] { "keys", "o arquivo prod.keys. Coloque pelo instalador do Jogos Retro." },
            new[] { "rpcs3", "o emulador de PlayStation 3. Instale pelo instalador do Jogos Retro." },
            new[] { "python", "o Python 3." },
            new[] { "espaco", null },
            new[] { "servidor", "conexão com o servidor. Confira se a VPN está ligada." },
            new[] { "mudou", "o jogo mudou no servidor. Avise o Neto." },
            new[] { "varios", "o jogo no servidor tem vários arquivos. Avise o Neto." },
            new[] { "nup", null },
            new[] { "bios", null },
            new[] { "firmware", null },
            new[] { "formato", null },
            new[] { "arquivo", null }
        };

        static int Ordem(string codigo)
        {
            var indice = Array.FindIndex(TextosFalta, t => t[0] == codigo);
            return indice < 0 ? int.MaxValue : indice;
        }

        // Um código desconhecido fica para o aviso conjunto, depois dos requisitos conhecidos.
        public static string Falta(string codigo, JogoRecomp r, long precisa, long livre, string drive)
        {
            switch (codigo)
            {
                case "espaco": return "espaço: precisa de " + PluginRecomps.Gb(precisa) + " GB livres em " + drive + ", tem " + PluginRecomps.Gb(livre) + " GB.";
                case "nup": return "o arquivo do jogo (.nup), que não foi encontrado em:\n" + r.Nup + "\nConfira se o servidor está ligado.";
                case "bios":
                    if (!string.Equals(r.Plataforma, "ps2", StringComparison.OrdinalIgnoreCase)) { return "a BIOS do console. Avise o Neto."; }
                    return !string.IsNullOrEmpty(r.Bios) ? "a BIOS do PS2, que não foi encontrada em:\n" + r.Bios
                        : "a BIOS do PS2 (a do seu console), que o PCSX2 usa. Coloque pelo instalador do Jogos Retro, em \"BIOS do PS2\".";
                case "firmware":
                    if (string.Equals(r.Plataforma, "switch", StringComparison.OrdinalIgnoreCase))
                    {
                        return !string.IsNullOrEmpty(r.Firmware) ? "o firmware do Switch, que não foi encontrado em:\n" + r.Firmware
                            : "o firmware do Switch (o do seu console) no Eden. Coloque pelo instalador do Jogos Retro, em \"Firmware do Switch\".";
                    }
                    if (string.Equals(r.Plataforma, "ps3", StringComparison.OrdinalIgnoreCase))
                    {
                        return !string.IsNullOrEmpty(r.Firmware) ? "o firmware do PS3, que não foi encontrado em:\n" + r.Firmware
                            : "o firmware do PS3 no RPCS3. Rode o instalador do Jogos Retro de novo com o PlayStation 3 marcado.";
                    }
                    return "o firmware do console. Avise o Neto.";
                case "formato":
                    var ext = Path.GetExtension(r.Romm == null ? null : r.Romm.Arquivo);
                    return "o jogo num formato que o Recomp aceite" + (string.IsNullOrEmpty(ext) ? "" : " (o do servidor é " + ext + ")") + ". Avise o Neto.";
                case "arquivo":
                    return "o arquivo do jogo, que não foi encontrado em:\n" + r.DumpMostrar + "\nConfira se o servidor está ligado.";
                default:
                    var item = TextosFalta.FirstOrDefault(t => t[0] == codigo);
                    return item == null ? null : item[1];
            }
        }

        public static string Faltas(IEnumerable<string> faltas, JogoRecomp r, long precisa, long livre, string drive)
        {
            var itens = new List<string>();
            var desconhecidos = new List<string>();
            foreach (var codigo in faltas.Distinct().OrderBy(Ordem))
            {
                var item = Falta(codigo, r, precisa, livre, drive);
                if (item == null) { desconhecidos.Add(codigo); }
                else { itens.Add(item); }
            }
            if (desconhecidos.Count > 0) { itens.Add("algo que o Recomp precisa (" + string.Join(", ", desconhecidos) + ")."); }
            var mensagem = "Ainda não dá para instalar o Recomp de " + r.Nome + ". Falta:\n" + string.Join("\n", itens.Select(x => "• " + x));
            if (desconhecidos.Count > 0)
            {
                mensagem += "\n\nFeche o Playnite, abra pelo atalho \"Jogos Retro\" e tente de novo. Se continuar, avise o Neto.";
            }
            return mensagem;
        }
    }

    public class PluginRecomps : GenericPlugin
    {
        const string AcaoAntiga = "Jogar nativo (Recomp)";
        static readonly ILogger log = LogManager.GetLogger();
        static readonly string PastaPlugin = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        static readonly Guid PluginRomm = Guid.Parse("9700aa21-447d-41b4-a989-acd38f407d9f");
        static int avisouLer, avisouRomm;
        readonly IPlayniteAPI api;

        public PluginRecomps(IPlayniteAPI api) : base(api)
        {
            this.api = api;
            Properties = new GenericPluginProperties { HasSettings = false };
        }

        public override Guid Id { get { return Guid.Parse("7d1f4c2a-9b3e-4a6d-8c5f-2e1a0b9d3f71"); } }

        // Catálogo do pacote juntado com o recomps-local.json e com os caminhos resolvidos. Sem
        // instalacao.txt ou com o catálogo ilegível (e nenhuma leitura boa antes): nenhum Recomp, e um aviso só no log.
        static Configuracao Ler() { return LerComReserva(LerCatalogo); }

        // Sem instalacao.txt: null. Catálogo ilegível: exceção.
        static Configuracao LerCatalogo()
        {
            var instalacao = Path.Combine(PastaPlugin, "instalacao.txt");
            if (!File.Exists(instalacao)) { return null; }
            var pastaBase = File.ReadAllText(instalacao, Encoding.UTF8).Trim();
            // Sem o catálogo do pacote, o recomps-local.json ainda vale: as pastas do dono continuam protegidas.
            var catalogo = Path.Combine(pastaBase, "programa", "recomps.json");
            var cfg = File.Exists(catalogo) ? Serialization.FromJsonFile<Configuracao>(catalogo) : new Configuracao();
            var local = Path.Combine(pastaBase, "recomps-local.json");
            if (File.Exists(local))
            {
                var o = Serialization.FromJsonFile<Configuracao>(local);
                if (!string.IsNullOrEmpty(o.Usar))
                {
                    var usar = Serialization.FromJsonFile<Configuracao>(o.Usar);
                    Juntar(usar, o);
                    o = usar;
                }
                Juntar(cfg, o);
            }
            Resolver(cfg, pastaBase);
            return cfg;
        }

        // A leitura com a reserva da última boa (pública para o teste: ler é a leitura de verdade).
        public static Configuracao LerComReserva(Func<Configuracao> ler)
        {
            try
            {
                var cfg = ler();
                if (cfg == null) { return Vazia(null, "Recomps: sem instalacao.txt em " + PastaPlugin); }
                ultimaBoa = cfg;
                return cfg;
            }
            catch (Exception e)
            {
                // Catálogo ilegível no meio da sessão (gravação pela metade, atualização): a última leitura boa continua
                // valendo, senão toda pasta de Recomp ficaria sem proteção.
                var boa = ultimaBoa;
                if (boa != null)
                {
                    if (Interlocked.Exchange(ref avisouUltima, 1) == 0) { log.Warn(e, "Recomps: recomps.json ilegível; usando a última leitura boa"); }
                    return boa;
                }
                return Vazia(e, "Recomps: recomps.json ilegível");
            }
        }

        static volatile Configuracao ultimaBoa;
        static int avisouUltima;

        static Configuracao Vazia(Exception e, string motivo)
        {
            if (Interlocked.Exchange(ref avisouLer, 1) == 0) { if (e == null) { log.Warn(motivo); } else { log.Error(e, motivo); } }
            return new Configuracao { Jogos = new List<JogoRecomp>() };
        }

        // Os campos de b ganham; jogo de b que não está em a entra inteiro.
        static void Juntar(Configuracao a, Configuracao b)
        {
            if (b.Recomps != null) { a.Recomps = b.Recomps; }
            if (b.Raizes != null) { a.Raizes = b.Raizes; }
            if (b.Salvos != null) { a.Salvos = b.Salvos; }
            if (b.Downloads != null) { a.Downloads = b.Downloads; }
            if (a.Jogos == null) { a.Jogos = new List<JogoRecomp>(); }
            if (b.Jogos == null) { return; }
            foreach (var jb in b.Jogos.Where(x => x != null && !string.IsNullOrEmpty(x.Id)))
            {
                var ja = a.Jogos.FirstOrDefault(x => x != null && x.Id == jb.Id);
                if (ja == null) { a.Jogos.Add(jb); continue; }
                foreach (var p in typeof(JogoRecomp).GetProperties().Where(x => x.CanWrite))
                {
                    var v = p.GetValue(jb, null);
                    if (v != null) { p.SetValue(ja, v, null); }
                }
            }
        }

        // Caminhos relativos ficam dentro da pasta dos Recomps do PC: a do recomps-local.json, a de cima
        // dos saves dele (o dono: D:\Recomps\_saves) ou <Base>\Recomps.
        static void Resolver(Configuracao cfg, string pastaBase)
        {
            cfg.Base = pastaBase;
            cfg.Contrato = 2;
            var recomps = !string.IsNullOrEmpty(cfg.Recomps) ? cfg.Recomps
                : !string.IsNullOrEmpty(cfg.Salvos) ? Path.GetDirectoryName(cfg.Salvos.TrimEnd('\\')) : "Recomps";
            cfg.Recomps = Path.Combine(pastaBase, recomps);
            cfg.Salvos = Path.Combine(cfg.Recomps, string.IsNullOrEmpty(cfg.Salvos) ? "_saves" : cfg.Salvos);
            cfg.Downloads = Path.Combine(cfg.Recomps, string.IsNullOrEmpty(cfg.Downloads) ? "_downloads" : cfg.Downloads);
            cfg.PastaOrigem = Path.Combine(cfg.Recomps, "_origem");
            if (cfg.Raizes == null) { cfg.Raizes = new List<string>(); }
            cfg.Jogos = (cfg.Jogos ?? new List<JogoRecomp>()).Where(j => j != null && !string.IsNullOrEmpty(j.Id) && !string.IsNullOrEmpty(j.Pasta) &&
                !string.IsNullOrEmpty(j.Exe) && !string.IsNullOrEmpty(j.Pronto)).ToList();
            var programa = Path.Combine(pastaBase, "programa");
            foreach (var j in cfg.Jogos)
            {
                j.Pasta = Path.Combine(cfg.Recomps, j.Pasta);
                if (!string.IsNullOrEmpty(j.Disco)) { j.Disco = Path.Combine(cfg.Recomps, j.Disco); }
                j.Exe = j.Exe.Replace("{programa}", programa);
                var precisa = j.Precisa ?? new List<string>();
                if (precisa.Contains("keys") && string.IsNullOrEmpty(j.Keys)) { j.Keys = Path.Combine(pastaBase, @"Emuladores\Eden\user\keys\prod.keys"); }
                if (precisa.Contains("rpcs3") && string.IsNullOrEmpty(j.Rpcs3)) { j.Rpcs3 = Path.Combine(pastaBase, @"Emuladores\RPCS3"); }
                j.DumpMostrar = CaminhoDump(j, cfg.PastaOrigem);
            }
            // (a raiz de um drive nunca entra: tudo nele contaria como pasta de Recomp)
            var protegidas = new List<string> { cfg.Recomps, cfg.PastaOrigem };
            protegidas.AddRange(cfg.Raizes);
            protegidas.AddRange(cfg.Jogos.Select(j => j.Pasta));
            protegidas.AddRange(cfg.Jogos.Select(j => j.Disco));
            protegidas = protegidas.Where(x => !string.IsNullOrEmpty(x) && Path.IsPathRooted(x) &&
                !string.Equals(Path.GetPathRoot(x).TrimEnd('\\'), x.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            foreach (var j in cfg.Jogos) { j.Protegidas = protegidas; }
        }

        static string CaminhoDump(JogoRecomp jogo, string pastaOrigem)
        {
            if (jogo.Romm == null || string.IsNullOrEmpty(jogo.Romm.Arquivo)) { return jogo.Dump; }
            // (fs_name que não é nome simples nunca vira caminho: sem dump, o Jogar cai no "dump ausente")
            if (!NomeSimples(jogo.Romm.Arquivo)) { return null; }
            var ext = Path.GetExtension(jogo.Romm.Arquivo);
            var original = string.Equals(ext, ".nsp", StringComparison.OrdinalIgnoreCase) ? jogo.Nsp
                : string.Equals(ext, ".iso", StringComparison.OrdinalIgnoreCase) ? jogo.Iso : null;
            if (!string.IsNullOrEmpty(original)) { return original; }
            if (!string.IsNullOrEmpty(jogo.Dump)) { return jogo.Dump; }
            return Path.Combine(pastaOrigem, jogo.Id, jogo.Romm.Arquivo);
        }

        // Só nome de arquivo: sem pasta, sem "." ou ".." e sem caractere que o Windows recusa (igual ao recomp.ps1).
        static bool NomeSimples(string nome)
        {
            return !string.IsNullOrEmpty(nome) && nome != "." && nome != ".." &&
                nome.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 && Path.GetFileName(nome) == nome;
        }

        static JogoRecomp Achar(Game jogo) { return Achar(Ler(), jogo); }

        // Primeiro pelo gameId do recomps-local.json (o PC do dono); senão pelo jogo do RomM.
        static JogoRecomp Achar(Configuracao cfg, Game jogo)
        {
            var r = cfg.Jogos.FirstOrDefault(j => j.GameId.HasValue && j.GameId.Value == jogo.Id);
            if (r != null || jogo.PluginId != PluginRomm) { return r; }
            long id;
            if (!long.TryParse(IdRomm(jogo), out id)) { return null; }
            return cfg.Jogos.FirstOrDefault(j => j.Romm != null && j.Romm.Id == id);
        }

        // Mesma regra do Jogos de PC: o GameId do plugin do RomM e "<id da rom>:<hash>" e, ao contrario de
        // Game.Roms, nao some ao desinstalar.
        public static string IdRomm(Game jogo)
        {
            var m = Regex.Match(jogo.GameId ?? "", @"^(\d+):");
            return m.Success ? m.Groups[1].Value : null;
        }

        static string FormatarArgumentosJogar(JogoRecomp r, out string campoFaltando)
        {
            string falta = null;
            // Os argumentos novos vêm sem aspas. Os antigos podem já incluir as suas.
            var cotarCaminhos = !string.IsNullOrEmpty(r.Plataforma) && r.Args != null && r.Args.IndexOf('"') < 0;
            var argumentos = string.IsNullOrEmpty(r.Args) ? null : Regex.Replace(r.Args, @"\{[^{}]*\}|\{", m =>
            {
                var caminho = m.Value == "{pasta}" ? r.Pasta : m.Value == "{dump}" ? r.DumpMostrar : null;
                if (!string.IsNullOrEmpty(caminho)) { return cotarCaminhos ? Aspas(caminho) : caminho; }
                if (falta == null) { falta = m.Value; }
                return m.Value;
            });
            campoFaltando = falta;
            return argumentos;
        }

        public override IEnumerable<PlayController> GetPlayActions(GetPlayActionsArgs args)
        {
            var r = Achar(args.Game);
            if (r == null || !r.Instalado) { yield break; }
            var c = new AutomaticPlayController(args.Game)
            {
                Name = "Recomp (nativo)",
                Type = AutomaticPlayActionType.File,
                TrackingMode = TrackingMode.Default,
                Path = r.CaminhoExe,
                WorkingDir = Path.GetDirectoryName(r.CaminhoExe)
            };
            // Os campos dos argumentos viram caminhos neste PC (o jogar-totk.ps1 recebe -Pasta).
            string campoFaltando;
            var argumentos = FormatarArgumentosJogar(r, out campoFaltando);
            if (campoFaltando != null)
            {
                log.Warn("Recomp " + r.Id + ": faltou " + campoFaltando + " nos argumentos do Jogar: " + r.Args);
                api.Dialogs.ShowMessage("Não deu para abrir o Recomp de " + r.Nome + ": falta um dado para montar o jeito de abrir o jogo (" + campoFaltando +
                    "). Feche o Playnite, abra pelo atalho \"Jogos Retro\" e tente de novo. Se continuar, avise o Neto.",
                    "Recomp: " + r.Nome, MessageBoxButton.OK, MessageBoxImage.Error);
                yield break;
            }
            if (argumentos != null) { c.Arguments = argumentos; }
            // O inFAMOUS 2 e o TotK abrem por um script que espera o jogo fechar: o Playnite conta o tempo por ele.
            if (r.Exe.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase))
            {
                c.Path = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
                c.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + r.CaminhoExe + "\"" + (argumentos == null ? "" : " " + argumentos);
                c.WorkingDir = r.Pasta;
            }
            yield return c;
        }

        // Com o RomM também oferecendo Instalar / Desinstalar, o Playnite pergunta qual usar.
        public override IEnumerable<InstallController> GetInstallActions(GetInstallActionsArgs args)
        {
            var r = Achar(args.Game);
            if (r == null) { yield break; }
            ProtegerPasta(args.Game, r, false);
            // Já instalando: não oferece de novo (duas instalações brigariam pela mesma pasta). O Jogos de PC
            // continuando a ROM pela metade: só o emulador, sem perguntar.
            if (r.Instalado || EmAndamento(r) != null || TarefasJogosPc.SoEmulador(args.Game.Id)) { yield break; }
            yield return new ControleInstalar(this, r, args.Game);
        }

        public override IEnumerable<UninstallController> GetUninstallActions(GetUninstallActionsArgs args)
        {
            var r = Achar(args.Game);
            if (r == null) { yield break; }
            // Antes do controller do RomM, que apaga a InstallDirectory.
            ProtegerPasta(args.Game, r, true);
            if (!r.Instalado)
            {
                // Só a ROM, e ela não foi achada: sem pasta de instalação, o Desinstalar do RomM falha sem apagar
                // nada e o jogo fica como estava (nunca apaga às cegas a pasta do console ou a raiz do drive).
                if (args.Game.IsInstalled && PastaRom.ResolverRom(args.Game, r, LerMapeamentosRomm()) == null) { RomNaoAchada(args.Game); }
                yield break;
            }
            yield return new ControleDesinstalar(this, r, args.Game);
        }

        static readonly HashSet<Guid> avisandoRom = new HashSet<Guid>();

        void RomNaoAchada(Game jogo)
        {
            var nome = PastaRom.Nome(jogo.Name);
            try
            {
                if (!string.IsNullOrEmpty(jogo.InstallDirectory))
                {
                    log.Warn("Desinstalar a ROM de " + jogo.Name + ": ROM não achada; pasta de instalação (" + jogo.InstallDirectory + ") deixada vazia, nada é apagado");
                    jogo.InstallDirectory = null;
                    api.Database.Games.Update(jogo);
                }
                else { log.Warn("Desinstalar a ROM de " + jogo.Name + ": ROM não achada, nada é apagado"); }
                api.Notifications.Add(new NotificationMessage("recomps-rom-" + jogo.Id, nome + ": não achei a ROM, nada foi apagado. Se precisar liberar espaço, avise o Neto.", NotificationType.Error));
            }
            catch (Exception e) { log.Error(e, "Falha ao proteger a ROM de " + jogo.Name); }
            // Como o ErroDownload do Jogos de PC, mas também no Desktop; uma mensagem por jogo de cada vez.
            var id = jogo.Id;
            lock (avisandoRom) { if (!avisandoRom.Add(id)) { return; } }
            api.MainView.UIDispatcher.BeginInvoke(new Action(() =>
            {
                try
                {
                    api.Dialogs.ShowMessage("Não achei a ROM de " + nome + " na pasta de jogos do emulador. Nada foi apagado.\n\nO Recomp e os seus saves continuam aqui.\n\n" +
                        "O Playnite pode mostrar outro erro sobre isso. Pode ignorar.\n\nSe precisar liberar espaço, avise o Neto.", "Desinstalar a ROM", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
                catch (Exception e) { log.Error(e, "Falha ao avisar que a ROM não foi achada"); }
                finally { lock (avisandoRom) { avisandoRom.Remove(id); } }
            }));
        }

        class ControleInstalar : InstallController
        {
            readonly PluginRecomps p; readonly JogoRecomp r;
            public ControleInstalar(PluginRecomps p, JogoRecomp r, Game jogo) : base(jogo) { this.p = p; this.r = r; Name = "Instalar o Recomp (versão nativa para PC)"; }
            public override void Install(InstallActionArgs args)
            {
                p.Instalar(r, Game);
                // Falhou (ex.: ISO sumiu): cancela, senão o Playnite marca o jogo como instalado sem nada para jogar.
                if (r.Instalado) { InvokeOnInstalled(new GameInstalledEventArgs()); }
                else { InvokeOnInstallationCancelled(new GameInstallationCancelledEventArgs()); }
            }
        }

        class ControleDesinstalar : UninstallController
        {
            readonly PluginRecomps p; readonly JogoRecomp r;
            public ControleDesinstalar(PluginRecomps p, JogoRecomp r, Game jogo) : base(jogo) { this.p = p; this.r = r; Name = "Remover o Recomp (guarda os saves)"; }
            public override void Uninstall(UninstallActionArgs args)
            {
                p.Desinstalar(r, Game);
                // Respondeu "Não" ou falhou: o SDK não tem "desinstalação cancelada", e avisar o fim marcaria o jogo
                // como desinstalado. A exceção faz o Playnite só desfazer o "desinstalando".
                if (r.Instalado) { throw new Exception("Remoção do Recomp cancelada; nada foi apagado."); }
                InvokeOnUninstalled(new GameUninstalledEventArgs());
            }
        }

        public override IEnumerable<GameMenuItem> GetGameMenuItems(GetGameMenuItemsArgs args)
        {
            if (args.Games.Count != 1) { yield break; }
            var r = Achar(args.Games[0]);
            if (r == null) { yield break; }
            var jogo = args.Games[0];
            if (r.Instalado)
            {
                yield return new GameMenuItem { MenuSection = "Recomp", Description = "Remover o Recomp (guarda os saves)", Action = a => Desinstalar(r, jogo) };
                // Com o recomp instalado o jogo já conta como instalado e o Playnite esconde o Instalar do RomM.
                // (plataforma sem emulador, como o Switch 2: não há para onde baixar)
                if (r.SemEmulador != true && !RomInstalada(jogo))
                {
                    yield return new GameMenuItem { MenuSection = "Recomp", Description = "Baixar também para o emulador", Action = a => InstalarEmulador(jogo) };
                }
            }
            var andamento = EmAndamento(r);
            if (!r.Instalado && andamento == null)
            {
                yield return new GameMenuItem { MenuSection = "Recomp", Description = "Instalar o Recomp", Action = a => Instalar(r, jogo) };
                // O botão da página do jogo (só no Fullscreen): esconder ou mostrar de novo, sem confirmação.
                if (api.ApplicationInfo.Mode == ApplicationMode.Fullscreen && RomInstalada(jogo))
                {
                    if (Dispensado(jogo.Id))
                    {
                        yield return new GameMenuItem { MenuSection = "Recomp", Description = "Mostrar o botão do Recomp", Action = a => Dispensar(jogo.Id, false) };
                    }
                    else
                    {
                        yield return new GameMenuItem { MenuSection = "Recomp", Description = "Não mostrar o botão do Recomp", Action = a => Dispensar(jogo.Id, true) };
                    }
                }
            }
            if (andamento != null && andamento.PodeCancelar)
            {
                yield return new GameMenuItem { MenuSection = "Recomp", Description = "Cancelar instalação do Recomp", Action = a => CancelarInstalacao(r, andamento) };
            }
            if (Directory.Exists(r.Pasta))
            {
                yield return new GameMenuItem { MenuSection = "Recomp", Description = "Abrir pasta do Recomp", Action = a => Process.Start("explorer.exe", "\"" + r.Pasta + "\"") };
            }
        }

        // Jogos em que a pessoa pediu "Não mostrar o botão do Recomp" (aviso-recomp-dispensado.json, lido uma vez).
        HashSet<Guid> dispensados;
        readonly object travaDispensados = new object();

        string ArquivoDispensados { get { return Path.Combine(GetPluginUserDataPath(), "aviso-recomp-dispensado.json"); } }

        bool Dispensado(Guid jogo)
        {
            lock (travaDispensados)
            {
                if (dispensados == null) { dispensados = BotaoRecompSelene.LerDispensados(ArquivoDispensados); }
                return dispensados.Contains(jogo);
            }
        }

        void Dispensar(Guid jogo, bool esconder)
        {
            try
            {
                lock (travaDispensados)
                {
                    if (dispensados == null) { dispensados = BotaoRecompSelene.LerDispensados(ArquivoDispensados); }
                    if (esconder) { dispensados.Add(jogo); } else { dispensados.Remove(jogo); }
                    BotaoRecompSelene.GravarDispensados(ArquivoDispensados, dispensados);
                }
            }
            catch (Exception e) { log.Error(e, "Recomps: falha ao gravar o botão do Recomp dispensado"); }
            BotaoRecompSelene.Invalidar();
        }

        // A conta do botão "Instalar o Recomp" da página do jogo (o BotaoRecompSelene guarda o resultado; não roda a cada tick).
        bool BotaoAplica(Game jogo)
        {
            var r = Achar(jogo);
            var ocupado = r != null && (EmAndamento(r) != null || Verificando(r.Id));
            var possivel = r != null && !r.Instalado && !ocupado;
            return BotaoRecompSelene.Visivel(api.ApplicationInfo.Mode == ApplicationMode.Fullscreen, r != null, possivel && RomInstalada(jogo),
                r != null && r.Instalado, ocupado, possivel && Dispensado(jogo.Id));
        }

        // Recomps na verificação/confirmação (antes do andamento existir): o menu e o botão não abrem outra no meio.
        static readonly HashSet<string> verificando = new HashSet<string>();

        static bool Verificando(string id) { lock (verificando) { return verificando.Contains(id); } }

        bool InstalarPeloBotao(Game jogo, Action depoisDoSim)
        {
            var r = Achar(jogo);
            return r != null && Instalar(r, jogo, depoisDoSim);
        }

        Andamento EmAndamento(JogoRecomp r)
        {
            Andamento andamento;
            lock (andamentos) { andamentos.TryGetValue(r.Id, out andamento); }
            return andamento;
        }

        // Diz se o Recomp ficou instalado. depoisDoSim (o botão da página do jogo) roda logo depois do "Sim", antes de instalar.
        bool Instalar(JogoRecomp r, Game jogo, Action depoisDoSim = null)
        {
            // Antes das instruções abaixo, que não fazem sentido para quem já está instalando.
            if (EmAndamento(r) != null) { JaInstalando(r); return false; }
            lock (verificando)
            {
                if (!verificando.Add(r.Id)) { JaInstalando(r); return false; }
            }
            try
            {
                if (!VerificarEConfirmar(r, jogo)) { return false; }
            }
            finally { lock (verificando) { verificando.Remove(r.Id); } }
            if (depoisDoSim != null)
            {
                try { depoisDoSim(); } catch (Exception e) { log.Error(e, "Recomps: falha depois do Sim"); }
            }
            // Todos instalam sem tela (o recomp.ps1 usa o modo de linha de comando de cada um).
            var ok = ExecutarInstalar(r);
            Acertar(jogo.Id);
            return ok;
        }

        // Antes de qualquer download (R9): o recomp.ps1 diz o que falta e quanto espaço vai usar. Faltando
        // algo, uma mensagem só com tudo; senão pede a confirmação. Diz se pode instalar.
        bool VerificarEConfirmar(JogoRecomp r, Game jogo)
        {
            var faltas = new List<string>();
            long precisa = 0, livre = 0;
            string drive = "", fim = null;
            Exception erro = null;
            ProgressoSemModal(() =>
            {
                string arquivo = null;
                try
                {
                    var info = new ProcessStartInfo(PowerShell, ArgumentosScript("verificar", r, out arquivo))
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        StandardOutputEncoding = Encoding.UTF8
                    };
                    using (var p = Process.Start(info))
                    {
                        string linha;
                        while ((linha = p.StandardOutput.ReadLine()) != null)
                        {
                            if (linha.StartsWith("FALTA: ")) { faltas.Add(linha.Substring(7).Trim()); }
                            else if (linha.StartsWith("ESPACO: "))
                            {
                                var partes = linha.Substring(8).Split(' ');
                                if (partes.Length == 3) { long.TryParse(partes[0], out precisa); long.TryParse(partes[1], out livre); drive = partes[2]; }
                            }
                            else if (linha.StartsWith("OK: ") || linha.StartsWith("ERRO: ")) { fim = linha; }
                        }
                        p.WaitForExit();
                    }
                }
                catch (Exception e) { erro = e; }
                finally { Apagar(arquivo); }
            }, new GlobalProgressOptions(Titulo(r.Nome) + " - Recomp: preparando", false) { IsIndeterminate = true });
            log.Info("recomp verificar " + r.Id + ": " + (fim ?? "(sem resultado)") + (faltas.Count > 0 ? " falta " + string.Join(", ", faltas) : ""));

            if (fim == null || !fim.StartsWith("OK: "))
            {
                MostrarErro(r, fim != null ? fim.Substring(fim.IndexOf(' ') + 1) : erro != null ? erro.Message : "O script terminou sem dizer o resultado.");
                return false;
            }
            if (faltas.Count > 0)
            {
                api.Dialogs.ShowMessage(TextosRecomp.Faltas(faltas, r, precisa, livre, drive),
                    "Instalar o Recomp", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
            var texto = "Instalar o Recomp de " + r.Nome + "?\n\nVai usar cerca de " + Gb(precisa) + " GB em " + drive + ".";
            if (jogo != null && RomInstalada(jogo))
            {
                texto += "\n\nA ROM do emulador continua aqui. Depois, ao jogar, você escolhe entre o Recomp e o emulador.";
            }
            if (r.Tipo == "infamous2")
            {
                texto += "\n\nNo meio da instalação o Windows vai pedir permissão. Essa janela não aceita o controle: escolha Sim com o mouse ou aperte Alt+S.";
            }
            else if (r.Tipo == "totk")
            {
                texto += "\n\nA instalação do TotK recompila o jogo no seu PC e pode levar mais de 1 hora.";
            }
            if (!string.IsNullOrWhiteSpace(r.AvisoInstalar)) { texto += "\n\n" + r.AvisoInstalar.Trim(); }
            return api.Dialogs.ShowMessage(texto, "Instalar o Recomp", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
        }

        // Regra 18: no Fullscreen o progresso só abre se o Selene for mostrar como card (a mesma conta do card do Jogos de PC);
        // senão a verificação roda sem progresso na tela, com a interface viva, e nunca abre a janela modal do Playnite.
        void ProgressoSemModal(Action trabalho, GlobalProgressOptions opcoes)
        {
            if (api.ApplicationInfo.Mode != ApplicationMode.Fullscreen || CardSelene.PodeAbrir(opcoes))
            {
                api.Dialogs.ActivateGlobalProgress(a => trabalho(), opcoes);
                return;
            }
            log.Info("Recomps: o Selene não mostraria o card agora; verificando sem progresso na tela");
            var ui = Application.Current == null ? null : Application.Current.Dispatcher;
            if (ui == null || !ui.CheckAccess()) { trabalho(); return; }
            var quadro = new System.Windows.Threading.DispatcherFrame();
            System.Threading.Tasks.Task.Factory.StartNew(trabalho).ContinueWith(t => { quadro.Continue = false; });
            System.Windows.Threading.Dispatcher.PushFrame(quadro);
        }

        static string PowerShell { get { return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"); } }

        static string Aspas(string s) { return "\"" + Regex.Replace(s, @"\\+$", m => m.Value + m.Value) + "\""; }

        // Grava o catálogo resolvido num JSON temporário para o recomp.ps1 (a junção com o
        // recomps-local.json fica só aqui) e devolve os argumentos do powershell.exe.
        static string ArgumentosScript(string acao, JogoRecomp r, out string arquivo)
        {
            var cfg = Ler();
            arquivo = Path.Combine(Path.GetTempPath(), "recomps-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".json");
            File.WriteAllText(arquivo, Serialization.ToJson(cfg, true), new UTF8Encoding(false));
            return "-NoProfile -ExecutionPolicy Bypass -File " + Aspas(Path.Combine(cfg.Base ?? "", "programa", "recomp.ps1")) + " -Acao " + acao + " -Id " + r.Id +
                " -Config " + Aspas(arquivo) + " -Base " + Aspas(cfg.Base ?? "");
        }

        static void Apagar(string arquivo)
        {
            if (arquivo == null) { return; }
            try { File.Delete(arquivo); } catch (Exception e) { log.Warn(e, "Recomps: não apaguei " + arquivo); }
        }

        void JaInstalando(JogoRecomp r)
        {
            api.Dialogs.ShowMessage("O Recomp de " + r.Nome + " já está sendo instalado.", "Recomp: " + r.Nome);
        }

        void CancelarInstalacao(JogoRecomp r, Andamento andamento)
        {
            var resp = api.Dialogs.ShowMessage("Cancelar a instalação do Recomp de " + r.Nome + "?\n\nO Recomp não fica instalado. Seus saves não são afetados.",
                "Cancelar instalação do Recomp", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (resp == MessageBoxResult.Yes) { CancelarOuAvisar(andamento); }
        }

        // O "Sim" pode chegar depois que a etapa mudou (os instaladores externos não são mortos).
        void CancelarOuAvisar(Andamento andamento)
        {
            if (andamento.Cancelar() || andamento.Cancelado) { return; }
            api.Dialogs.ShowMessage("Não dá mais para cancelar: a instalação já passou dessa etapa.", "Cancelar instalação do Recomp");
        }

        void Desinstalar(JogoRecomp r, Game jogo)
        {
            var extra = string.IsNullOrEmpty(r.Disco) ? "" : " e a cópia do disco em " + r.Disco;
            var resp = api.Dialogs.ShowMessage("Remover o Recomp de " + r.Nome + "?\n\nApaga " + r.Pasta + extra +
                ". Os saves e as configurações ficam guardados e voltam se você instalar de novo. O jogo no emulador não muda.",
                "Recomp: " + r.Nome, MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (resp != MessageBoxResult.Yes) { return; }
            Executar("desinstalar", r);
            Acertar(jogo.Id);
        }

        // A ROM que o RomM baixou para o emulador (ele limpa a lista ao desinstalar), ou a pasta dela.
        // Com a lista de ROMs preenchida só o arquivo exato vale (um download interrompido deixa só o .parcial),
        // achado mesmo com a pasta de instalação vazia ou errada (PastaRom.ResolverRom).
        bool RomInstalada(Game jogo)
        {
            var roms = jogo.Roms == null ? new List<GameRom>() : jogo.Roms.Where(x => !string.IsNullOrEmpty(x.Path)).ToList();
            var r = Achar(jogo);
            if (roms.Count > 0) { return PastaRom.ResolverRom(jogo, r, LerMapeamentosRomm()) != null; }
            var dir = string.IsNullOrEmpty(jogo.InstallDirectory) ? null : api.ExpandGameVariables(jogo, jogo.InstallDirectory);
            return dir != null && Directory.Exists(dir) &&
                Directory.EnumerateFiles(dir).Any(f => !f.EndsWith(".parcial", StringComparison.OrdinalIgnoreCase)) &&
                (r == null || !PastaRom.PastaDeRecomp(dir, r));
        }

        // As pastas de jogos do emulador do plugin do RomM ({PlayniteDir} expandido). Sem o config.json, ou ilegível,
        // lista vazia e um aviso só no log (regra 14): aí nenhuma pasta de ROM é aceita e nada é apagado.
        List<MapeamentoRomm> LerMapeamentosRomm()
        {
            try
            {
                var arq = Path.Combine(api.Paths.ExtensionsDataPath, PluginRomm.ToString(), "config.json");
                if (!File.Exists(arq)) { return new List<MapeamentoRomm>(); }
                var cfg = Serialization.FromJson<ConfigRomm>(File.ReadAllText(arq, Encoding.UTF8));
                var lista = cfg == null || cfg.Mappings == null ? new List<MapeamentoRomm>() : cfg.Mappings.Where(m => m != null && !string.IsNullOrEmpty(m.DestinationPath)).ToList();
                foreach (var m in lista) { m.DestinationPath = m.DestinationPath.Replace("{PlayniteDir}", api.Paths.ApplicationPath); }
                return lista;
            }
            catch (Exception e)
            {
                if (Interlocked.Exchange(ref avisouRomm, 1) == 0) { log.Warn(e, "Recomps: config.json do RomM ilegível"); }
                return new List<MapeamentoRomm>();
            }
        }

        // "{InstallDir}\arquivo" (o RomM grava assim) vira o caminho absoluto da ROM achada, para o jogo não depender da
        // pasta de instalação estar certa. Diz se mudou; quem chama grava.
        static bool NormalizarRoms(Game jogo, JogoRecomp r, List<MapeamentoRomm> mapas)
        {
            if (jogo.Roms == null) { return false; }
            var mudou = false;
            foreach (var x in jogo.Roms.Where(x => x != null && !string.IsNullOrEmpty(x.Path) && PastaRom.Normalizar(x.Path) == null).ToList())
            {
                var c = PastaRom.ResolverCaminho(x.Path, jogo.InstallDirectory, mapas, r);
                string motivo;
                if (c == null || !PastaRom.PastaRomSegura(Path.GetDirectoryName(c), c, mapas, r, out motivo)) { continue; }
                log.Info("ROM de " + jogo.Name + ": " + x.Path + " -> " + c);
                x.Path = c;
                mudou = true;
            }
            return mudou;
        }

        // Só oferece jogar pelo emulador quando a ROM está lá; o recomp já só aparece quando instalado.
        bool AjustarAcoesEmulador(Game jogo)
        {
            if (jogo.GameActions == null) { return false; }
            var tem = RomInstalada(jogo);
            var mudou = false;
            foreach (var a in jogo.GameActions.Where(x => x.Type == GameActionType.Emulator && x.IsPlayAction != tem))
            {
                a.IsPlayAction = tem;
                mudou = true;
            }
            return mudou;
        }

        // O jogo conta como instalado se tiver o recomp ou a ROM, venha a mudança de onde vier.
        void Acertar(Guid id)
        {
            var jogo = api.Database.Games.Get(id);
            var r = jogo == null ? null : Achar(jogo);
            if (r == null) { return; }
            // (antes de esvaziar a pasta sumida: o Remover do Recomp limpa a pasta de instalação, e ela volta para a da ROM)
            var mapas = LerMapeamentosRomm();
            var mudou = NormalizarRoms(jogo, r, mapas);
            if (CorrigirPastaDeInstalacao(jogo, r, mapas)) { mudou = true; }
            var deve = r.Instalado || RomInstalada(jogo);
            if (AjustarAcoesEmulador(jogo)) { mudou = true; }
            if (EsvaziarPastaSumida(jogo, r)) { mudou = true; }
            if (jogo.IsInstalled != deve) { jogo.IsInstalled = deve; mudou = true; }
            if (mudou) { api.Database.Games.Update(jogo); }
        }

        // O Selene Core marca "não instalado" todo jogo cuja pasta de instalação não existe ("game folder gone").
        // Com o Recomp instalado e a ROM ainda não baixada, essa pasta é a da ROM e não existe: sem pasta, o
        // Selene deixa o jogo em paz (e o Desinstalar do RomM falha sem apagar nada). Diz se mudou.
        bool EsvaziarPastaSumida(Game jogo, JogoRecomp r)
        {
            if (!r.Instalado || string.IsNullOrEmpty(jogo.InstallDirectory)) { return false; }
            var dir = api.ExpandGameVariables(jogo, jogo.InstallDirectory);
            if (string.IsNullOrEmpty(dir) || Directory.Exists(dir)) { return false; }
            // Como o Selene: com o drive fora do ar (rede caída) não se sabe se a pasta sumiu; não mexe.
            var raiz = Path.GetPathRoot(dir);
            if (string.IsNullOrEmpty(raiz) || !Directory.Exists(raiz)) { return false; }
            log.Info("Pasta de instalação de " + jogo.Name + " não existe (" + dir + ") e o Recomp está instalado: deixada vazia");
            jogo.InstallDirectory = null;
            return true;
        }

        // Com o recomp instalado o Playnite não mostra o Instalar: desmarca e pede a instalação, que aí só tem a do RomM.
        void InstalarEmulador(Game jogo)
        {
            var r = Achar(jogo);
            if (r != null && r.SemEmulador == true) { return; }
            jogo.IsInstalled = false;
            api.Database.Games.Update(jogo);
            api.InstallGame(jogo.Id);
        }

        // O Playnite grava o próprio "instalado/desinstalado" depois de avisar os plugins: acerta na volta do dispatcher.
        void AcertarDepois(Guid id)
        {
            api.MainView.UIDispatcher.BeginInvoke(new Action(() =>
            {
                try { Acertar(id); } catch (Exception e) { log.Error(e, "Acertar " + id); }
            }), System.Windows.Threading.DispatcherPriority.Background);
        }

        public override void OnGameInstalled(OnGameInstalledEventArgs args) { AcertarDepois(args.Game.Id); BotaoRecompSelene.Invalidar(); }

        public override void OnGameUninstalled(OnGameUninstalledEventArgs args) { AcertarDepois(args.Game.Id); BotaoRecompSelene.Invalidar(); }

        public override void OnGameStopped(OnGameStoppedEventArgs args)
        {
            var r = Achar(args.Game);
            if (r != null) { ProtegerPasta(args.Game, r, false); }
        }

        bool Executar(string acao, JogoRecomp r)
        {
            string fim = null;
            api.Dialogs.ActivateGlobalProgress(a =>
            {
                string arquivo = null;
                try
                {
                    var info = new ProcessStartInfo(PowerShell, ArgumentosScript(acao, r, out arquivo))
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        StandardOutputEncoding = Encoding.UTF8
                    };
                    using (var p = Process.Start(info))
                    {
                        string linha;
                        while ((linha = p.StandardOutput.ReadLine()) != null)
                        {
                            if (linha.StartsWith("ETAPA: ")) { a.Text = r.Nome + ": " + linha.Substring(7); }
                            else if (linha.StartsWith("OK: ") || linha.StartsWith("ERRO: ")) { fim = linha; }
                        }
                        p.WaitForExit();
                    }
                }
                finally { Apagar(arquivo); }
            }, new GlobalProgressOptions((acao == "instalar" ? "Instalando" : "Desinstalando") + " o Recomp de " + r.Nome, false) { IsIndeterminate = true });

            var ok = fim != null && fim.StartsWith("OK: ");
            var texto = fim == null ? "O script terminou sem dizer o resultado." : fim.Substring(fim.IndexOf(' ') + 1);
            log.Info("recomp " + acao + " " + r.Id + ": " + (fim ?? "(sem resultado)"));
            api.Dialogs.ShowMessage(texto, "Recomp: " + r.Nome, MessageBoxButton.OK, ok ? MessageBoxImage.Information : MessageBoxImage.Error);
            return ok;
        }

        // Uma instalação em andamento: o processo do recomp.ps1 e a etapa, para cancelar só enquanto baixa ou extrai.
        class Andamento
        {
            readonly object trava = new object();
            Process proc;
            string etapa = "preparando";
            public volatile bool Cancelado;
            // Id da tarefa no Jogos de PC (null sem ele).
            public volatile string Id;

            public bool PodeCancelar { get { lock (trava) { return proc != null && !Cancelado && (etapa == "baixando" || etapa == "extraindo"); } } }
            public void Iniciou(Process p) { lock (trava) { proc = p; } }
            public void Etapa(string e) { lock (trava) { etapa = e; } }

            // Mata a árvore do recomp.ps1, como o Jogos de PC faz com os workers. Os instaladores externos
            // só rodam nas outras etapas, então nunca são mortos. Não apaga nada. Diz se cancelou.
            public bool Cancelar()
            {
                lock (trava)
                {
                    if (proc == null || Cancelado || (etapa != "baixando" && etapa != "extraindo")) { return false; }
                    Cancelado = true;
                    // Tira o "Cancelar" do menu do Jogos de PC na hora.
                    TarefasJogosPc.PodeCancelar(Id, null);
                    try
                    {
                        if (!proc.HasExited) { Process.Start(new ProcessStartInfo("taskkill.exe", "/T /F /PID " + proc.Id) { UseShellExecute = false, CreateNoWindow = true }); }
                    }
                    catch (Exception e) { log.Error(e, "Falha ao cancelar a instalação do Recomp"); }
                    return true;
                }
            }
        }

        static readonly Dictionary<string, Andamento> andamentos = new Dictionary<string, Andamento>();
        static readonly CultureInfo Br = new CultureInfo("pt-BR");

        // Instalar com o andamento no card do Selene: "<Nome> - Recomp: <etapa> ...". Cada etapa tem uma
        // forma só do começo ao fim, porque o Selene troca o card quando muda o texto sem os números.
        bool ExecutarInstalar(JogoRecomp r)
        {
            string fim = null, motivo = null;
            var mostrouErro = false;
            // "AVISO: shaders" do recomp.ps1: instalou, mas os shaders ficam para a 1ª vez que o jogo abrir.
            var semShaders = false;
            var andamento = new Andamento();
            var jaHavia = false;
            lock (andamentos)
            {
                if (andamentos.ContainsKey(r.Id)) { jaHavia = true; }
                else { andamentos[r.Id] = andamento; }
            }
            if (jaHavia) { JaInstalando(r); return false; }
            var telaCheia = api.ApplicationInfo.Mode == ApplicationMode.Fullscreen;
            var titulo = Titulo(r.Nome);
            Action<GlobalProgressActionArgs> tarefa = a =>
            {
                var id = TarefasJogosPc.Abrir(r.Nome, a);
                andamento.Id = id;
                string arquivo = null;
                try
                {
                    var etapa = "preparando";
                    long feito = 0, total = 0, anterior = 0, quando = 0;
                    int passo = 0, passos = 0;
                    double velocidade = 0;
                    var relogio = Stopwatch.StartNew();
                    Action mostrar = () =>
                    {
                        a.Text = titulo + " - " + TextoEtapa(etapa, feito, total, velocidade, passo, passos);
                        a.IsIndeterminate = total <= 0;
                        if (total > 0) { a.ProgressMaxValue = 100; a.CurrentProgressValue = Math.Min(feito, total) * 100.0 / total; }
                    };
                    var info = new ProcessStartInfo(PowerShell, ArgumentosScript("instalar", r, out arquivo))
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        StandardOutputEncoding = Encoding.UTF8
                    };
                    using (var p = Process.Start(info))
                    {
                        andamento.Iniciou(p);
                        string linha;
                        while ((linha = p.StandardOutput.ReadLine()) != null)
                        {
                            if (linha.StartsWith("ETAPA: "))
                            {
                                log.Info("recomp instalar " + r.Id + ": " + linha);
                                etapa = PalavraDaEtapa(linha.Substring(7));
                                PassoDaEtapa(linha.Substring(7), out passo, out passos);
                                feito = 0; total = 0; anterior = 0; velocidade = 0; quando = relogio.ElapsedMilliseconds;
                                andamento.Etapa(EtapaDeFato(etapa));
                                TarefasJogosPc.Atualizar(id, EtapaDeFato(etapa), 0, 0);
                                TarefasJogosPc.PodeCancelar(id, andamento.PodeCancelar ? (Action)(() => CancelarOuAvisar(andamento)) : null);
                                mostrar();
                            }
                            else if (linha.StartsWith("PROGRESSO: "))
                            {
                                var partes = linha.Substring(11).Split(' ');
                                long f, t;
                                if (partes.Length != 2 || !long.TryParse(partes[0], out f) || !long.TryParse(partes[1], out t)) { continue; }
                                // Velocidade (só o baixando mostra): média das últimas medidas de pelo menos 1 s.
                                var agora = relogio.ElapsedMilliseconds;
                                if (agora - quando >= 900 && f >= anterior)
                                {
                                    var medida = (f - anterior) * 1000.0 / (agora - quando);
                                    velocidade = velocidade <= 0 ? medida : velocidade * 0.7 + medida * 0.3;
                                    anterior = f; quando = agora;
                                }
                                feito = f; total = t;
                                TarefasJogosPc.Atualizar(id, EtapaDeFato(etapa), feito, total);
                                mostrar();
                            }
                            else if (linha.Trim() == "AVISO: shaders") { semShaders = true; }
                            else if (linha.StartsWith("OK: ") || linha.StartsWith("ERRO: ")) { fim = linha; }
                        }
                        p.WaitForExit();
                    }
                }
                finally
                {
                    Apagar(arquivo);
                    var deuCerto = fim != null && fim.StartsWith("OK: ");
                    TarefasJogosPc.Resultado(id, deuCerto ? "pronto" : andamento.Cancelado ? "cancelado" : "erro",
                        deuCerto || andamento.Cancelado ? null : fim == null ? "O script terminou sem dizer o resultado." : fim.Substring(fim.IndexOf(' ') + 1));
                    TarefasJogosPc.Fechar(id);
                    Soltar(r, andamento);
                }

                // Como terminou: 3 s no card; o erro fica 10 s, com a mensagem por cima na tela cheia. Instalado com os
                // shaders para depois: 6 s no card e uma notificação (sem janela), porque a 1ª abertura demora mais.
                a.IsIndeterminate = false;
                if (fim != null && fim.StartsWith("OK: ") && semShaders)
                {
                    a.ProgressMaxValue = 100; a.CurrentProgressValue = 100;
                    a.Text = titulo + " - Recomp instalado. Pronto para jogar (a 1ª abertura prepara os shaders)";
                    try
                    {
                        api.Notifications.Add(new NotificationMessage("recomps-shaders-" + r.Id, PastaRom.Nome(r.Nome) +
                            ": os shaders não foram preparados agora. O jogo prepara na primeira vez que abrir, então essa abertura demora mais. Não é um erro.", NotificationType.Info));
                    }
                    catch (Exception e) { log.Error(e, "Recomps: falha ao avisar dos shaders"); }
                    Thread.Sleep(6000);
                }
                else if (fim != null && fim.StartsWith("OK: "))
                {
                    a.ProgressMaxValue = 100; a.CurrentProgressValue = 100;
                    a.Text = titulo + " - Recomp instalado. Pronto para jogar";
                    Thread.Sleep(3000);
                }
                else if (andamento.Cancelado)
                {
                    a.Text = titulo + " - Recomp: instalação cancelada";
                    Thread.Sleep(3000);
                }
                else
                {
                    a.Text = titulo + " - O Recomp não foi instalado. Seus saves continuam guardados";
                    motivo = fim == null ? "O script terminou sem dizer o resultado." : fim.Substring(fim.IndexOf(' ') + 1);
                    if (telaCheia)
                    {
                        mostrouErro = true;
                        var m = motivo;
                        api.MainView.UIDispatcher.BeginInvoke(new Action(() => MostrarErro(r, m)));
                        Thread.Sleep(10000);
                    }
                }
            };
            GlobalProgressResult resultado;
            // Mesmo se o progresso falhar antes de rodar a tarefa, a instalação sai da lista (senão o
            // jogo ficaria "já está sendo instalado" até reabrir o Playnite).
            try { resultado = api.Dialogs.ActivateGlobalProgress(tarefa, new GlobalProgressOptions(titulo + " - Recomp: preparando", false) { IsIndeterminate = true }); }
            finally { Soltar(r, andamento); }

            var ok = fim != null && fim.StartsWith("OK: ");
            log.Info("recomp instalar " + r.Id + ": " + (fim ?? (andamento.Cancelado ? "(cancelado)" : "(sem resultado)")));
            if (!ok && !andamento.Cancelado && !mostrouErro)
            {
                if (motivo == null) { motivo = resultado != null && resultado.Error != null ? resultado.Error.Message : "O script terminou sem dizer o resultado."; }
                MostrarErro(r, motivo);
            }
            BotaoRecompSelene.Invalidar();
            return ok;
        }

        static void Soltar(JogoRecomp r, Andamento andamento)
        {
            lock (andamentos) { Andamento x; if (andamentos.TryGetValue(r.Id, out x) && x == andamento) { andamentos.Remove(r.Id); } }
        }

        void MostrarErro(JogoRecomp r, string motivo)
        {
            try
            {
                api.Dialogs.ShowMessage("O Recomp de " + r.Nome + " não foi instalado.\n\n" + motivo + "\n\nSeus saves continuam guardados. Para tentar de novo, escolha Instalar.",
                    "Recomp não instalado", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            catch (Exception e) { log.Error(e, "Falha ao avisar que o Recomp não foi instalado"); }
        }

        // Mesmas regras do card do Jogos de PC: título até 32 caracteres, " - " separa título e texto, e
        // "Closing", "Exiting" ou "Shutting" no texto fariam o Selene abrir a janela de progresso do Playnite.
        static string Titulo(string nome)
        {
            var n = (nome ?? "").Replace(" - ", " – ");
            n = Regex.Replace(n, "(?<=clos)(?=ing)|(?<=exit)(?=ing)|(?<=shut)(?=ting)", "​", RegexOptions.IgnoreCase);
            return n.Length > 32 ? n.Substring(0, 31) + "…" : n;
        }

        // "ETAPA: baixando: ..." -> baixando. Etapa sem uma das palavras do card conta como preparando.
        static string PalavraDaEtapa(string texto)
        {
            // (um preparando com texto próprio, que o Jogos de PC também conhece)
            if (texto.Trim() == "preparando: baixando um complemento do instalador") { return "complemento"; }
            var p = texto.Split(new[] { ':', ' ' }, 2)[0].Trim().ToLowerInvariant();
            // (conferindo: o Triforce conferindo a versão do jogo; um preparando com texto próprio)
            return p == "baixando" || p == "extraindo" || p == "instalando" || p == "compilando" || p == "conferindo" ? p : "preparando";
        }

        // "compilando: etapa 4 de 5: ..." -> 4 e 5 (0 e 0 sem esse trecho).
        static void PassoDaEtapa(string texto, out int passo, out int passos)
        {
            var m = Regex.Match(texto, @"\betapa (\d+) de (\d+)\b");
            passo = 0; passos = 0;
            if (m.Success) { int.TryParse(m.Groups[1].Value, out passo); int.TryParse(m.Groups[2].Value, out passos); }
        }

        // Compilando é uma instalação para o resto (sem cancelar; "Instalando" no Jogos de PC): só o card muda. Conferindo
        // é um preparando (o Jogos de PC não conhece a palavra).
        static string EtapaDeFato(string etapa) { return etapa == "compilando" ? "instalando" : etapa == "conferindo" ? "preparando" : etapa; }

        internal static string Gb(long b) { return (Math.Max(b, 0) / 1073741824.0).ToString("0.0", Br); }

        // Número desconhecido vira "...", para o texto sem os números não mudar.
        static string TextoEtapa(string etapa, long feito, long total, double velocidade, int passo, int passos)
        {
            var pct = total > 0 ? ((long)Math.Floor(Math.Min(Math.Max(feito, 0), total) * 100.0 / total)).ToString(Br) : "...";
            switch (etapa)
            {
                case "baixando":
                    var minutos = velocidade > 0 && total > 0 ? ((long)Math.Ceiling(Math.Max(total - feito, 0) / velocidade / 60)).ToString(Br) : "...";
                    var mbs = velocidade > 0 ? (velocidade / 1048576).ToString("0.0", Br) : "...";
                    return "Recomp: baixando " + pct + "% · " + Gb(feito) + "/" + (total > 0 ? Gb(total) : "...") + " GB · " + mbs + " MB/s · faltam " + minutos + " min";
                case "extraindo": return "Recomp: extraindo " + pct + "%";
                case "instalando": return total > 0 ? "Recomp: instalando " + pct + "%" : "Recomp: instalando";
                case "compilando":
                    return "Recomp: compilando " + pct + "% (etapa " + (passo > 0 ? passo.ToString(Br) : "...") + " de " + (passos > 0 ? passos.ToString(Br) : "...") + ")";
                case "complemento": return "Recomp: preparando · baixando um complemento do instalador";
                case "conferindo": return "Recomp: preparando · conferindo a versão do jogo";
                default: return "Recomp: preparando";
            }
        }

        // Tira as ações fixas da primeira versão (o plugin oferece o recomp agora) e marca como
        // instalado o jogo cujo recomp está pronto, mesmo que a biblioteca dele diga que não.
        void Sincronizar()
        {
            var cfg = Ler();
            if (cfg.Jogos.Count == 0) { return; }
            var mapas = LerMapeamentosRomm();
            foreach (var jogo in api.Database.Games.ToList())
            {
                var r = Achar(cfg, jogo);
                if (r == null) { continue; }
                var mudou = false;
                if (jogo.GameActions != null && jogo.GameActions.Any(x => x.Name == AcaoAntiga))
                {
                    jogo.GameActions = new System.Collections.ObjectModel.ObservableCollection<GameAction>(jogo.GameActions.Where(x => x.Name != AcaoAntiga));
                    mudou = true;
                }
                // (estado travado de versões antigas: pasta vazia ou da pasta do console, ROM em "{InstallDir}\...")
                if (NormalizarRoms(jogo, r, mapas)) { mudou = true; }
                if (CorrigirPastaDeInstalacao(jogo, r, mapas)) { mudou = true; }
                if (EsvaziarPastaSumida(jogo, r)) { mudou = true; }
                if (r.Instalado && !jogo.IsInstalled) { jogo.IsInstalled = true; mudou = true; }
                // Regra 6: sem Recomp e sem ROM, "não instalado" (uma remoção interrompida deixava o jogo
                // instalado com a pasta vazia, sem Jogar nem Instalar). Só com a pasta já vazia, nunca no meio de uma instalação.
                else if (!r.Instalado && jogo.IsInstalled && !jogo.IsInstalling && string.IsNullOrEmpty(jogo.InstallDirectory) && !RomInstalada(jogo) &&
                    !string.IsNullOrEmpty(r.Pasta) && Directory.Exists(Path.GetPathRoot(r.Pasta)))
                { jogo.IsInstalled = false; mudou = true; }
                if (AjustarAcoesEmulador(jogo)) { mudou = true; }
                if (mudou) { api.Database.Games.Update(jogo); }
            }
        }

        // O Desinstalar do RomM apaga a pasta de instalação do jogo inteira: ela nunca pode ser a do recomp.
        // O Selene grava como pasta de instalação a do exe que viu abrir, então isto roda também ao
        // fechar o jogo e antes de Instalar / Desinstalar. Diz se mudou; quem chama grava.
        // O Selene também grava a pasta do EMULADOR que viu abrir (Eden apagado em 2026-11-17), e o Remover do Recomp
        // deixa a pasta vazia: a pasta de instalação de um jogo com Recomp só pode ser a pasta segura da ROM
        // (PastaRom.PastaRomSegura), ou nada (sem pasta, o Desinstalar do RomM falha sem apagar nada).
        bool CorrigirPastaDeInstalacao(Game jogo, JogoRecomp r, List<MapeamentoRomm> mapas)
        {
            var rom = PastaRom.ResolverRom(jogo, r, mapas);
            string motivo = null;
            var segura = rom != null && PastaRom.PastaRomSegura(Path.GetDirectoryName(rom), rom, mapas, r, out motivo) ? PastaRom.Normalizar(Path.GetDirectoryName(rom)) : null;
            var atual = jogo.InstallDirectory;
            if (string.IsNullOrEmpty(atual))
            {
                if (segura == null) { return false; }
                log.Info("Pasta de instalação de " + jogo.Name + " estava vazia; reposta pela pasta da ROM (" + segura + ")");
                jogo.InstallDirectory = segura;
                return true;
            }
            string dir = null;
            try { dir = PastaRom.Normalizar(atual.Contains("{") ? api.ExpandGameVariables(jogo, atual) : atual); }
            catch (Exception) { dir = null; }
            if (dir == null)
            {
                log.Warn("Pasta de instalação de " + jogo.Name + " inválida (" + atual + "); trocada por " + (segura ?? "nada"));
                jogo.InstallDirectory = segura;
                return true;
            }
            if (segura != null)
            {
                if (string.Equals(dir, segura, StringComparison.OrdinalIgnoreCase)) { return false; }
                log.Warn("Pasta de instalação de " + jogo.Name + " não era a da ROM (" + atual + "); trocada por " + segura);
                jogo.InstallDirectory = segura;
                return true;
            }
            // Sem a ROM achada: a pasta fica se ainda é a de um jogo na pasta de jogos do emulador. Com o drive fora do
            // ar (rede caída) não dá para saber: não mexe.
            if (PastaRom.PastaSemRomSegura(dir, mapas, r, PastaRom.ArquivosDoJogo(jogo, r)) || !Directory.Exists(Path.GetPathRoot(dir))) { return false; }
            log.Warn("Pasta de instalação de " + jogo.Name + " não era a da ROM (" + atual + (rom != null ? "; ROM em " + rom + ": " + motivo : "") + "); trocada por nada");
            jogo.InstallDirectory = null;
            return true;
        }

        // fechar: no caminho do Desinstalar, uma falha aqui deixa a pasta de instalação vazia (o RomM falha sem apagar).
        void ProtegerPasta(Game jogo, JogoRecomp r, bool fechar)
        {
            var erro = PastaRom.Proteger(jogo, () =>
            {
                var mapas = LerMapeamentosRomm();
                var mudou = NormalizarRoms(jogo, r, mapas);
                if (CorrigirPastaDeInstalacao(jogo, r, mapas)) { mudou = true; }
                return mudou;
            }, () => api.Database.Games.Update(jogo), fechar);
            if (erro != null) { log.Error(erro, "Falha ao conferir a pasta de instalação de " + jogo.Name + (fechar ? "; deixada vazia" : "")); }
        }

        public override void OnApplicationStarted(OnApplicationStartedEventArgs args)
        {
            Sincronizar();
            SincronizarDepois();
            api.Database.Games.ItemUpdated += InstalacaoAcabou;
            if (api.ApplicationInfo.Mode == ApplicationMode.Fullscreen)
            {
                try { api.MainView.UIDispatcher.Invoke(new Action(() => BotaoRecompSelene.Iniciar(api, BotaoAplica, InstalarPeloBotao))); }
                catch (Exception e) { log.Error(e, "Recomps: falha ao iniciar o botão do Recomp"); }
            }
        }

        public override void OnGameSelected(OnGameSelectedEventArgs args) { BotaoRecompSelene.Invalidar(); }

        // "Baixar também para o emulador" desmarca o instalado; cancelada ou com erro, a instalação da ROM não avisa
        // os plugins e o jogo ficaria "não instalado" com o Recomp instalado. Só na passagem de instalando para não
        // instalando (o Acertar não mexe no instalando: não volta aqui).
        void InstalacaoAcabou(object sender, ItemUpdatedEventArgs<Game> e)
        {
            try
            {
                foreach (var u in e.UpdatedItems)
                {
                    if (u.OldData == null || u.NewData == null || !u.OldData.IsInstalling || u.NewData.IsInstalling) { continue; }
                    if (Achar(u.NewData) != null) { AcertarDepois(u.NewData.Id); BotaoRecompSelene.Invalidar(); }
                }
            }
            catch (Exception ex) { log.Error(ex, "Recomps: falha ao conferir o fim de uma instalação"); }
        }

        public override void OnLibraryUpdated(OnLibraryUpdatedEventArgs args) { Sincronizar(); SincronizarDepois(); }

        // O Selene confere as pastas na abertura e depois da atualização da biblioteca, às vezes depois de nós:
        // uma segunda passada alguns segundos depois desfaz um "não instalado" que ele tenha marcado.
        void SincronizarDepois()
        {
            var t = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background, api.MainView.UIDispatcher) { Interval = TimeSpan.FromSeconds(8) };
            t.Tick += (s, e) =>
            {
                t.Stop();
                try { Sincronizar(); } catch (Exception ex) { log.Error(ex, "Sincronizar depois"); }
            };
            t.Start();
        }
    }
}
