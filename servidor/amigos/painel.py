# Painel "Amigos" no ZimaOS: convida amigos, gera codigo de novo e revoga acesso ao servidor de jogos.
# Mesma logica do app "Amigos do Servidor.exe" / amigos.psm1, agora rodando no servidor.
# So biblioteca padrao do Python. Dados em /app/dados (fora do que o site entrega).

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APP = os.path.dirname(os.path.abspath(__file__))
DADOS = os.path.join(APP, 'dados')
SITE = os.path.join(APP, 'site')
INSTALADORES = os.path.join(APP, 'instaladores')
LOGINS = os.path.join(DADOS, 'logins.txt')
REDES = os.path.join(DADOS, 'amigos.json')
TOKEN = os.path.join(DADOS, 'netbird-token.txt')
CONFIG = os.path.join(DADOS, 'painel.json')
HTPASSWD = os.environ.get('HTPASSWD', '/htpasswd')
JOGOS_URL = os.environ.get('JOGOS_URL', 'http://192.168.0.10:8095')
# Pasta compartilhada com o container jogos-pc-catalogo (gerar-catalogo.py).
JOGOS_PC = os.environ.get('JOGOS_PC', '/jogos-pc')
NETBIRD_API = 'https://api.netbird.io/api'
PORTA = int(os.environ.get('PORTA', '8094'))
DONO = os.environ.get('DONO', 'dono')  # seu proprio login no servidor de jogos (nao aparece na lista)
SESSAO_DIAS = 30
# Downloads dos amigos: o PC avisa pelo servidor de jogos (nginx), que confere o login do
# amigo e repassa em /relato com o nome dele e a chave abaixo.
CHAVE_RELATO = os.path.join(DADOS, 'relato-chave.txt')
HISTORICO = os.path.join(DADOS, 'downloads.json')
HISTORICO_MAX = 200
PARADO_SEG = 180  # sem noticia ha 3 min: o PC desligou ou a internet caiu
ESTADOS = ('baixando', 'reconectando', 'fila', 'verificando', 'instalando', 'ok', 'erro', 'cancelado')
# Fim do download: sai dos ativos e vai para o historico. 'cancelado' vem do plugin (o worker e morto e nao avisa).
FINS = ('ok', 'erro', 'cancelado')
# Servidores de jogo: o container "monitor" grava o estado e atende os pedidos de reinicio.
SERVIDORES = os.path.join(DADOS, 'servidores.json')
PEDIDOS = os.path.join(DADOS, 'pedidos')
# Versao do programa de cada amigo, que o monitor tira do log do nginx do servidor de jogos.
ATUALIZACOES = os.path.join(DADOS, 'atualizacoes.json')
# Falhas do programa no PC dos amigos (atualizacao, multiplayer...), que chegam pelo mesmo /relato.
ERROS = os.path.join(DADOS, 'erros.json')
ERROS_MAX = 100

trava = threading.Lock()
trava_downloads = threading.Lock()
# Tentativas de senha: a conta e feita com trava (pedidos em paralelo nao zeram o contador)
# e no maximo 2 conferencias de senha rodam juntas, venham de quantos IPs vierem.
trava_falhas = threading.Lock()
conferindo_senha = threading.BoundedSemaphore(2)
falhas = {}  # ip -> [quantidade, bloqueado_ate]
FALHAS_MAX_IPS = 1000
ativos = {}  # (amigo, tipo, jogo) -> download em andamento


def ler_config():
    with open(CONFIG, encoding='utf-8') as f:
        return json.load(f)


# ---------- arquivos ----------

def ler_linhas(caminho):
    if not os.path.exists(caminho):
        return []
    with open(caminho, encoding='utf-8') as f:
        return [l.strip() for l in f if l.strip()]


def gravar_linhas(caminho, linhas):
    # So "\n": o nginx nao aceita "\r". Grava por cima do mesmo arquivo (o nginx enxerga o arquivo, nao a pasta).
    with open(caminho, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(l for l in linhas if l) + '\n')


def ler_redes():
    if not os.path.exists(REDES):
        return {}
    with open(REDES, encoding='utf-8-sig') as f:
        return json.load(f)


def gravar_rede(nome, rede):
    r = ler_redes()
    if rede:
        r[nome] = rede
    else:
        r.pop(nome, None)
    with open(REDES, 'w', encoding='utf-8') as f:
        json.dump({k: r[k] for k in sorted(r, key=str.lower)}, f, indent=2, ensure_ascii=False)


# ---------- NetBird ----------

def netbird(metodo, caminho, corpo=None):
    with open(TOKEN, encoding='utf-8-sig') as f:
        token = f.read().strip()
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(NETBIRD_API + caminho, data=dados, method=metodo,
                                 headers={'Authorization': 'Token ' + token, 'Content-Type': 'application/json',
                                          'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=20) as r:
        texto = r.read()
    return json.loads(texto) if texto.strip() else None


def revogar_chave(k):
    netbird('PUT', '/setup-keys/' + k['id'], {'revoked': True, 'auto_groups': k.get('auto_groups') or []})


# ---------- amigos ----------

def validar_nome(nome):
    if not re.fullmatch(r'[A-Za-z0-9_.-]{2,32}', nome or ''):
        raise ValueError('Use só letras, números, ponto, traço ou sublinhado (2 a 32).')
    if nome.lower() == DONO.lower():
        raise ValueError('Esse é o seu login.')


def ssha(senha):
    # {SSHA} = base64(sha1(senha + sal) + sal), formato que o nginx aceita.
    sal = secrets.token_bytes(8)
    # SHA-1 basta aqui: a senha e aleatoria de 32 caracteres (novo_convite), nao da para adivinhar.
    return '{SSHA}' + base64.b64encode(hashlib.sha1(senha.encode() + sal).digest() + sal).decode()  # noqa: S324


def novo_convite(nome, rede):
    validar_nome(nome)
    if rede not in ('netbird', 'tailscale'):
        raise ValueError('Rede inválida.')

    # 1) Login no servidor de jogos (amigo que ja existe ganha so um convite novo).
    logins = ler_linhas(LOGINS)
    linha = next((l for l in logins if l.split(' ')[0] == nome), None)
    # Nome igual com maiuscula diferente vira confusao no NetBird ("<nome>-pc").
    if not linha and any(l.split(' ')[0].lower() == nome.lower() for l in logins):
        raise ValueError('Já existe um amigo com esse nome (com outras maiúsculas).')
    # Os PCs no NetBird sao achados por "<nome>-": com traco, revogar "ana" levaria junto
    # o PC de "ana-maria". So para amigo novo (quem ja existe continua podendo).
    if not linha and '-' in nome:
        raise ValueError('Nome novo não pode ter traço (use ponto ou sublinhado).')
    if linha:
        senha = linha.split(' ')[1]
    else:
        letras = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        senha = ''.join(secrets.choice(letras) for _ in range(32))
        gravar_linhas(LOGINS, logins + [nome + ' ' + senha])
        gravar_linhas(HTPASSWD, ler_linhas(HTPASSWD) + [nome + ':' + ssha(senha)])

    # 2) Confere o login no servidor (o nginx le o arquivo a cada acesso).
    auth = base64.b64encode((nome + ':' + senha).encode()).decode()
    try:
        urllib.request.urlopen(urllib.request.Request(JOGOS_URL + '/instalador/versao.json',
                                                      headers={'Authorization': 'Basic ' + auth}), timeout=10).read()
    except Exception as e:
        raise ValueError('O servidor de jogos não aceitou o login: %s' % e) from e

    # 3) Chave NetBird de uso unico, valendo 7 dias, que coloca o PC no grupo Friends.
    chave = ''
    if rede == 'netbird':
        # Convite anterior que nao foi usado deixa de valer: um convite valido por pessoa.
        for k in netbird('GET', '/setup-keys'):
            if k['name'] == 'convite-' + nome and k.get('valid') and k.get('used_times', 0) == 0:
                revogar_chave(k)
        grupo = next((g['id'] for g in netbird('GET', '/groups') if g['name'] == 'Friends'), None)
        if not grupo:
            raise ValueError('Grupo Friends não encontrado no NetBird.')
        chave = netbird('POST', '/setup-keys', {'name': 'convite-' + nome, 'type': 'one-off', 'expires_in': 604800,
                                                 'auto_groups': [grupo], 'usage_limit': 1, 'ephemeral': False})['key']
    gravar_rede(nome, rede)

    # 4) Codigo de convite (o mesmo formato que o instalador entende).
    corpo = json.dumps({'u': nome, 's': senha, 'k': chave}, separators=(',', ':')).encode()
    codigo = 'JR1-' + base64.urlsafe_b64encode(corpo).decode().rstrip('=')
    return {'nome': nome, 'rede': rede, 'loginNovo': not linha, 'codigo': codigo,
            'instalador': 'Instalar Jogos Retro (%s).exe' % ('NetBird' if rede == 'netbird' else 'Tailscale')}


def remover_amigo(nome):
    validar_nome(nome)
    feito = []
    antes = ler_linhas(LOGINS)
    depois = [l for l in antes if l.split(' ')[0] != nome]
    if len(depois) < len(antes):
        gravar_linhas(LOGINS, depois)
        gravar_linhas(HTPASSWD, [l for l in ler_linhas(HTPASSWD) if l.split(':')[0] != nome])
        feito.append('Login removido')
    prefixo = nome.lower() + '-'
    for p in netbird('GET', '/peers'):
        if p['name'].lower().startswith(prefixo):
            netbird('DELETE', '/peers/' + p['id'])
            feito.append('PC removido do NetBird: ' + p['name'])
    for k in netbird('GET', '/setup-keys'):
        if k['name'] == 'convite-' + nome and k.get('valid'):
            revogar_chave(k)
            feito.append('Convite cancelado')
    gravar_rede(nome, None)
    return feito


def listar_amigos():
    redes = ler_redes()
    peers = netbird('GET', '/peers')
    chaves = [k for k in netbird('GET', '/setup-keys') if k['name'].startswith('convite-')]
    lista = []
    for linha in ler_linhas(LOGINS):
        nome = linha.split(' ')[0]
        if nome == DONO:
            continue
        pcs = [p for p in peers if p['name'].lower().startswith(nome.lower() + '-')]
        pendente = next((k for k in chaves if k['name'] == 'convite-' + nome and k.get('valid')
                         and k.get('used_times', 0) == 0), None)
        lista.append({
            'nome': nome,
            'rede': redes.get(nome, ''),
            'online': any(p.get('connected') for p in pcs),
            'vistoEm': max((p.get('last_seen') or '' for p in pcs), default=''),
            'pcs': [p['name'] for p in pcs],
            'conviteVence': pendente.get('expires', '') if pendente else '',
        })
    return sorted(lista, key=lambda a: a['nome'].lower())


# ---------- jogos de PC ----------

def estado_jogos():
    if not os.path.isdir(JOGOS_PC):
        raise ValueError('O painel não enxerga a pasta do catálogo (falta o volume /jogos-pc).')
    estado = {}
    try:
        with open(os.path.join(JOGOS_PC, 'estado.json'), encoding='utf-8') as f:
            estado = json.load(f)
    except (FileNotFoundError, ValueError):
        pass
    estado['pedido'] = os.path.exists(os.path.join(JOGOS_PC, 'verificar'))
    estado['agora'] = time.time()
    return estado


def pedir_verificacao():
    estado_jogos()
    with open(os.path.join(JOGOS_PC, 'verificar'), 'w') as f:
        f.write(str(time.time()))
    return estado_jogos()


# ---------- downloads dos amigos ----------

def ler_historico():
    try:
        with open(HISTORICO, encoding='utf-8') as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return []


def numero(v):
    try:
        return max(0, int(v))
    except (TypeError, ValueError):
        return 0


def registrar_relato(amigo, r):
    # Chamado com trava_downloads. Fim (ok/erro/cancelado) sai dos ativos e entra no historico.
    jogo = str(r.get('jogo') or '').strip()[:200]
    tipo = r.get('tipo') if r.get('tipo') in ('rom', 'pc') else 'rom'
    estado = r.get('estado')
    if not jogo or estado not in ESTADOS:
        raise ValueError('Relato inválido.')
    agora = time.time()
    chave = (amigo, tipo, jogo)
    item = ativos.get(chave) or {'amigo': amigo, 'tipo': tipo, 'jogo': jogo, 'inicio': agora}
    item.update({'console': str(r.get('console') or '')[:20], 'estado': estado, 'baixado': numero(r.get('baixado')),
                 'total': numero(r.get('total')), 'velocidade': numero(r.get('velocidade')),
                 'msg': str(r.get('msg') or '')[:300], 'atualizado': agora})
    if estado not in FINS:
        ativos[chave] = item
        return
    ativos.pop(chave, None)
    hist = ler_historico()
    # O mesmo fim pode chegar duas vezes (o PC avisa por mais de um caminho).
    if hist and all(hist[0].get(k) == item[k] for k in ('amigo', 'tipo', 'jogo', 'estado')) and agora - hist[0].get('fim', 0) < 120:
        return
    hist.insert(0, dict(item, fim=agora))
    with open(HISTORICO + '.tmp', 'w', encoding='utf-8') as f:
        json.dump(hist[:HISTORICO_MAX], f, ensure_ascii=False)
    os.replace(HISTORICO + '.tmp', HISTORICO)


def estado_downloads():
    agora = time.time()
    with trava_downloads:
        # Sem noticia ha um dia: some da lista (o PC nunca mais voltou para esse jogo).
        for chave in [c for c, d in ativos.items() if agora - d['atualizado'] > 86400]:
            ativos.pop(chave)
        lista = [dict(d, parado=agora - d['atualizado'] > PARADO_SEG) for d in ativos.values()]
    return {'ativos': sorted(lista, key=lambda d: d['inicio']), 'historico': ler_historico()[:50], 'agora': agora}


# ---------- erros do programa dos amigos ----------

def ler_erros():
    try:
        with open(ERROS, encoding='utf-8') as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return []


def gravar_erros(lista):
    with open(ERROS + '.tmp', 'w', encoding='utf-8') as f:
        json.dump(lista[:ERROS_MAX], f, ensure_ascii=False)
    os.replace(ERROS + '.tmp', ERROS)


def id_erro(amigo, etapa, msg):
    return hashlib.sha1(('%s|%s|%s' % (amigo, etapa, msg)).encode(), usedforsecurity=False).hexdigest()[:12]


def registrar_erro(amigo, r):
    # Chamado com trava_downloads. A mesma falha de novo (ou por outro caminho) so conta mais uma vez.
    etapa = str(r.get('etapa') or '')
    if not re.fullmatch(r'[a-z0-9-]{1,20}', etapa):
        raise ValueError('Relato inválido.')
    msg = str(r.get('msg') or '').strip()[:300]
    agora = time.time()
    lista = ler_erros()
    ident = id_erro(amigo, etapa, msg)
    item = next((e for e in lista if e['id'] == ident), None)
    if item:
        lista.remove(item)
        if agora - item['ultima'] < 30:  # o mesmo aviso chegando pela rede local e pela VPN
            lista.insert(0, item)
            return
        item['vezes'] += 1
    else:
        item = {'id': ident, 'amigo': amigo, 'etapa': etapa, 'msg': msg, 'primeira': agora, 'vezes': 1}
    item.update({'ultima': agora, 'versao': numero(r.get('versao'))})
    lista.insert(0, item)
    gravar_erros(lista)


def estado_erros():
    with trava_downloads:
        return {'erros': ler_erros(), 'agora': time.time()}


def resolver_erro(ident):
    # Sem id: limpa tudo.
    with trava_downloads:
        lista = [e for e in ler_erros() if ident and e['id'] != ident]
        gravar_erros(lista)
    return estado_erros()


# ---------- servidores de jogo ----------

def estado_servidores():
    try:
        with open(SERVIDORES, encoding='utf-8') as f:
            s = json.load(f)
    except FileNotFoundError:
        raise ValueError('O monitor dos servidores ainda não rodou (container monitor-jogos).') from None
    except ValueError:
        raise ValueError('O monitor gravou um arquivo inválido; ele tenta de novo em segundos.') from None
    s['agora'] = time.time()
    s['pedidos'] = sorted(os.listdir(PEDIDOS)) if os.path.isdir(PEDIDOS) else []
    return s


def salas_publicas():
    # O que os amigos veem (plugin JogosPc, via nginx): so as salas no ar e quem esta nelas.
    try:
        servidores = estado_servidores().get('servidores', [])
    except ValueError:
        servidores = []
    return {'salas': [{'titulo': s.get('titulo', ''), 'jogadores': s.get('jogadores') or []}
                      for s in servidores if s.get('rodando') and s.get('nome') != 'ponte-vpn']}


def estado_atualizacoes():
    # So os amigos que tem acesso hoje (logins antigos e de teste ficam de fora).
    try:
        with open(ATUALIZACOES, encoding='utf-8') as f:
            a = json.load(f)
    except FileNotFoundError:
        raise ValueError('O monitor ainda não leu os registros do servidor de jogos.') from None
    except ValueError:
        raise ValueError('O monitor gravou um arquivo inválido; ele tenta de novo em segundos.') from None
    redes, usuarios = ler_redes(), a.get('usuarios', {})
    lista = []
    for linha in ler_linhas(LOGINS):
        nome = linha.split(' ')[0]
        if nome == DONO:
            continue
        u = usuarios.get(nome, {})
        lista.append({'nome': nome, 'rede': redes.get(nome, ''), 'versao': u.get('versao'),
                      'atualizou': u.get('atualizou'), 'verificou': u.get('verificou')})
    return {'publicada': a.get('publicada'), 'amigos': sorted(lista, key=lambda x: x['nome'].lower()), 'agora': time.time()}


def pedir_reinicio(nome):
    if nome not in [x.get('nome') for x in estado_servidores().get('servidores', [])]:
        raise ValueError('Servidor desconhecido.')
    os.makedirs(PEDIDOS, exist_ok=True)
    with open(os.path.join(PEDIDOS, nome), 'w') as f:
        f.write(str(time.time()))
    return estado_servidores()


# ---------- sessao ----------

def assinar(valor, segredo):
    return hmac.new(segredo.encode(), valor.encode(), hashlib.sha256).hexdigest()


def nova_sessao():
    validade = str(int(time.time()) + SESSAO_DIAS * 86400)
    return validade + '.' + assinar(validade, ler_config()['segredo'])


def sessao_valida(cookie):
    m = re.search(r'(?:^|;\s*)painel=(\d+)\.([0-9a-f]{64})', cookie or '')
    if not m or int(m.group(1)) < time.time():
        return False
    return hmac.compare_digest(m.group(2), assinar(m.group(1), ler_config()['segredo']))


def senha_certa(senha):
    c = ler_config()
    h = hashlib.pbkdf2_hmac('sha256', senha.encode(), bytes.fromhex(c['sal']), c['iteracoes']).hex()
    return hmac.compare_digest(h, c['hash'])


# ---------- HTTP ----------

TIPOS = {'.html': 'text/html; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
         '.webmanifest': 'application/manifest+json'}


class Painel(BaseHTTPRequestHandler):
    server_version = 'Painel'
    sys_version = ''
    timeout = 15  # conexao parada nao prende uma thread para sempre

    def log_message(self, formato, *args):
        print(time.strftime('%d/%m %H:%M:%S'), self.client_address[0], formato % args, flush=True)

    def responder(self, status, corpo, tipo='application/json; charset=utf-8', extras=None):
        if not isinstance(corpo, bytes):
            corpo = json.dumps(corpo, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', tipo)
        self.send_header('Content-Length', str(len(corpo)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        for k, v in (extras or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(corpo)

    def logado(self):
        return sessao_valida(self.headers.get('Cookie'))

    def do_GET(self):
        caminho = self.path.split('?')[0]
        if caminho == '/api/amigos':
            if not self.logado():
                return self.responder(401, {'erro': 'Entre de novo.'})
            try:
                return self.responder(200, {'amigos': listar_amigos(),
                                            'instaladores': sorted(n for n in os.listdir(INSTALADORES)
                                                                   if n.lower().endswith('.exe'))
                                            if os.path.isdir(INSTALADORES) else []})
            except Exception as e:
                return self.responder(502, {'erro': 'Falha ao falar com o NetBird: %s' % e})
        if caminho == '/api/jogos':
            if not self.logado():
                return self.responder(401, {'erro': 'Entre de novo.'})
            try:
                return self.responder(200, estado_jogos())
            except ValueError as e:
                return self.responder(500, {'erro': str(e)})
        estados = {'/api/downloads': estado_downloads, '/api/servidores': estado_servidores, '/api/atualizacoes': estado_atualizacoes,
                   '/api/erros': estado_erros}
        if caminho in estados:
            if not self.logado():
                return self.responder(401, {'erro': 'Entre de novo.'})
            try:
                return self.responder(200, estados[caminho]())
            except ValueError as e:
                return self.responder(503, {'erro': str(e)})
        if caminho == '/api/sessao':
            return self.responder(200 if self.logado() else 401, {})
        if caminho == '/salas':
            if not self.veio_do_nginx():
                return self.responder(403, {'erro': 'Não autorizado.'})
            return self.responder(200, salas_publicas())
        if caminho.startswith('/instaladores/'):
            if not self.logado():
                return self.responder(401, {'erro': 'Entre de novo.'})
            nome = urllib.parse.unquote(caminho[len('/instaladores/'):])
            arquivo = os.path.join(INSTALADORES, os.path.basename(nome))
            if os.path.basename(nome) != nome or not nome.lower().endswith('.exe') or not os.path.isfile(arquivo):
                return self.responder(404, {'erro': 'Não encontrado.'})
            with open(arquivo, 'rb') as f:
                dados = f.read()
            return self.responder(200, dados, 'application/octet-stream', {
                'Content-Disposition': "attachment; filename*=UTF-8''" + urllib.parse.quote(nome)})
        arquivos = {'/': 'index.html', '/icone.svg': 'icone.svg', '/manifest.webmanifest': 'manifest.webmanifest'}
        if caminho in arquivos:
            arquivo = os.path.join(SITE, arquivos[caminho])
            with open(arquivo, 'rb') as f:
                return self.responder(200, f.read(), TIPOS[os.path.splitext(arquivo)[1]])
        self.responder(404, {'erro': 'Não encontrado.'})

    def do_POST(self):
        # Pedidos de outro site nao passam (alem do cookie SameSite=Strict).
        origem = self.headers.get('Origin')
        if origem and origem.split('://', 1)[-1] != self.headers.get('Host'):
            return self.responder(403, {'erro': 'Origem não permitida.'})
        if 'application/json' not in (self.headers.get('Content-Type') or ''):
            return self.responder(415, {'erro': 'Use JSON.'})
        try:
            tamanho = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            return self.responder(400, {'erro': 'Pedido inválido.'})
        # Negativo viraria read(-1), que le ate a conexao fechar.
        if not 0 <= tamanho <= 10000:
            return self.responder(413, {'erro': 'Pedido grande demais.'})
        try:
            corpo = json.loads(self.rfile.read(tamanho) or b'{}')
        except ValueError:
            return self.responder(400, {'erro': 'Pedido inválido.'})

        caminho = self.path.split('?')[0]
        if caminho == '/relato':
            return self.relato(corpo)
        if caminho == '/api/entrar':
            return self.entrar(str(corpo.get('senha', '')))
        if caminho == '/api/sair':
            return self.responder(200, {}, extras={'Set-Cookie': 'painel=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict'})
        if not self.logado():
            return self.responder(401, {'erro': 'Entre de novo.'})
        try:
            with trava:
                if caminho == '/api/convite':
                    return self.responder(200, novo_convite(str(corpo.get('nome', '')).strip(), corpo.get('rede')))
                if caminho == '/api/revogar':
                    return self.responder(200, {'feito': remover_amigo(str(corpo.get('nome', '')))})
                if caminho == '/api/jogos/verificar':
                    return self.responder(200, pedir_verificacao())
                if caminho == '/api/servidores/reiniciar':
                    return self.responder(200, pedir_reinicio(str(corpo.get('nome', ''))))
                if caminho == '/api/erros/resolver':
                    return self.responder(200, resolver_erro(str(corpo.get('id') or '')))
        except ValueError as e:
            return self.responder(400, {'erro': str(e)})
        except urllib.error.HTTPError as e:
            return self.responder(502, {'erro': 'O NetBird recusou: %s' % e})
        except Exception as e:
            # Detalhe so no log do container; o navegador recebe a mensagem generica.
            print(time.strftime('%d/%m %H:%M:%S'), 'erro em', caminho, repr(e), flush=True)
            return self.responder(500, {'erro': 'Erro interno (veja o log do container).'})
        self.responder(404, {'erro': 'Não encontrado.'})

    def veio_do_nginx(self):
        # So o nginx do servidor de jogos conhece a chave; o amigo vem do login que ele conferiu.
        try:
            with open(CHAVE_RELATO, encoding='utf-8') as f:
                chave = f.read().strip()
        except FileNotFoundError:
            chave = ''
        return bool(chave) and hmac.compare_digest(self.headers.get('X-Relato-Chave', ''), chave)

    def relato(self, corpo):
        if not self.veio_do_nginx():
            return self.responder(403, {'erro': 'Não autorizado.'})
        amigo = self.headers.get('X-Amigo', '')
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,32}', amigo):
            return self.responder(400, {'erro': 'Amigo inválido.'})
        corpo = corpo if isinstance(corpo, dict) else {}
        try:
            with trava_downloads:
                (registrar_erro if corpo.get('tipo') == 'erro' else registrar_relato)(amigo, corpo)
        except ValueError as e:
            return self.responder(400, {'erro': str(e)})
        self.responder(200, {})

    def entrar(self, senha):
        # 5 erros seguidos do mesmo aparelho = 15 minutos bloqueado.
        # A tentativa conta ANTES de conferir a senha: pedidos em paralelo nao passam do limite.
        ip = self.client_address[0]
        agora = time.time()
        with trava_falhas:
            qtd, ate = falhas.get(ip, (0, 0))
            if ate > agora:
                return self.responder(429, {'erro': 'Muitas tentativas. Espere %d minutos.' % ((ate - agora) // 60 + 1)})
            if ip not in falhas and len(falhas) >= FALHAS_MAX_IPS:
                for velho in [i for i, (_, a) in falhas.items() if a <= agora]:
                    falhas.pop(velho)
            qtd += 1
            falhas[ip] = (0, agora + 900) if qtd >= 5 else (qtd, 0)
        time.sleep(0.5)
        with conferindo_senha:
            certa = senha_certa(senha)
        if not certa:
            print(time.strftime('%d/%m %H:%M:%S'), ip, 'senha errada', flush=True)
            return self.responder(401, {'erro': 'Senha errada.'})
        with trava_falhas:
            falhas.pop(ip, None)
        self.responder(200, {}, extras={'Set-Cookie': 'painel=%s; Max-Age=%d; Path=/; HttpOnly; SameSite=Strict'
                                                      % (nova_sessao(), SESSAO_DIAS * 86400)})


if __name__ == '__main__':
    import sys
    if '--definir-senha' in sys.argv:
        # Uso: echo SENHA | python painel.py --definir-senha  (troca a senha e derruba as sessoes abertas)
        senha = sys.stdin.readline().strip()
        sal = secrets.token_bytes(16)
        cfg = {'sal': sal.hex(), 'iteracoes': 300000, 'segredo': secrets.token_hex(32),
               'hash': hashlib.pbkdf2_hmac('sha256', senha.encode(), sal, 300000).hex()}
        with open(CONFIG, 'w', encoding='utf-8') as f:
            json.dump(cfg, f, indent=2)
        print('Senha definida.')
    else:
        print('Painel na porta', PORTA, flush=True)
        ThreadingHTTPServer(('0.0.0.0', PORTA), Painel).serve_forever()
