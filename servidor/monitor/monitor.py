# Monitor dos servidores de jogo (multiplayer) para o painel Amigos.
# A cada 15 s confere cada container pelo Docker, se a porta esta aberta (lendo /proc/net,
# sem conectar, para nao sujar o log nem ocupar vaga nas salas) e quem esta conectado, e
# grava dados/servidores.json. Tambem atende os pedidos de reinicio que o painel deixa em
# dados/pedidos/<nome>, so para os containers da lista. E o unico que fala com o Docker.
# Na partida e a cada 6 h (numa thread, sem atrasar o ciclo) confere no GitHub as releases dos
# Recomps do catalogo publicado (recomps.json de dentro do pacote), so lendo.
# So biblioteca padrao do Python.

import http.client
import json
import os
import re
import socket
import struct
import threading
import time
import urllib.error
import urllib.request
import zipfile
from datetime import UTC, datetime

DADOS = os.environ.get('DADOS', '/dados')
SOCK = os.environ.get('DOCKER_SOCK', '/var/run/docker.sock')
RELAY_LOG = os.environ.get('RELAY_LOG', '/relay/tunnel.log')
PSP_STATUS = os.environ.get('PSP_STATUS', 'http://127.0.0.1:8888/data.json')
DONO_ARQUIVOS = (int(os.environ.get('PAINEL_UID', '999')), int(os.environ.get('PAINEL_GID', '1000')))
VERSAO_PUBLICADA = os.environ.get('VERSAO_PUBLICADA', '/instalador/versao.json')
VERSAO_TESTE = os.environ.get('VERSAO_TESTE', '/instalador/versao-teste.json')
GITHUB_API = os.environ.get('GITHUB_API', 'https://api.github.com')
RECOMPS_INTERVALO = 6 * 3600
# Mesmo formato de pacote que o atualizador dos amigos aceita.
PACOTE = re.compile(r'^programa-\d+\.zip$')
CATALOGO_MAX = 1024 * 1024
INTERVALO = 15
EVENTOS_MAX = 30
# Atualizacoes do programa dos amigos: tiradas do log do nginx do servidor de jogos.
CONTAINER_JOGOS = 'jogos-pc'
LOG_NGINX = re.compile(r'^\S+ - (\S+) \[([^\]]+)\] "GET /instalador/(versao\.json|programa-(\d+)\.zip) HTTP/[\d.]+" (\d{3}) ')

# nome do container, titulo no painel, porta que precisa estar aberta (protocolo, numero)
SERVIDORES = [
    ('psp-adhoc', 'PSP (ad hoc)', ('tcp', 27312)),
    ('switch-room', 'Switch (sala do Eden)', ('udp', 24872)),
    ('3ds-room', '3DS (sala do Azahar)', ('udp', 24873)),
    ('rpcn', 'PS3 (RPCN)', ('tcp', 31313)),
    ('retroarch-relay', 'RetroArch (relay do netplay)', ('tcp', 55435)),
    ('ponte-vpn', 'Ponte Tailscale/Netbird', None),
]
NOMES = [s[0] for s in SERVIDORES]
ANSI = re.compile(r'\x1b\[[0-9;]*m')


# ---------- Docker (API pelo socket) ----------

class ConexaoSocket(http.client.HTTPConnection):
    def __init__(self, caminho):
        super().__init__('localhost', timeout=20)
        self.caminho = caminho

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(20)
        self.sock.connect(self.caminho)


def docker(metodo, caminho):
    c = ConexaoSocket(SOCK)
    try:
        c.request(metodo, caminho)
        r = c.getresponse()
        return r.status, r.read()
    finally:
        c.close()


def separar_logs(dados):
    # Sem TTY o Docker manda o log em blocos com cabecalho de 8 bytes (fluxo, 0, 0, 0, tamanho).
    partes, i = [], 0
    while i + 8 <= len(dados) and dados[i] in (0, 1, 2) and dados[i + 1:i + 4] == b'\0\0\0':
        n = struct.unpack('>I', dados[i + 4:i + 8])[0]
        partes.append(dados[i + 8:i + 8 + n])
        i += 8 + n
    texto = b''.join(partes) if i else dados
    return ANSI.sub('', texto.decode('utf-8', errors='replace'))


def iso_para_epoch(iso):
    # "2026-11-13T17:02:11.123456789Z" (nanossegundos que o Python nao le).
    if not iso or iso.startswith('0001-'):
        return None
    base = iso.split('.')[0].rstrip('Z')
    return datetime.strptime(base, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=UTC).timestamp()


def info_container(nome):
    status, dados = docker('GET', '/containers/%s/json' % nome)
    if status != 200:
        return None
    e = json.loads(dados)
    return {'rodando': bool(e['State'].get('Running')) and not e['State'].get('Restarting'),
            'desde': iso_para_epoch(e['State'].get('StartedAt')), 'reinicios': e.get('RestartCount', 0)}


def logs_desde(nome, desde):
    status, dados = docker('GET', '/containers/%s/logs?stdout=1&stderr=1&since=%d' % (nome, int(desde or 0)))
    return separar_logs(dados) if status == 200 else ''


# ---------- portas e jogadores ----------

def portas_abertas(raiz='/proc/net'):
    # {('tcp', porta), ('udp', porta)} que estao ouvindo (tcp LISTEN = 0A, udp = 07).
    abertas = set()
    for proto, estado in (('tcp', '0A'), ('tcp6', '0A'), ('udp', '07'), ('udp6', '07')):
        try:
            with open(os.path.join(raiz, proto)) as f:
                next(f)
                for linha in f:
                    c = linha.split()
                    if len(c) > 3 and c[3] == estado:
                        abertas.add((proto[:3], int(c[1].rsplit(':', 1)[1], 16)))
        except (OSError, StopIteration, ValueError):
            pass
    return abertas


def jogadores_sala(log):
    # Salas do Eden e do Azahar: "[ip] Nome has joined." / "has left." / "has been kicked."
    presentes = []
    for m in re.finditer(r'\[[0-9A-Fa-f:.]+\] (.+?) has (joined|left|been kicked)\.', log):
        nome = m.group(1).strip()
        if m.group(2) == 'joined':
            if nome not in presentes:
                presentes.append(nome)
        elif nome in presentes:
            presentes.remove(nome)
    return presentes


def jogadores_psp(dados):
    # data.json do aemu: jogos > grupos > usuarios. Devolve "apelido (jogo)".
    lista = []
    for jogo in dados.get('games') or []:
        for grupo in jogo.get('groups') or []:
            for u in grupo.get('users') or []:
                lista.append('%s (%s)' % (u.get('name', '?'), jogo.get('name', '?')))
    return lista


def sessoes_relay(log, desde):
    # Linhas "(dd/mm/aaaa hh:mm:ss) [INFO] Tunnel session created/closed for: ip|porta".
    abertas = 0
    for m in re.finditer(r'^\((\d\d/\d\d/\d{4} \d\d:\d\d:\d\d)\) \[INFO\] Tunnel session (created|closed) for', log, re.M):
        quando = datetime.strptime(m.group(1), '%d/%m/%Y %H:%M:%S').replace(tzinfo=UTC).timestamp()
        if desde and quando < desde:
            continue
        abertas = abertas + 1 if m.group(2) == 'created' else max(0, abertas - 1)
    return abertas


def ler_url_json(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read() or b'{}')


def ler_relay():
    try:
        with open(RELAY_LOG, encoding='utf-8', errors='replace') as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 200000))
            return f.read()
    except OSError:
        return ''


# ---------- atualizacoes do programa dos amigos ----------

def ler_atualizacoes(log, usuarios):
    # Cada amigo: quando o programa conferiu atualizacao (versao.json) e o maior pacote
    # programa-N.zip que baixou. So conta resposta 200 e login de verdade. Ler a mesma
    # linha de novo nao muda nada, entao pode sobrepor o trecho ja lido.
    for linha in log.splitlines():
        m = LOG_NGINX.match(linha)
        if not m or m.group(1) == '-' or m.group(5) != '200':
            continue
        # O painel testa o login novo pedindo o versao.json ao gerar o convite: nao e o amigo.
        if '"Python-urllib/' in linha:
            continue
        quando = datetime.strptime(m.group(2), '%d/%b/%Y:%H:%M:%S %z').timestamp()
        u = usuarios.setdefault(m.group(1), {})
        if m.group(3) == 'versao.json':
            u['verificou'] = max(u.get('verificou', 0), quando)
        elif int(m.group(4)) > u.get('versao', 0) or (int(m.group(4)) == u.get('versao') and quando > u.get('atualizou', 0)):
            u['versao'], u['atualizou'] = int(m.group(4)), quando
    return usuarios


def atualizar_atualizacoes():
    # Guarda o resumo em arquivo: o log do container se perde se ele for recriado.
    destino = os.path.join(DADOS, 'atualizacoes.json')
    try:
        with open(destino, encoding='utf-8') as f:
            estado = json.load(f)
    except (FileNotFoundError, ValueError):
        estado = {'usuarios': {}, 'lido_ate': 0}
    if estado.get('formato', 1) < 2:
        # Versoes antigas contavam o teste de login do painel como "abriu o programa":
        # refaz as conferencias lendo o log desde o comeco (os pacotes baixados ficam).
        for u in estado['usuarios'].values():
            u.pop('verificou', None)
        estado['lido_ate'], estado['formato'] = 0, 2
    agora = time.time()
    status, dados = docker('GET', '/containers/%s/logs?stdout=1&stderr=1&since=%d' % (CONTAINER_JOGOS, max(0, int(estado['lido_ate']) - 60)))
    if status == 200:
        ler_atualizacoes(separar_logs(dados), estado['usuarios'])
        estado['lido_ate'] = agora
    try:
        with open(VERSAO_PUBLICADA, encoding='utf-8') as f:
            estado['publicada'] = int(json.load(f)['versao'])
    except (OSError, ValueError, KeyError):
        pass
    gravar_json(destino, estado)


# ---------- Recomps: releases no GitHub ----------

def ler_catalogos():
    # Os recomps.json de dentro dos pacotes publicados: {canal: jogos} e os avisos (pacote sem catalogo etc.).
    # Sem versao-teste.json e normal (nada em teste).
    pasta = os.path.dirname(VERSAO_PUBLICADA)
    canais, avisos = {}, []
    for canal, manifesto in (('liberado', VERSAO_PUBLICADA), ('teste', VERSAO_TESTE)):
        try:
            with open(manifesto, encoding='utf-8') as f:
                arquivo = json.load(f)['arquivo']
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not isinstance(arquivo, str) or not PACOTE.match(arquivo):
            avisos.append('%s: pacote com nome inesperado' % canal)
            continue
        try:
            with zipfile.ZipFile(os.path.join(pasta, arquivo)) as z:
                info = z.getinfo('recomps.json')
                if info.file_size > CATALOGO_MAX:
                    avisos.append('%s: recomps.json maior que 1 MB em %s' % (canal, arquivo))
                    continue
                jogos = json.loads(z.read(info).decode('utf-8')).get('jogos') or []
        except KeyError:
            avisos.append('%s: %s sem recomps.json' % (canal, arquivo))
            continue
        except (OSError, zipfile.BadZipFile, ValueError, AttributeError) as e:
            avisos.append('%s: não li o catálogo de %s (%s)' % (canal, arquivo, e))
            continue
        canais[canal] = [j for j in jogos if isinstance(j, dict) and j.get('id') and j.get('repo')]
    return canais, avisos


def recomps_do_catalogo(canais):
    # Uma linha por Recomp: "liberado" quando esta no pacote de todos; "teste" quando so esta no de teste
    # ou quando o de teste mudou a entrada (as duas linhas aparecem).
    liberados = {j['id']: j for j in canais.get('liberado', [])}
    lista = [(j, 'liberado') for j in canais.get('liberado', [])]
    for j in canais.get('teste', []):
        if liberados.get(j['id']) != j:
            lista.append((j, 'teste'))
    return lista


def ultima_release(releases):
    # A primeira que nao e rascunho (aceita pre-release), como o recomp.ps1; so o que o painel usa.
    for r in releases if isinstance(releases, list) else []:
        if isinstance(r, dict) and not r.get('draft'):
            return {'tag': r.get('tag_name'), 'data': r.get('published_at'), 'prerelease': bool(r.get('prerelease')),
                    'assets': [{'nome': a.get('name'), 'digest': a.get('digest')} for a in r.get('assets') or [] if isinstance(a, dict)]}
    return None


def consultar_github(repo, cache, agora):
    # Uma consulta (sem token): If-None-Match com o ETag de antes (304 reaproveita); 403/429 respeita o
    # X-RateLimit-Reset e mantem o ultimo. Devolve o cache novo: etag, ultima, erro, espera_ate, conferido.
    novo = dict(cache or {})
    req = urllib.request.Request('%s/repos/%s/releases?per_page=10' % (GITHUB_API, repo),
                                 headers={'User-Agent': 'monitor-jogos-retro', 'Accept': 'application/vnd.github+json'})
    if novo.get('etag'):
        req.add_header('If-None-Match', novo['etag'])
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            dados = json.loads(r.read())
            novo.update({'etag': r.headers.get('ETag'), 'ultima': ultima_release(dados), 'existe': True, 'erro': None, 'conferido': agora})
    except urllib.error.HTTPError as e:
        if e.code == 304:
            novo.update({'erro': None, 'conferido': agora})
        elif e.code in (403, 429):
            try:
                novo['espera_ate'] = float(e.headers.get('X-RateLimit-Reset') or 0) or agora + 3600
            except ValueError:
                novo['espera_ate'] = agora + 3600
            novo['erro'] = 'o GitHub limitou as consultas (HTTP %d)' % e.code
        elif e.code == 404:
            novo.update({'ultima': None, 'existe': False, 'erro': None, 'etag': None, 'conferido': agora})
        else:
            novo['erro'] = 'HTTP %d' % e.code
    except (OSError, ValueError, http.client.HTTPException) as e:
        novo['erro'] = str(e) or e.__class__.__name__
    return novo


def estado_recomp(jogo, canal, cache, vistas, agora):
    # O que o painel mostra de um Recomp. Vermelho: erro-github, sem-release, regex-nenhum, regex-varios,
    # sem-sha; amarelo: versao-nova; verde: ok. Sem "versao" no catalogo, a referencia e a 1a tag vista.
    cache = cache or {}
    ultima = cache.get('ultima')
    ref, vista = jogo.get('versao'), None
    if not ref:
        v = vistas.get(jogo['id'])
        if not v and ultima and ultima.get('tag'):
            v = vistas[jogo['id']] = {'tag': ultima['tag'], 'em': agora}
        if v:
            ref, vista = v.get('tag'), v.get('em')
    s = {'id': jogo['id'], 'nome': jogo.get('nome') or jogo['id'], 'repo': jogo.get('repo'), 'canal': canal, 'versao_ref': ref,
         'vista_em': vista, 'ultima': {k: ultima.get(k) for k in ('tag', 'data', 'prerelease')} if ultima else None,
         'casam': [], 'estado': 'ok', 'detalhe': '', 'conferido': cache.get('conferido')}
    if cache.get('erro') and not cache.get('conferido'):
        s.update(estado='erro-github', detalhe=cache['erro'])
        return s
    if not ultima:
        s['estado'] = 'sem-release'
        return s
    try:
        rx = re.compile(jogo.get('asset') or '', re.IGNORECASE)
    except re.error as e:
        s.update(estado='regex-nenhum', detalhe='regex inválida: %s' % e)
        return s
    casam = [a for a in ultima['assets'] if a.get('nome') and rx.search(a['nome'])]
    s['casam'] = [a['nome'] for a in casam]
    if not casam:
        s['estado'] = 'regex-nenhum'
    elif len(casam) > 1:
        s['estado'] = 'regex-varios'
    elif not re.match(r'^sha256:[0-9a-fA-F]{64}$', casam[0].get('digest') or ''):
        s['estado'] = 'sem-sha'
    elif ultima.get('tag') != ref:
        s['estado'] = 'versao-nova'
    if cache.get('erro'):
        s['detalhe'] = '%s; mostrando a última conferência' % cache['erro']
    return s


def conferir_recomps(agora=None):
    # Le o estado de antes (/dados/recomps-github.json), consulta cada repo uma vez e grava o novo. So leitura no GitHub.
    agora = agora or time.time()
    destino = os.path.join(DADOS, 'recomps-github.json')
    try:
        with open(destino, encoding='utf-8') as f:
            antes = json.load(f)
    except (OSError, ValueError):
        antes = {}
    repos, vistas = antes.get('repos') or {}, antes.get('vistas') or {}
    canais, avisos = ler_catalogos()
    lista = recomps_do_catalogo(canais)
    espera = max([c.get('espera_ate') or 0 for c in repos.values()] + [0])
    for repo in sorted({j['repo'] for j, _ in lista}):
        if agora < espera:
            repos.setdefault(repo, {})['erro'] = 'o GitHub limitou as consultas até %s' % time.strftime('%H:%M', time.localtime(espera))
            continue
        repos[repo] = consultar_github(repo, repos.get(repo), agora)
        espera = max(espera, repos[repo].get('espera_ate') or 0)
    recomps = [estado_recomp(j, canal, repos.get(j['repo']), vistas, agora) for j, canal in lista]
    resumo = {'conferido': agora, 'lista': recomps, 'avisos': avisos}
    gravar_json(destino, {'repos': {r: repos[r] for r in {j['repo'] for j, _ in lista} if r in repos}, 'vistas': vistas, **resumo})
    return resumo


recomps_trava = threading.Lock()
recomps_atual = {}


def ler_recomps_gravados():
    # O que a ultima conferencia gravou, para o painel ter o que mostrar logo na partida.
    try:
        with open(os.path.join(DADOS, 'recomps-github.json'), encoding='utf-8') as f:
            d = json.load(f)
        return {'conferido': d.get('conferido'), 'lista': d.get('lista') or [], 'avisos': d.get('avisos') or []}
    except (OSError, ValueError, AttributeError):
        return None


def vigiar_recomps():
    while True:
        try:
            r = conferir_recomps()
            with recomps_trava:
                recomps_atual['valor'] = r
        except Exception as e:
            print(time.strftime('%d/%m %H:%M:%S'), 'erro nos Recomps:', e, flush=True)
        time.sleep(RECOMPS_INTERVALO)


def recomps_agora():
    with recomps_trava:
        return recomps_atual.get('valor')


# ---------- ciclo ----------

def conferir(eventos, anterior):
    abertas = portas_abertas()
    lista = []
    for nome, titulo, porta in SERVIDORES:
        s = {'nome': nome, 'titulo': titulo, 'rodando': False, 'desde': None, 'reinicios': 0,
             'responde': None, 'jogadores': [], 'detalhe': ''}
        try:
            info = info_container(nome)
        except OSError as e:
            info, s['detalhe'] = None, 'sem acesso ao Docker: %s' % e
        if info is None:
            s['detalhe'] = s['detalhe'] or 'container não existe'
        else:
            s.update(info)
        if s['rodando']:
            if porta:
                s['responde'] = porta in abertas
            try:
                if nome == 'psp-adhoc':
                    s['jogadores'] = jogadores_psp(ler_url_json(PSP_STATUS))
                elif nome in ('switch-room', '3ds-room'):
                    s['jogadores'] = jogadores_sala(logs_desde(nome, s['desde']))
                elif nome == 'retroarch-relay':
                    n = sessoes_relay(ler_relay(), s['desde'])
                    s['detalhe'] = '%d sala(s) de netplay aberta(s)' % n if n else ''
                elif nome == 'ponte-vpn':
                    ok = 'ponte ativa' in logs_desde(nome, s['desde'])
                    s['responde'] = ok
                    s['detalhe'] = 'regras de tradução ativas' if ok else 'container rodando, mas as regras não subiram'
            except Exception as e:
                s['detalhe'] = 'não consegui ler os jogadores: %s' % e
        antes = anterior.get(nome)
        if antes is not None and antes != s['rodando']:
            eventos.insert(0, {'quando': time.time(), 'texto': '%s %s' % (titulo, 'voltou' if s['rodando'] else 'parou')})
        anterior[nome] = s['rodando']
        lista.append(s)
    return lista


def atender_pedidos(eventos):
    pasta = os.path.join(DADOS, 'pedidos')
    if not os.path.isdir(pasta):
        return
    for nome in os.listdir(pasta):
        try:
            os.remove(os.path.join(pasta, nome))
        except OSError:
            continue
        if nome not in NOMES:
            continue
        status, _ = docker('POST', '/containers/%s/restart?t=10' % nome)
        titulo = {n: t for n, t, _ in SERVIDORES}[nome]
        texto = '%s reiniciado pelo painel' % titulo if status == 204 else 'falha ao reiniciar %s (Docker %d)' % (titulo, status)
        eventos.insert(0, {'quando': time.time(), 'texto': texto})
        print(time.strftime('%d/%m %H:%M:%S'), texto, flush=True)


def gravar(servidores, eventos, recomps=None):
    dados = {'atualizado': time.time(), 'servidores': servidores, 'eventos': eventos[:EVENTOS_MAX]}
    if recomps is not None:
        dados['recomps'] = recomps
    gravar_json(os.path.join(DADOS, 'servidores.json'), dados)


def gravar_json(destino, dados):
    # Troca atomica, com dono e permissao para o painel (outro usuario) conseguir ler.
    tmp = destino + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(dados, f, ensure_ascii=False)
    if hasattr(os, 'chown'):  # so existe no Linux (o servidor); os testes rodam no Windows tambem
        try:
            os.chown(tmp, *DONO_ARQUIVOS)
        except OSError:
            pass
    os.chmod(tmp, 0o640)
    os.replace(tmp, destino)


def main():
    eventos, anterior = [], {}
    print('Monitor dos servidores de jogo, a cada %d s' % INTERVALO, flush=True)
    # Recomps no GitHub: thread propria (as consultas nao atrasam o ciclo); ate a 1a terminar, vale a gravada.
    try:
        gravados = ler_recomps_gravados()
        if gravados is not None:
            with recomps_trava:
                recomps_atual.setdefault('valor', gravados)
        threading.Thread(target=vigiar_recomps, daemon=True).start()
    except Exception as e:
        print(time.strftime('%d/%m %H:%M:%S'), 'erro nos Recomps:', e, flush=True)
    while True:
        try:
            atender_pedidos(eventos)
            gravar(conferir(eventos, anterior), eventos, recomps_agora())
        except Exception as e:
            print(time.strftime('%d/%m %H:%M:%S'), 'erro:', e, flush=True)
        try:
            atualizar_atualizacoes()
        except Exception as e:
            print(time.strftime('%d/%m %H:%M:%S'), 'erro nas atualizacoes:', e, flush=True)
        del eventos[EVENTOS_MAX:]
        time.sleep(INTERVALO)


if __name__ == '__main__':
    main()
