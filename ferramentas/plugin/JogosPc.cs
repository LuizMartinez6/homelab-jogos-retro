// Biblioteca "Jogos de PC" do Playnite: lista o catalogo do servidor e da aos jogos os
// botoes Instalar, Jogar e Desinstalar. O trabalho de instalar fica no jogos-pc-worker.ps1.
// Compilado com o csc do .NET Framework (C# 5).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Threading;
using System.Windows.Threading;
using Playnite.SDK;
using Playnite.SDK.Data;
using Playnite.SDK.Events;
using Playnite.SDK.Models;
using Playnite.SDK.Plugins;

namespace JogosPc
{
    // Um download em andamento, na fila ou pausado. So um roda por vez, na ordem de chegada; pausar libera a vez.
    public class Execucao
    {
        readonly IPlayniteAPI api;
        readonly ManualResetEvent terminou = new ManualResetEvent(false);
        // Setado no Cancelar/Encerrar: acorda quem espera o servidor (Consultar).
        readonly ManualResetEvent cancelou = new ManualResetEvent(false);
        // "Conferir Cancelado + iniciar o worker" e "matar o worker" nunca se cruzam.
        readonly object travaProc = new object();
        Func<Process> iniciar;
        string arqProgresso;
        volatile bool pedirPausa;
        volatile Process proc;
        volatile bool temVez;
        // 1 depois do Finalizar: o fim acontece uma vez so, venha de onde vier.
        int finalizado;
        volatile bool iniciouWorker;
        DateTime canceladoEm = DateTime.MinValue, matouEm = DateTime.MinValue;

        public readonly Guid JogoId;
        // "pc" (jogos-pc-worker) ou "rom" (baixar-worker).
        public readonly string Tipo;
        public readonly string Nome;
        // Jogo de PC: o id do catalogo (pasta _baixando\<id>).
        public string IdCatalogo;
        public volatile bool Pausado;
        public volatile bool Cancelado;
        // Cancelado pela tela ou pelo menu, e nao pelo fechamento do Playnite: o que baixou vai para "Pela metade".
        public volatile bool PeloUsuario;
        public volatile Progresso Atual;
        // Lugar na fila (Gerenciador): menor vai antes.
        public long Seq;
        // So ROM: o arquivo final e o .parcial que o baixar-worker grava.
        public volatile string Destino, Parcial;
        // Antes de o worker escrever o progresso: o que ja esta no disco e o tamanho do jogo, se souber.
        public long JaTem, Tamanho;
        // Ate quando o Dispose do controller nao cancela: outro Instalar do mesmo jogo troca o controller.
        public DateTime ProtegidoAte;
        public volatile Progresso Resultado;
        // Jogo de PC: o nome no catalogo, o mesmo que o worker manda ao painel.
        public string NomeCatalogo;
        // Cancelado, o worker nao saiu em 10 s: o fim veio sem ele (vai para "Pela metade" com esse aviso).
        public volatile bool DemorouParar;

        public Execucao(IPlayniteAPI api, Guid jogoId, string tipo, string nome)
        {
            this.api = api; JogoId = jogoId; Tipo = tipo; Nome = nome;
        }

        public bool NaFila { get { return !temVez && !Pausado; } }
        public bool PodePausar { get { return temVez ? (Atual == null || Atual.estado != "instalando") : Pausado; } }
        public string Situacao { get { return Pausado ? "pausado" : Instalando ? "instalando" : "fila"; } }

        // Na hora do Instalar, antes de ir a rede: a vaga na fila e a linha na tela ja aparecem.
        public void Registrar()
        {
            Gerenciador.Entrar(this);
            Tarefas.Entrar(this);
            FilaSalva.Mudou(this);
        }

        // Falhou ou foi cancelado antes de comecar a baixar (servidor fora do ar, catalogo...).
        public void Falhar(string motivo)
        {
            var fim = Cancelado ? "cancelado" : "erro";
            Finalizar(fim, null, fim == "erro" ? motivo : null);
        }

        // O fim do download, uma vez so: solta a vez, sai da fila, mostra como terminou e grava. Cancelado sem nada no
        // disco aparece como "cancelado-nada" no card e na tela. Diz se foi esta chamada que finalizou.
        public bool Finalizar(string fim, Progresso r, string motivo)
        {
            if (Interlocked.Exchange(ref finalizado, 1) != 0) { return false; }
            var etapa = fim == "cancelado" && !FilaSalva.AlgoNoDisco(this) ? "cancelado-nada" : fim;
            SoltarVez();
            Gerenciador.Sair(this);
            Tarefas.Terminar(this, etapa, motivo);
            try { if (api != null) { Barra.Esconder(api); } } catch (Exception e) { LogManager.GetLogger().Warn(e, "Falha ao esconder a barra"); }
            // O worker morto nao avisa o painel: o fim vai daqui (o fechamento do Playnite nao e fim).
            if (fim == "cancelado" && iniciouWorker && !Gerenciador.Encerrando) { RelatoPainel.Cancelado(this); }
            Acabou(fim, r);
            return true;
        }

        void Acabou(string fim, Progresso r)
        {
            Resultado = r;
            FilaSalva.Terminou(this, fim);
            terminou.Set();
        }

        // Para outro controller do mesmo jogo acompanhar este download ate o fim.
        public Progresso Esperar() { terminou.WaitOne(); return Resultado; }

        // Uma consulta ao servidor antes de baixar (catalogo, endereco, dados da ROM), que pode demorar ate o timeout.
        // Cancelar nao espera por ela: sai na hora com OperationCanceledException, e a consulta termina sozinha.
        public T Consultar<T>(Func<T> consulta)
        {
            if (Cancelado) { throw new OperationCanceledException(); }
            var t = Task.Run(consulta);
            if (WaitHandle.WaitAny(new WaitHandle[] { ((IAsyncResult)t).AsyncWaitHandle, cancelou }) == 1 && !t.IsCompleted)
            {
                // (o erro dela, se vier, nao derruba nada)
                t.ContinueWith(x => { var ignorado = x.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                throw new OperationCanceledException();
            }
            return t.GetAwaiter().GetResult();
        }

        // Um worker anterior do mesmo jogo ainda segura o arquivo (cancelado que "demorou para parar", sessao anterior):
        // espera ele soltar antes de abrir outro no mesmo .parcial / _baixando. Cancelar sai na hora.
        public void EsperarLivre(string trava)
        {
            if (string.IsNullOrEmpty(trava) || !Descarte.EmUso(trava)) { return; }
            LogManager.GetLogger().Info("Download de " + Nome + ": esperando o worker anterior soltar " + trava);
            while (Descarte.EmUso(trava))
            {
                if (Cancelado || cancelou.WaitOne(2000)) { throw new OperationCanceledException(); }
            }
        }

        bool EsperarVez()
        {
            if (!Gerenciador.EsperarVez(this)) { return false; }
            temVez = true;
            return true;
        }

        void SoltarVez() { if (temVez) { temVez = false; Gerenciador.Soltar(this); } }

        // taskkill na arvore do worker; com forte, tambem mata o processo direto (taskkill pode falhar calado).
        void Matar(bool forte)
        {
            lock (travaProc)
            {
                matouEm = DateTime.Now;
                var p = proc;
                if (p == null) { return; }
                try { if (!p.HasExited) { Process.Start(new ProcessStartInfo("taskkill.exe", "/T /F /PID " + p.Id) { UseShellExecute = false, CreateNoWindow = true }); } }
                catch (Exception e) { LogManager.GetLogger().Warn(e, "taskkill no download de " + Nome); }
                if (!forte) { return; }
                try { if (!p.HasExited) { p.Kill(); } }
                catch (Exception e) { LogManager.GetLogger().Warn(e, "Kill no download de " + Nome); }
            }
        }

        public Progresso Rodar(string arqProgresso, Func<Process> iniciar)
        {
            this.arqProgresso = arqProgresso; this.iniciar = iniciar;
            CartaoSelene.Garantir(api);
            // Como terminou, para o card e o indicador do topo: pronto, cancelado ou erro.
            var fim = "erro";
            string motivo = null;
            Progresso r = null;
            try
            {
                if (!EsperarVez()) { fim = "cancelado"; return null; }
                while (true)
                {
                    // (o Cancelar pode chegar entre a vez e o worker abrir: nunca abre um worker ja cancelado)
                    lock (travaProc)
                    {
                        if (Cancelado) { fim = "cancelado"; return null; }
                        proc = this.iniciar();
                        iniciouWorker = true;
                    }
                    while (!proc.WaitForExit(1000))
                    {
                        // O card e o indicador do topo leem o Atual pelas Tarefas; a barra e so do Desktop.
                        var p = InstaladorJogo.LerProgresso(this.arqProgresso);
                        if (p != null)
                        {
                            var antes = Atual;
                            Atual = p;
                            // Instalando nao continua sozinho ao abrir de novo (o Windows pede permissao).
                            if (p.estado == "instalando" && (antes == null || antes.estado != "instalando")) { FilaSalva.Mudou(this); }
                            if (api.ApplicationInfo.Mode == ApplicationMode.Desktop) { Barra.Mostrar(api, Nome, p); }
                        }
                        // Cancelado e o worker continua (taskkill que falhou): mata de novo a cada 3 s e desiste em 10 s.
                        // Nunca na instalacao, que vai ate o fim.
                        if (!Cancelado || InstalandoAgora()) { continue; }
                        var desde = canceladoEm == DateTime.MinValue ? DateTime.Now : canceladoEm;
                        if ((DateTime.Now - desde).TotalSeconds >= 10)
                        {
                            DemorouParar = true;
                            LogManager.GetLogger().Warn("Download de " + Nome + " cancelado: o worker (PID " + proc.Id + ") nao parou em 10 s; o download foi dado como cancelado");
                            r = InstaladorJogo.LerProgresso(this.arqProgresso);
                            fim = "cancelado"; motivo = "demorou para parar";
                            return null;
                        }
                        if ((DateTime.Now - matouEm).TotalSeconds >= 3) { Matar(true); }
                    }
                    if (!pedirPausa || Cancelado)
                    {
                        r = InstaladorJogo.LerProgresso(this.arqProgresso);
                        // Cancelar durante a instalacao nao para o instalador: se ele terminou, ficou pronto.
                        fim = r != null && r.estado == "ok" ? "pronto" : Cancelado ? "cancelado" : "erro";
                        return r;
                    }
                    Pausado = true; pedirPausa = false;
                    SoltarVez();
                    FilaSalva.Mudou(this);
                    Barra.Esconder(api);
                    while (Pausado && !Cancelado) { System.Threading.Thread.Sleep(300); }
                    // (o worker so abre de novo depois de conferir o Cancelado, no comeco do laco)
                    if (Cancelado || !EsperarVez()) { fim = "cancelado"; return null; }
                }
            }
            finally
            {
                Finalizar(fim, r, motivo ?? (fim == "erro" && r != null && r.estado == "erro" ? r.msg : null));
            }
        }

        // Pausar solta a vez; continuar volta para o fim da fila (comeca na hora se ninguem esta baixando).
        public void Alternar()
        {
            if (Pausado) { Pausado = false; Gerenciador.ParaOFim(this); FilaSalva.Mudou(this); }
            else if (temVez) { pedirPausa = true; Matar(false); }
        }

        public bool Instalando { get { var p = Atual; return p != null && p.estado == "instalando"; } }

        // O instalador nao para com o worker: ele segue ate o fim para o jogo ficar registrado.
        public void Cancelar()
        {
            if (!Cancelado) { canceladoEm = DateTime.Now; }
            Cancelado = true; Pausado = false;
            cancelou.Set();
            Gerenciador.Acordar();
            if (!InstalandoAgora()) { Matar(false); }
        }

        // O Atual so e lido a cada 1 s: antes de matar o worker, le o progresso de novo (o setup pode ter acabado de comecar).
        bool InstalandoAgora()
        {
            if (Instalando) { return true; }
            var p = this.arqProgresso == null ? null : InstaladorJogo.LerProgresso(this.arqProgresso);
            return p != null && p.estado == "instalando";
        }

        // Gravado na hora (antes do fim): fechar o Playnite antes de o worker sair nao faz o download voltar sozinho.
        public void CancelarPeloUsuario() { PeloUsuario = true; FilaSalva.Cancelou(this); Cancelar(); }

        // O Playnite esta fechando: o worker para (menos na instalacao) e o download continua na proxima abertura.
        public void Encerrar()
        {
            if (InstalandoAgora()) { return; }
            if (!Cancelado) { canceladoEm = DateTime.Now; }
            Cancelado = true; Pausado = false;
            cancelou.Set();
            Gerenciador.Acordar();
            Matar(false);
        }

        // Como o Playnite registra o jogo quando o download termina bem.
        public GameInstallationData Instalacao()
        {
            if (Tipo == "rom") { return Destino == null ? null : new GameInstallationData { InstallDirectory = Path.GetDirectoryName(Destino), Roms = new List<GameRom> { new GameRom(Nome, Destino) } }; }
            Instalado i;
            return IdCatalogo != null && Dados.Instalados().TryGetValue(IdCatalogo, out i) ? new GameInstallationData { InstallDirectory = i.pasta } : null;
        }
    }

    // A fila dos downloads, na ordem de chegada. Nunca chama Tarefas nem mexe na UI com a trava presa:
    // Tarefas.Copia prende a dela e pergunta a Posicao (a ordem e sempre Tarefas -> Gerenciador).
    public static class Gerenciador
    {
        static readonly object trava = new object();
        static readonly List<Execucao> ordem = new List<Execucao>();
        // Lugares guardados pela retomada ao abrir: o jogo volta na frente de quem chegou depois (e pausado, se estava).
        static readonly Dictionary<Guid, KeyValuePair<long, bool>> reservas = new Dictionary<Guid, KeyValuePair<long, bool>>();
        static Execucao dono;
        static long seq;
        // O Playnite esta fechando: nada muda no downloads-fila.json.
        public static volatile bool Encerrando;

        public static void Entrar(Execucao e)
        {
            lock (trava)
            {
                KeyValuePair<long, bool> r;
                if (reservas.TryGetValue(e.JogoId, out r)) { reservas.Remove(e.JogoId); e.Seq = r.Key; if (r.Value) { e.Pausado = true; } }
                else { e.Seq = ++seq; }
                ordem.Add(e);
                Monitor.PulseAll(trava);
            }
        }

        public static void Sair(Execucao e)
        {
            lock (trava) { ordem.Remove(e); if (dono == e) { dono = null; } Monitor.PulseAll(trava); }
        }

        // O primeiro da fila que nao esta pausado nem cancelado.
        static Execucao Primeiro() { return ordem.Where(x => !x.Pausado && !x.Cancelado).OrderBy(x => x.Seq).FirstOrDefault(); }

        // A vez e do primeiro da fila, quando ninguem esta baixando.
        public static bool TentarVez(Execucao e)
        {
            lock (trava)
            {
                if (dono != null || Primeiro() != e) { return false; }
                dono = e;
                return true;
            }
        }

        public static bool EsperarVez(Execucao e)
        {
            lock (trava)
            {
                while (!e.Cancelado)
                {
                    if (dono == null && Primeiro() == e) { dono = e; return true; }
                    Monitor.Wait(trava, 300);
                }
                return false;
            }
        }

        public static void Soltar(Execucao e) { lock (trava) { if (dono == e) { dono = null; } Monitor.PulseAll(trava); } }

        public static void Acordar() { lock (trava) { Monitor.PulseAll(trava); } }

        // Continuar depois de pausar: volta para o fim da fila.
        public static void ParaOFim(Execucao e) { lock (trava) { e.Seq = ++seq; Monitor.PulseAll(trava); } }

        // "Baixar a seguir": passa na frente da fila sem interromper o que esta baixando.
        public static bool MoverParaFrente(Execucao e)
        {
            lock (trava)
            {
                if (e == dono || e.Pausado || e.Cancelado || !ordem.Contains(e)) { return false; }
                var menor = ordem.Where(x => x != dono && !x.Pausado && !x.Cancelado).Min(x => x.Seq);
                if (e.Seq > menor) { e.Seq = menor - 1; }
                Monitor.PulseAll(trava);
                return true;
            }
        }

        // 1 = o proximo a baixar; 0 = nao esta esperando (baixando, pausado ou cancelado).
        public static int Posicao(Execucao e)
        {
            lock (trava)
            {
                if (e == dono || e.Pausado || e.Cancelado || !ordem.Contains(e)) { return 0; }
                return 1 + ordem.Count(x => x != dono && !x.Pausado && !x.Cancelado && x.Seq < e.Seq);
            }
        }

        // O que esta baixando, a fila em ordem, os pausados e por fim os cancelados que ainda nao sairam.
        public static List<Execucao> Copia()
        {
            lock (trava)
            {
                var d = dono;
                return ordem.OrderBy(x => x == d ? 0 : x.Cancelado ? 3 : x.Pausado ? 2 : 1).ThenBy(x => x.Seq).ToList();
            }
        }

        public static Execucao Vivo(Guid jogo) { return Copia().FirstOrDefault(x => x.JogoId == jogo && !x.Cancelado); }

        // Ainda na fila, mesmo cancelando (o worker pode nao ter saido): Continuar e Descartar esperam.
        public static bool Presente(Guid jogo) { lock (trava) { return ordem.Any(x => x.JogoId == jogo); } }

        // Retomada ao abrir: lugares (e pausados) na ordem da lista, antes de qualquer clique novo.
        public static void Restaurar(List<KeyValuePair<Guid, bool>> lista)
        {
            lock (trava)
            {
                long s = -1000000;
                foreach (var x in lista) { reservas[x.Key] = new KeyValuePair<long, bool>(s++, x.Value); }
            }
        }

        public static void TirarReserva(Guid jogo) { lock (trava) { reservas.Remove(jogo); } }
    }

    // Uma tarefa que aparece no card do Selene, no indicador do topo e na tela de Downloads: um download
    // (Execucao) ou a instalacao de um Recomp, que o plugin Recomps registra.
    public class Tarefa
    {
        public string Id, Nome, Etapa;
        public long Feito, Total, Velocidade;
        public bool Recomp;
        public DateTime Fim;
        public Execucao Download;
        public object Args, Holder;
        public Action Cancelar;
        // Downloads: o jogo, "pc" ou "rom" e o lugar na fila (1 = o proximo; 0 = nao esta esperando).
        public Guid JogoId;
        public string Tipo;
        public int Posicao;
        // Como terminou (Recomp: o que o plugin Recomps informou) e por que, para "Terminados nesta sessao".
        public string Resultado, Motivo;

        public bool Terminada { get { return Fim != DateTime.MinValue; } }
    }

    // Registro das tarefas visiveis. A parte publica so usa tipos do .NET: o plugin Recomps chama
    // Abrir, Atualizar, PodeCancelar e Fechar (e, se existirem, Resultado e SoEmulador) por reflexao,
    // sem referencia a esta DLL. Por isso nenhum desses nomes pode ganhar sobrecarga.
    public static class Tarefas
    {
        static readonly List<Tarefa> Lista = new List<Tarefa>();
        // "Terminados nesta sessao": so em memoria, some quando o Playnite fecha.
        static readonly List<Tarefa> Sessao = new List<Tarefa>();
        // Jogos que o nosso plugin vai baixar para o emulador agora (Continuar, retomada ao abrir).
        static readonly Dictionary<Guid, DateTime> SoRom = new Dictionary<Guid, DateTime>();

        // Etapas do Recomp: preparando, baixando, extraindo, instalando. argsDoCard e o
        // GlobalProgressActionArgs do card dele, para o card voltar se outra tarefa tomar a vaga.
        public static string Abrir(string nome, object argsDoCard)
        {
            var t = new Tarefa { Id = Guid.NewGuid().ToString("N"), Nome = nome, Etapa = "preparando", Recomp = true, Args = argsDoCard };
            lock (Lista) { Lista.Add(t); }
            return t.Id;
        }

        // total <= 0: sem porcentagem.
        public static void Atualizar(string id, string etapa, long feito, long total)
        {
            lock (Lista)
            {
                var t = Lista.FirstOrDefault(x => x.Id == id);
                if (t == null) { return; }
                if (!string.IsNullOrEmpty(etapa)) { t.Etapa = etapa; }
                t.Feito = feito; t.Total = total;
            }
        }

        // null: nao da para cancelar agora.
        public static void PodeCancelar(string id, Action cancelar)
        {
            lock (Lista)
            {
                var t = Lista.FirstOrDefault(x => x.Id == id);
                if (t != null) { t.Cancelar = cancelar; }
            }
        }

        // Opcional para o plugin Recomps, antes do Fechar: fim e "pronto", "cancelado" ou "erro".
        public static void Resultado(string id, string fim, string motivo)
        {
            lock (Lista)
            {
                var t = Lista.FirstOrDefault(x => x.Id == id);
                if (t != null) { t.Resultado = fim; t.Motivo = motivo; }
            }
        }

        public static void Fechar(string id)
        {
            lock (Lista)
            {
                foreach (var t in Lista.Where(x => x.Id == id && x.Recomp))
                {
                    var r = Retrato(t);
                    r.Etapa = string.IsNullOrEmpty(t.Resultado) ? "terminou" : t.Resultado;
                    r.Fim = DateTime.Now;
                    Guardar(r);
                }
                Lista.RemoveAll(x => x.Id == id);
            }
        }

        // Opcional para o plugin Recomps, no GetInstallActions: true enquanto o nosso plugin pede o Instalar
        // so para continuar a ROM (o Playnite nao pergunta entre o Recomp e o emulador).
        public static bool SoEmulador(string jogoId)
        {
            Guid id;
            if (!Guid.TryParse(jogoId ?? "", out id)) { return false; }
            lock (SoRom)
            {
                DateTime ate;
                return SoRom.TryGetValue(id, out ate) && DateTime.Now < ate;
            }
        }

        public static void MarcarSoEmulador(Guid jogo) { lock (SoRom) { SoRom[jogo] = DateTime.Now.AddSeconds(60); } }

        public static void Entrar(Execucao e)
        {
            lock (Lista) { Lista.Add(new Tarefa { Id = Guid.NewGuid().ToString("N"), Nome = e.Nome, Download = e, JogoId = e.JogoId, Tipo = e.Tipo }); }
        }

        // O download fica mais um pouco para o card e o topo mostrarem como terminou.
        public static void Terminar(Execucao e, string fim, string motivo)
        {
            lock (Lista)
            {
                var t = Lista.FirstOrDefault(x => x.Download == e);
                if (t == null) { return; }
                t.Etapa = fim; t.Fim = DateTime.Now; t.Motivo = motivo;
                Guardar(Retrato(t));
            }
        }

        // Com a trava da Lista presa.
        static void Guardar(Tarefa r)
        {
            r.Download = null; r.Args = null; r.Holder = null; r.Cancelar = null;
            Sessao.Insert(0, r);
            if (Sessao.Count > 50) { Sessao.RemoveRange(50, Sessao.Count - 50); }
        }

        // Os terminados desta sessao, o mais recente primeiro.
        public static List<Tarefa> Terminados() { lock (Lista) { return Sessao.ToList(); } }

        // Quanto tempo o fim (pronto, cancelado, erro) fica no card e no indicador do topo.
        public static double SegundosNoCartao(string etapa) { return etapa == "erro" ? 10 : 3; }
        public static double SegundosNoTopo(string etapa) { return etapa == "erro" ? 30 : etapa == "cancelado" || etapa == "cancelado-nada" ? 5 : 10; }

        // O Selene criou um holder para o card do Recomp: guarda para devolver o card depois.
        public static void GuardarHolder(object args, object holder)
        {
            lock (Lista)
            {
                foreach (var t in Lista.Where(x => x.Args != null && x.Holder == null && ReferenceEquals(x.Args, args))) { t.Holder = holder; }
            }
        }

        // Falso se ja nao da para cancelar (a etapa mudou ou a instalacao acabou).
        public static bool CancelarRecomp(string id)
        {
            Action cancelar;
            lock (Lista)
            {
                var t = Lista.FirstOrDefault(x => x.Id == id);
                cancelar = t == null ? null : t.Cancelar;
            }
            if (cancelar == null) { return false; }
            cancelar();
            return true;
        }

        // Retrato de agora: o estado dos downloads vem da Execucao; os terminados que ja passaram do tempo saem.
        public static List<Tarefa> Copia()
        {
            var agora = DateTime.Now;
            lock (Lista)
            {
                Lista.RemoveAll(x => x.Terminada && (agora - x.Fim).TotalSeconds > SegundosNoTopo(x.Etapa));
                return Lista.Select(Retrato).ToList();
            }
        }

        static Tarefa Retrato(Tarefa t)
        {
            var r = new Tarefa { Id = t.Id, Nome = t.Nome, Etapa = t.Etapa, Feito = t.Feito, Total = t.Total, Recomp = t.Recomp, Fim = t.Fim, Download = t.Download, Args = t.Args, Holder = t.Holder, Cancelar = t.Cancelar,
                JogoId = t.JogoId, Tipo = t.Tipo, Resultado = t.Resultado, Motivo = t.Motivo };
            var e = t.Download;
            if (e == null) { return r; }
            var p = e.Atual;
            if (p != null) { r.Feito = p.baixado; r.Total = p.total; r.Velocidade = p.velocidade; }
            else { r.Feito = e.JaTem; r.Total = e.Tamanho; }
            if (r.Terminada) { return r; }
            // Cancelado e o worker ainda nao saiu (ate 10 s). Na instalacao o instalador vai ate o fim.
            if (e.Cancelado && !e.Instalando) { r.Etapa = "cancelando"; return r; }
            r.Posicao = Gerenciador.Posicao(e);
            if (e.Pausado) { r.Etapa = "pausado"; }
            else if (e.NaFila) { r.Etapa = "nafila"; }
            else if (p == null) { r.Etapa = "conectando"; }
            else
            {
                switch (p.estado)
                {
                    case "baixando": case "fila": case "reconectando": case "verificando": case "instalando": r.Etapa = p.estado; break;
                    // "ok" e "erro" duram so ate o worker sair.
                    default: r.Etapa = "verificando"; break;
                }
            }
            return r;
        }

        static bool Ativo(Tarefa t) { return !t.Terminada && t.Etapa != "pausado" && t.Etapa != "nafila"; }

        // Downloads esperando a vez, fora o que esta sendo mostrado.
        public static int NaFila(List<Tarefa> lista, Tarefa mostrada) { return lista.Count(x => !x.Recomp && !x.Terminada && x.Etapa == "nafila" && x.Id != mostrada.Id); }

        // Card dos downloads: o fim que acabou de acontecer, depois o ativo, depois o primeiro pausado.
        public static Tarefa DoCartao(List<Tarefa> lista)
        {
            var agora = DateTime.Now;
            var d = lista.Where(x => !x.Recomp).ToList();
            return d.Where(x => x.Terminada && (agora - x.Fim).TotalSeconds < SegundosNoCartao(x.Etapa)).OrderByDescending(x => x.Fim).FirstOrDefault()
                ?? d.FirstOrDefault(Ativo) ?? d.FirstOrDefault(x => x.Etapa == "pausado") ?? d.FirstOrDefault(x => !x.Terminada);
        }

        // Indicador do topo: o fim recente (3 s; sem nada ativo, o tempo todo dele), o download ativo,
        // o Recomp, o pausado, o da fila.
        public static Tarefa DoTopo(List<Tarefa> lista)
        {
            var agora = DateTime.Now;
            var fins = lista.Where(x => x.Terminada).OrderByDescending(x => x.Fim).ToList();
            var vivos = lista.Where(x => !x.Terminada).ToList();
            return fins.FirstOrDefault(x => (agora - x.Fim).TotalSeconds < 3)
                ?? vivos.FirstOrDefault(x => !x.Recomp && Ativo(x)) ?? vivos.FirstOrDefault(x => x.Recomp)
                ?? fins.FirstOrDefault() ?? vivos.FirstOrDefault(x => x.Etapa == "pausado") ?? vivos.FirstOrDefault();
        }

        // Barra sem porcentagem no card dos downloads.
        public static bool Indeterminada(Tarefa t)
        {
            switch (t.Etapa)
            {
                case "baixando": return t.Total <= 0;
                case "reconectando": case "pausado": case "pronto": case "cancelado": case "cancelado-nada": case "erro": return false;
                default: return true;
            }
        }
    }

    // Textos do card e do indicador do topo. O Selene troca o card inteiro (e ele pode nao voltar)
    // quando muda o texto sem os numeros: ele tira [\d/%.,()] e compara. Por isso cada estado tem
    // uma forma fixa e numero desconhecido vira "...". O titulo do card e o trecho antes de " - ".
    public static class Textos
    {
        static readonly CultureInfo Br = new CultureInfo("pt-BR");
        const string Sep = " · ";

        public static string Nome(string nome, int max)
        {
            var n = (nome ?? "").Replace(" - ", " – ");
            // Com "Closing", "Exiting" ou "Shutting" no texto, o Selene mostra a janela de progresso do Playnite.
            n = Regex.Replace(n, "(?<=clos)(?=ing)|(?<=exit)(?=ing)|(?<=shut)(?=ting)", "​", RegexOptions.IgnoreCase);
            return n.Length > max ? n.Substring(0, max - 1) + "…" : n;
        }

        // Porcentagem inteira (para baixo); -1 sem total.
        public static long Pct(long feito, long total) { return total > 0 ? (long)Math.Floor(Math.Min(Math.Max(feito, 0), total) * 100.0 / total) : -1; }

        static string Num(long pct) { return pct < 0 ? "..." : pct.ToString(Br); }
        static string Gb(long b) { return (Math.Max(b, 0) / 1073741824.0).ToString("0.0", Br); }
        static string GbTotal(long b) { return b > 0 ? Gb(b) : "..."; }
        static string Mbs(long v) { return v > 0 ? (v / 1048576.0).ToString("0.0", Br) : "..."; }

        static string Minutos(long feito, long total, long v)
        {
            return v > 0 && total > 0 ? ((long)Math.Ceiling(Math.Max(total - feito, 0) / (double)v / 60)).ToString(Br) : "...";
        }

        public static string Cartao(string nome, string etapa, long feito, long total, long velocidade, int fila)
        {
            var naFila = Sep + "na fila: " + fila.ToString(Br);
            var pct = Num(Pct(feito, total));
            string s;
            switch (etapa)
            {
                case "baixando": s = "Baixando " + pct + "%" + Sep + Gb(feito) + "/" + GbTotal(total) + " GB" + Sep + Mbs(velocidade) + " MB/s" + Sep + "faltam " + Minutos(feito, total, velocidade) + " min" + naFila; break;
                case "fila": s = "Aguardando: outra pessoa está baixando" + naFila; break;
                case "reconectando": s = "A conexão caiu. Reconectando em " + pct + "%" + naFila; break;
                case "verificando": s = "Verificando os arquivos" + naFila; break;
                case "instalando": s = "Instalando. Se o Windows perguntar, escolha Sim" + naFila; break;
                case "pausado": s = "Pausado em " + pct + "%" + Sep + Gb(feito) + "/" + GbTotal(total) + " GB" + Sep + "continue nas opções do jogo"; break;
                case "pronto": s = "Pronto para jogar"; break;
                case "cancelando": s = "Cancelando. O que já baixou fica guardado"; break;
                case "cancelado": s = "Cancelado. O que já baixou ficou guardado"; break;
                case "cancelado-nada": s = "Cancelado. Nada tinha sido baixado"; break;
                case "erro": s = "Não terminou. O que já baixou ficou guardado"; break;
                default: s = "Conectando" + naFila; break;
            }
            return Nome(nome, 32) + " - " + s;
        }

        public static string Topo(string nome, string etapa, long feito, long total, long velocidade, int fila, bool recomp)
        {
            var pct = Num(Pct(feito, total));
            string s;
            // (o "complemento" do plugin Recomps e um preparando com texto proprio no card dele)
            if (recomp) { s = "Recomp " + (etapa == "complemento" ? "preparando" : etapa) + (total > 0 ? " " + pct + "%" : ""); }
            else
            {
                switch (etapa)
                {
                    case "baixando": s = pct + "%" + (total > 0 && velocidade > 0 ? Sep + "faltam " + Minutos(feito, total, velocidade) + " min" : ""); break;
                    case "fila": s = "aguardando o servidor"; break;
                    case "reconectando": s = "reconectando" + Sep + pct + "%"; break;
                    case "verificando": s = "verificando"; break;
                    case "instalando": s = "instalando"; break;
                    case "pausado": s = "pausado em " + pct + "%"; break;
                    case "pronto": s = "pronto para jogar"; break;
                    case "cancelando": s = "cancelando"; break;
                    case "cancelado": case "cancelado-nada": s = "cancelado"; break;
                    case "erro": s = "não terminou"; break;
                    default: s = "conectando"; break;
                }
            }
            return Nome(nome, 24) + Sep + s + (fila >= 1 ? Sep + "+" + fila.ToString(Br) + " na fila" : "");
        }
    }

    // Na tela cheia nao ha barra nem janela de downloads: o Selene mostra a tela de progresso
    // do Playnite como um card proprio e deixa a navegacao livre. O card tem uma vaga so
    // (ProgressToast.source): outra tarefa que a toma deixa a vaga vazia ao terminar, e o nosso
    // card sumia. Um relogio na thread da UI abre o card quando da, devolve o card quando a vaga
    // fica vazia (nunca tira a vaga de uma tarefa viva de outro) e atualiza o indicador do topo.
    public static class CartaoSelene
    {
        static readonly object trava = new object();
        static readonly HashSet<string> avisos = new HashSet<string>();
        static int ativo;
        static bool procurou;
        static IPlayniteAPI playnite;
        static System.Windows.Threading.DispatcherTimer relogio;
        // O GlobalProgressActionArgs do nosso card e o holder que o Selene criou para ele.
        static volatile object argsCartao, holderCartao;
        static FieldInfo campoVaga;
        static MethodInfo mostrarTarefa, usavel, ligado, mine;

        public static bool NaTelaCheia(IPlayniteAPI api)
        {
            return api.ApplicationInfo.Mode == ApplicationMode.Fullscreen && api.Dialogs.GetType().FullName.IndexOf("Selene", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        public static void Iniciar(IPlayniteAPI api)
        {
            if (!NaTelaCheia(api)) { return; }
            playnite = api;
            api.MainView.UIDispatcher.Invoke(new Action(() =>
            {
                relogio = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                relogio.Tick += (s, e) => Vigiar();
                relogio.Start();
            }));
        }

        public static void Garantir(IPlayniteAPI api)
        {
            if (!NaTelaCheia(api)) { return; }
            playnite = api;
            api.MainView.UIDispatcher.BeginInvoke(new Action(() => Tentar("abrir", () => Abrir(Tarefas.Copia()))));
        }

        static void Vigiar()
        {
            var lista = Tarefas.Copia();
            Tentar("abrir", () => Abrir(lista));
            Tentar("devolver", () => Devolver(lista));
            Tentar("topo", () => IndicadorTopo.Atualizar(lista));
        }

        // Roda a cada segundo: avisa no log uma vez so por tipo de falha.
        static void Tentar(string oque, Action acao)
        {
            try { acao(); }
            catch (Exception e)
            {
                bool primeira;
                lock (avisos) { primeira = avisos.Add(oque); }
                if (primeira) { LogManager.GetLogger().Error(e, "Card de download: falha ao " + oque); }
            }
        }

        // Na thread da UI.
        static void Abrir(List<Tarefa> lista)
        {
            if (playnite == null || Interlocked.CompareExchange(ref ativo, 0, 0) != 0) { return; }
            var t = Tarefas.DoCartao(lista);
            if (t == null || t.Terminada) { return; }
            var opcoes = new GlobalProgressOptions(Textos.Cartao(t.Nome, t.Etapa, t.Feito, t.Total, t.Velocidade, Tarefas.NaFila(lista, t)), false) { IsIndeterminate = Tarefas.Indeterminada(t) };
            // Em outro tema, ou com a janela minimizada, seria a janela de progresso do Playnite, que
            // trava a tela cheia durante todo o download: espera e tenta de novo no proximo segundo.
            if (!PodeAbrir(opcoes)) { return; }
            if (Interlocked.CompareExchange(ref ativo, 1, 0) != 0) { return; }
            var api = playnite;
            Task.Run(() =>
            {
                try { api.Dialogs.ActivateGlobalProgress((Action<GlobalProgressActionArgs>)Acompanhar, opcoes); }
                catch (Exception e) { LogManager.GetLogger().Error(e, "Falha no card de download"); }
                finally { Interlocked.Exchange(ref ativo, 0); }
            });
        }

        // Para o diagnostico da tela de Downloads: o card do Selene continua utilizavel (ProgressToast.Usable)?
        public static string Usavel()
        {
            try { return !AcharSelene() ? "sem Selene" : (bool)usavel.Invoke(null, null) ? "sim" : "nao"; }
            catch (Exception) { return "erro"; }
        }

        // A mesma conta do Selene (SeleneDialogs.Mine) para mostrar o card e nao a janela do Playnite.
        // Se o Selene mudar, abre como antes.
        static bool PodeAbrir(GlobalProgressOptions opcoes)
        {
            try
            {
                if (!AcharSelene()) { return true; }
                if (mine != null) { return (bool)mine.Invoke(null, new object[] { opcoes }); }
                return (bool)ligado.Invoke(null, new object[] { "dialogs" }) && (bool)ligado.Invoke(null, new object[] { "progresstoast" }) && (bool)usavel.Invoke(null, null);
            }
            catch (Exception) { return true; }
        }

        // Os membros sao do SeleneCore 1.5.6; se mudarem, avisa uma vez no log e nao devolve nada.
        static bool AcharSelene()
        {
            lock (trava)
            {
                if (campoVaga != null) { return true; }
                if (procurou) { return false; }
                var asm = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "SeleneCore");
                if (asm == null) { return false; }
                // Procura uma vez so, e nao a cada segundo.
                procurou = true;
                const BindingFlags f = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
                var toast = asm.GetType("Selene.ProgressToast");
                var recursos = asm.GetType("Selene.Features");
                var dialogos = asm.GetType("Selene.SeleneDialogs");
                FieldInfo vaga = null;
                MethodInfo mostrar = null, usa = null, on = null;
                if (toast != null && recursos != null)
                {
                    vaga = toast.GetField("source", f);
                    mostrar = toast.GetMethod("ShowTask", f, null, new[] { typeof(object) }, null);
                    usa = toast.GetMethod("Usable", f, null, Type.EmptyTypes, null);
                    on = recursos.GetMethod("On", f, null, new[] { typeof(string) }, null);
                }
                if (vaga == null || vaga.FieldType != typeof(object) || mostrar == null || usa == null || usa.ReturnType != typeof(bool) || on == null || on.ReturnType != typeof(bool))
                {
                    LogManager.GetLogger().Warn("Card de download: ProgressToast.source/ShowTask/Usable ou Features.On nao encontrados no Selene");
                    return false;
                }
                var m = dialogos == null ? null : dialogos.GetMethod("Mine", f, null, new[] { typeof(GlobalProgressOptions) }, null);
                mine = m != null && m.ReturnType == typeof(bool) ? m : null;
                usavel = usa; ligado = on; mostrarTarefa = mostrar; campoVaga = vaga;
                return true;
            }
        }

        static object ArgsDo(object holder)
        {
            var p = holder.GetType().GetProperty("ProgressArgs", BindingFlags.Public | BindingFlags.Instance);
            return p == null || p.GetIndexParameters().Length > 0 ? null : p.GetValue(holder, null);
        }

        // Na thread da UI. Com a vaga ocupada, so aprende quais holders sao nossos; com a vaga vazia,
        // devolve o card dos downloads (ou o do Recomp). Com "taskcards" desligado, o Selene nao mostra
        // card de tarefa: fica so o indicador do topo.
        static void Devolver(List<Tarefa> lista)
        {
            if (!AcharSelene()) { return; }
            var vaga = campoVaga.GetValue(null);
            if (vaga != null)
            {
                var args = ArgsDo(vaga);
                if (args == null) { return; }
                if (ReferenceEquals(args, argsCartao)) { holderCartao = vaga; }
                Tarefas.GuardarHolder(args, vaga);
                return;
            }
            if (!(bool)ligado.Invoke(null, new object[] { "taskcards" }) || !(bool)usavel.Invoke(null, null)) { return; }
            var holder = argsCartao != null ? holderCartao : null;
            if (holder == null) { holder = lista.Where(x => x.Recomp && x.Holder != null).Select(x => x.Holder).FirstOrDefault(); }
            if (holder == null) { return; }
            LogManager.GetLogger().Info("Card de download: a vaga ficou vazia, devolvendo o card");
            mostrarTarefa.Invoke(null, new[] { holder });
        }

        static void Acompanhar(GlobalProgressActionArgs a)
        {
            argsCartao = a; holderCartao = null;
            try
            {
                a.ProgressMaxValue = 100;
                // Sem nada para mostrar, fecha logo: o fim ja ficou o tempo dele (3 s, erro 10 s), e o
                // proximo da fila ja esta na lista. Se um download comecar depois, o relogio abre outro card.
                for (; ; Thread.Sleep(1000))
                {
                    // O Selene pos o holder deste card na vaga ao abrir: guarda para devolver depois.
                    if (holderCartao == null) { Capturar(a); }
                    var lista = Tarefas.Copia();
                    var t = Tarefas.DoCartao(lista);
                    if (t == null) { break; }
                    a.Text = Textos.Cartao(t.Nome, t.Etapa, t.Feito, t.Total, t.Velocidade, Tarefas.NaFila(lista, t));
                    var indeterminada = Tarefas.Indeterminada(t);
                    a.IsIndeterminate = indeterminada;
                    // Cancelado e erro deixam a barra parada onde estava.
                    if (t.Etapa == "pronto") { a.CurrentProgressValue = 100; }
                    else if (!indeterminada && !t.Terminada && t.Total > 0) { a.CurrentProgressValue = Math.Min(t.Feito, t.Total) * 100.0 / t.Total; }
                }
            }
            finally { argsCartao = null; holderCartao = null; }
        }

        static void Capturar(object a)
        {
            try
            {
                if (!AcharSelene()) { return; }
                var vaga = campoVaga.GetValue(null);
                if (vaga != null && ReferenceEquals(ArgsDo(vaga), a)) { holderCartao = vaga; }
            }
            catch (Exception) { }
        }
    }

    // No topo da tela cheia do Selene, antes do "tocando agora": nome, estado e uma barra fina.
    // Continua mostrando o nosso progresso quando o card esta com outra tarefa. So mexe no proprio
    // painel (nunca move as partes PART_ do tema) e so roda na thread da UI.
    public static class IndicadorTopo
    {
        static StackPanel painel;
        static TextBlock texto;
        static Border cheio;
        static ColumnDefinition feito, falta;
        static string corBarra;

        static void Criar()
        {
            // Como o "tocando agora" do Main.xaml do Selene.
            texto = new TextBlock { FontSize = 20, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 420, Focusable = false, IsHitTestVisible = false };
            texto.SetResourceReference(TextBlock.ForegroundProperty, "SeleneInk90Brush");
            texto.SetResourceReference(TextBlock.FontFamilyProperty, "FontMain");
            var barra = new Grid { Height = 4, Margin = new Thickness(0, 4, 0, 0), Focusable = false, IsHitTestVisible = false };
            feito = new ColumnDefinition { Width = new GridLength(0, GridUnitType.Star) };
            falta = new ColumnDefinition { Width = new GridLength(100, GridUnitType.Star) };
            barra.ColumnDefinitions.Add(feito); barra.ColumnDefinitions.Add(falta);
            cheio = new Border { CornerRadius = new CornerRadius(2), Focusable = false, IsHitTestVisible = false };
            barra.Children.Add(cheio);
            painel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 28, 0), Focusable = false, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
            System.Windows.Input.KeyboardNavigation.SetIsTabStop(painel, false);
            painel.Children.Add(texto); painel.Children.Add(barra);
        }

        // Poe o painel antes do SeleneNowPlaying, na fila do relogio (PART_TextClock). O FindName nao
        // acha as partes do tema: percorre a arvore visual. Sem as partes, nao faz nada.
        public static bool Encaixar(DependencyObject raiz)
        {
            if (painel == null) { Criar(); }
            var pai = painel.Parent as Panel;
            if (pai != null && PresentationSource.FromVisual(painel) != null) { return true; }
            var relogio = Achar(raiz, "PART_TextClock");
            var fila = relogio == null ? null : VisualTreeHelper.GetParent(relogio) as Panel;
            var tocando = fila == null ? null : fila.Children.OfType<FrameworkElement>().FirstOrDefault(x => x.Name == "SeleneNowPlaying");
            if (tocando == null) { return false; }
            if (pai == fila) { return true; }
            // Saiu da arvore (o tema refez a tela): tira do lugar antigo e poe de novo.
            if (pai != null) { pai.Children.Remove(painel); }
            fila.Children.Insert(fila.Children.IndexOf(tocando), painel);
            return true;
        }

        static FrameworkElement Achar(DependencyObject no, string nome)
        {
            if (!(no is Visual) && !(no is System.Windows.Media.Media3D.Visual3D)) { return null; }
            var fe = no as FrameworkElement;
            if (fe != null && fe.Name == nome) { return fe; }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(no); i++)
            {
                var r = Achar(VisualTreeHelper.GetChild(no, i), nome);
                if (r != null) { return r; }
            }
            return null;
        }

        public static void Atualizar(List<Tarefa> lista)
        {
            var t = Tarefas.DoTopo(lista);
            if (t == null) { if (painel != null) { painel.Visibility = Visibility.Collapsed; } return; }
            var janela = Application.Current == null ? null : Application.Current.MainWindow;
            if (janela == null || !Encaixar(janela)) { return; }
            texto.Text = Textos.Topo(t.Nome, t.Etapa, t.Feito, t.Total, t.Velocidade, Tarefas.NaFila(lista, t), t.Recomp);
            var semPct = t.Total <= 0 || (!t.Recomp && Tarefas.Indeterminada(t));
            var pct = t.Etapa == "pronto" ? 100 : semPct ? 0 : Textos.Pct(t.Feito, t.Total);
            feito.Width = new GridLength(pct, GridUnitType.Star);
            falta.Width = new GridLength(100 - pct, GridUnitType.Star);
            var cor = t.Etapa == "pausado" ? "SeleneInk60Brush" : "SeleneInk90Brush";
            if (cor != corBarra) { cheio.SetResourceReference(Border.BackgroundProperty, cor); corBarra = cor; }
            painel.Visibility = Visibility.Visible;
        }
    }

    // Na tela cheia a notificacao nao aparece: o erro do download vira uma mensagem (uma por jogo de cada vez).
    public static class ErroDownload
    {
        static readonly HashSet<string> Abertos = new HashSet<string>();

        public static void Mostrar(IPlayniteAPI api, string nome, string motivo)
        {
            if (api.ApplicationInfo.Mode != ApplicationMode.Fullscreen) { return; }
            lock (Abertos) { if (!Abertos.Add(nome)) { return; } }
            api.MainView.UIDispatcher.BeginInvoke(new Action(() =>
            {
                try
                {
                    api.Dialogs.ShowMessage(nome + " não terminou de baixar.\n\n" + motivo + "\n\nO que já baixou ficou guardado. Para tentar de novo, escolha Instalar.",
                        "Download não terminou", MessageBoxButton.OK, MessageBoxImage.Error);
                }
                catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao avisar o erro do download"); }
                finally { lock (Abertos) { Abertos.Remove(nome); } }
            }));
        }
    }

    // O fim "cancelado" no painel do dono (aba Downloads): o worker avisa o andamento pelo relato.ps1, mas morto no
    // cancelamento nunca avisa o fim, e o painel mostraria o download parado por um dia. Mesmos campos, servidor e
    // login do relato.ps1 (launcher.json); em segundo plano, e qualquer falha e ignorada (nada vai para o log).
    public static class RelatoPainel
    {
        public static void Cancelado(Execucao e)
        {
            try
            {
                var s = Dados.Conexao;
                if (s == null || string.IsNullOrEmpty(s.usuario)) { return; }
                string jogo, console = "";
                if (e.Tipo == "rom")
                {
                    // (como o baixar-worker: o nome do arquivo e o console pela pasta <...>\Jogos\<console>\)
                    if (string.IsNullOrEmpty(e.Destino)) { return; }
                    jogo = Path.GetFileNameWithoutExtension(e.Destino);
                    var m = Regex.Match(e.Destino, @"\\Jogos\\([^\\]+)\\");
                    if (m.Success) { console = m.Groups[1].Value; }
                }
                else { jogo = e.NomeCatalogo ?? e.Nome; }
                var p = e.Atual;
                var corpo = Serialization.ToJson(new Dictionary<string, object>
                {
                    { "tipo", e.Tipo == "rom" ? "rom" : "pc" }, { "jogo", jogo }, { "console", console }, { "estado", "cancelado" },
                    { "baixado", p == null ? e.JaTem : p.baixado }, { "total", p == null || p.total <= 0 ? e.Tamanho : p.total }, { "velocidade", 0L }, { "msg", "" }
                });
                var auth = Dados.Auth(s);
                // Cada caminho (rede local, NetBird, Tailscale) recebe; o painel junta repetidos.
                foreach (var u in new[] { s.lan, s.netbird, s.tailscale }.Where(x => !string.IsNullOrEmpty(x)))
                {
                    var url = u.TrimEnd('/') + "/relato";
                    Task.Run(() =>
                    {
                        try
                        {
                            using (var web = new WebClient())
                            {
                                web.Encoding = Encoding.UTF8;
                                web.Headers[HttpRequestHeader.Authorization] = auth;
                                web.Headers[HttpRequestHeader.ContentType] = "application/json";
                                web.UploadString(url, "POST", corpo);
                            }
                        }
                        catch (Exception) { }
                    });
                }
            }
            catch (Exception) { }
        }
    }

    // O Selene so tira a capa de "abrindo" quando acha a janela do jogo, e nao enxerga dialogo de
    // erro nem jogo em tela cheia fora da pasta dele (recomps). Este vigia acompanha os processos
    // do jogo e, quando uma janela aparece e fica parada, pede ao proprio Selene para revelar.
    public static class CapaSelene
    {
        // Ordem de preferencia quando ha mais de uma janela: dialogo, janela normal, tela cheia.
        const int TelaCheia = 1, Normal = 2, Dialogo = 3;
        static readonly object trava = new object();
        static CancellationTokenSource atual;
        static Guid vigiado;
        static int avisou;
        static FieldInfo campoLancando, campoJogo;
        static MethodInfo revelar;

        class Candidata { public IntPtr Janela; public int Tipo; public Retangulo R; }

        public static void Iniciar(IPlayniteAPI api, OnGameStartedEventArgs args)
        {
            try
            {
                if (!CartaoSelene.NaTelaCheia(api) || args.StartedProcessId == 0) { return; }
                // Emulador tem a regra do proprio Selene.
                if (args.SourceAction != null && args.SourceAction.Type == GameActionType.Emulator) { return; }
                if (!AcharSelene()) { return; }
                var jogo = args.Game.Id;
                var pasta = PastaDoSelene(args.Game);
                var pid = args.StartedProcessId;
                var relogio = Stopwatch.StartNew();
                var cts = new CancellationTokenSource();
                lock (trava)
                {
                    if (atual != null) { atual.Cancel(); }
                    atual = cts;
                    vigiado = jogo;
                }
                Task.Run(() => Vigiar(api, jogo, pid, relogio, pasta, cts));
            }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao vigiar a capa do Selene"); }
        }

        public static void Parar(Guid jogo)
        {
            lock (trava)
            {
                if (atual != null && vigiado == jogo) { atual.Cancel(); atual = null; }
            }
        }

        // Os membros sao privados no SeleneCore; se mudarem, avisa uma vez no log e nao faz nada.
        static bool AcharSelene()
        {
            if (revelar != null) { return true; }
            var asm = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "SeleneCore");
            if (asm == null) { return false; }
            var t = asm.GetType("Selene.HomeNav");
            const BindingFlags f = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
            FieldInfo lancando = null, jogo = null;
            MethodInfo metodo = null;
            if (t != null)
            {
                lancando = t.GetField("launching", f);
                jogo = t.GetField("launchGameId", f);
                metodo = t.GetMethod("RevealGame", f, null, new[] { typeof(IntPtr), typeof(string) }, null);
            }
            if (lancando == null || jogo == null || metodo == null || lancando.FieldType != typeof(bool) || jogo.FieldType != typeof(Guid))
            {
                if (Interlocked.Exchange(ref avisou, 1) == 0) { LogManager.GetLogger().Warn("Capa do Selene: HomeNav.launching/launchGameId/RevealGame nao encontrados"); }
                return false;
            }
            campoLancando = lancando; campoJogo = jogo; revelar = metodo;
            return true;
        }

        // Mesma regra do LocalGames.GameFolder do Selene: a pasta do .exe da primeira acao de jogar,
        // se fica dentro da instalacao (ou nao ha instalacao); senao, a propria instalacao.
        static string PastaDoSelene(Game g)
        {
            try
            {
                var inst = g.InstallDirectory;
                var acao = g.GameActions == null ? null : g.GameActions.FirstOrDefault(a => a.IsPlayAction);
                if (acao != null && acao.Type == GameActionType.File && !string.IsNullOrWhiteSpace(acao.Path) && acao.Path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                {
                    var exe = acao.Path.Replace("{InstallDir}", inst ?? "");
                    if (!Path.IsPathRooted(exe)) { exe = Path.Combine(inst ?? "", exe); }
                    var dir = Path.GetDirectoryName(exe);
                    var dentro = !string.IsNullOrWhiteSpace(inst) && dir != null && Completo(dir).StartsWith(Completo(inst), StringComparison.Ordinal);
                    if (!string.IsNullOrWhiteSpace(dir) && (dentro || string.IsNullOrWhiteSpace(inst))) { return Completo(dir); }
                }
                return string.IsNullOrWhiteSpace(inst) ? null : Completo(inst);
            }
            catch (Exception e) { LogManager.GetLogger().Warn(e, "Capa do Selene: pasta de " + g.Name); return null; }
        }

        // Como o LocalGames.Full do Selene.
        static string Completo(string p) { return Path.GetFullPath(p).TrimEnd('\\').ToLowerInvariant(); }

        static void Vigiar(IPlayniteAPI api, Guid jogo, int pid, Stopwatch relogio, string pasta, CancellationTokenSource cts)
        {
            try
            {
                var arvore = new HashSet<int> { pid };
                var fora = new Dictionary<int, bool>();
                Candidata antes = null;
                long desde = 0;
                while (relogio.ElapsedMilliseconds < 120000)
                {
                    Thread.Sleep(250);
                    if (cts.IsCancellationRequested || !(bool)campoLancando.GetValue(null)) { return; }
                    CrescerArvore(arvore);
                    var agora = Escolher(arvore, pasta, fora);
                    if (!Igual(agora, antes)) { antes = agora; desde = relogio.ElapsedMilliseconds; continue; }
                    if (agora == null || relogio.ElapsedMilliseconds - desde < (agora.Tipo == TelaCheia ? 3000 : 1500)) { continue; }
                    Revelar(api, jogo, agora.Janela);
                    return;
                }
            }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao vigiar a capa do Selene"); }
            finally
            {
                lock (trava) { if (atual == cts) { atual = null; } }
                cts.Dispose();
            }
        }

        static bool Igual(Candidata a, Candidata b)
        {
            if (a == null || b == null) { return a == b; }
            return a.Janela == b.Janela && a.Tipo == b.Tipo && a.R.Esq == b.R.Esq && a.R.Topo == b.R.Topo && a.R.Dir == b.R.Dir && a.R.Base == b.R.Base;
        }

        static void Revelar(IPlayniteAPI api, Guid jogo, IntPtr janela)
        {
            api.MainView.UIDispatcher.BeginInvoke(new Action(() =>
            {
                try
                {
                    if (!(bool)campoLancando.GetValue(null) || (Guid)campoJogo.GetValue(null) != jogo) { return; }
                    LogManager.GetLogger().Info("Capa do Selene: janela do jogo apareceu");
                    // Nunca passar a janela ao RevealGame: com ela, o Selene grava a pasta do exe como
                    // InstallDirectory do jogo, e o Desinstalar do RomM apagaria essa pasta (um Recomp).
                    // Com IntPtr.Zero ele usa a janela em primeiro plano, entao o foco vai antes para o jogo.
                    if (IsIconic(janela)) { ShowWindow(janela, 9); }
                    SetForegroundWindow(janela);
                    revelar.Invoke(null, new object[] { IntPtr.Zero, "Jogos de PC: janela do jogo" });
                    SetForegroundWindow(janela);
                }
                catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao revelar o jogo no Selene"); }
            }));
        }

        // Launchers abrem o jogo como filho: entram na arvore todos os descendentes do pid inicial.
        static void CrescerArvore(HashSet<int> arvore)
        {
            var foto = CreateToolhelp32Snapshot(2, 0);
            if (foto == IntPtr.Zero || foto == new IntPtr(-1)) { return; }
            try
            {
                var pais = new List<KeyValuePair<int, int>>();
                var e = new EntradaProcesso { dwSize = (uint)Marshal.SizeOf(typeof(EntradaProcesso)) };
                for (var ok = Process32FirstW(foto, ref e); ok; ok = Process32NextW(foto, ref e))
                {
                    pais.Add(new KeyValuePair<int, int>((int)e.th32ProcessID, (int)e.th32ParentProcessID));
                }
                for (var cresceu = true; cresceu; )
                {
                    cresceu = false;
                    foreach (var p in pais) { if (arvore.Contains(p.Value) && arvore.Add(p.Key)) { cresceu = true; } }
                }
            }
            finally { CloseHandle(foto); }
        }

        static Candidata Escolher(HashSet<int> arvore, string pasta, Dictionary<int, bool> fora)
        {
            Candidata melhor = null;
            EnumWindows((h, l) =>
            {
                try
                {
                    uint dono;
                    GetWindowThreadProcessId(h, out dono);
                    if (!arvore.Contains((int)dono) || !IsWindowVisible(h) || IsIconic(h)) { return true; }
                    int escondida;
                    if (DwmGetWindowAttribute(h, 14, out escondida, 4) == 0 && escondida != 0) { return true; }
                    Retangulo r;
                    if (!GetWindowRect(h, out r)) { return true; }
                    var tipo = Tipo(h, r, (int)dono, pasta, fora);
                    if (tipo == 0) { return true; }
                    long area = (long)(r.Dir - r.Esq) * (r.Base - r.Topo);
                    if (melhor == null || tipo > melhor.Tipo || (tipo == melhor.Tipo && area > (long)(melhor.R.Dir - melhor.R.Esq) * (melhor.R.Base - melhor.R.Topo)))
                    {
                        melhor = new Candidata { Janela = h, Tipo = tipo, R = r };
                    }
                }
                catch (Exception) { }
                return true;
            }, IntPtr.Zero);
            return melhor;
        }

        static int Tipo(IntPtr h, Retangulo r, int dono, string pasta, Dictionary<int, bool> fora)
        {
            var classe = new StringBuilder(64);
            GetClassName(h, classe, classe.Capacity);
            if (classe.ToString() == "#32770") { return Dialogo; }
            if (classe.ToString() == "SysShadow") { return 0; }
            var m = new InfoMonitor { cbSize = Marshal.SizeOf(typeof(InfoMonitor)) };
            if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref m)) { return 0; }
            long largura = r.Dir - r.Esq, altura = r.Base - r.Topo;
            long telaL = m.Tela.Dir - m.Tela.Esq, telaA = m.Tela.Base - m.Tela.Topo;
            if (largura * 10 >= telaL * 9 && altura * 10 >= telaA * 9) { return ForaDaPasta(dono, pasta, fora) ? TelaCheia : 0; }
            var estilo = GetWindowLong(h, -16);
            var extra = GetWindowLong(h, -20);
            // WS_EX_TOOLWINDOW, WS_EX_NOACTIVATE, WS_EX_TRANSPARENT; GW_OWNER. Precisa de barra de titulo (WS_CAPTION)
            // ou ser janela de aplicativo (WS_EX_APPWINDOW, a da barra de tarefas): launchers sem borda, como o do
            // Astral Chain, nao tem titulo. (A sombra que o Windows desenha em volta, SysShadow, ja saiu acima.)
            if ((extra & (0x80 | 0x08000000 | 0x20)) != 0 || GetWindow(h, 4) != IntPtr.Zero) { return 0; }
            if ((estilo & 0xC00000) != 0xC00000 && (extra & 0x40000) == 0) { return 0; }
            return largura >= 400 && altura >= 300 ? Normal : 0;
        }

        // Jogo em tela cheia que o Selene enxerga segue a regra dele. Sem pasta, ele nao enxerga nenhum.
        static bool ForaDaPasta(int pid, string pasta, Dictionary<int, bool> fora)
        {
            bool sim;
            if (fora.TryGetValue(pid, out sim)) { return sim; }
            if (pasta == null) { sim = true; }
            else
            {
                var exe = CaminhoExe(pid);
                sim = exe != null && !exe.StartsWith(pasta.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase);
            }
            fora[pid] = sim;
            return sim;
        }

        static string CaminhoExe(int pid)
        {
            var p = OpenProcess(0x1000, false, pid);
            if (p == IntPtr.Zero) { return null; }
            try
            {
                var sb = new StringBuilder(1024);
                var tam = sb.Capacity;
                return QueryFullProcessImageNameW(p, 0, sb, ref tam) ? sb.ToString(0, tam) : null;
            }
            finally { CloseHandle(p); }
        }

        public struct Retangulo { public int Esq, Topo, Dir, Base; }
        public struct InfoMonitor { public int cbSize; public Retangulo Tela, Trabalho; public uint dwFlags; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct EntradaProcesso
        {
            public uint dwSize, cntUsage, th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID, cntThreads, th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }
        delegate bool CadaJanela(IntPtr h, IntPtr l);

        [DllImport("user32.dll")] static extern bool EnumWindows(CadaJanela cada, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int modo);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Retangulo r);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr h, int indice);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint tipo);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder nome, int max);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint modo);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr m, ref InfoMonitor info);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int atributo, out int valor, int tamanho);
        [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr foto, ref EntradaProcesso e);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr foto, ref EntradaProcesso e);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint acesso, bool herdar, int pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr p, int flags, StringBuilder nome, ref int tamanho);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    }

    // Numeros da tela de Downloads, sempre em pt-BR (a cultura do Windows pode ser outra).
    public static class Formato
    {
        static readonly CultureInfo Br = new CultureInfo("pt-BR");

        // Menos de 1 GB em MB sem decimal; dali para cima em GB com uma casa.
        public static string Tam(long b)
        {
            b = Math.Max(b, 0);
            return b >= 1073741824 ? (b / 1073741824.0).ToString("0.0", Br) + " GB" : (b / 1048576.0).ToString("0", Br) + " MB";
        }

        // "3,1 de 7,4 GB"; com unidades diferentes, as duas ("600 MB de 1,2 GB").
        public static string De(long feito, long total)
        {
            var f = Tam(feito); var t = Tam(total);
            var unidade = f.Substring(f.LastIndexOf(' '));
            return t.EndsWith(unidade) ? f.Substring(0, f.Length - unidade.Length) + " de " + t : f + " de " + t;
        }

        public static string Vel(long v) { return (v > 0 ? (v / 1048576.0).ToString("0.0", Br) : "...") + " MB/s"; }

        // Vazio quando nao da para saber.
        public static string Faltam(long feito, long total, long v)
        {
            if (v <= 0 || total <= 0) { return ""; }
            var seg = Math.Max(total - feito, 0) / (double)v;
            if (seg < 60) { return "falta menos de 1 min"; }
            var min = (long)Math.Ceiling(seg / 60);
            return min > 60 ? "faltam " + (min / 60).ToString(Br) + " h " + (min % 60).ToString(Br) + " min" : "faltam " + min.ToString(Br) + " min";
        }

        public static string Pct(long feito, long total) { var p = Textos.Pct(feito, total); return p < 0 ? "" : p.ToString(Br) + "%"; }

        public static string Tipo(string tipo) { return tipo == "rom" ? "Emulador" : tipo == "recomp" ? "Recomp" : "Jogo de PC"; }

        public static string Hora(DateTime d) { return d.ToString("HH:mm", Br); }
    }

    // Quem toca na linha: o botao (Acao) ou a propria linha sem botao (Acao null).
    public class Alvo { public Linha Linha; public string Acao; }

    // Uma linha da tela de Downloads. A chave e estavel ("d:" + jogo, "r:" + tarefa do Recomp,
    // "h:" + terminado): a cada segundo so os textos mudam, e a linha com foco continua a mesma.
    public class Linha
    {
        public string Chave;
        public Border Raiz;
        public TextBlock Nome, Tipo, Pct, Estado, Aviso;
        public ProgressBar Barra;
        public StackPanel Botoes;
        // Terminados: "HH:mm  Nome · tipo" numa linha so, com o nome em negrito.
        public System.Windows.Documents.Run Hora, NomeForte, TipoFim;
        public ModeloLinha Modelo;
        public readonly Dictionary<string, Button> PorAcao = new Dictionary<string, Button>();
        public HashSet<string> Inativos = new HashSet<string>();

        public IEnumerable<Button> EmOrdem { get { return Botoes.Children.OfType<Button>(); } }

        // O primeiro botao, ou a linha mesmo quando nao ha botao.
        public UIElement Primeiro { get { return (UIElement)EmOrdem.FirstOrDefault() ?? Raiz; } }
    }

    // O que uma linha mostra agora. Barra: -1 sem barra, -2 sem porcentagem, 0 a 100 o valor.
    public class ModeloLinha
    {
        public string Chave, Nome, Tipo, Pct, Estado, Aviso, Hora;
        // Estado em amarelo (esperando o download anterior terminar).
        public bool Alerta;
        public double Barra = -1;
        public readonly List<KeyValuePair<string, string>> Botoes = new List<KeyValuePair<string, string>>();
        public readonly HashSet<string> Inativos = new HashSet<string>();

        public ModeloLinha Botao(string acao, string texto) { Botoes.Add(new KeyValuePair<string, string>(acao, texto)); return this; }
    }

    // Mantem as linhas das secoes sem refazer a lista: troca textos e botoes, insere, tira e reordena so o
    // que mudou. Nunca Children.Clear(): o controle perderia o lugar.
    public class ListaViva
    {
        public readonly Dictionary<string, Linha> Linhas = new Dictionary<string, Linha>();
        readonly Func<string, Linha> criar;
        readonly Func<string, Button> criarBotao;
        // Depois de preencher cada linha: cores (botao desativado, estado em alerta) e a linha dos terminados.
        public Action<Linha> Pintar;

        public ListaViva(Func<string, Linha> criar, Func<string, Button> criarBotao) { this.criar = criar; this.criarBotao = criarBotao; }

        // Cada secao: o painel dela e as linhas em ordem. Devolve as chaves de cima para baixo.
        public List<string> Aplicar(List<KeyValuePair<Panel, List<ModeloLinha>>> secoes)
        {
            var querem = new HashSet<string>(secoes.SelectMany(s => s.Value).Select(m => m.Chave));
            foreach (var chave in Linhas.Keys.Where(k => !querem.Contains(k)).ToList())
            {
                var pai = Linhas[chave].Raiz.Parent as Panel;
                if (pai != null) { pai.Children.Remove(Linhas[chave].Raiz); }
                Linhas.Remove(chave);
            }
            foreach (var s in secoes)
            {
                for (var i = 0; i < s.Value.Count; i++)
                {
                    var m = s.Value[i];
                    Linha l;
                    if (!Linhas.TryGetValue(m.Chave, out l)) { l = criar(m.Chave); Linhas[m.Chave] = l; }
                    Preencher(l, m);
                    var pai = l.Raiz.Parent as Panel;
                    // As anteriores ja estao no lugar: esta so pode estar no indice i ou depois.
                    if (pai == s.Key && pai.Children.IndexOf(l.Raiz) == i) { continue; }
                    if (pai != null) { pai.Children.Remove(l.Raiz); }
                    s.Key.Children.Insert(Math.Min(i, s.Key.Children.Count), l.Raiz);
                }
            }
            return secoes.SelectMany(s => s.Value).Select(m => m.Chave).ToList();
        }

        static void Texto(TextBlock t, string s)
        {
            if (t == null) { return; }
            if (t.Text != (s ?? "")) { t.Text = s ?? ""; }
            var v = string.IsNullOrEmpty(s) ? Visibility.Collapsed : Visibility.Visible;
            if (t.Visibility != v) { t.Visibility = v; }
        }

        void Preencher(Linha l, ModeloLinha m)
        {
            Texto(l.Nome, m.Nome); Texto(l.Tipo, m.Tipo); Texto(l.Pct, m.Pct); Texto(l.Estado, m.Estado); Texto(l.Aviso, m.Aviso);
            if (l.Barra != null)
            {
                var v = m.Barra == -1 ? Visibility.Collapsed : Visibility.Visible;
                if (l.Barra.Visibility != v) { l.Barra.Visibility = v; }
                var indeterminada = m.Barra == -2;
                if (l.Barra.IsIndeterminate != indeterminada) { l.Barra.IsIndeterminate = indeterminada; }
                if (m.Barra >= 0 && l.Barra.Value != m.Barra) { l.Barra.Value = m.Barra; }
            }
            l.Modelo = m;
            l.Inativos = new HashSet<string>(m.Inativos);
            var acoes = m.Botoes.Select(b => b.Key).ToList();
            foreach (var acao in l.PorAcao.Keys.Where(a => !acoes.Contains(a)).ToList())
            {
                l.Botoes.Children.Remove(l.PorAcao[acao]);
                l.PorAcao.Remove(acao);
            }
            for (var i = 0; i < m.Botoes.Count; i++)
            {
                Button b;
                if (!l.PorAcao.TryGetValue(m.Botoes[i].Key, out b))
                {
                    b = criarBotao(m.Botoes[i].Key);
                    b.Tag = new Alvo { Linha = l, Acao = m.Botoes[i].Key };
                    l.PorAcao[m.Botoes[i].Key] = b;
                }
                if (!Equals(b.Content, m.Botoes[i].Value)) { b.Content = m.Botoes[i].Value; }
                var idx = l.Botoes.Children.IndexOf(b);
                if (idx == i) { continue; }
                if (idx >= 0) { l.Botoes.Children.Remove(b); }
                l.Botoes.Children.Insert(Math.Min(i, l.Botoes.Children.Count), b);
            }
            l.Botoes.Visibility = m.Botoes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            // Linha sem botao recebe o foco ela mesma (instalando, terminados, esperando).
            l.Raiz.Focusable = m.Botoes.Count == 0;
            if (Pintar != null) { Pintar(l); }
        }

        // A linha com foco sumiu: a que ocupou o lugar (a de baixo; sem ela, a de cima).
        public static string Substituta(List<string> antes, string chave, List<string> depois)
        {
            if (chave == null) { return null; }
            if (depois.Contains(chave)) { return chave; }
            var i = antes.IndexOf(chave);
            if (i < 0) { return depois.FirstOrDefault(); }
            for (var j = i + 1; j < antes.Count; j++) { if (depois.Contains(antes[j])) { return antes[j]; } }
            for (var j = i - 1; j >= 0; j--) { if (depois.Contains(antes[j])) { return antes[j]; } }
            return depois.FirstOrDefault();
        }
    }

    // Janela de Downloads: o que baixa, a fila, os pausados, o que ficou pela metade e o que terminou nesta
    // sessao, mais o armazenamento e um grafico pequeno da rede. Funciona com o controle no Fullscreen e com
    // o mouse no Desktop. Fechar so fecha: nao pausa nem cancela nada.
    public static class JanelaDownloads
    {
        // Fullscreen: ShowDialog (a biblioteca por baixo nao recebe o controle). Se o teste do controle pedir,
        // trocar para false abre com Show(), ainda com Owner.
        public const bool ModalNaTelaCheia = true;
        static TelaDownloads aberta;
        static bool abrindo;

        public static void Abrir(IPlayniteAPI api) { Abrir(api, Guid.Empty); }

        // foco: o jogo do "Ver downloads" (Guid.Empty: pelo Start, pelo topo ou pela barra lateral).
        public static void Abrir(IPlayniteAPI api, Guid foco)
        {
            try
            {
                if (aberta != null) { aberta.Frente(); return; }
                if (abrindo) { return; }
                if (api.ApplicationInfo.Mode != ApplicationMode.Fullscreen) { Criar(api, foco); return; }
                // Abrir dentro da acao do menu deixa o Selene devolver o foco a biblioteca por cima: espera o menu
                // fechar e a trava de foco dele passar (350 ms no HomeNav.FocusPill).
                abrindo = true;
                api.MainView.UIDispatcher.BeginInvoke(new Action(() =>
                {
                    var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
                    t.Tick += (s, e) =>
                    {
                        t.Stop();
                        abrindo = false;
                        try { if (aberta != null) { aberta.Frente(); } else { Criar(api, foco); } }
                        catch (Exception ex) { aberta = null; LogManager.GetLogger().Error(ex, "Falha ao abrir a tela de Downloads"); }
                    };
                    t.Start();
                }), DispatcherPriority.ApplicationIdle);
            }
            catch (Exception e) { abrindo = false; LogManager.GetLogger().Error(e, "Falha ao abrir a tela de Downloads"); }
        }

        static void Criar(IPlayniteAPI api, Guid foco)
        {
            var tela = new TelaDownloads(api, foco);
            aberta = tela;
            tela.Fechou += () => { if (aberta == tela) { aberta = null; } };
            tela.Mostrar(ModalNaTelaCheia);
        }

        public static string UltimoControle;
        public static int UltimoToque;
        public static bool UsandoTeclado;

        // Nomes dos botoes de baixo e da direita (confirmar/voltar) do controle. O SDL chama de A o botao de baixo:
        // no PlayStation ele e o X; no controle da Nintendo, o B.
        public static string[] Botoes(string nome)
        {
            var n = (nome ?? "").ToLowerInvariant();
            if (Regex.IsMatch(n, "ps3|ps4|ps5|dualshock|dualsense|playstation|sony")) { return new[] { "✕", "○" }; }
            if (Regex.IsMatch(n, "nintendo|switch|joy-con|pro controller")) { return new[] { "B", "A" }; }
            return new[] { "A", "B" };
        }

        public static string Dicas(bool teclado, string controle, bool trocarAB)
        {
            if (teclado) { return "[PgUp·PgDn] Rolar        [Enter] Escolher        [Esc] Voltar"; }
            var b = Botoes(controle);
            var escolher = trocarAB ? b[1] : b[0];
            var fechar = trocarAB ? b[0] : b[1];
            return "[" + Rolar(false, controle) + "] Rolar        [" + escolher + "] Escolher        [" + fechar + "] Voltar";
        }

        // Glifo da dica "Rolar": os botoes de ombro (no PlayStation tambem o analogico direito, R3).
        public static string Rolar(bool teclado, string controle)
        {
            if (teclado) { return "PgUp·PgDn"; }
            var n = (controle ?? "").ToLowerInvariant();
            if (Regex.IsMatch(n, "ps3|ps4|ps5|dualshock|dualsense|playstation|sony")) { return "L1·R1"; }
            if (Regex.IsMatch(n, "nintendo|switch|joy-con|pro controller")) { return "L·R"; }
            return "LB·RB";
        }

        // OnControllerButtonStateChanged do plugin, na thread da UI.
        public static void Controle(OnControllerButtonStateChangedArgs args)
        {
            if (args == null) { return; }
            // Guarda qual controle foi usado por ultimo, para as dicas mostrarem os botoes certos (PlayStation, Xbox...).
            if (args.Controller != null) { UltimoControle = args.Controller.Name ?? ""; }
            UltimoToque = Environment.TickCount;
            var t = aberta;
            if (t == null) { return; }
            try { t.DoSdk(args.Button, args.State); }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Downloads: falha no controle"); }
        }
    }

    public class TelaDownloads
    {
        readonly IPlayniteAPI api;
        readonly Window w;
        readonly bool telaCheia, trocarAB;
        readonly double esc;
        readonly Guid focoPedido;
        readonly ListaViva lista;
        readonly Stopwatch aberta = Stopwatch.StartNew();
        readonly DispatcherTimer relogio;
        readonly Dictionary<string, Tarefa> recomps = new Dictionary<string, Tarefa>();
        readonly Dictionary<string, ItemFila> metades = new Dictionary<string, ItemFila>();
        // A seguir, os retomados que esperam o trabalho da sessao anterior (sem Execucao ainda).
        readonly Dictionary<string, ItemFila> esperas = new Dictionary<string, ItemFila>();
        readonly Dictionary<Guid, DateTime> pausando = new Dictionary<Guid, DateTime>();
        // Ultima vez que cada acao veio e de onde: o mesmo aperto chega pela janela e pelo SDK.
        readonly Dictionary<string, KeyValuePair<int, string>> ultimas = new Dictionary<string, KeyValuePair<int, string>>();
        readonly List<double> historico = new List<double>();
        StackPanel corpo, pBaixando, pSeguir, pPausados, pMetade, pTerminados;
        StackPanel dicas;
        string dicasAtuais;
        TextBlock resumo, topo, hora, semNada, semAgora, txtRede;
        FrameworkElement vazio, tBaixando, tSeguir, tPausados, tMetade, tTerminados;
        Button fechar;
        Border armazenamento, pilula, cartaoTerminados;
        ControlTemplate modeloBarra;
        // Trecho claro que corre na barra sem porcentagem (o mesmo pincel em todas; para ao fechar).
        readonly LinearGradientBrush corredor;
        readonly TranslateTransform corre = new TranslateTransform();
        bool carregada, correndo, precisaCorrer, encerrada;
        // Rolagem pelo controle: o analogico direito pelo SDK (1 cima, -1 baixo, 0 solto) e, se houver, o XInput.
        readonly DispatcherTimer rolador;
        readonly Stopwatch passoRolagem = new Stopwatch();
        int analogicoSdk;
        bool rolando, semRolar;
        double posRolagem;
        int xinputSlot = -1, xinputProcura = unchecked(Environment.TickCount - 5000);
        static bool semXinput14, semXinput91;
        ScrollViewer rolagem;
        System.Windows.Shapes.Polygon area;
        System.Windows.Shapes.Polyline linhaRede;
        Canvas grafico;
        List<string> ordem = new List<string>();
        string focoChave, focoAcao;
        string pendenteChave, pendenteAcao;
        DateTime pendenteAte;
        bool retomouFoco, focoInicial, viuControle;
        int quietoAte;
        double maxima;
        int diagnosticos;

        public event Action Fechou;

        public TelaDownloads(IPlayniteAPI api, Guid foco)
        {
            this.api = api;
            focoPedido = foco;
            telaCheia = api.ApplicationInfo.Mode == ApplicationMode.Fullscreen;
            esc = telaCheia ? 1.4 : 1.0;
            try { trocarAB = api.ApplicationSettings.Fullscreen.SwapConfirmCancelButtons; } catch (Exception) { }
            lista = new ListaViva(CriarLinha, CriarBotao) { Pintar = Pintar };
            corredor = new LinearGradientBrush { StartPoint = new Point(0, 0.5), EndPoint = new Point(1, 0.5), RelativeTransform = corre };
            var claro = (Color)ColorConverter.ConvertFromString("#E8ECF2");
            foreach (var p in new[] { new KeyValuePair<double, bool>(0, false), new KeyValuePair<double, bool>(0.001, true), new KeyValuePair<double, bool>(0.4, true), new KeyValuePair<double, bool>(0.401, false) })
            {
                corredor.GradientStops.Add(new GradientStop(p.Value ? claro : Colors.Transparent, p.Key));
            }
            w = api.Dialogs.CreateWindow(new WindowCreationOptions { ShowCloseButton = true, ShowMinimizeButton = !telaCheia, ShowMaximizeButton = !telaCheia });
            w.Title = "Downloads";
            if (telaCheia)
            {
                // Filha da janela do Playnite, centrada, sem minimizar: nunca fica atras nem some.
                var dona = api.Dialogs.GetCurrentAppWindow();
                if (dona == null || dona == w) { dona = Application.Current.MainWindow; }
                if (dona != null && dona != w) { w.Owner = dona; w.WindowStartupLocation = WindowStartupLocation.CenterOwner; }
                else { w.WindowStartupLocation = WindowStartupLocation.CenterScreen; }
                double larg = dona != null && dona.ActualWidth > 0 ? dona.ActualWidth : SystemParameters.PrimaryScreenWidth;
                double alt = dona != null && dona.ActualHeight > 0 ? dona.ActualHeight : SystemParameters.PrimaryScreenHeight;
                w.Width = Limite(larg * 0.6, 900, larg * 0.9);
                w.Height = Limite(alt * 0.85, 620, alt * 0.9);
                w.ResizeMode = ResizeMode.NoResize;
                w.ShowInTaskbar = false;
            }
            else
            {
                w.Width = 960; w.Height = 760;
                w.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            }
            w.Content = Montar();
            w.PreviewKeyDown += (s, e) => Tecla(e);
            w.PreviewGotKeyboardFocus += (s, e) => Focou(e.NewFocus as FrameworkElement);
            w.Loaded += (s, e) => { carregada = true; Animar(precisaCorrer); Carregou(); };
            w.Activated += (s, e) => { Diagnostico("janela ativada"); if (telaCheia) { rolador.Start(); } };
            w.Deactivated += (s, e) => { rolador.Stop(); PararRolagem(); Desativou(); };
            // Rolagem pelo analogico direito: so com a janela ativa (para ao desativar e ao fechar).
            rolador = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(16) };
            rolador.Tick += (s, e) => Rolar();
            relogio = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
            relogio.Tick += (s, e) => Atualizar();
            w.Closed += (s, e) => Encerrar();
        }

        static double Limite(double v, double min, double max) { return Math.Max(Math.Min(v, max), Math.Min(min, max)); }

        // A barra sem porcentagem so corre com a janela carregada e alguma barra assim visivel.
        void Animar(bool liga)
        {
            if (liga == correndo) { return; }
            correndo = liga;
            // Como no CSS do desenho: 40% da largura, de -100% a 250% dela em 1,6 s.
            corre.BeginAnimation(TranslateTransform.XProperty, !liga ? null : new System.Windows.Media.Animation.DoubleAnimation(-0.4, 1.0, new Duration(TimeSpan.FromSeconds(1.6)))
                { RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever });
        }

        // Fechou (ou nem chegou a abrir): para o relogio e a animacao e avisa uma vez so.
        void Encerrar()
        {
            relogio.Stop();
            rolador.Stop();
            carregada = false;
            Animar(false);
            if (encerrada) { return; }
            encerrada = true;
            var f = Fechou;
            if (f != null) { f(); }
        }

        public void Mostrar(bool modalNaTelaCheia)
        {
            try
            {
                Atualizar();
                relogio.Start();
                if (telaCheia && modalNaTelaCheia) { w.ShowDialog(); } else { w.Show(); }
            }
            catch (Exception)
            {
                Encerrar();
                throw;
            }
        }

        public void Frente()
        {
            if (w.WindowState == WindowState.Minimized) { w.WindowState = WindowState.Normal; }
            w.Activate();
        }

        // ---------- Montagem ----------

        static SolidColorBrush Cor(string hex) { var c = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); c.Freeze(); return c; }
        // Cores do desenho aprovado (v40). Os alfas: .05 = 0D, .07 = 12, .08 = 14, .10 = 1A, .12 = 1F, .14 = 24.
        static readonly Brush Branco = Cor("#F2F4F8"), Claro = Cor("#C9D0DB"), Cinza = Cor("#9AA4B4"), Amarelo = Cor("#E8C27A"), Destaque = Cor("#FFFFFF"),
            FundoBotao = Cor("#1FFFFFFF"), FundoFoco = Cor("#FFFFFF"), TextoFoco = Cor("#141820"), FundoInativo = Cor("#14FFFFFF"), TextoInativo = Cor("#7F8898"),
            FundoLinha = Cor("#12FFFFFF"), FundoTerminados = Cor("#0DFFFFFF"), FundoPilula = Cor("#1AFFFFFF"), FundoTecla = Cor("#24FFFFFF"), Trilho = Cor("#24FFFFFF"),
            Cheio = Cor("#E8ECF2"), Divisa = Cor("#1FFFFFFF"), Transparente = Cor("#00000000");
        // Inter (a do desenho) se estiver instalada; senao a do Selene.
        static readonly FontFamily Fonte = new FontFamily("Inter, Segoe UI Variable Display, Segoe UI");

        TextBlock Txt(double tamanho, Brush cor, bool forte)
        {
            return new TextBlock { FontSize = tamanho * esc, Foreground = cor, FontWeight = forte ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        }

        // Fundo da tela: radial-gradient(120% 90% at 20% 0%, #2a3140, #141820 55%, #0c0e13).
        static Brush Fundo()
        {
            var g = new RadialGradientBrush { Center = new Point(0.2, 0), GradientOrigin = new Point(0.2, 0), RadiusX = 1.2, RadiusY = 0.9 };
            g.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#2A3140"), 0));
            g.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#141820"), 0.55));
            g.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#0C0E13"), 1));
            g.Freeze();
            return g;
        }

        // Barra fina: trilho claro, preenchimento quase branco; sem porcentagem, o trecho que corre.
        ProgressBar NovaBarra()
        {
            if (modeloBarra == null)
            {
                var raio = new CornerRadius(3 * esc);
                var grade = new FrameworkElementFactory(typeof(Grid));
                var trilho = new FrameworkElementFactory(typeof(Border), "PART_Track");
                trilho.SetValue(Border.BackgroundProperty, Trilho);
                trilho.SetValue(Border.CornerRadiusProperty, raio);
                var cheio = new FrameworkElementFactory(typeof(Border), "PART_Indicator");
                cheio.SetValue(Border.BackgroundProperty, Cheio);
                cheio.SetValue(Border.CornerRadiusProperty, raio);
                cheio.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Left);
                var faixa = new FrameworkElementFactory(typeof(Border), "corredor");
                faixa.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.ForegroundProperty));
                faixa.SetValue(Border.CornerRadiusProperty, raio);
                faixa.SetValue(UIElement.VisibilityProperty, Visibility.Collapsed);
                grade.AppendChild(trilho); grade.AppendChild(cheio); grade.AppendChild(faixa);
                var sem = new Trigger { Property = ProgressBar.IsIndeterminateProperty, Value = true };
                sem.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Collapsed, "PART_Indicator"));
                sem.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Visible, "corredor"));
                modeloBarra = new ControlTemplate(typeof(ProgressBar)) { VisualTree = grade };
                modeloBarra.Triggers.Add(sem);
            }
            return new ProgressBar { Template = modeloBarra, Foreground = corredor, Height = 6 * esc, Minimum = 0, Maximum = 100, Focusable = false };
        }

        // Titulo de secao: 13 px, caixa alta, letras espacadas (.12em). O WPF nao espaca letras: uma por bloco.
        FrameworkElement Titulo(StackPanel destino, string texto)
        {
            var p = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 20 * esc, 0, 0) };
            foreach (var c in texto.ToUpper(new CultureInfo("pt-BR")))
            {
                var t = Txt(13, Cinza, true); t.Text = c.ToString(); t.TextTrimming = TextTrimming.None; t.Margin = new Thickness(0, 0, 13 * 0.12 * esc, 0);
                p.Children.Add(t);
            }
            destino.Children.Add(p);
            return p;
        }

        // Botao em pilula com desenho proprio: o foco do controle fica claro em qualquer tema.
        static ControlTemplate modelo;
        static ControlTemplate Modelo()
        {
            if (modelo != null) { return modelo; }
            var borda = new FrameworkElementFactory(typeof(Border));
            borda.AddHandler(FrameworkElement.SizeChangedEvent, new SizeChangedEventHandler(Redonda));
            borda.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
            borda.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
            borda.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
            borda.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
            var conteudo = new FrameworkElementFactory(typeof(ContentPresenter));
            conteudo.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            conteudo.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
            borda.AppendChild(conteudo);
            modelo = new ControlTemplate(typeof(Button)) { VisualTree = borda };
            return modelo;
        }

        // Pilula (raio 999 do CSS): no WPF um raio maior que a metade da altura vira elipse, entao segue a altura.
        static void Redonda(object s, SizeChangedEventArgs e)
        {
            var b = (Border)s;
            var r = b.ActualHeight / 2;
            if (b.CornerRadius.TopLeft != r) { b.CornerRadius = new CornerRadius(r); }
        }

        Button CriarBotao(string acao)
        {
            // Pilula 10x22, 15 px; o espaco de 10 entre elas fica a direita de cada uma.
            var b = new Button
            {
                Template = Modelo(), FocusVisualStyle = null, FontFamily = Fonte, FontSize = 15 * esc, Padding = new Thickness(22 * esc, 10 * esc, 22 * esc, 10 * esc),
                Margin = new Thickness(0, 0, 10 * esc, 0), BorderBrush = Transparente, BorderThickness = new Thickness(0)
            };
            PintarBotao(b, false);
            b.GotKeyboardFocus += (s, e) => PintarBotao(b, true);
            b.LostKeyboardFocus += (s, e) => PintarBotao(b, false);
            b.Click += (s, e) => { var a = b.Tag as Alvo; if (a != null) { Escolher(a); } };
            return b;
        }

        // Normal: fundo .12 e texto claro; com foco: branco e texto escuro em semibold; desativado: mais apagado.
        static void PintarBotao(Button b, bool foco)
        {
            var a = b.Tag as Alvo;
            var inativo = a != null && a.Acao != null && a.Linha.Inativos.Contains(a.Acao);
            var fundo = foco ? FundoFoco : inativo ? FundoInativo : FundoBotao;
            var texto = foco ? TextoFoco : inativo ? TextoInativo : Branco;
            var peso = foco ? FontWeights.SemiBold : FontWeights.Normal;
            if (b.Background != fundo) { b.Background = fundo; }
            if (b.Foreground != texto) { b.Foreground = texto; }
            if (b.FontWeight != peso) { b.FontWeight = peso; }
        }

        // Depois de cada atualizacao da linha: botoes desativados, estado em alerta e a linha dos terminados.
        void Pintar(Linha l)
        {
            foreach (var b in l.EmOrdem) { PintarBotao(b, b.IsKeyboardFocused); }
            var m = l.Modelo;
            if (m == null) { return; }
            if (l.Estado != null)
            {
                var cor = m.Alerta ? Amarelo : Claro;
                if (l.Estado.Foreground != cor) { l.Estado.Foreground = cor; }
                // O aviso em amarelo quebra a linha; o estado comum (muda a cada segundo) nao.
                var quebra = m.Alerta || l.NomeForte != null ? TextWrapping.Wrap : TextWrapping.NoWrap;
                if (l.Estado.TextWrapping != quebra) { l.Estado.TextWrapping = quebra; }
            }
            if (l.NomeForte == null) { return; }
            var tipo = string.IsNullOrEmpty(m.Tipo) ? "" : " · " + m.Tipo;
            if (l.Hora.Text != (m.Hora ?? "")) { l.Hora.Text = m.Hora ?? ""; }
            if (l.NomeForte.Text != (m.Nome ?? "")) { l.NomeForte.Text = m.Nome ?? ""; }
            if (l.TipoFim.Text != tipo) { l.TipoFim.Text = tipo; }
        }

        // Cartao do jogo: padding 18x22, raio 18, fundo .07; linhas com 10 de espaco. Terminados ("h:"): so as
        // linhas, dentro do cartao comum da secao, com 12 de espaco. A borda de 2 so aparece no foco da linha.
        Linha CriarLinha(string chave)
        {
            var l = new Linha { Chave = chave };
            var textos = new StackPanel();
            l.Estado = Txt(15, Claro, false);
            l.Aviso = Txt(14, Cinza, false); l.Aviso.TextWrapping = TextWrapping.Wrap; l.Aviso.TextTrimming = TextTrimming.None;
            l.Barra = NovaBarra(); l.Barra.Margin = new Thickness(0, 10 * esc, 0, 0); l.Barra.Visibility = Visibility.Collapsed;
            l.Botoes = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10 * esc, 0, 0) };
            if (chave.StartsWith("h:"))
            {
                var linha1 = Txt(15, Branco, false);
                l.Hora = new System.Windows.Documents.Run { Foreground = Cinza };
                l.NomeForte = new System.Windows.Documents.Run { FontWeight = FontWeights.Bold };
                l.TipoFim = new System.Windows.Documents.Run();
                linha1.Inlines.Add(l.Hora); linha1.Inlines.Add(new System.Windows.Documents.Run("  ")); linha1.Inlines.Add(l.NomeForte); linha1.Inlines.Add(l.TipoFim);
                l.Estado.TextWrapping = TextWrapping.Wrap; l.Estado.TextTrimming = TextTrimming.None;
                textos.Children.Add(linha1); textos.Children.Add(l.Estado); textos.Children.Add(l.Aviso); textos.Children.Add(l.Botoes);
                // 6 + 6 de folga entre duas linhas = os 12 do desenho; o cartao da secao desconta a folga.
                l.Raiz = new Border { Child = textos, Padding = new Thickness(8 * esc - 2, 6 * esc - 2, 8 * esc - 2, 6 * esc - 2), CornerRadius = new CornerRadius(10 * esc),
                    BorderBrush = Transparente, BorderThickness = new Thickness(2), FocusVisualStyle = null, Tag = new Alvo { Linha = l } };
            }
            else
            {
                l.Nome = Txt(20, Branco, true); l.Nome.VerticalAlignment = VerticalAlignment.Top;
                l.Tipo = Txt(14, Cinza, false); l.Tipo.Margin = new Thickness(16 * esc, 0, 0, 0); l.Tipo.VerticalAlignment = VerticalAlignment.Top;
                l.Pct = Txt(20, Branco, true); l.Pct.Margin = new Thickness(16 * esc, 0, 0, 0); l.Pct.VerticalAlignment = VerticalAlignment.Top;
                l.Estado.Margin = new Thickness(0, 10 * esc, 0, 0);
                l.Aviso.Margin = new Thickness(0, 10 * esc, 0, 0);
                var cabeca = new DockPanel { LastChildFill = true };
                DockPanel.SetDock(l.Pct, Dock.Right); DockPanel.SetDock(l.Tipo, Dock.Right);
                cabeca.Children.Add(l.Pct); cabeca.Children.Add(l.Tipo); cabeca.Children.Add(l.Nome);
                textos.Children.Add(cabeca); textos.Children.Add(l.Estado); textos.Children.Add(l.Aviso); textos.Children.Add(l.Barra); textos.Children.Add(l.Botoes);
                l.Raiz = new Border { Child = textos, Padding = new Thickness(22 * esc - 2, 18 * esc - 2, 22 * esc - 2, 18 * esc - 2), Margin = new Thickness(0, 20 * esc, 0, 0),
                    CornerRadius = new CornerRadius(18 * esc), Background = FundoLinha, BorderBrush = Transparente, BorderThickness = new Thickness(2), FocusVisualStyle = null, Tag = new Alvo { Linha = l } };
            }
            l.Raiz.GotKeyboardFocus += (s, e) => { if (e.NewFocus == l.Raiz) { l.Raiz.BorderBrush = Destaque; } };
            l.Raiz.LostKeyboardFocus += (s, e) => { if (e.OldFocus == l.Raiz) { l.Raiz.BorderBrush = Transparente; } };
            return l;
        }

        StackPanel Secao(StackPanel destino) { var p = new StackPanel(); destino.Children.Add(p); return p; }

        // Barra de rolagem so desta tela: fina e escura, trilho transparente, polegar arredondado (.18), sem setas.
        Style Rolagem()
        {
            var larg = (7 * esc).ToString(CultureInfo.InvariantCulture);
            var raio = (3.5 * esc).ToString(CultureInfo.InvariantCulture);
            var xaml = "<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='ScrollBar'>"
                + "<Setter Property='Width' Value='" + larg + "'/><Setter Property='MinWidth' Value='" + larg + "'/><Setter Property='Background' Value='Transparent'/>"
                + "<Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ScrollBar'><Border Background='Transparent'>"
                + "<Track x:Name='PART_Track' IsDirectionReversed='True'><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType='Thumb'>"
                + "<Border CornerRadius='" + raio + "' Background='#2EFFFFFF'/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>"
                + "</Border></ControlTemplate></Setter.Value></Setter></Style>";
            return (Style)System.Windows.Markup.XamlReader.Parse(xaml);
        }

        FrameworkElement Montar()
        {
            var raiz = new Grid { Background = telaCheia ? Fundo() : Transparente };
            raiz.SetValue(System.Windows.Documents.TextElement.FontFamilyProperty, Fonte);
            raiz.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            raiz.RowDefinitions.Add(new RowDefinition());
            raiz.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var margem = 48 * esc;

            // Cabecalho: "Downloads" a esquerda; a direita a pilula do indicador do topo, a hora e Fechar.
            var cabeca = new DockPanel { Margin = new Thickness(margem, margem, margem, 0) };
            var direita = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            topo = Txt(15, Claro, false);
            pilula = new Border { Child = topo, Padding = new Thickness(14 * esc, 6 * esc, 14 * esc, 6 * esc), Background = FundoPilula,
                Margin = new Thickness(0, 0, 14 * esc, 0), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
            pilula.SizeChanged += Redonda;
            hora = Txt(15, Claro, false); hora.Text = Formato.Hora(DateTime.Now);
            fechar = CriarBotao("fechar");
            fechar.Content = "Fechar"; fechar.Tag = "fechar"; fechar.Margin = new Thickness(14 * esc, 0, 0, 0); fechar.VerticalAlignment = VerticalAlignment.Center;
            fechar.Click += (s, e) => w.Close();
            direita.Children.Add(pilula); direita.Children.Add(hora); direita.Children.Add(fechar);
            DockPanel.SetDock(direita, Dock.Right);
            cabeca.Children.Add(direita);
            var titulos = new StackPanel();
            var titulo = Txt(34, Branco, false); titulo.FontWeight = FontWeights.Bold; titulo.Text = "Downloads";
            resumo = Txt(15, Claro, false); resumo.Margin = new Thickness(0, 4 * esc, 0, 0);
            titulos.Children.Add(titulo); titulos.Children.Add(resumo);
            cabeca.Children.Add(titulos);
            raiz.Children.Add(cabeca);

            // Tudo com 20 de espaco acima (titulos, cartoes, avisos), como o gap da coluna do desenho.
            corpo = new StackPanel { Margin = new Thickness(margem, 0, margem, 0) };
            var caixaVazio = new StackPanel { Margin = new Thickness(0, 20 * esc, 0, 0) };
            semNada = Txt(20, Branco, true); semNada.Text = "Nenhum download";
            var dica = Txt(15, Claro, false); dica.Text = "Para baixar, escolha um jogo e use Instalar."; dica.Margin = new Thickness(0, 10 * esc, 0, 0);
            caixaVazio.Children.Add(semNada); caixaVazio.Children.Add(dica);
            vazio = caixaVazio;
            corpo.Children.Add(caixaVazio);
            tBaixando = Titulo(corpo, "Baixando agora");
            semAgora = Txt(15, Claro, false); semAgora.Text = "Nenhum download agora."; semAgora.Margin = new Thickness(0, 20 * esc, 0, 0); corpo.Children.Add(semAgora);
            pBaixando = Secao(corpo);
            tSeguir = Titulo(corpo, "A seguir"); pSeguir = Secao(corpo);
            tPausados = Titulo(corpo, "Pausados"); pPausados = Secao(corpo);
            tMetade = Titulo(corpo, "Pela metade"); pMetade = Secao(corpo);
            tTerminados = Titulo(corpo, "Terminados nesta sessão");
            // Os terminados ficam num cartao so (padding 16x22, fundo .05); as linhas tem 6 de folga em volta.
            pTerminados = new StackPanel();
            cartaoTerminados = new Border { Child = pTerminados, Padding = new Thickness(14 * esc, 10 * esc, 14 * esc, 10 * esc), Margin = new Thickness(0, 20 * esc, 0, 0),
                CornerRadius = new CornerRadius(18 * esc), Background = FundoTerminados };
            corpo.Children.Add(cartaoTerminados);
            corpo.Children.Add(Armazenamento());
            rolagem = new ScrollViewer { Content = corpo, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
            rolagem.Resources[typeof(System.Windows.Controls.Primitives.ScrollBar)] = Rolagem();
            Grid.SetRow(rolagem, 1);
            raiz.Children.Add(rolagem);

            // Dicas do controle (so na tela cheia): a direita, com uma linha fina em cima.
            if (telaCheia)
            {
                dicas = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                AtualizarDicas();
                var rodape = new Border { Child = dicas, BorderBrush = Divisa, BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(0, 14 * esc, 0, 0),
                    Margin = new Thickness(margem, 20 * esc, margem, margem) };
                Grid.SetRow(rodape, 2);
                raiz.Children.Add(rodape);
            }
            return raiz;
        }

        // Armazenamento e rede: so leitura, um bloco focavel sem acao no fim (para o controle rolar ate la).
        // Os discos sao lidos uma vez, ao abrir.
        FrameworkElement Armazenamento()
        {
            var p = new StackPanel();
            var t = Txt(20, Branco, true); t.Text = "Armazenamento"; t.Margin = new Thickness(0, 0, 0, 10 * esc);
            p.Children.Add(t);
            try
            {
                var instalados = api.Database.Games.Where(x => x.IsInstalled && x.InstallSize.HasValue && x.InstallSize.Value > 0).ToList();
                var discos = instalados.Where(x => !string.IsNullOrEmpty(x.InstallDirectory) && Path.IsPathRooted(x.InstallDirectory)).Select(x => Path.GetPathRoot(x.InstallDirectory).ToUpperInvariant())
                    .Concat(new[] { Path.GetPathRoot(Dados.Raiz).ToUpperInvariant() }).Distinct().OrderBy(x => x);
                foreach (var d in discos)
                {
                    DriveInfo info;
                    try { info = new DriveInfo(d); if (!info.IsReady) { continue; } }
                    catch (ArgumentException) { continue; }
                    if (info.TotalSize <= 0) { continue; }
                    var usado = info.TotalSize - info.AvailableFreeSpace;
                    var rotulo = Txt(15, Claro, false);
                    rotulo.Text = "Disco " + d.TrimEnd('\\') + "  ·  " + Formato.Tam(usado) + " usados de " + Formato.Tam(info.TotalSize) + "  ·  " + Formato.Tam(info.AvailableFreeSpace) + " livres";
                    p.Children.Add(rotulo);
                    var uso = NovaBarra(); uso.Value = usado * 100.0 / info.TotalSize; uso.Margin = new Thickness(0, 6 * esc, 0, 12 * esc);
                    p.Children.Add(uso);
                }
                var resumoJogos = Txt(15, Claro, true);
                resumoJogos.Text = instalados.Count + " jogos instalados ocupam " + Formato.Tam(instalados.Sum(x => (long)x.InstallSize.Value));
                resumoJogos.Margin = new Thickness(0, 0, 0, 4 * esc);
                p.Children.Add(resumoJogos);
                foreach (var g in instalados.OrderByDescending(x => x.InstallSize.Value).Take(10))
                {
                    var l = Txt(14, Cinza, false); l.Text = Formato.Tam((long)g.InstallSize.Value) + "  ·  " + Textos.Nome(g.Name, 60); l.Margin = new Thickness(0, 3 * esc, 0, 0);
                    p.Children.Add(l);
                }
            }
            catch (Exception e) { LogManager.GetLogger().Warn(e, "Downloads: armazenamento"); }

            txtRede = Txt(15, Claro, false); txtRede.Margin = new Thickness(0, 16 * esc, 0, 6 * esc);
            p.Children.Add(txtRede);
            grafico = new Canvas { Height = 60 * esc, ClipToBounds = true, Background = Cor("#14FFFFFF") };
            area = new System.Windows.Shapes.Polygon { Fill = Cor("#40E8ECF2") };
            linhaRede = new System.Windows.Shapes.Polyline { Stroke = Cheio, StrokeThickness = 2 };
            grafico.Children.Add(area); grafico.Children.Add(linhaRede);
            p.Children.Add(grafico);
            // No mesmo cartao dos jogos.
            armazenamento = new Border { Child = p, Padding = new Thickness(22 * esc - 2, 18 * esc - 2, 22 * esc - 2, 18 * esc - 2), Margin = new Thickness(0, 20 * esc, 0, 0), CornerRadius = new CornerRadius(18 * esc),
                Background = FundoLinha, BorderBrush = Transparente, BorderThickness = new Thickness(2), Focusable = true, FocusVisualStyle = null, Tag = "armazenamento" };
            armazenamento.GotKeyboardFocus += (s, e) => armazenamento.BorderBrush = Destaque;
            armazenamento.LostKeyboardFocus += (s, e) => armazenamento.BorderBrush = Transparente;
            return armazenamento;
        }

        // ---------- Lista viva ----------

        static string Etapa(Tarefa t)
        {
            var feito = Formato.De(t.Feito, t.Total);
            switch (t.Etapa)
            {
                case "baixando":
                    var s = "Baixando" + (t.Total > 0 ? " · " + feito : t.Feito > 0 ? " · " + Formato.Tam(t.Feito) : "") + " · " + Formato.Vel(t.Velocidade);
                    var falta = Formato.Faltam(t.Feito, t.Total, t.Velocidade);
                    return falta.Length > 0 ? s + " · " + falta : s;
                case "fila": return "Aguardando: outra pessoa está baixando";
                case "reconectando": return "A conexão caiu. Reconectando...";
                case "verificando": return "Verificando os arquivos...";
                case "instalando": return "Instalando. Se o Windows perguntar, escolha Sim";
                case "pausado": return "Pausado" + (t.Total > 0 ? " · " + feito : t.Feito > 0 ? " · " + Formato.Tam(t.Feito) : "");
                case "cancelando": return "Cancelando...";
                default: return "Conectando...";
            }
        }

        static string EtapaRecomp(Tarefa t)
        {
            switch (t.Etapa)
            {
                case "baixando": return "Baixando" + (t.Total > 0 ? " · " + Formato.De(t.Feito, t.Total) : "");
                case "extraindo": return "Extraindo";
                case "instalando": return "Instalando";
                case "complemento": return "Preparando · baixando um complemento do instalador";
                default: return "Preparando";
            }
        }

        static double Valor(Tarefa t) { var p = Textos.Pct(t.Feito, t.Total); return p < 0 ? -2 : p; }

        ModeloLinha Download(Tarefa t)
        {
            var m = new ModeloLinha { Chave = "d:" + t.JogoId, Nome = Textos.Nome(t.Nome, 48), Tipo = Formato.Tipo(t.Tipo), Pct = Formato.Pct(t.Feito, t.Total), Estado = Etapa(t) };
            var e = t.Download;
            if (t.Etapa == "instalando")
            {
                m.Barra = -2; m.Pct = "";
                m.Aviso = "Não dá para pausar nem cancelar durante a instalação.";
                return m;
            }
            if (t.Etapa == "cancelando")
            {
                m.Barra = -2; m.Pct = "";
                m.Botao("cancelando", "Cancelando...");
                m.Inativos.Add("cancelando");
                return m;
            }
            m.Barra = t.Etapa == "baixando" || t.Etapa == "reconectando" || t.Etapa == "pausado" ? Valor(t) : -2;
            if (e == null) { return m; }
            DateTime desde;
            if (pausando.TryGetValue(t.JogoId, out desde) && !e.Pausado && (DateTime.Now - desde).TotalSeconds < 5) { m.Botao("pausar", "Pausando..."); m.Inativos.Add("pausar"); }
            else if (e.PodePausar) { m.Botao("pausar", "Pausar"); }
            m.Botao("cancelar", "Cancelar");
            return m;
        }

        ModeloLinha Recomp(Tarefa t)
        {
            var m = new ModeloLinha { Chave = "r:" + t.Id, Nome = Textos.Nome(t.Nome, 48), Tipo = "Recomp", Pct = Formato.Pct(t.Feito, t.Total), Estado = EtapaRecomp(t), Barra = Valor(t) };
            if (t.Cancelar != null) { m.Botao("cancelarRecomp", "Cancelar"); }
            else { m.Aviso = "Não dá para cancelar nesta etapa."; }
            return m;
        }

        ModeloLinha Terminado(Tarefa t, bool temMetade)
        {
            var m = new ModeloLinha { Chave = "h:" + t.Id + ":" + t.Fim.Ticks, Hora = Formato.Hora(t.Fim), Nome = Textos.Nome(t.Nome, 48), Tipo = Formato.Tipo(t.Recomp ? "recomp" : t.Tipo) };
            var motivo = string.IsNullOrEmpty(t.Motivo) ? null : Textos.Nome(t.Motivo.Trim().TrimEnd('.'), 300);
            if (t.Recomp)
            {
                switch (t.Etapa)
                {
                    case "pronto": m.Estado = "Recomp instalado. Pronto para jogar"; break;
                    case "cancelado": m.Estado = "Cancelado. O Recomp não ficou instalado."; break;
                    case "erro": m.Estado = (motivo == null ? "Não terminou." : "Não terminou: " + motivo + ".") + " O Recomp não ficou instalado."; break;
                    default: m.Estado = "A instalação do Recomp terminou. Confira na biblioteca se ficou instalado."; break;
                }
                return m;
            }
            switch (t.Etapa)
            {
                case "pronto": m.Estado = "Pronto para jogar"; break;
                case "cancelado-nada": m.Estado = "Cancelado. Nada tinha sido baixado."; break;
                case "cancelado":
                    m.Estado = temMetade && t.Motivo == "demorou para parar" ? "Cancelado. Demorou para parar; o que já baixou está em Pela metade."
                        : "Cancelado." + (temMetade ? " O que já baixou está em Pela metade." : "");
                    break;
                default:
                    m.Estado = motivo == null ? "Não terminou." : "Não terminou: " + motivo + ".";
                    if (temMetade) { m.Aviso = "O que já baixou está em Pela metade."; }
                    break;
            }
            return m;
        }

        void Atualizar()
        {
            try
            {
                var todas = Tarefas.Copia();
                var tarefas = todas.Where(x => !x.Terminada).ToList();
                var terminados = Tarefas.Terminados();
                // (cancelando fica so em Baixando agora ate o worker sair)
                var metade = FilaSalva.Metade().Where(x => !Gerenciador.Presente(x.Key.jogo)).ToList();
                var esperando = FilaSalva.Esperando();
                var baixando = tarefas.Where(x => !x.Recomp && x.Etapa != "pausado" && x.Etapa != "nafila").ToList();
                var rec = tarefas.Where(x => x.Recomp).ToList();
                var fila = tarefas.Where(x => !x.Recomp && x.Etapa == "nafila").OrderBy(x => x.Posicao).ToList();
                var pausados = tarefas.Where(x => !x.Recomp && x.Etapa == "pausado").ToList();
                var comMetade = new HashSet<Guid>(metade.Select(x => x.Key.jogo));

                recomps.Clear(); metades.Clear(); esperas.Clear();
                var mBaixando = baixando.Select(x => Download(x)).Concat(rec.Select(x => { recomps["r:" + x.Id] = x; return Recomp(x); })).ToList();
                var mSeguir = new List<ModeloLinha>();
                var n = 0;
                foreach (var t in fila)
                {
                    n++;
                    var m = new ModeloLinha { Chave = "d:" + t.JogoId, Nome = n + "º  " + Textos.Nome(t.Nome, 48), Tipo = Formato.Tipo(t.Tipo), Estado = t.Total > 0 ? Formato.Tam(t.Total) : null };
                    if (n >= 2) { m.Botao("frente", "Baixar a seguir"); }
                    mSeguir.Add(m.Botao("tirar", "Tirar da fila"));
                }
                foreach (var i in esperando)
                {
                    n++;
                    esperas["d:" + i.jogo] = i;
                    mSeguir.Add(new ModeloLinha { Chave = "d:" + i.jogo, Nome = n + "º  " + Textos.Nome(i.nome, 48), Tipo = Formato.Tipo(i.tipo), Estado = "Terminando o download anterior... Começa sozinho em seguida.", Alerta = true }
                        .Botao("tirarEspera", "Tirar da fila"));
                }
                var mPausados = pausados.Select(t =>
                {
                    var m = new ModeloLinha { Chave = "d:" + t.JogoId, Nome = Textos.Nome(t.Nome, 48), Tipo = Formato.Tipo(t.Tipo), Pct = Formato.Pct(t.Feito, t.Total), Estado = Etapa(t), Barra = Valor(t) };
                    return m.Botao("continuar", "Continuar").Botao("cancelar", "Cancelar");
                }).ToList();
                var mMetade = metade.Select(x =>
                {
                    var chave = "d:" + x.Key.jogo;
                    metades[chave] = x.Key;
                    var tam = FilaSalva.Baixado(x.Key);
                    var m = new ModeloLinha { Chave = chave, Nome = Textos.Nome(x.Key.nome, 48), Tipo = Formato.Tipo(x.Key.tipo), Estado = (tam > 0 ? Formato.Tam(tam) + " baixados · " : "") + x.Value };
                    return m.Botao("retomar", "Continuar").Botao("descartar", "Descartar");
                }).ToList();
                var mTerminados = terminados.Select(t => Terminado(t, !t.Recomp && comMetade.Contains(t.JogoId))).ToList();

                var antes = ordem;
                ordem = lista.Aplicar(new List<KeyValuePair<Panel, List<ModeloLinha>>>
                {
                    new KeyValuePair<Panel, List<ModeloLinha>>(pBaixando, mBaixando),
                    new KeyValuePair<Panel, List<ModeloLinha>>(pSeguir, mSeguir),
                    new KeyValuePair<Panel, List<ModeloLinha>>(pPausados, mPausados),
                    new KeyValuePair<Panel, List<ModeloLinha>>(pMetade, mMetade),
                    new KeyValuePair<Panel, List<ModeloLinha>>(pTerminados, mTerminados)
                });

                var nada = ordem.Count == 0;
                Mostrar(vazio, nada);
                Mostrar(tBaixando, !nada); Mostrar(semAgora, !nada && mBaixando.Count == 0);
                Secao(tSeguir, pSeguir, mSeguir.Count);
                Secao(tPausados, pPausados, mPausados.Count);
                Secao(tMetade, pMetade, mMetade.Count);
                Secao(tTerminados, cartaoTerminados, mTerminados.Count);
                var partes = new List<string>();
                if (baixando.Count > 0) { partes.Add(baixando.Count + " baixando"); }
                if (rec.Count > 0) { partes.Add(rec.Count + " Recomp"); }
                if (mSeguir.Count > 0) { partes.Add(mSeguir.Count + " na fila"); }
                if (pausados.Count > 0) { partes.Add(pausados.Count + " pausado" + (pausados.Count > 1 ? "s" : "")); }
                resumo.Text = string.Join(" · ", partes);
                resumo.Visibility = partes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
                // A pilula repete o indicador do topo do Selene (mesma tarefa, mesmo texto).
                var doTopo = Tarefas.DoTopo(todas);
                var textoTopo = doTopo == null ? "" : Textos.Topo(doTopo.Nome, doTopo.Etapa, doTopo.Feito, doTopo.Total, doTopo.Velocidade, Tarefas.NaFila(todas, doTopo), doTopo.Recomp);
                if (topo.Text != textoTopo) { topo.Text = textoTopo; }
                Mostrar(pilula, doTopo != null);
                var agora = Formato.Hora(DateTime.Now);
                if (hora.Text != agora) { hora.Text = agora; }

                Grafico(baixando.Where(x => x.Etapa == "baixando").Select(x => x.Velocidade).FirstOrDefault());
                ArrumarFoco(antes);
                precisaCorrer = lista.Linhas.Values.Any(x => x.Barra != null && x.Barra.IsIndeterminate && x.Barra.Visibility == Visibility.Visible);
                if (carregada) { Animar(precisaCorrer); }
            }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Downloads: falha ao atualizar a tela"); }
        }

        static void Mostrar(UIElement e, bool sim) { var v = sim ? Visibility.Visible : Visibility.Collapsed; if (e.Visibility != v) { e.Visibility = v; } }

        static void Secao(UIElement titulo, UIElement painel, int n)
        {
            Mostrar(titulo, n > 0); Mostrar(painel, n > 0);
        }

        void Grafico(long veloc)
        {
            maxima = Math.Max(maxima, veloc);
            historico.Add(veloc);
            if (historico.Count > 150) { historico.RemoveAt(0); }
            txtRede.Text = "Rede " + Formato.Vel(veloc).Replace("...", "0,0") + "  ·  Máxima " + Formato.Vel((long)maxima).Replace("...", "0,0");
            double larg = grafico.ActualWidth, alt = grafico.ActualHeight, passo = larg / 149, teto = Math.Max(maxima, 1) * 1.1;
            var pontos = new PointCollection();
            for (var i = 0; i < historico.Count; i++) { pontos.Add(new Point(larg - (historico.Count - 1 - i) * passo, alt - historico[i] / teto * alt)); }
            linhaRede.Points = pontos;
            var fundo = new PointCollection(pontos);
            if (pontos.Count > 0) { fundo.Add(new Point(larg, alt)); fundo.Add(new Point(pontos[0].X, alt)); }
            area.Points = fundo;
        }

        // ---------- Foco ----------

        void Focou(FrameworkElement e)
        {
            if (e == null) { return; }
            if (Equals(e.Tag, "armazenamento")) { focoChave = "armazenamento"; focoAcao = null; if (!semRolar) { rolagem.ScrollToEnd(); } return; }
            if (Equals(e.Tag, "fechar")) { focoChave = "fechar"; focoAcao = null; return; }
            var a = e.Tag as Alvo;
            if (a == null) { return; }
            focoChave = a.Linha.Chave; focoAcao = a.Acao;
            // Foco posto depois de rolar: ja esta visivel, nao mexe na rolagem.
            if (semRolar) { return; }
            // Mostra a linha inteira, com um pouco de folga para o titulo da secao.
            a.Linha.Raiz.BringIntoView(new Rect(0, -48 * esc, a.Linha.Raiz.ActualWidth, a.Linha.Raiz.ActualHeight + 48 * esc));
        }

        bool FocoDentro()
        {
            var f = Keyboard.FocusedElement as DependencyObject;
            if (f == null) { return false; }
            if (f == fechar || f == armazenamento) { return true; }
            var fe = f as FrameworkElement;
            var a = fe == null ? null : fe.Tag as Alvo;
            return a != null && lista.Linhas.ContainsKey(a.Linha.Chave) && (a.Acao == null ? a.Linha.Raiz.Focusable : a.Linha.PorAcao.ContainsKey(a.Acao));
        }

        static bool Focar(UIElement e) { return e != null && e.Focusable && e.IsVisible && Keyboard.Focus(e) == e; }

        // O botao pedido da linha; sem ele, o primeiro; sem botao, a linha.
        static UIElement NaLinha(Linha l, string acao)
        {
            Button b;
            if (acao != null && l.PorAcao.TryGetValue(acao, out b)) { return b; }
            return l.Primeiro;
        }

        void ArrumarFoco(List<string> antes)
        {
            if (!focoInicial || !w.IsVisible) { return; }
            Linha l;
            // Depois de uma acao o foco segue o jogo (ex.: Pausar -> Continuar em Pausados, quando a pausa acontecer).
            if (pendenteChave != null && DateTime.Now > pendenteAte) { pendenteChave = null; }
            if (pendenteChave != null && w.IsActive && lista.Linhas.TryGetValue(pendenteChave, out l) && (pendenteAcao == null || l.PorAcao.ContainsKey(pendenteAcao)))
            {
                pendenteChave = null;
                Focar(NaLinha(l, pendenteAcao));
                return;
            }
            if (FocoDentro() || !w.IsActive) { return; }
            if (focoChave == "fechar") { Focar(fechar); return; }
            if (focoChave == "armazenamento") { Focar(armazenamento); return; }
            var chave = ListaViva.Substituta(antes, focoChave, ordem);
            if (chave != null && lista.Linhas.TryGetValue(chave, out l)) { Focar(NaLinha(l, chave == focoChave ? focoAcao : null)); }
            else { Focar(fechar); }
        }

        // Pelo Start: o primeiro botao da primeira linha com acao (sem nenhuma, Fechar). Pelo "Ver downloads":
        // a linha do jogo; se ja terminou, a dele em Terminados.
        void FocarInicial()
        {
            focoInicial = true;
            Linha l;
            if (focoPedido != Guid.Empty)
            {
                if (lista.Linhas.TryGetValue("d:" + focoPedido, out l) && Focar(l.Primeiro)) { return; }
                var jogo = api.Database.Games.Get(focoPedido);
                var rec = jogo == null ? null : recomps.Where(x => x.Value.Nome == jogo.Name).Select(x => x.Key).FirstOrDefault();
                if (rec != null && lista.Linhas.TryGetValue(rec, out l) && Focar(l.Primeiro)) { return; }
                var fim = Tarefas.Terminados().FirstOrDefault(x => x.JogoId == focoPedido || (x.Recomp && jogo != null && x.Nome == jogo.Name));
                if (fim != null && lista.Linhas.TryGetValue("h:" + fim.Id + ":" + fim.Fim.Ticks, out l) && Focar(l.Primeiro)) { return; }
            }
            foreach (var chave in ordem)
            {
                if (lista.Linhas[chave].PorAcao.Count > 0 && Focar(lista.Linhas[chave].Primeiro)) { return; }
            }
            Focar(fechar);
        }

        void Carregou()
        {
            w.Activate();
            if (!w.IsActive) { SetForegroundWindow(new System.Windows.Interop.WindowInteropHelper(w).Handle); }
            FocarInicial();
            Diagnostico("abriu");
        }

        // Perdeu o foco logo depois de abrir (o Selene devolvendo o foco a biblioteca): retoma uma vez so.
        void Desativou()
        {
            Diagnostico("janela desativada");
            if (retomouFoco || aberta.ElapsedMilliseconds > 1500) { return; }
            retomouFoco = true;
            w.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (!w.IsVisible) { return; }
                w.Activate();
                if (!w.IsActive) { SetForegroundWindow(new System.Windows.Interop.WindowInteropHelper(w).Handle); }
                if (!FocoDentro()) { FocarInicial(); }
                Diagnostico("retomou o foco");
            }), DispatcherPriority.Background);
        }

        // ---------- Entrada ----------

        // O Playnite manda o controle como GameControllerInputEventArgs (Key.None, com o botao), e as direcoes
        // tambem como setas para a janela ativa. O SDK (OnControllerButtonStateChanged) chama logo depois.
        static Playnite.SDK.Events.ControllerInput? BotaoDe(KeyEventArgs e)
        {
            if (e.GetType().Name != "GameControllerInputEventArgs") { return null; }
            var p = e.GetType().GetProperty("Button");
            var v = p == null ? null : p.GetValue(e, null);
            return v is Playnite.SDK.Events.ControllerInput ? (Playnite.SDK.Events.ControllerInput?)v : null;
        }

        string AcaoDe(Playnite.SDK.Events.ControllerInput b)
        {
            switch (b)
            {
                case Playnite.SDK.Events.ControllerInput.A: return trocarAB ? "fechar" : "escolher";
                case Playnite.SDK.Events.ControllerInput.B: return trocarAB ? "escolher" : "fechar";
                case Playnite.SDK.Events.ControllerInput.Back: return "fechar";
                case Playnite.SDK.Events.ControllerInput.DPadUp: case Playnite.SDK.Events.ControllerInput.LeftStickUp: return "cima";
                case Playnite.SDK.Events.ControllerInput.DPadDown: case Playnite.SDK.Events.ControllerInput.LeftStickDown: return "baixo";
                case Playnite.SDK.Events.ControllerInput.DPadLeft: case Playnite.SDK.Events.ControllerInput.LeftStickLeft: return "esquerda";
                case Playnite.SDK.Events.ControllerInput.DPadRight: case Playnite.SDK.Events.ControllerInput.LeftStickRight: return "direita";
                case Playnite.SDK.Events.ControllerInput.LeftShoulder: return "paginaCima";
                case Playnite.SDK.Events.ControllerInput.RightShoulder: return "paginaBaixo";
                // O analogico direito rola pelo relogio da rolagem (estado pelo SDK): aqui so nao faz mais nada.
                case Playnite.SDK.Events.ControllerInput.RightStickUp: case Playnite.SDK.Events.ControllerInput.RightStickDown: return "analogico";
                default: return null;
            }
        }

        static string AcaoDe(Key k)
        {
            switch (k)
            {
                case Key.Up: return "cima";
                case Key.Down: return "baixo";
                case Key.Left: return "esquerda";
                case Key.Right: return "direita";
                case Key.Enter: case Key.Space: return "escolher";
                case Key.PageUp: return "paginaCima";
                case Key.PageDown: return "paginaBaixo";
                case Key.Escape: case Key.Back: case Key.BrowserBack: return "fechar";
                default: return null;
            }
        }

        void Tecla(KeyEventArgs e)
        {
            var botao = BotaoDe(e);
            string acao, fonte;
            if (botao.HasValue) { viuControle = true; acao = AcaoDe(botao.Value); fonte = "janela-controle"; Diagnostico("fonte=janela-controle botao=" + botao.Value); Usou(false); }
            else
            {
                acao = AcaoDe(e.Key); fonte = "janela-tecla"; Diagnostico("fonte=janela-tecla tecla=" + e.Key);
                if (acao != null) { TalvezTeclado(); }
            }
            if (acao == null) { return; }
            e.Handled = true;
            Executar(acao, fonte);
        }

        public void DoSdk(Playnite.SDK.Events.ControllerInput botao, Playnite.SDK.Events.ControllerInputState estado)
        {
            // Analogico direito: guarda se esta inclinado (o SDK avisa ao inclinar e ao soltar); quem rola e o relogio.
            if (botao == Playnite.SDK.Events.ControllerInput.RightStickUp || botao == Playnite.SDK.Events.ControllerInput.RightStickDown)
            {
                var sinal = botao == Playnite.SDK.Events.ControllerInput.RightStickUp ? 1 : -1;
                if (estado == Playnite.SDK.Events.ControllerInputState.Pressed) { analogicoSdk = sinal; }
                else if (analogicoSdk == sinal) { analogicoSdk = 0; }
                return;
            }
            if (estado != Playnite.SDK.Events.ControllerInputState.Pressed || !w.IsVisible) { return; }
            Diagnostico("fonte=sdk botao=" + botao + " controle=" + JanelaDownloads.UltimoControle);
            Usou(false);
            // O SDK e a reserva para quando o controle nao chega a janela: se ja chegou uma vez, a janela basta. Nunca
            // com uma confirmacao aberta ou logo depois dela, nem com outro programa na frente (um jogo).
            if (viuControle || unchecked(Environment.TickCount - quietoAte) < 0) { return; }
            if (OutraJanelaAtiva() || (!w.IsActive && !PlayniteNaFrente())) { return; }
            var acao = AcaoDe(botao);
            if (acao == null) { return; }
            if (!w.IsActive) { w.Activate(); }
            Executar(acao, "sdk");
        }

        // As dicas seguem o ultimo jeito usado: teclado ou o controle (com os botoes da marca dele).
        void Usou(bool teclado)
        {
            JanelaDownloads.UsandoTeclado = teclado;
            AtualizarDicas();
        }

        // O direcional do controle tambem chega como seta, antes ou depois do aviso do SDK: so conta como teclado
        // se nenhum botao do controle chegou perto (300 ms) da tecla.
        void TalvezTeclado()
        {
            var tecla = Environment.TickCount;
            if (Math.Abs((long)unchecked(tecla - JanelaDownloads.UltimoToque)) < 300) { return; }
            var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            t.Tick += (s, e) =>
            {
                t.Stop();
                if (Math.Abs((long)unchecked(JanelaDownloads.UltimoToque - tecla)) >= 300) { Usou(true); }
            };
            t.Start();
        }

        void AtualizarDicas()
        {
            if (dicas == null) { return; }
            var teclado = JanelaDownloads.UsandoTeclado;
            var texto = JanelaDownloads.Dicas(teclado, JanelaDownloads.UltimoControle, trocarAB);
            if (dicasAtuais == texto) { return; }
            dicasAtuais = texto;
            var b = JanelaDownloads.Botoes(JanelaDownloads.UltimoControle);
            dicas.Children.Clear();
            dicas.Children.Add(Dica(Tecla(JanelaDownloads.Rolar(teclado, JanelaDownloads.UltimoControle)), "Rolar", false));
            dicas.Children.Add(Dica(Tecla(teclado ? "Enter" : trocarAB ? b[1] : b[0]), "Escolher", true));
            dicas.Children.Add(Dica(Tecla(teclado ? "Esc" : trocarAB ? b[0] : b[1]), "Voltar", true));
        }

        // Glifo do botao num circulo de 26 (fundo .14); no teclado o nome da tecla nao cabe e vira pilula.
        Border Tecla(string simbolo)
        {
            var t = new TextBlock { Text = simbolo, FontSize = 15 * esc, FontWeight = FontWeights.Bold, Foreground = Claro, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var circulo = simbolo.Length <= 1;
            return new Border { Child = t, Background = FundoTecla, CornerRadius = new CornerRadius(13 * esc), MinWidth = 26 * esc, Height = 26 * esc,
                Padding = circulo ? new Thickness(0) : new Thickness(8 * esc, 0, 8 * esc, 0), VerticalAlignment = VerticalAlignment.Center };
        }

        // Rotulo 15 px; 22 de espaco entre as dicas.
        StackPanel Dica(FrameworkElement icone, string rotulo, bool depois)
        {
            var p = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(depois ? 22 * esc : 0, 0, 0, 0) };
            p.Children.Add(icone);
            var t = Txt(15, Claro, false);
            t.Text = rotulo;
            t.Margin = new Thickness(5 * esc, 0, 0, 0);
            p.Children.Add(t);
            return p;
        }

        // O mesmo aperto chega por mais de um caminho (janela, setas, SDK): vale o primeiro.
        void Executar(string acao, string fonte)
        {
            var agora = Environment.TickCount;
            KeyValuePair<int, string> antes;
            if (ultimas.TryGetValue(acao, out antes) && antes.Value != fonte && unchecked(agora - antes.Key) < 150) { return; }
            ultimas[acao] = new KeyValuePair<int, string>(agora, fonte);
            switch (acao)
            {
                case "fechar": w.Close(); break;
                case "escolher": EscolherFoco(); break;
                case "cima": Mover(-1, 0); break;
                case "baixo": Mover(1, 0); break;
                case "esquerda": Mover(0, -1); break;
                case "direita": Mover(0, 1); break;
                case "paginaCima": Pagina(-1); break;
                case "paginaBaixo": Pagina(1); break;
            }
            // Uma confirmacao pode ter ficado aberta: o mesmo aperto, chegando depois por outro caminho, nao conta.
            ultimas[acao] = new KeyValuePair<int, string>(Environment.TickCount, fonte);
        }

        bool OutraJanelaAtiva()
        {
            return Application.Current != null && Application.Current.Windows.OfType<Window>().Any(x => x != w && x.IsActive && x != Application.Current.MainWindow);
        }

        void EscolherFoco()
        {
            var f = Keyboard.FocusedElement as FrameworkElement;
            if (f == fechar) { w.Close(); return; }
            var a = f == null ? null : f.Tag as Alvo;
            if (a != null && a.Acao != null) { Escolher(a); }
            else if (!FocoDentro()) { FocarInicial(); }
        }

        // Cima/baixo: o primeiro botao da linha vizinha (titulos nao recebem foco); acima da primeira, Fechar;
        // abaixo da ultima, o armazenamento. Esquerda/direita: entre os botoes da linha, sem dar a volta.
        void Mover(int dy, int dx)
        {
            var f = Keyboard.FocusedElement as FrameworkElement;
            if (!FocoDentro()) { FocarInicial(); return; }
            if (f == fechar)
            {
                if (dy > 0) { if (ordem.Count > 0) { Focar(lista.Linhas[ordem[0]].Primeiro); } else { Focar(armazenamento); } }
                return;
            }
            if (f == armazenamento)
            {
                if (dy < 0) { if (ordem.Count > 0) { Focar(lista.Linhas[ordem[ordem.Count - 1]].Primeiro); } else { Focar(fechar); } }
                return;
            }
            var a = f.Tag as Alvo;
            if (a == null) { return; }
            if (dx != 0)
            {
                if (a.Acao == null) { return; }
                var botoes = a.Linha.EmOrdem.ToList();
                var i = botoes.IndexOf((Button)f) + dx;
                if (i >= 0 && i < botoes.Count) { Focar(botoes[i]); }
                return;
            }
            var j = ordem.IndexOf(a.Linha.Chave) + dy;
            if (j < 0) { Focar(fechar); }
            else if (j >= ordem.Count) { Focar(armazenamento); }
            else { Focar(lista.Linhas[ordem[j]].Primeiro); }
        }

        // ---------- Rolagem ----------

        // LB/RB (L1/R1, L/R) e PageUp/PageDown: uma pagina. So rola; nao aperta nada.
        void Pagina(int d)
        {
            if (d < 0) { rolagem.PageUp(); } else { rolagem.PageDown(); }
            DepoisDeRolar();
        }

        // A cada 16 ms com a janela ativa: o analogico direito rola suave, mais rapido quanto mais inclinado.
        void Rolar()
        {
            if (!w.IsActive || rolagem == null) { PararRolagem(); return; }
            var v = Inclinacao();
            if (v == 0)
            {
                if (rolando) { rolando = false; passoRolagem.Reset(); DepoisDeRolar(); }
                return;
            }
            if (!rolando) { rolando = true; posRolagem = rolagem.VerticalOffset; passoRolagem.Restart(); return; }
            var dt = Math.Min(passoRolagem.Elapsed.TotalSeconds, 0.1);
            passoRolagem.Restart();
            posRolagem = Math.Max(0, Math.Min(rolagem.ScrollableHeight, posRolagem - v * 1400 * esc * dt));
            rolagem.ScrollToVerticalOffset(posRolagem);
        }

        void PararRolagem() { analogicoSdk = 0; rolando = false; passoRolagem.Reset(); }

        // -1 a 1 (para cima positivo). XInput com zona morta de 0,25; sem ele, o SDK so diz se esta inclinado.
        double Inclinacao()
        {
            const double zona = 0.25;
            var y = LerXinput();
            if (Math.Abs(y) > zona) { return Math.Sign(y) * (Math.Abs(y) - zona) / (1 - zona); }
            return analogicoSdk * 0.6;
        }

        // Ao soltar: se o item com foco saiu da area visivel, o foco vai para o primeiro visivel, sem rolar de novo.
        void DepoisDeRolar() { w.Dispatcher.BeginInvoke(new Action(ConferirFoco), DispatcherPriority.Loaded); }

        void ConferirFoco()
        {
            var f = Keyboard.FocusedElement as UIElement;
            if (f == null || !corpo.IsAncestorOf(f) || Visivel(f)) { return; }
            UIElement novo = null;
            foreach (var chave in ordem)
            {
                var p = lista.Linhas[chave].Primeiro;
                if (Visivel(p)) { novo = p; break; }
            }
            if (novo == null && Visivel(armazenamento)) { novo = armazenamento; }
            if (novo == null) { return; }
            semRolar = true;
            try { Focar(novo); }
            finally { semRolar = false; }
        }

        bool Visivel(UIElement e)
        {
            if (e == null || !e.IsVisible || !e.Focusable || !rolagem.IsAncestorOf(e)) { return false; }
            var r = e.TransformToAncestor(rolagem).TransformBounds(new Rect(e.RenderSize));
            return r.Top >= -1 && r.Bottom <= rolagem.ViewportHeight + 1;
        }

        // Analogico direito pelo XInput (controles Xbox). Sem a DLL, ou sem controle, devolve 0 calado. Um slot
        // sem controle e lento para ler: procura de novo so a cada 2 s.
        double LerXinput()
        {
            if (semXinput14 && semXinput91) { return 0; }
            EstadoXinput s;
            if (xinputSlot < 0)
            {
                if (unchecked(Environment.TickCount - xinputProcura) < 2000) { return 0; }
                xinputProcura = Environment.TickCount;
                for (var i = 0; i < 4 && xinputSlot < 0; i++) { if (EstadoDe(i, out s)) { xinputSlot = i; } }
                if (xinputSlot < 0) { return 0; }
            }
            if (!EstadoDe(xinputSlot, out s)) { xinputSlot = -1; return 0; }
            return Math.Max(-1.0, Math.Min(1.0, s.RY / 32767.0));
        }

        static bool EstadoDe(int i, out EstadoXinput s)
        {
            s = new EstadoXinput();
            if (!semXinput14)
            {
                try { return XInputGetState14(i, ref s) == 0; }
                catch (DllNotFoundException) { semXinput14 = true; }
                catch (EntryPointNotFoundException) { semXinput14 = true; }
            }
            if (!semXinput91)
            {
                try { return XInputGetState91(i, ref s) == 0; }
                catch (DllNotFoundException) { semXinput91 = true; }
                catch (EntryPointNotFoundException) { semXinput91 = true; }
            }
            return false;
        }

#pragma warning disable 0649
        [StructLayout(LayoutKind.Sequential)]
        struct EstadoXinput { public uint Pacote; public ushort Botoes; public byte GatilhoE, GatilhoD; public short LX, LY, RX, RY; }
#pragma warning restore 0649

        [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")] static extern uint XInputGetState14(int i, ref EstadoXinput s);
        [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")] static extern uint XInputGetState91(int i, ref EstadoXinput s);

        // ---------- Acoes ----------

        void Escolher(Alvo a)
        {
            if (a.Acao == null || a.Linha.Inativos.Contains(a.Acao)) { return; }
            var chave = a.Linha.Chave;
            Guid jogo;
            var e = chave.StartsWith("d:") && Guid.TryParse(chave.Substring(2), out jogo) ? Gerenciador.Vivo(jogo) : null;
            var botao = a.Linha.PorAcao.ContainsKey(a.Acao) ? a.Linha.PorAcao[a.Acao] : null;
            switch (a.Acao)
            {
                case "pausar":
                    if (e == null || !e.PodePausar || e.Pausado) { break; }
                    pausando[e.JogoId] = DateTime.Now;
                    e.Alternar();
                    pendenteChave = chave; pendenteAcao = "continuar"; pendenteAte = DateTime.Now.AddSeconds(5);
                    break;
                case "continuar":
                    if (e == null || !e.Pausado) { break; }
                    e.Alternar();
                    pendenteChave = chave; pendenteAcao = null; pendenteAte = DateTime.Now.AddSeconds(5);
                    break;
                case "cancelar": if (e != null) { AcoesDownload.CancelarDownload(api, e); } break;
                case "tirar": if (e != null) { AcoesDownload.TirarDaFila(api, e); } break;
                case "frente":
                    if (e == null || !Gerenciador.MoverParaFrente(e)) { break; }
                    FilaSalva.Mudou(e);
                    pendenteChave = chave; pendenteAcao = null; pendenteAte = DateTime.Now.AddSeconds(5);
                    break;
                case "cancelarRecomp": Tarefa t; if (recomps.TryGetValue(chave, out t)) { AcoesDownload.CancelarRecomp(api, t); } break;
                case "retomar": ItemFila i; if (metades.TryGetValue(chave, out i)) { AcoesDownload.Continuar(api, i); } break;
                case "descartar": ItemFila d; if (metades.TryGetValue(chave, out d)) { AcoesDownload.Descartar(api, d); } break;
                case "tirarEspera": ItemFila q; if (esperas.TryGetValue(chave, out q)) { AcoesDownload.TirarDaEspera(api, q); } break;
            }
            // Volta da confirmacao: o mesmo botao, se ainda existir.
            if (pendenteChave == null && botao != null && lista.Linhas.ContainsKey(chave) && a.Linha.PorAcao.ContainsValue(botao)) { Focar(botao); }
            quietoAte = Environment.TickCount + 500;
            Atualizar();
        }

        // ---------- Diagnostico do teste do controle ----------

        // Uma linha por evento nas primeiras teclas/botoes depois de abrir: de onde veio a entrada, se a janela
        // esta ativa e na frente, e se o card do Selene continua utilizavel com a tela aberta.
        void Diagnostico(string oque)
        {
            if (!telaCheia || diagnosticos >= 25) { return; }
            diagnosticos++;
            try
            {
                LogManager.GetLogger().Info("Downloads (diagnostico " + diagnosticos + "): " + oque + "; ativa=" + w.IsActive + "; primeiroPlano=" + (GetForegroundWindow() == new System.Windows.Interop.WindowInteropHelper(w).Handle)
                    + "; playniteNaFrente=" + PlayniteNaFrente() + "; modal=" + JanelaDownloads.ModalNaTelaCheia + "; cardDoSelene=" + CartaoSelene.Usavel() + "; foco=" + (Keyboard.FocusedElement == null ? "nenhum" : Keyboard.FocusedElement.GetType().Name));
            }
            catch (Exception) { }
        }

        static bool PlayniteNaFrente()
        {
            uint pid;
            GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            return pid == (uint)Process.GetCurrentProcess().Id;
        }

        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    }

    // Pausar, cancelar, tirar da fila, continuar e descartar: as mesmas confirmacoes no menu do jogo e na tela.
    public static class AcoesDownload
    {
        static bool Confirmar(IPlayniteAPI api, string texto, string titulo)
        {
            return api.Dialogs.ShowMessage(texto, titulo, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
        }

        public static void CancelarDownload(IPlayniteAPI api, Execucao e)
        {
            if (!Confirmar(api, "Cancelar o download de " + e.Nome + "?\n\nO que já baixou fica guardado. Se instalar de novo, continua de onde parou.", "Cancelar download")) { return; }
            if (e.Instalando) { api.Dialogs.ShowMessage("Não dá mais para cancelar: a instalação de " + e.Nome + " já começou. Ela vai até o fim.", "Cancelar download"); return; }
            e.CancelarPeloUsuario();
        }

        public static void TirarDaFila(IPlayniteAPI api, Execucao e)
        {
            if (!Confirmar(api, "Tirar " + e.Nome + " da fila de downloads?", "Tirar da fila")) { return; }
            if (e.Instalando) { api.Dialogs.ShowMessage("Não dá mais para cancelar: a instalação de " + e.Nome + " já começou. Ela vai até o fim.", "Cancelar download"); return; }
            e.CancelarPeloUsuario();
        }

        // O Recomp so pode ser cancelado enquanto baixa ou extrai; o plugin Recomps confere de novo
        // (e avisa ele mesmo se a etapa mudou no meio).
        public static void CancelarRecomp(IPlayniteAPI api, Tarefa t)
        {
            if (!Confirmar(api, "Cancelar a instalação do Recomp de " + t.Nome + "?\n\nO Recomp não fica instalado. Seus saves não são afetados.", "Cancelar instalação do Recomp")) { return; }
            if (!Tarefas.CancelarRecomp(t.Id)) { api.Dialogs.ShowMessage("Não dá mais para cancelar: a instalação já passou dessa etapa.", "Cancelar instalação do Recomp"); }
        }

        // Retomado que espera o trabalho da sessao anterior: sai da fila sem ter comecado. O que ja estava no disco
        // vai para "Pela metade"; se comecou a baixar no meio da confirmacao, so avisa.
        public static void TirarDaEspera(IPlayniteAPI api, ItemFila i)
        {
            var nome = Textos.Nome(i.nome, 60);
            if (!Confirmar(api, "Tirar " + nome + " da fila de downloads?", "Tirar da fila")) { return; }
            if (Gerenciador.Presente(i.jogo) || !FilaSalva.Esperando().Any(x => x.jogo == i.jogo))
            {
                api.Dialogs.ShowMessage("Não dá mais para tirar da fila: " + nome + " já começou a baixar. Para parar, use Cancelar.", "Tirar da fila");
                return;
            }
            FilaSalva.TirouDaEspera(i);
        }

        // Continuar o que ficou pela metade: o mesmo Instalar do Playnite.
        public static void Continuar(IPlayniteAPI api, ItemFila i)
        {
            var jogo = api.Database.Games.Get(i.jogo);
            // (Presente: um cancelado cujo worker ainda nao saiu nao pode ganhar um segundo worker no mesmo arquivo)
            if (jogo == null || Gerenciador.Presente(i.jogo) || !FilaSalva.Metade().Any(x => x.Key.jogo == i.jogo))
            {
                api.Dialogs.ShowMessage("Não dá mais para continuar: " + i.nome + " já não está pela metade.", "Continuar download");
                return;
            }
            if (FilaSalva.Origem(i.jogo) == FilaSalva.FaltaInstalar)
            {
                var sim = new MessageBoxOption("Continuar", true, false);
                var nao = new MessageBoxOption("Agora não", false, true);
                var r = api.Dialogs.ShowMessage("Para terminar de instalar " + i.nome + ", o Windows vai pedir permissão.\n\nEssa janela do Windows não aceita o controle: escolha Sim com o mouse, ou aperte Alt+S no teclado.",
                    "Continuar instalação", MessageBoxImage.Information, new List<MessageBoxOption> { sim, nao });
                if (r != sim) { return; }
            }
            if (i.tipo == "rom") { Tarefas.MarcarSoEmulador(i.jogo); }
            api.InstallGame(i.jogo);
        }

        public static void Descartar(IPlayniteAPI api, ItemFila i)
        {
            var livra = Formato.Tam(FilaSalva.Baixado(i));
            var texto = "Apagar o que já baixou de " + i.nome + "?\n\nIsso libera " + livra + ". " + (i.tipo == "rom"
                ? "Só o arquivo pela metade é apagado. Seus saves e o Recomp, se tiver, não são afetados."
                : "Se instalar de novo, o download começa do zero.");
            var sim = new MessageBoxOption("Sim, apagar", false, false);
            var nao = new MessageBoxOption("Não", true, true);
            if (api.Dialogs.ShowMessage(texto, "Descartar download", MessageBoxImage.Question, new List<MessageBoxOption> { sim, nao }) != sim) { return; }
            // Confere tudo de novo depois do "Sim": se algo mudou, nada e apagado.
            if (!Descarte.Apagar(i))
            {
                api.Dialogs.ShowMessage("Não dá mais para descartar " + i.nome + ": o download voltou a andar ou já terminou. Nada foi apagado.", "Descartar download");
                return;
            }
            FilaSalva.Remover(i.jogo);
        }
    }

    // Descartar so apaga o que e com certeza do download pela metade: a pasta _baixando\<id> do jogo de PC
    // ou o <destino>.parcial da ROM. Nunca a ROM completa, a pasta dela ou qualquer coisa fora disso.
    public static class Descarte
    {
        // A pasta do jogo de PC dentro de <raiz>\_baixando, ou null se o id ou o caminho nao servem.
        public static string PastaPc(string raiz, string id)
        {
            if (string.IsNullOrEmpty(raiz) || string.IsNullOrEmpty(id) || !Path.IsPathRooted(raiz) || id == "." || id == ".." || !Regex.IsMatch(id, "^[A-Za-z0-9._-]*[A-Za-z0-9_-]$")) { return null; }
            var pai = Path.GetFullPath(Path.Combine(raiz, "_baixando")).TrimEnd('\\');
            var pasta = Path.GetFullPath(Path.Combine(pai, id)).TrimEnd('\\');
            return string.Equals(Path.GetDirectoryName(pasta), pai, StringComparison.OrdinalIgnoreCase) ? pasta : null;
        }

        // O .parcial que o baixar-worker grava ao lado do destino: exatamente <destino>.parcial.
        public static bool ParcialValido(string parcial, string destino)
        {
            if (string.IsNullOrEmpty(parcial) || string.IsNullOrEmpty(destino) || !Path.IsPathRooted(parcial) || !Path.IsPathRooted(destino)) { return false; }
            if (!parcial.EndsWith(".parcial", StringComparison.OrdinalIgnoreCase) || parcial.Split('\\', '/').Any(x => x == "..")) { return false; }
            string p, d;
            try { p = Path.GetFullPath(parcial); d = Path.GetFullPath(destino); }
            catch (Exception) { return false; }
            return string.Equals(p, d + ".parcial", StringComparison.OrdinalIgnoreCase) && !string.Equals(p, d, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(d).Length > 0;
        }

        public static string DestinoDe(string parcial)
        {
            return parcial != null && parcial.EndsWith(".parcial", StringComparison.OrdinalIgnoreCase) ? parcial.Substring(0, parcial.Length - ".parcial".Length) : null;
        }

        // O worker mantem este arquivo aberto enquanto trabalha.
        public static bool EmUso(string trava)
        {
            if (!File.Exists(trava)) { return false; }
            try { using (File.Open(trava, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { return false; } }
            catch (IOException) { return true; }
            catch (UnauthorizedAccessException) { return true; }
        }

        // Algum processo rodando de dentro da pasta (o setup do jogo, que pode estar instalando).
        static bool RodandoDentro(string pasta)
        {
            var prefixo = pasta.TrimEnd('\\') + "\\";
            foreach (var p in Process.GetProcesses())
            {
                try
                {
                    var h = OpenProcess(0x1000, false, p.Id);
                    if (h == IntPtr.Zero) { continue; }
                    try
                    {
                        var sb = new StringBuilder(1024);
                        var tam = sb.Capacity;
                        if (QueryFullProcessImageNameW(h, 0, sb, ref tam) && sb.ToString(0, tam).StartsWith(prefixo, StringComparison.OrdinalIgnoreCase)) { return true; }
                    }
                    finally { CloseHandle(h); }
                }
                catch (Exception) { }
                finally { p.Dispose(); }
            }
            return false;
        }

        // Apaga depois de conferir tudo de novo. Falso: nada foi apagado.
        public static bool Apagar(ItemFila i)
        {
            if (Gerenciador.Presente(i.jogo)) { return false; }
            try
            {
                if (i.tipo == "rom")
                {
                    var destino = DestinoDe(i.parcial);
                    if (!ParcialValido(i.parcial, destino) || !File.Exists(i.parcial) || Directory.Exists(i.parcial) || EmUso(i.parcial)) { return false; }
                    File.Delete(i.parcial);
                    return true;
                }
                var raiz = Dados.Raiz;
                var pasta = PastaPc(raiz, i.id);
                if (pasta == null || !Directory.Exists(pasta) || EmUso(pasta + ".lock") || RodandoDentro(pasta) || Dados.Instalados().ContainsKey(i.id)) { return false; }
                Directory.Delete(pasta, true);
                if (File.Exists(pasta + ".lock")) { File.Delete(pasta + ".lock"); }
                return true;
            }
            catch (Exception e) { LogManager.GetLogger().Warn(e, "Descartar " + i.nome); return false; }
        }

        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint acesso, bool herdar, int pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr p, int flags, StringBuilder nome, ref int tamanho);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    }

    // Um download no downloads-fila.json. situacao: fila (baixando ou esperando), pausado, instalando
    // (jogo de PC) ou metade (cancelado, erro ou de versao antiga). parcial: so ROM; id: so jogo de PC.
    public class ItemFila { public Guid jogo; public string tipo; public string nome; public string situacao; public string parcial; public string id; }

    // downloads-fila.json na instalacao: o que estava baixando, na fila, pausado ou pela metade, para continuar
    // quando o Playnite abrir de novo. Os terminados nunca vao para o disco. O fechamento do Playnite nao muda
    // nada aqui: o que estava andando continua andando na proxima abertura.
    public static class FilaSalva
    {
        public const string FaltaInstalar = "falta instalar; o Windows vai pedir permissão";
        public const string SoRomComRecomp = "ROM para o emulador; o Recomp já está instalado";
        static readonly object trava = new object(), escrita = new object();
        static readonly List<ItemFila> itens = new List<ItemFila>();
        // De onde veio cada "pela metade" (o arquivo so guarda que esta pela metade).
        static readonly Dictionary<Guid, string> origens = new Dictionary<Guid, string>();
        // Retomados que esperam o trabalho da sessao anterior terminar.
        static readonly List<ItemFila> esperando = new List<ItemFila>();
        static string arquivo;

        public static string Texto(List<ItemFila> lista)
        {
            var s = new System.Runtime.Serialization.Json.DataContractJsonSerializer(typeof(List<ItemFila>));
            using (var m = new MemoryStream()) { s.WriteObject(m, lista); return Encoding.UTF8.GetString(m.ToArray()); }
        }

        public static List<ItemFila> DoTexto(string texto)
        {
            var s = new System.Runtime.Serialization.Json.DataContractJsonSerializer(typeof(List<ItemFila>));
            using (var m = new MemoryStream(Encoding.UTF8.GetBytes(texto ?? ""))) { return ((List<ItemFila>)s.ReadObject(m) ?? new List<ItemFila>()).Where(x => x != null && x.jogo != Guid.Empty).ToList(); }
        }

        // UTF-8 sem BOM, num .tmp trocado pelo arquivo.
        public static void Gravar(string arq, List<ItemFila> lista)
        {
            var tmp = arq + ".tmp";
            File.WriteAllText(tmp, Texto(lista), new UTF8Encoding(false));
            if (File.Exists(arq)) { File.Replace(tmp, arq, null); } else { File.Move(tmp, arq); }
        }

        // Arquivo estragado ou ausente: lista vazia (nunca impede o Playnite de abrir).
        public static List<ItemFila> Ler(string arq)
        {
            try { return File.Exists(arq) ? DoTexto(File.ReadAllText(arq, Encoding.UTF8)) : new List<ItemFila>(); }
            catch (Exception e) { LogManager.GetLogger().Warn(e, "downloads-fila.json ilegivel"); return new List<ItemFila>(); }
        }

        // Ao abrir: carrega o que ficou da sessao anterior; os "pela metade" vem de antes.
        public static List<ItemFila> Iniciar(string arq)
        {
            lock (trava)
            {
                arquivo = arq;
                itens.Clear();
                itens.AddRange(Ler(arq));
                return itens.Select(Copiar).ToList();
            }
        }

        static ItemFila Copiar(ItemFila i) { return new ItemFila { jogo = i.jogo, tipo = i.tipo, nome = i.nome, situacao = i.situacao, parcial = i.parcial, id = i.id }; }

        // Fora da trava das listas; uma escrita por vez.
        static void Salvar(string arq, List<ItemFila> copia)
        {
            if (arq == null || Gerenciador.Encerrando) { return; }
            lock (escrita)
            {
                try { Gravar(arq, copia); }
                catch (Exception e) { LogManager.GetLogger().Warn(e, "Falha ao gravar downloads-fila.json"); }
            }
        }

        // A lista fica na ordem real da fila (a retomada segue essa ordem); o que nao esta na fila vai para o fim.
        static void Mexer(Action<List<ItemFila>> mudar)
        {
            if (Gerenciador.Encerrando) { return; }
            var lugar = new Dictionary<Guid, long>();
            foreach (var e in Gerenciador.Copia().Where(x => !x.Cancelado)) { if (!lugar.ContainsKey(e.JogoId)) { lugar[e.JogoId] = e.Seq; } }
            List<ItemFila> copia;
            string arq;
            lock (trava)
            {
                mudar(itens);
                var ordenados = itens.OrderBy(x => lugar.ContainsKey(x.jogo) ? lugar[x.jogo] : long.MaxValue).ToList();
                itens.Clear(); itens.AddRange(ordenados);
                copia = itens.Select(Copiar).ToList(); arq = arquivo;
            }
            Salvar(arq, copia);
        }

        // Registrou, pausou, continuou ou chegou na instalacao.
        public static void Mudou(Execucao e)
        {
            // (cancelado pela pessoa ja foi gravado; o worker ainda vivo nao desfaz isso)
            if (e.PeloUsuario) { return; }
            var situacao = e.Situacao;
            Mexer(l =>
            {
                var i = l.FirstOrDefault(x => x.jogo == e.JogoId);
                if (i == null) { i = new ItemFila { jogo = e.JogoId }; l.Add(i); }
                i.tipo = e.Tipo; i.nome = e.Nome; i.situacao = situacao;
                if (e.Parcial != null) { i.parcial = e.Parcial; }
                if (e.IdCatalogo != null) { i.id = e.IdCatalogo; }
                origens.Remove(e.JogoId);
                esperando.RemoveAll(x => x.jogo == e.JogoId);
            });
        }

        // Pronto sai; erro e cancelado na tela ou no menu ficam pela metade (se ha algo no disco); cancelado
        // pelo fechamento do Playnite fica como estava, para continuar na proxima abertura.
        public static void Terminou(Execucao e, string fim)
        {
            if (fim == "cancelado" && !e.PeloUsuario) { return; }
            Mexer(l =>
            {
                var i = l.FirstOrDefault(x => x.jogo == e.JogoId);
                if (i == null) { return; }
                if (fim != "pronto" && NoDisco(i))
                {
                    i.situacao = "metade";
                    origens[e.JogoId] = fim != "cancelado" ? "parou nesta sessão" : e.DemorouParar ? "cancelado nesta sessão (demorou para parar)" : "cancelado nesta sessão";
                }
                else { l.Remove(i); origens.Remove(e.JogoId); }
            });
        }

        // Cancelado pela pessoa, na hora do Sim (o worker pode demorar a sair): com algo no disco vai para "Pela
        // metade", senao sai. Assim fechar o Playnite antes do fim nao faz o download voltar sozinho.
        public static void Cancelou(Execucao e)
        {
            var algo = AlgoNoDisco(e);
            Mexer(l =>
            {
                var i = l.FirstOrDefault(x => x.jogo == e.JogoId);
                if (i == null) { return; }
                if (algo) { i.situacao = "metade"; origens[e.JogoId] = "cancelado nesta sessão"; }
                else { l.Remove(i); origens.Remove(e.JogoId); }
            });
        }

        // Retomado tirado da fila antes de comecar (Tirar da fila em "A seguir").
        public static void TirouDaEspera(ItemFila i)
        {
            var algo = NoDisco(i);
            Mexer(l =>
            {
                esperando.RemoveAll(x => x.jogo == i.jogo);
                var it = l.FirstOrDefault(x => x.jogo == i.jogo);
                if (it == null) { return; }
                if (algo) { it.situacao = "metade"; origens[i.jogo] = "cancelado nesta sessão"; }
                else { l.Remove(it); origens.Remove(i.jogo); }
            });
        }

        // O download ja deixou algo no disco (o .parcial da ROM ou a pasta em _baixando), nesta sessao ou numa anterior.
        public static bool AlgoNoDisco(Execucao e)
        {
            ItemFila salvo;
            lock (trava) { salvo = itens.FirstOrDefault(x => x.jogo == e.JogoId); salvo = salvo == null ? null : Copiar(salvo); }
            return NoDisco(new ItemFila
            {
                jogo = e.JogoId, tipo = e.Tipo,
                parcial = e.Parcial ?? (salvo == null ? null : salvo.parcial),
                id = e.IdCatalogo ?? (salvo == null ? null : salvo.id)
            });
        }

        public static void Remover(Guid jogo) { Mexer(l => { l.RemoveAll(x => x.jogo == jogo); origens.Remove(jogo); esperando.RemoveAll(x => x.jogo == jogo); }); }

        // Pasta antiga em _baixando, sem registro (versoes anteriores): fica pela metade, sem continuar sozinha.
        public static void Antigo(Guid jogo, string nome, string id)
        {
            Mexer(l => { if (!l.Any(x => x.jogo == jogo)) { l.Add(new ItemFila { jogo = jogo, tipo = "pc", nome = nome, situacao = "metade", id = id }); } });
        }

        // Nao continua sozinho ao abrir: vai para "Pela metade" com o motivo.
        public static void NaoRetomado(Guid jogo, string origem) { lock (trava) { origens[jogo] = origem; } }

        public static void Esperar(ItemFila i) { lock (trava) { if (!esperando.Any(x => x.jogo == i.jogo)) { esperando.Add(Copiar(i)); } } }
        public static void ParouDeEsperar(Guid jogo) { lock (trava) { esperando.RemoveAll(x => x.jogo == jogo); } }
        public static List<ItemFila> Esperando() { lock (trava) { return esperando.Select(Copiar).ToList(); } }

        // O jogo tem registro no downloads-fila.json (fila, pausado, instalando ou pela metade).
        public static bool Tem(Guid jogo) { lock (trava) { return itens.Any(x => x.jogo == jogo); } }

        public static string Origem(Guid jogo) { lock (trava) { string o; return origens.TryGetValue(jogo, out o) ? o : "de uma sessão anterior"; } }

        // Pela metade, com a origem: os "metade" e os que nao continuaram sozinhos ao abrir.
        public static List<KeyValuePair<ItemFila, string>> Metade()
        {
            lock (trava)
            {
                var r = new List<KeyValuePair<ItemFila, string>>();
                foreach (var i in itens)
                {
                    string o;
                    var naoRetomado = origens.TryGetValue(i.jogo, out o) && (o == FaltaInstalar || o == SoRomComRecomp);
                    if (i.situacao == "metade" || naoRetomado) { r.Add(new KeyValuePair<ItemFila, string>(Copiar(i), o ?? "de uma sessão anterior")); }
                }
                return r;
            }
        }

        static bool NoDisco(ItemFila i)
        {
            try
            {
                if (i.tipo == "rom") { return i.parcial != null && File.Exists(i.parcial); }
                var pasta = Descarte.PastaPc(Dados.Raiz, i.id);
                return pasta != null && Directory.Exists(pasta);
            }
            catch (Exception) { return false; }
        }

        // Quanto ja esta no disco.
        public static long Baixado(ItemFila i)
        {
            try
            {
                if (i.tipo == "rom") { return i.parcial != null && File.Exists(i.parcial) ? new FileInfo(i.parcial).Length : 0; }
                var pasta = Descarte.PastaPc(Dados.Raiz, i.id);
                return pasta != null && Directory.Exists(pasta) ? new DirectoryInfo(pasta).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) : 0;
            }
            catch (Exception) { return 0; }
        }
    }

    // Aba "Instalados" no modo de abas do Playnite (filtertabs = "playnite" no Selene): um filtro salvo criado
    // uma vez so. Se a pessoa apagar ou renomear, nao volta. O "Installed" que o Selene cria para a Colecao
    // nao e aba e nao e reaproveitado.
    public static class FiltroInstalados
    {
        public const string NomeFiltro = "Instalados";

        // So "instalado" marcado, nenhum outro criterio.
        public static bool SoInstalados(FilterPresetSettings s)
        {
            if (s == null || !s.IsInstalled) { return false; }
            foreach (var p in typeof(FilterPresetSettings).GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.Name == "IsInstalled" || p.Name == "UseAndFilteringStyle" || p.GetIndexParameters().Length > 0) { continue; }
                if (Preenchido(p.GetValue(s, null), 0)) { return false; }
            }
            return true;
        }

        static bool Preenchido(object v, int nivel)
        {
            if (v == null) { return false; }
            if (v is bool) { return (bool)v; }
            var texto = v as string;
            if (texto != null) { return texto.Length > 0; }
            var lista = v as System.Collections.IEnumerable;
            if (lista != null) { return lista.Cast<object>().Any(); }
            if (v.GetType().IsValueType || nivel > 0) { return false; }
            return v.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance).Where(p => p.GetIndexParameters().Length == 0).Any(p => Preenchido(p.GetValue(v, null), nivel + 1));
        }

        public static bool Equivalente(FilterPreset p)
        {
            return string.Equals((p.Name ?? "").Trim(), NomeFiltro, StringComparison.OrdinalIgnoreCase) || (p.ShowInFullscreeQuickSelection && SoInstalados(p.Settings));
        }

        // Guid.Empty: criar. Outro: ja existe um equivalente (so marcar, sem mexer nele).
        public static Guid Existente(IEnumerable<FilterPreset> presets)
        {
            var p = presets.FirstOrDefault(Equivalente);
            return p == null ? Guid.Empty : p.Id;
        }

        // Mesmos campos dos filtros de plataforma.
        public static FilterPreset Novo()
        {
            return new FilterPreset
            {
                Name = NomeFiltro,
                Settings = new FilterPresetSettings { IsInstalled = true },
                SortingOrder = SortOrder.Name,
                SortingOrderDirection = SortOrderDirection.Ascending,
                ShowInFullscreeQuickSelection = true
            };
        }

        // A ordem completa com o nosso logo depois do primeiro da tela cheia (All); sem ele, no comeco.
        // Nunca tira nenhum Id.
        public static List<Guid> NovaOrdem(List<Guid> completa, Guid nosso, Guid primeiro)
        {
            var r = completa.Where(x => x != nosso).ToList();
            var i = primeiro == nosso ? -1 : r.IndexOf(primeiro);
            r.Insert(i < 0 ? 0 : i + 1, nosso);
            return r;
        }
    }

    public class Arquivo { public string caminho; public long tamanho; public string sha256; }

    public class JogoCatalogo
    {
        public string id; public string nome; public string tipo; public string pasta; public long tamanho;
        public List<Arquivo> arquivos; public List<string> instaladores; public string executavel;
    }

    public class Catalogo { public List<JogoCatalogo> jogos; }
    public class Servidor { public string lan; public string netbird; public string tailscale; public string usuario; public string senha; }
    public class LauncherJson { public Servidor jogos; }
    public class Instalado { public string nome; public string pasta; public string executavel; }

    public class Trabalho
    {
        public string url; public string auth; public JogoCatalogo jogo; public string raiz; public string progresso;
        [SerializationPropertyName("base")] public string pastaBase;
    }

    public class Progresso { public string estado; public string msg; public long baixado; public long total; public long velocidade; }

    // Barra no topo do Playnite; fica recolhida enquanto nada esta sendo instalado.
    public static class Barra
    {
        static readonly StackPanel Painel = new StackPanel { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed };
        static readonly TextBlock Texto = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        static readonly ProgressBar Andamento = new ProgressBar { Width = 140, Height = 8, Minimum = 0, Maximum = 100, VerticalAlignment = VerticalAlignment.Center };

        static Barra() { Painel.Children.Add(Texto); Painel.Children.Add(Andamento); }

        public static object Conteudo { get { return Painel; } }

        public static void Mostrar(IPlayniteAPI api, string nome, Progresso p)
        {
            var pct = p.total > 0 ? Math.Floor(p.baixado * 100.0 / p.total) : 0;
            string msg;
            switch (p.estado)
            {
                case "baixando":
                    msg = "Baixando " + nome + ": " + pct + "%" + (p.velocidade > 0 ? " - " + Math.Round(p.velocidade / 1048576.0, 1) + " MB/s" : "");
                    break;
                case "fila": msg = nome + ": na fila, outra pessoa esta baixando"; break;
                case "reconectando": msg = nome + ": conexao caiu, reconectando..."; break;
                case "verificando": msg = "Verificando " + nome + "..."; break;
                case "instalando": msg = "Instalando " + nome + "..."; break;
                default: return;
            }
            api.MainView.UIDispatcher.Invoke(new Action(() =>
            {
                Texto.Text = msg;
                Andamento.Value = pct;
                Painel.Visibility = Visibility.Visible;
            }));
        }

        public static void Esconder(IPlayniteAPI api)
        {
            api.MainView.UIDispatcher.Invoke(new Action(() => Painel.Visibility = Visibility.Collapsed));
        }
    }

    public static class Dados
    {
        static readonly UTF8Encoding SemBom = new UTF8Encoding(false);
        static readonly string PastaPlugin = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        public static string Base { get { return File.ReadAllText(Path.Combine(PastaPlugin, "instalacao.txt"), Encoding.UTF8).Trim(); } }
        static string ArqCache { get { return Path.Combine(PastaPlugin, "catalogo.json"); } }
        static string ArqInstalados { get { return Path.Combine(Base, "jogos-pc.json"); } }

        public static string Raiz
        {
            get
            {
                var f = Path.Combine(Base, "jogos-pc-pasta.txt");
                return File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8).Trim() : Path.Combine(Base, "JogosPC");
            }
        }

        public static Servidor Conexao
        {
            get { return Serialization.FromJson<LauncherJson>(File.ReadAllText(Path.Combine(Base, "launcher.json"), Encoding.UTF8)).jogos; }
        }

        public static string Auth(Servidor s)
        {
            return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(s.usuario + ":" + s.senha));
        }

        public static string AcharServidor(Servidor s)
        {
            // Rede local primeiro; fora de casa, NetBird e depois Tailscale.
            foreach (var t in new[] { Tuple.Create(s.lan, 2000), Tuple.Create(s.netbird, 4000), Tuple.Create(s.tailscale, 5000) })
            {
                if (string.IsNullOrEmpty(t.Item1)) { continue; }
                var url = t.Item1.TrimEnd('/');
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create(url + "/saude");
                    req.Timeout = t.Item2;
                    using (var resp = (HttpWebResponse)req.GetResponse())
                    {
                        if (resp.StatusCode == HttpStatusCode.OK) { return url; }
                    }
                }
                catch (WebException) { }
            }
            return null;
        }

        public static List<JogoCatalogo> LerCatalogo()
        {
            // Sem servidor, usa a ultima lista conhecida.
            var s = Conexao;
            var url = s == null ? null : AcharServidor(s);
            if (url != null)
            {
                using (var web = new WebClient())
                {
                    web.Encoding = Encoding.UTF8;
                    web.Headers[HttpRequestHeader.Authorization] = Auth(s);
                    var texto = web.DownloadString(url + "/instalador/catalogo.json");
                    File.WriteAllText(ArqCache, texto, SemBom);
                    return Serialization.FromJson<Catalogo>(texto).jogos;
                }
            }
            return File.Exists(ArqCache) ? Serialization.FromJson<Catalogo>(File.ReadAllText(ArqCache, Encoding.UTF8)).jogos : new List<JogoCatalogo>();
        }

        public static Dictionary<string, Instalado> Instalados()
        {
            return File.Exists(ArqInstalados)
                ? Serialization.FromJson<Dictionary<string, Instalado>>(File.ReadAllText(ArqInstalados, Encoding.UTF8))
                : new Dictionary<string, Instalado>();
        }

        public static void Esquecer(string id)
        {
            var d = Instalados();
            d.Remove(id);
            File.WriteAllText(ArqInstalados, Serialization.ToJson(d, true), SemBom);
        }

        public static string Worker { get { return Path.Combine(Base, "programa", "jogos-pc-worker.ps1"); } }

        // So as instalacoes feitas pelo instalador dos amigos tem este arquivo.
        public static bool InstalacaoDeAmigo { get { return File.Exists(Path.Combine(Base, "instalacao-amigo.txt")); } }
    }

    public class InstaladorJogo : InstallController
    {
        readonly IPlayniteAPI api;
        Execucao execucao;

        public InstaladorJogo(Game jogo, IPlayniteAPI api) : base(jogo) { Name = "Instalar"; this.api = api; }

        void Avisar(string msg, NotificationType tipo)
        {
            api.Notifications.Add("jogospc-" + Game.GameId, Game.Name + ": " + msg, tipo);
        }

        public static Progresso LerProgresso(string arquivo)
        {
            // O worker troca o arquivo o tempo todo; uma leitura perdida nao importa.
            try { return File.Exists(arquivo) ? Serialization.FromJson<Progresso>(File.ReadAllText(arquivo)) : null; }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        // O que ja esta numa pasta (o download pela metade em _baixando).
        public static long TamanhoPasta(string pasta)
        {
            try { return Directory.Exists(pasta) ? new DirectoryInfo(pasta).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) : 0; }
            catch (Exception) { return 0; }
        }

        public override void Install(InstallActionArgs args)
        {
            // A vaga na fila e reservada no clique, antes de ir a rede.
            var e = new Execucao(api, Game.Id, "pc", Game.Name) { IdCatalogo = Game.GameId };
            execucao = e;
            e.Registrar();
            Task.Run(() =>
            {
                var rodou = false;
                // O Playnite sai do "instalando" so com um aviso: exatamente um, pelo finally.
                var avisou = false;
                try
                {
                    // (cancelar no meio da consulta ao servidor nao espera o timeout dela)
                    var alvo = e.Consultar(() => Dados.LerCatalogo().First(j => j.id == Game.GameId));
                    var s = Dados.Conexao;
                    var url = e.Consultar(() => Dados.AcharServidor(s));
                    if (url == null) { throw new Exception("Nao consegui falar com o servidor. Confira a conexao."); }
                    e.NomeCatalogo = alvo.nome;
                    // (nunca dois workers na mesma pasta _baixando: o anterior segura o .lock enquanto trabalha)
                    var pastaBaixando = Descarte.PastaPc(Dados.Raiz, alvo.id);
                    if (pastaBaixando != null) { e.EsperarLivre(pastaBaixando + ".lock"); }

                    var temp = Path.Combine(Path.GetTempPath(), "JogosPC_" + Guid.NewGuid().ToString("N").Substring(0, 8));
                    Directory.CreateDirectory(temp);
                    var arqProgresso = Path.Combine(temp, "progresso.json");
                    var arqTrabalho = Path.Combine(temp, "job.json");
                    Directory.CreateDirectory(Dados.Raiz);
                    File.WriteAllText(arqTrabalho, Serialization.ToJson(new Trabalho { url = url, auth = Dados.Auth(s), jogo = alvo, raiz = Dados.Raiz, pastaBase = Dados.Base, progresso = arqProgresso }), new UTF8Encoding(false));
                    e.Tamanho = alvo.tamanho;
                    e.JaTem = TamanhoPasta(Path.Combine(Dados.Raiz, "_baixando", alvo.id));

                    if (e.Cancelado) { throw new OperationCanceledException(); }
                    Avisar("baixando e instalando. Se o Windows pedir permissao, clique em Sim.", NotificationType.Info);
                    rodou = true;
                    var fim = e.Rodar(arqProgresso, () =>
                    {
                        var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + Dados.Worker + "\"") { UseShellExecute = false, CreateNoWindow = true };
                        psi.EnvironmentVariables["JOGOSPC_JOB_ARQ"] = arqTrabalho;
                        return Process.Start(psi);
                    });
                    try { Directory.Delete(temp, true); } catch (IOException) { }
                    if (fim != null && fim.estado == "ok")
                    {
                        var i = Dados.Instalados()[Game.GameId];
                        api.Notifications.Remove("jogospc-" + Game.GameId);
                        avisou = true;
                        InvokeOnInstalled(new GameInstalledEventArgs(new GameInstallationData { InstallDirectory = i.pasta }));
                        return;
                    }
                    throw new Exception(fim != null && !string.IsNullOrEmpty(fim.msg) ? fim.msg : "Instalacao interrompida. O que ja baixou ficou guardado.");
                }
                catch (Exception ex)
                {
                    try
                    {
                        if (!rodou) { e.Falhar(ex.Message); }
                        Barra.Esconder(api);
                        // Cancelado pela pessoa: nada de erro (a tela e o card ja dizem que cancelou).
                        if (e.PeloUsuario) { api.Notifications.Remove("jogospc-" + Game.GameId); }
                        else if (!(ex is OperationCanceledException))
                        {
                            Avisar(ex.Message, NotificationType.Error);
                            if (!e.Cancelado) { ErroDownload.Mostrar(api, Game.Name, ex.Message); }
                        }
                    }
                    catch (Exception ex2) { LogManager.GetLogger().Error(ex2, "Falha ao terminar o download de " + Game.Name); }
                }
                finally
                {
                    if (!avisou)
                    {
                        try { InvokeOnInstallationCancelled(new GameInstallationCancelledEventArgs()); }
                        catch (Exception ex3) { LogManager.GetLogger().Error(ex3, "Falha ao avisar o fim da instalacao de " + Game.Name); }
                    }
                }
            });
        }

        public override void Dispose()
        {
            // Cancelar no Playnite interrompe o download; o que veio fica guardado. Outro Instalar do mesmo
            // jogo tambem chega aqui (o Playnite troca o controller): esse nao cancela.
            if (execucao != null && DateTime.Now > execucao.ProtegidoAte) { execucao.Cancelar(); }
        }
    }

    // Instalar de novo um jogo que ja esta nos downloads: avisa e acompanha o mesmo download ate o fim,
    // sem tocar nele (dois workers no mesmo .parcial se estragariam).
    public class JaNosDownloads : InstallController
    {
        readonly IPlayniteAPI api;
        readonly Execucao execucao;

        public JaNosDownloads(Game jogo, IPlayniteAPI api, Execucao e) : base(jogo)
        {
            Name = e.Tipo == "rom" ? "Baixar para o emulador" : "Instalar"; this.api = api; execucao = e;
        }

        public override void Install(InstallActionArgs args)
        {
            var nome = Game.Name;
            api.MainView.UIDispatcher.BeginInvoke(new Action(() =>
            {
                try { api.Dialogs.ShowMessage(nome + " já está nos downloads.\n\nPara ver, pausar ou cancelar, abra Downloads no menu Jogos de PC.", "Instalar"); }
                catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao avisar que o jogo ja esta nos downloads"); }
            }));
            Task.Run(() =>
            {
                // Um aviso so: o InstallationCancelled nunca vem depois de um InvokeOnInstalled que falhou.
                var avisou = false;
                try
                {
                    var fim = execucao.Esperar();
                    var dados = fim != null && fim.estado == "ok" ? execucao.Instalacao() : null;
                    if (dados != null) { avisou = true; InvokeOnInstalled(new GameInstalledEventArgs(dados)); return; }
                }
                catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao acompanhar o download de " + nome); }
                if (avisou) { return; }
                try { InvokeOnInstallationCancelled(new GameInstallationCancelledEventArgs()); }
                catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao avisar o fim da instalacao de " + nome); }
            });
        }
    }

    public class MapeamentoRomm { public bool Enabled; public int RomMPlatformId; public string DestinationPath; public bool InstallFlat; }
    public class ConfigRomm { public string RomMHost; public string RomMUsername; public string RomMPassword; public List<MapeamentoRomm> Mappings; }
    public class MetadadosScreenScraper { public string fanart_url; }
    public class RomArte { public List<string> merged_screenshots; public MetadadosScreenScraper ss_metadata; }
    public class RomRomm { public string sha1_hash; public int id; public int platform_id; public string fs_name; public long fs_size_bytes; public bool has_simple_single_file; public bool missing_from_fs; }

    // Instala um jogo retro do RomM continuando de onde parou, com o baixar-worker.ps1.
    public class InstaladorRetomada : InstallController
    {
        public static readonly Guid PluginRomm = Guid.Parse("9700aa21-447d-41b4-a989-acd38f407d9f");
        readonly IPlayniteAPI api;
        Execucao execucao;

        public InstaladorRetomada(Game jogo, IPlayniteAPI api) : base(jogo) { Name = "Baixar para o emulador"; this.api = api; }

        string Expandir(string caminho) { return caminho.Replace("{PlayniteDir}", api.Paths.ApplicationPath); }

        public static string IdRomm(Game jogo)
        {
            // O GameId do plugin do RomM e "<id da rom>:<hash>" e, ao contrario de Game.Roms, nao some ao desinstalar.
            var m = Regex.Match(jogo.GameId ?? "", @"^(\d+):");
            return m.Success ? m.Groups[1].Value : null;
        }

        RomRomm LerRom(ConfigRomm cfg, string auth, string id)
        {
            using (var web = new WebClient())
            {
                web.Encoding = Encoding.UTF8;
                web.Headers[HttpRequestHeader.Authorization] = auth;
                return Serialization.FromJson<RomRomm>(web.DownloadString(cfg.RomMHost.TrimEnd('/') + "/api/roms/" + id));
            }
        }

        string Destino(ConfigRomm cfg, RomRomm rom)
        {
            // Mesma regra do plugin do RomM: <pasta>\<nome sem extensao>\<arquivo>, ou direto na pasta.
            var m = cfg.Mappings.FirstOrDefault(x => x.Enabled && x.RomMPlatformId == rom.platform_id);
            if (m == null) { throw new Exception("Este console nao esta ligado ao RomM neste PC."); }
            var pasta = Expandir(m.DestinationPath);
            return m.InstallFlat ? Path.Combine(pasta, rom.fs_name) : Path.Combine(pasta, Path.GetFileNameWithoutExtension(rom.fs_name), rom.fs_name);
        }

        public override void Install(InstallActionArgs args)
        {
            // A vaga na fila e reservada no clique, antes de ir a rede.
            var e = new Execucao(api, Game.Id, "rom", Game.Name);
            execucao = e;
            e.Registrar();
            Task.Run(() =>
            {
                var rodou = false;
                // O Playnite sai do "instalando" so com um aviso: exatamente um, pelo finally.
                var avisou = false;
                try
                {
                    var arqConfig = Path.Combine(api.Paths.ExtensionsDataPath, InstaladorRetomada.PluginRomm.ToString(), "config.json");
                    var cfg = Serialization.FromJson<ConfigRomm>(File.ReadAllText(arqConfig, Encoding.UTF8));
                    var auth = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(cfg.RomMUsername + ":" + cfg.RomMPassword));
                    // (cancelar no meio da consulta ao RomM nao espera o timeout dela, de 100 s)
                    var idRom = IdRomm(Game);
                    var rom = e.Consultar(() => LerRom(cfg, auth, idRom));
                    if (!rom.has_simple_single_file || rom.missing_from_fs) { throw new Exception("Este jogo tem varios arquivos. Use a opcao normal de instalacao."); }
                    var destino = Destino(cfg, rom);
                    // O .parcial fica registrado ja: se o Playnite fechar, o download continua dele ao abrir.
                    e.Destino = destino; e.Parcial = destino + ".parcial";
                    e.Tamanho = rom.fs_size_bytes;
                    e.JaTem = File.Exists(e.Parcial) ? new FileInfo(e.Parcial).Length : 0;
                    FilaSalva.Mudou(e);
                    // (nunca dois workers no mesmo .parcial: o anterior o mantem aberto enquanto trabalha)
                    e.EsperarLivre(e.Parcial);
                    e.JaTem = File.Exists(e.Parcial) ? new FileInfo(e.Parcial).Length : 0;

                    var temp = Path.Combine(Path.GetTempPath(), "JogosRetomada_" + Guid.NewGuid().ToString("N").Substring(0, 8));
                    Directory.CreateDirectory(temp);
                    var arqProgresso = Path.Combine(temp, "progresso.json");
                    var url = cfg.RomMHost.TrimEnd('/') + "/api/roms/" + rom.id + "/content/" + Uri.EscapeDataString(rom.fs_name);
                    var trabalho = new Dictionary<string, object> { { "url", url }, { "auth", auth }, { "destino", destino }, { "total", rom.fs_size_bytes }, { "progresso", arqProgresso }, { "sha1", rom.sha1_hash } };
                    if (e.Cancelado) { throw new OperationCanceledException(); }
                    rodou = true;
                    var fim = e.Rodar(arqProgresso, () =>
                    {
                        var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(Dados.Base, "programa", "baixar-worker.ps1") + "\"") { UseShellExecute = false, CreateNoWindow = true };
                        psi.EnvironmentVariables["JOGOSRETRO_DOWNLOAD"] = Serialization.ToJson(trabalho);
                        return Process.Start(psi);
                    });
                    try { Directory.Delete(temp, true); } catch (IOException) { }
                    if (fim == null || fim.estado != "ok") { throw new Exception(fim != null && !string.IsNullOrEmpty(fim.msg) ? fim.msg : "Download pausado. Clique em Instalar para continuar."); }
                    avisou = true;
                    InvokeOnInstalled(new GameInstalledEventArgs(new GameInstallationData { InstallDirectory = Path.GetDirectoryName(destino), Roms = new List<GameRom> { new GameRom(Game.Name, destino) } }));
                }
                catch (Exception ex)
                {
                    try
                    {
                        if (!rodou) { e.Falhar(ex.Message); }
                        Barra.Esconder(api);
                        // Cancelado pela pessoa: nada de erro nem do "Download pausado..." (a tela e o card ja dizem que cancelou).
                        if (e.PeloUsuario) { api.Notifications.Remove("retomada-" + Game.Id); }
                        else if (!(ex is OperationCanceledException))
                        {
                            api.Notifications.Add("retomada-" + Game.Id, Game.Name + ": " + ex.Message, NotificationType.Error);
                            if (!e.Cancelado) { ErroDownload.Mostrar(api, Game.Name, ex.Message); }
                        }
                    }
                    catch (Exception ex2) { LogManager.GetLogger().Error(ex2, "Falha ao terminar o download de " + Game.Name); }
                }
                finally
                {
                    if (!avisou)
                    {
                        try { InvokeOnInstallationCancelled(new GameInstallationCancelledEventArgs()); }
                        catch (Exception ex3) { LogManager.GetLogger().Error(ex3, "Falha ao avisar o fim da instalacao de " + Game.Name); }
                    }
                }
            });
        }

        public override void Dispose()
        {
            if (execucao != null && DateTime.Now > execucao.ProtegidoAte) { execucao.Cancelar(); }
        }
    }

    public class DesinstaladorJogo : UninstallController
    {
        readonly IPlayniteAPI api;

        public DesinstaladorJogo(Game jogo, IPlayniteAPI api) : base(jogo) { Name = "Desinstalar"; this.api = api; }

        public override void Uninstall(UninstallActionArgs args)
        {
            Task.Run(() =>
            {
                try
                {
                    Instalado i;
                    if (!Dados.Instalados().TryGetValue(Game.GameId, out i)) { throw new Exception("Nao encontrei o registro da instalacao."); }
                    var pasta = Path.GetFullPath(i.pasta);
                    if (pasta == Path.GetPathRoot(pasta)) { throw new Exception("Pasta de instalacao invalida."); }

                    var dados = Dados.LerCatalogo().FirstOrDefault(j => j.id == Game.GameId);
                    var desinstalador = Path.Combine(pasta, "unins000.exe");
                    if ((dados == null || dados.tipo == "gog") && File.Exists(desinstalador))
                    {
                        var psi = new ProcessStartInfo(desinstalador, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART") { UseShellExecute = true, Verb = "runas" };
                        using (var p = Process.Start(psi)) { p.WaitForExit(); }
                    }
                    if (Directory.Exists(pasta)) { Directory.Delete(pasta, true); }
                    Dados.Esquecer(Game.GameId);
                    InvokeOnUninstalled();
                }
                catch (Exception e)
                {
                    api.Notifications.Add("jogospc-" + Game.GameId, Game.Name + ": nao consegui desinstalar. " + e.Message, NotificationType.Error);
                    Game.IsUninstalling = false;
                    api.Database.Games.Update(Game);
                }
            });
        }
    }

    public class SalaMultiplayer { public string titulo; public List<string> jogadores; }
    public class SalasMultiplayer { public List<SalaMultiplayer> salas; }

    // Avisa no Playnite quem esta nas salas de multiplayer do servidor (Switch, 3DS, PSP...): le
    // /salas no servidor de jogos a cada minuto. O aviso some quando a pessoa sai da sala, e o
    // proprio apelido (o login, como o multiplayer.ps1 monta) nao aparece.
    public class AvisoSalas
    {
        readonly IPlayniteAPI api;
        HashSet<string> avisados = new HashSet<string>();
        System.Threading.Timer relogio;
        string url;

        public AvisoSalas(IPlayniteAPI api) { this.api = api; }

        public void Iniciar()
        {
            relogio = new System.Threading.Timer(_ => Conferir(), null, TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(60));
        }

        public static string Apelido(string usuario)
        {
            return Regex.Replace(usuario ?? "", "[^A-Za-z0-9_-]", "").ToLowerInvariant();
        }

        // Ids das notificacoes para a lista de salas; fora a pessoa do proprio PC.
        public static Dictionary<string, string> Avisos(SalasMultiplayer s, string usuario)
        {
            var saida = new Dictionary<string, string>();
            var eu = Apelido(usuario);
            foreach (var sala in (s == null ? null : s.salas) ?? new List<SalaMultiplayer>())
            {
                foreach (var nome in sala.jogadores ?? new List<string>())
                {
                    if (string.IsNullOrEmpty(nome) || nome.ToLowerInvariant() == eu) { continue; }
                    saida["sala-" + sala.titulo + "-" + nome] = nome + " esta jogando online: " + sala.titulo + ". Abra o emulador e entre na sala para jogar junto.";
                }
            }
            return saida;
        }

        void Conferir()
        {
            try
            {
                var s = Dados.Conexao;
                if (s == null) { return; }
                if (url == null) { url = Dados.AcharServidor(s); }
                if (url == null) { return; }
                string texto;
                try
                {
                    using (var web = new WebClient())
                    {
                        web.Encoding = Encoding.UTF8;
                        web.Headers[HttpRequestHeader.Authorization] = Dados.Auth(s);
                        texto = web.DownloadString(url + "/salas");
                    }
                }
                catch (WebException e)
                {
                    // Servidor sem /salas (versao antiga) responde erro: tenta de novo depois. Sem
                    // resposta nenhuma, procura o caminho de novo (saiu de casa, VPN caiu).
                    if (e.Status != WebExceptionStatus.ProtocolError) { url = null; }
                    return;
                }
                var agora = Avisos(Serialization.FromJson<SalasMultiplayer>(texto), s.usuario);
                foreach (var id in avisados.Where(i => !agora.ContainsKey(i)).ToList()) { api.Notifications.Remove(id); }
                foreach (var a in agora.Where(a => !avisados.Contains(a.Key)))
                {
                    api.Notifications.Add(new NotificationMessage(a.Key, a.Value, NotificationType.Info));
                }
                avisados = new HashSet<string>(agora.Keys);
            }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao ler as salas de multiplayer"); }
        }
    }

    public class BibliotecaJogosPc : LibraryPlugin
    {
        readonly IPlayniteAPI api;
        readonly AvisoSalas salas;

        public BibliotecaJogosPc(IPlayniteAPI api) : base(api)
        {
            this.api = api;
            salas = new AvisoSalas(api);
            Properties = new LibraryPluginProperties { CanShutdownClient = false, HasCustomizedGameImport = false };
        }

        public override Guid Id { get { return Guid.Parse("c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3"); } }
        public override string Name { get { return "Jogos de PC"; } }

        public override IEnumerable<GameMetadata> GetGames(LibraryGetGamesArgs args)
        {
            var instalados = Dados.Instalados();
            var saida = new List<GameMetadata>();
            foreach (var j in Dados.LerCatalogo())
            {
                Instalado i;
                var tem = instalados.TryGetValue(j.id, out i);
                saida.Add(new GameMetadata
                {
                    Name = j.nome,
                    GameId = j.id,
                    IsInstalled = tem,
                    InstallDirectory = tem ? i.pasta : null,
                    Source = new MetadataNameProperty("Jogos de PC"),
                    Platforms = new HashSet<MetadataProperty> { new MetadataSpecProperty("pc_windows") }
                });
            }
            return saida;
        }

        public override IEnumerable<InstallController> GetInstallActions(GetInstallActionsArgs args)
        {
            var nosso = args.Game.PluginId == Id || (args.Game.PluginId == InstaladorRetomada.PluginRomm && InstaladorRetomada.IdRomm(args.Game) != null);
            if (!nosso) { yield break; }
            // Ja esta nos downloads: o Playnite vai trocar o controller (e o Dispose do antigo nao cancela).
            var vivo = Gerenciador.Vivo(args.Game.Id);
            if (vivo != null)
            {
                vivo.ProtegidoAte = DateTime.Now.AddSeconds(10);
                yield return new JaNosDownloads(args.Game, api, vivo);
                yield break;
            }
            if (args.Game.PluginId == Id) { yield return new InstaladorJogo(args.Game, api); }
            else { yield return new InstaladorRetomada(args.Game, api); }
        }

        public override IEnumerable<UninstallController> GetUninstallActions(GetUninstallActionsArgs args)
        {
            if (args.Game.PluginId == Id) { yield return new DesinstaladorJogo(args.Game, api); }
        }

        public override IEnumerable<PlayController> GetPlayActions(GetPlayActionsArgs args)
        {
            if (args.Game.PluginId != Id) { yield break; }
            Instalado i;
            if (!Dados.Instalados().TryGetValue(args.Game.GameId, out i)) { yield break; }
            var exe = Path.Combine(i.pasta, i.executavel.Replace('/', '\\'));
            yield return new AutomaticPlayController(args.Game)
            {
                Name = "Jogar",
                Type = AutomaticPlayActionType.File,
                TrackingMode = TrackingMode.Default,
                Path = exe,
                WorkingDir = Path.GetDirectoryName(exe)
            };
        }

        public override void OnApplicationStarted(OnApplicationStartedEventArgs args)
        {
            // Na tela cheia ninguem pede a barra na tela principal, e criar controle numa tarefa de fundo derruba o download.
            api.MainView.UIDispatcher.Invoke(new Action(() => { var barra = Barra.Conteudo; }));
            CartaoSelene.Iniciar(api);
            // Tira os registros criados pela extensao antiga, que nao tinha Instalar/Desinstalar.
            foreach (var g in api.Database.Games.Where(g => g.PluginId == Guid.Empty && g.GameId != null && g.GameId.StartsWith("jogospc-")).ToList())
            {
                api.Database.Games.Remove(g);
            }
            try
            {
                var salvos = FilaSalva.Iniciar(Path.Combine(Dados.Base, "downloads-fila.json"));
                OferecerContinuar(salvos);
                RetomarDepois(salvos);
            }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao ler os downloads da sessao anterior"); }
            RodarAoAbrir();
            salas.Iniciar();
            Task.Run(() =>
            {
                try { CriarFiltroInstalados(); }
                catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao criar o filtro Instalados"); }
                try { CriarFiltrosPlataforma(); PreencherIcones(); PreencherArtes(); }
                catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao buscar artes"); }
            });
        }

        // Os downloads param junto com o Playnite (menos a instalacao, que vai ate o fim) e continuam na
        // proxima abertura; nada muda no downloads-fila.json daqui em diante.
        public override void OnApplicationStopped(OnApplicationStoppedEventArgs args)
        {
            Gerenciador.Encerrando = true;
            foreach (var e in Gerenciador.Copia())
            {
                try { e.Encerrar(); }
                catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao parar o download de " + e.Nome); }
            }
        }

        // Reserva para a tela de Downloads quando o controle nao chega nela pelas teclas.
        public override void OnControllerButtonStateChanged(OnControllerButtonStateChangedArgs args) { JanelaDownloads.Controle(args); }

        // Quem abre o Playnite por outro atalho nao passa pelo launcher: o ao-abrir.ps1 atualiza o
        // programa e liga o multiplayer (e nao faz nada se o launcher acabou de rodar). Pasta de
        // trabalho na instalacao, para nao prender a pasta programa, que a atualizacao troca.
        static void RodarAoAbrir()
        {
            try
            {
                var script = Path.Combine(Dados.Base, "programa", "ao-abrir.ps1");
                if (!File.Exists(script)) { return; }
                Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"")
                {
                    UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Dados.Base
                });
            }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao rodar o ao-abrir.ps1"); }
        }

        public override void OnGameStarted(OnGameStartedEventArgs args) { CapaSelene.Iniciar(api, args); }

        public override void OnGameStopped(OnGameStoppedEventArgs args) { CapaSelene.Parar(args.Game.Id); }

        // Na primeira abertura, os jogos so existem depois que a biblioteca atualiza.
        public override void OnLibraryUpdated(OnLibraryUpdatedEventArgs args) { Task.Run(() => Organizar()); }

        void Organizar()
        {
            try { OcultarRepetidos(); }
            catch (Exception e) { LogManager.GetLogger().Error(e, "Falha ao ocultar repetidos"); }
        }

        void OcultarRepetidos()
        {
            // Jogo da loja que nao esta instalado e tambem existe no catalogo: fica so o do
            // catalogo, porque o botao Instalar da loja abre o site dela. O instalador da GOG
            // registra o jogo no Windows, entao o que veio do catalogo tambem aparece como da GOG.
            if (!Dados.InstalacaoDeAmigo) { return; }
            Func<string, string> limpar = n => Regex.Replace((n ?? "").ToLowerInvariant(), "[^a-z0-9]", "");
            var doCatalogo = api.Database.Games.Where(g => g.PluginId == Id).ToList();
            var catalogo = new HashSet<string>(doCatalogo.Select(g => limpar(g.Name)));
            var instalados = new HashSet<string>(doCatalogo.Where(g => g.IsInstalled).Select(g => limpar(g.Name)));
            var gog = Guid.Parse("aebe8b7c-6dc3-4a66-af31-e7375c6b5e9e");
            foreach (var g in api.Database.Games.Where(x => x.PluginId != Id && x.PluginId != InstaladorRetomada.PluginRomm && !x.Hidden && catalogo.Contains(limpar(x.Name)) && (!x.IsInstalled || (x.PluginId == gog && instalados.Contains(limpar(x.Name))))).ToList())
            {
                var jogo = g;
                api.MainView.UIDispatcher.Invoke(new Action(() =>
                {
                    jogo.Hidden = true;
                    api.Database.Games.Update(jogo);
                }));
            }
        }

        public override void OnGameInstalled(OnGameInstalledEventArgs args) { Task.Run(() => Organizar()); }

        public override void OnGameUninstalled(OnGameUninstalledEventArgs args) { Task.Run(() => Organizar()); }

        static byte[] Reduzir(byte[] b)
        {
            // Nos PCs dos amigos, a imagem de fundo fica em ate 1280 px para ocupar menos disco.
            try
            {
                if (BitmapDecoder.Create(new MemoryStream(b), BitmapCreateOptions.None, BitmapCacheOption.OnDemand).Frames[0].PixelWidth <= 1280) { return b; }
                var imagem = new BitmapImage();
                imagem.BeginInit();
                imagem.CacheOption = BitmapCacheOption.OnLoad;
                imagem.DecodePixelWidth = 1280;
                imagem.StreamSource = new MemoryStream(b);
                imagem.EndInit();
                imagem.Freeze();
                var jpeg = new JpegBitmapEncoder { QualityLevel = 80 };
                jpeg.Frames.Add(BitmapFrame.Create(imagem));
                using (var saida = new MemoryStream()) { jpeg.Save(saida); return saida.ToArray(); }
            }
            catch (Exception e) { LogManager.GetLogger().Warn(e, "Nao reduziu a imagem"); return b; }
        }

        public override IEnumerable<TopPanelItem> GetTopPanelItems()
        {
            yield return new TopPanelItem { Icon = Barra.Conteudo, Title = "Abrir downloads", Activated = () => JanelaDownloads.Abrir(api) };
        }

        // No Start so "Downloads": pausar, cancelar e o resto ficam dentro da tela.
        public override IEnumerable<MainMenuItem> GetMainMenuItems(GetMainMenuItemsArgs args)
        {
            yield return new MainMenuItem { Description = "Downloads", MenuSection = "@Jogos de PC", Action = a => JanelaDownloads.Abrir(api) };
        }

        private static readonly string[] ExesEmulador = { "retroarch.exe", "PPSSPPWindows64.exe", "pcsx2-qt.exe", "duckstation-qt-x64-ReleaseLTCG.exe", "Dolphin.exe", "eden.exe", "rpcs3.exe", "azahar.exe", "melonDS.exe" };

        private string ExeDoEmulador(Game jogo)
        {
            if (jogo.GameActions == null) { return null; }
            var acao = jogo.GameActions.FirstOrDefault(x => x.Type == GameActionType.Emulator && x.EmulatorId != Guid.Empty);
            if (acao == null) { return null; }
            var emulador = api.Database.Emulators.Get(acao.EmulatorId);
            if (emulador == null || string.IsNullOrEmpty(emulador.InstallDir)) { return null; }
            var pasta = emulador.InstallDir.Replace("{PlayniteDir}", api.Paths.ApplicationPath);
            return ExesEmulador.Select(x => Path.Combine(pasta, x)).FirstOrDefault(x => File.Exists(x));
        }

        private void AbrirEmulador(string exe)
        {
            var nome = Path.GetFileNameWithoutExtension(exe);
            if (Process.GetProcessesByName(nome).Length > 0) { api.Dialogs.ShowMessage("O emulador já está aberto."); return; }
            // Estes dois tem uma interface propria para controle; os outros abrem normalmente.
            var bigPicture = nome.StartsWith("pcsx2", StringComparison.OrdinalIgnoreCase) || nome.StartsWith("duckstation", StringComparison.OrdinalIgnoreCase);
            try { Process.Start(new ProcessStartInfo(exe, bigPicture ? "-bigpicture" : "") { WorkingDirectory = Path.GetDirectoryName(exe), UseShellExecute = false }); }
            catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao abrir o emulador"); api.Dialogs.ShowErrorMessage("Não foi possível abrir o emulador.", "Configurar emulador"); }
        }

        public override IEnumerable<GameMenuItem> GetGameMenuItems(GetGameMenuItemsArgs args)
        {
            // Pausar e cancelar pelo controle, nas opcoes do jogo.
            if (args.Games.Count != 1) { yield break; }
            var emulador = ExeDoEmulador(args.Games[0]);
            if (emulador != null) { yield return new GameMenuItem { Description = "Configurar emulador", Action = a => AbrirEmulador(emulador) }; }
            var jogo = args.Games[0];
            var e = Gerenciador.Vivo(jogo.Id);
            if (e != null)
            {
                if (e.Pausado) { yield return new GameMenuItem { Description = "Continuar download", Action = a => e.Alternar() }; }
                else if (e.PodePausar) { yield return new GameMenuItem { Description = "Pausar download", Action = a => e.Alternar() }; }
                if (!e.Instalando) { yield return new GameMenuItem { Description = "Cancelar download", Action = a => AcoesDownload.CancelarDownload(api, e) }; }
            }
            var recomp = Tarefas.Copia().Any(x => x.Recomp && !x.Terminada && x.Nome == jogo.Name);
            if (e != null || recomp || FilaSalva.Metade().Any(x => x.Key.jogo == jogo.Id))
            {
                var id = jogo.Id;
                yield return new GameMenuItem { Description = "Ver downloads", Action = a => JanelaDownloads.Abrir(api, id) };
            }
        }

        public override IEnumerable<SidebarItem> GetSidebarItems()
        {
            yield return new SidebarItem
            {
                Title = "Downloads",
                Type = SiderbarItemType.Button,
                Icon = new TextBlock { Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 20 },
                Activated = () => JanelaDownloads.Abrir(api)
            };
        }

        static bool EhImagem(byte[] b)
        {
            // O ScreenScraper responde com texto quando esta sem vaga.
            return b.Length > 1024 && ((b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x89 && b[1] == 0x50));
        }

        void CriarFiltrosPlataforma()
        {
            // Um filtro salvo por plataforma com jogos; o tema Selene mostra esses filtros como abas.
            var usadas = api.Database.Games.Where(g => g.PlatformIds != null).SelectMany(g => g.PlatformIds).Distinct().ToList();
            api.MainView.UIDispatcher.Invoke(new Action(() =>
            {
                foreach (var id in usadas)
                {
                    var plataforma = api.Database.Platforms.Get(id);
                    if (plataforma == null || api.Database.FilterPresets.Any(f => f.Name == plataforma.Name)) { continue; }
                    api.Database.FilterPresets.Add(new FilterPreset
                    {
                        Name = plataforma.Name,
                        Settings = new FilterPresetSettings { Platform = new IdItemFilterItemProperties(id) },
                        SortingOrder = SortOrder.Name,
                        SortingOrderDirection = SortOrderDirection.Ascending,
                        ShowInFullscreeQuickSelection = true
                    });
                }
            }));
        }

        // Uma vez so (marca em filtro-instalados.txt, mesmo que a pessoa apague ou renomeie depois).
        void CriarFiltroInstalados()
        {
            var pasta = GetPluginUserDataPath();
            Directory.CreateDirectory(pasta);
            var marca = Path.Combine(pasta, "filtro-instalados.txt");
            if (File.Exists(marca)) { return; }
            api.MainView.UIDispatcher.Invoke(new Action(() =>
            {
                var existente = FiltroInstalados.Existente(api.Database.FilterPresets);
                if (existente != Guid.Empty) { File.WriteAllText(marca, existente.ToString()); return; }
                var novo = FiltroInstalados.Novo();
                api.Database.FilterPresets.Add(novo);
                File.WriteAllText(marca, novo.Id.ToString());
                PosicionarFiltro(novo.Id);
            }));
        }

        // Na thread da UI. A ordem dos filtros fica no banco do Playnite (FilterPresetsSettings.SortingOrder),
        // fora do SDK: por reflexao, e qualquer diferenca so avisa uma vez no log (o filtro fica no fim).
        void PosicionarFiltro(Guid id)
        {
            try
            {
                var completa = api.MainView.GetSortedFilterPresets().Select(x => x.Id).ToList();
                var tela = api.MainView.GetSortedFilterFullscreenPresets();
                var nova = FiltroInstalados.NovaOrdem(completa, id, tela.Count > 0 ? tela[0].Id : Guid.Empty);
                const BindingFlags f = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
                object banco = api.Database;
                var ler = banco.GetType().GetMethod("GetFilterPresetsSettings", f, null, Type.EmptyTypes, null);
                if (ler == null)
                {
                    // O api.Database e o DatabaseAPI, que guarda o GameDatabase no campo "database".
                    var campo = banco.GetType().GetField("database", f);
                    banco = campo == null ? null : campo.GetValue(banco);
                    ler = banco == null ? null : banco.GetType().GetMethod("GetFilterPresetsSettings", f, null, Type.EmptyTypes, null);
                }
                var cfg = ler == null ? null : ler.Invoke(banco, null);
                var prop = cfg == null ? null : cfg.GetType().GetProperty("SortingOrder", f);
                var gravar = cfg == null ? null : banco.GetType().GetMethod("SetFilterPresetsSettings", f, null, new[] { cfg.GetType() }, null);
                if (prop == null || prop.PropertyType != typeof(List<Guid>) || gravar == null)
                {
                    LogManager.GetLogger().Warn("Filtro Instalados: GetFilterPresetsSettings/SortingOrder/SetFilterPresetsSettings nao encontrados no Playnite; o filtro fica no fim");
                    return;
                }
                var antiga = prop.GetValue(cfg, null) as List<Guid>;
                LogManager.GetLogger().Info("Filtro Instalados: ordem antiga dos filtros: " + string.Join(",", (antiga ?? new List<Guid>()).Select(x => x.ToString())));
                prop.SetValue(cfg, nova, null);
                gravar.Invoke(banco, new[] { cfg });
            }
            catch (Exception e) { LogManager.GetLogger().Warn(e, "Filtro Instalados: nao consegui mudar a ordem; o filtro fica no fim"); }
        }

        void PreencherIcones()
        {
            // Jogo sem icone, mas com capa, usa a capa na lista lateral.
            foreach (var g in api.Database.Games.Where(x => string.IsNullOrEmpty(x.Icon) && !string.IsNullOrEmpty(x.CoverImage)).ToList())
            {
                var capa = api.Database.GetFullFilePath(g.CoverImage);
                if (!File.Exists(capa)) { continue; }
                var jogo = g;
                api.MainView.UIDispatcher.Invoke(new Action(() =>
                {
                    jogo.Icon = api.Database.AddFile(capa, jogo.Id);
                    api.Database.Games.Update(jogo);
                }));
            }
        }

        void TirarCapturasAntigas(string marca)
        {
            // A primeira versao colocou capturas de tela; roda uma vez para trocar so essas.
            if (File.Exists(marca)) { return; }
            var limite = new DateTime(2026, 11, 8, 16, 55, 0);
            foreach (var g in api.Database.Games.Where(x => x.PluginId == InstaladorRetomada.PluginRomm && !string.IsNullOrEmpty(x.BackgroundImage)).ToList())
            {
                var arquivo = api.Database.GetFullFilePath(g.BackgroundImage);
                if (!File.Exists(arquivo) || File.GetCreationTime(arquivo) < limite || !arquivo.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase)) { continue; }
                var jogo = g;
                api.MainView.UIDispatcher.Invoke(new Action(() =>
                {
                    api.Database.RemoveFile(jogo.BackgroundImage);
                    jogo.BackgroundImage = null;
                    api.Database.Games.Update(jogo);
                }));
            }
            File.WriteAllText(marca, "ok");
        }

        void PreencherArtes()
        {
            // Jogo retro sem imagem de fundo usa a fanart do RomM; sem fanart, a primeira captura de tela.
            var pastaPlugin = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            var arqSem = Path.Combine(pastaPlugin, "sem-fanart.txt");
            var semArte = new HashSet<string>(File.Exists(arqSem) ? File.ReadAllLines(arqSem) : new string[0]);
            TirarCapturasAntigas(Path.Combine(pastaPlugin, "capturas-removidas.txt"));
            var cfg = Serialization.FromJson<ConfigRomm>(File.ReadAllText(Path.Combine(api.Paths.ExtensionsDataPath, InstaladorRetomada.PluginRomm.ToString(), "config.json"), Encoding.UTF8));
            var host = cfg.RomMHost.TrimEnd('/');
            var auth = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(cfg.RomMUsername + ":" + cfg.RomMPassword));
            foreach (var g in api.Database.Games.Where(x => x.PluginId == InstaladorRetomada.PluginRomm && string.IsNullOrEmpty(x.BackgroundImage)).ToList())
            {
                var id = InstaladorRetomada.IdRomm(g);
                if (id == null || semArte.Contains(id)) { continue; }
                try
                {
                    using (var web = new WebClient())
                    {
                        web.Encoding = Encoding.UTF8;
                        web.Headers[HttpRequestHeader.Authorization] = auth;
                        var rom = Serialization.FromJson<RomArte>(web.DownloadString(host + "/api/roms/" + id));
                        byte[] imagem = null;
                        if (rom.ss_metadata != null && !string.IsNullOrEmpty(rom.ss_metadata.fanart_url))
                        {
                            // A fanart vem do ScreenScraper, que nao recebe o login do RomM.
                            web.Headers.Remove(HttpRequestHeader.Authorization);
                            try { imagem = web.DownloadData(rom.ss_metadata.fanart_url); }
                            catch (WebException e) { LogManager.GetLogger().Warn(e, "Fanart de " + g.Name); }
                            if (imagem != null && !EhImagem(imagem)) { imagem = null; }
                        }
                        if (imagem == null && rom.merged_screenshots != null && rom.merged_screenshots.Count > 0)
                        {
                            web.Headers[HttpRequestHeader.Authorization] = auth;
                            imagem = web.DownloadData(host + rom.merged_screenshots[0]);
                        }
                        if (imagem == null || !EhImagem(imagem)) { semArte.Add(id); continue; }
                        if (Dados.InstalacaoDeAmigo) { imagem = Reduzir(imagem); }
                        var temp = Path.Combine(Path.GetTempPath(), "arte_" + id + (imagem[0] == 0x89 ? ".png" : ".jpg"));
                        File.WriteAllBytes(temp, imagem);
                        var jogo = g;
                        api.MainView.UIDispatcher.Invoke(new Action(() =>
                        {
                            jogo.BackgroundImage = api.Database.AddFile(temp, jogo.Id);
                            api.Database.Games.Update(jogo);
                        }));
                        File.Delete(temp);
                    }
                }
                catch (WebException e) { LogManager.GetLogger().Error(e, "Arte de " + g.Name); }
            }
            File.WriteAllLines(arqSem, semArte);
        }

        // Pastas de _baixando sem registro no downloads-fila.json (versoes anteriores): ficam "Pela metade",
        // sem continuar sozinhas. No Desktop, o aviso de sempre oferece continuar.
        void OferecerContinuar(List<ItemFila> salvos)
        {
            var pendentes = Path.Combine(Dados.Raiz, "_baixando");
            if (!Directory.Exists(pendentes)) { return; }
            var instalados = Dados.Instalados();
            foreach (var pasta in Directory.GetDirectories(pendentes))
            {
                var id = Path.GetFileName(pasta);
                var jogo = api.Database.Games.FirstOrDefault(g => g.PluginId == Id && g.GameId == id);
                if (jogo == null || instalados.ContainsKey(id) || Descarte.EmUso(pasta + ".lock") || salvos.Any(x => x.jogo == jogo.Id)) { continue; }
                FilaSalva.Antigo(jogo.Id, jogo.Name, id);
                if (api.ApplicationInfo.Mode != ApplicationMode.Desktop) { continue; }
                var alvo = jogo.Id;
                api.Notifications.Add(new NotificationMessage("continuar-" + id, jogo.Name + ": download pela metade. Clique aqui para continuar.", NotificationType.Info, () => api.InstallGame(alvo)));
            }
        }

        // Downloads interrompidos pelo fechamento do Playnite continuam sozinhos, na ordem da fila, ~10 s
        // depois de abrir (depois da segunda conferencia do plugin Recomps, regra 21).
        void RetomarDepois(List<ItemFila> salvos)
        {
            var t = new System.Windows.Threading.DispatcherTimer(DispatcherPriority.Background, api.MainView.UIDispatcher) { Interval = TimeSpan.FromSeconds(10) };
            t.Tick += (s, e) =>
            {
                t.Stop();
                var retomados = new HashSet<Guid>();
                if (salvos.Count > 0)
                {
                    try { retomados = Retomar(salvos); } catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao continuar os downloads da sessao anterior"); }
                }
                try { DestravarInstalando(retomados); } catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao conferir jogos presos em instalando"); }
            };
            t.Start();
        }

        // Jogo nosso marcado "instalando" sem download nenhum (o Playnite fechou ou o fim nao foi avisado numa versao
        // antiga): sai do "instalando". Nunca o que acabou de ser retomado, nem nada com um Recomp instalando (a tarefa
        // dele tem o nome do catalogo dos Recomps, que pode nao ser o do jogo), nem jogo do RomM sem registro no
        // downloads-fila.json (pode ser a instalacao do proprio RomM).
        void DestravarInstalando(HashSet<Guid> retomados)
        {
            if (Tarefas.Copia().Any(x => x.Recomp && !x.Terminada)) { return; }
            foreach (var g in api.Database.Games.Where(x => x.IsInstalling).ToList())
            {
                var nosso = g.PluginId == Id || (g.PluginId == InstaladorRetomada.PluginRomm && InstaladorRetomada.IdRomm(g) != null && FilaSalva.Tem(g.Id));
                if (!nosso || retomados.Contains(g.Id) || Gerenciador.Presente(g.Id)) { continue; }
                LogManager.GetLogger().Info("Jogo " + g.Name + " estava preso em instalando sem download: destravado");
                g.IsInstalling = false;
                api.Database.Games.Update(g);
            }
        }

        // Na thread da UI. Devolve os jogos que vao continuar (agora ou quando o trabalho anterior liberar).
        HashSet<Guid> Retomar(List<ItemFila> salvos)
        {
            var instalados = Dados.Instalados();
            var vao = new List<ItemFila>();
            foreach (var i in salvos)
            {
                var jogo = api.Database.Games.Get(i.jogo);
                if (Gerenciador.Vivo(i.jogo) != null) { continue; }
                // Jogo que saiu da biblioteca ou que ja terminou: sai da lista.
                if (jogo == null || (i.tipo == "pc" && i.id != null && instalados.ContainsKey(i.id)) || (i.tipo == "rom" && i.parcial != null && File.Exists(Descarte.DestinoDe(i.parcial))))
                {
                    FilaSalva.Remover(i.jogo);
                    continue;
                }
                if (i.situacao == "metade") { continue; }
                if (i.tipo == "pc" && i.situacao == "instalando") { FilaSalva.NaoRetomado(i.jogo, FilaSalva.FaltaInstalar); continue; }
                // ROM de jogo com o Recomp instalado: so baixa para o emulador quando a pessoa pedir.
                if (i.tipo == "rom" && jogo.IsInstalled) { FilaSalva.NaoRetomado(i.jogo, FilaSalva.SoRomComRecomp); continue; }
                vao.Add(i);
            }
            Gerenciador.Restaurar(vao.Select(x => new KeyValuePair<Guid, bool>(x.jogo, x.situacao == "pausado")).ToList());
            var esperar = new List<ItemFila>();
            foreach (var i in vao)
            {
                if (AnteriorEmUso(i))
                {
                    // O trabalho da sessao anterior ainda esta aberto: entra no fim da fila quando liberar.
                    Gerenciador.TirarReserva(i.jogo);
                    FilaSalva.Esperar(i);
                    esperar.Add(i);
                    continue;
                }
                Instalar(i);
            }
            if (esperar.Count > 0) { EsperarAnteriores(esperar); }
            return new HashSet<Guid>(vao.Select(x => x.jogo));
        }

        void Instalar(ItemFila i)
        {
            if (i.tipo == "rom") { Tarefas.MarcarSoEmulador(i.jogo); }
            api.InstallGame(i.jogo);
        }

        bool AnteriorEmUso(ItemFila i)
        {
            if (i.tipo == "pc") { var pasta = Descarte.PastaPc(Dados.Raiz, i.id); return pasta != null && Descarte.EmUso(pasta + ".lock"); }
            return i.parcial != null && Descarte.EmUso(i.parcial);
        }

        void EsperarAnteriores(List<ItemFila> lista)
        {
            var t = new System.Windows.Threading.DispatcherTimer(DispatcherPriority.Background, api.MainView.UIDispatcher) { Interval = TimeSpan.FromSeconds(5) };
            t.Tick += (s, e) =>
            {
                try
                {
                    foreach (var i in lista.ToList())
                    {
                        if (!FilaSalva.Esperando().Any(x => x.jogo == i.jogo) || Gerenciador.Vivo(i.jogo) != null) { lista.Remove(i); FilaSalva.ParouDeEsperar(i.jogo); continue; }
                        if (AnteriorEmUso(i)) { continue; }
                        lista.Remove(i);
                        FilaSalva.ParouDeEsperar(i.jogo);
                        Instalar(i);
                    }
                }
                catch (Exception ex) { LogManager.GetLogger().Error(ex, "Falha ao continuar um download da sessao anterior"); lista.Clear(); }
                if (lista.Count == 0) { t.Stop(); }
            };
            t.Start();
        }
    }
}
