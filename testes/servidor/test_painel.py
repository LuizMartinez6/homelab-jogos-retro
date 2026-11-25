import base64
import hashlib
import http.client
import json
import secrets
import time
import urllib.error

import pytest
from conftest import RAIZ, carregar, powershell_51

SENHA = 'senha-do-painel'


class NetBirdFalso:
    """Imita a API do NetBird guardando o que o painel pediu."""

    def __init__(self):
        self.chaves = []
        self.peers = []
        self.grupos = [{'id': 'g-amigos', 'name': 'Friends'}, {'id': 'g-all', 'name': 'All'}]
        self.pedidos = []

    def __call__(self, metodo, caminho, corpo=None):
        self.pedidos.append((metodo, caminho, corpo))
        if (metodo, caminho) == ('GET', '/setup-keys'):
            return self.chaves
        if (metodo, caminho) == ('GET', '/groups'):
            return self.grupos
        if (metodo, caminho) == ('GET', '/peers'):
            return self.peers
        if (metodo, caminho) == ('POST', '/setup-keys'):
            self.chaves.append({'id': 'k%d' % len(self.chaves), 'name': corpo['name'], 'valid': True, 'used_times': 0})
            return {'key': 'CHAVE-NETBIRD-%d' % len(self.chaves)}
        if metodo == 'PUT' and caminho.startswith('/setup-keys/'):
            for k in self.chaves:
                if k['id'] == caminho.rsplit('/', 1)[1]:
                    k['valid'] = False
            return {}
        if metodo == 'DELETE' and caminho.startswith('/peers/'):
            self.peers = [p for p in self.peers if p['id'] != caminho.rsplit('/', 1)[1]]
            return None
        raise AssertionError('pedido inesperado ao NetBird: %s %s' % (metodo, caminho))


class Resposta:
    def read(self):
        return b'{}'


@pytest.fixture
def painel(tmp_path, monkeypatch):
    mod = carregar('servidor/amigos/painel.py', 'painel')
    dados = tmp_path / 'dados'
    dados.mkdir()
    (tmp_path / 'instaladores').mkdir()
    for nome, arquivo in [('LOGINS', 'logins.txt'), ('REDES', 'amigos.json'), ('TOKEN', 'netbird-token.txt'), ('CONFIG', 'painel.json'),
                          ('CHAVE_RELATO', 'relato-chave.txt'), ('HISTORICO', 'downloads.json'), ('SERVIDORES', 'servidores.json'),
                          ('PEDIDOS', 'pedidos'), ('ATUALIZACOES', 'atualizacoes.json'), ('ERROS', 'erros.json')]:
        monkeypatch.setattr(mod, nome, str(dados / arquivo))
    mod.ativos.clear()
    monkeypatch.setattr(mod, 'HTPASSWD', str(tmp_path / 'logins.htpasswd'))
    monkeypatch.setattr(mod, 'INSTALADORES', str(tmp_path / 'instaladores'))
    monkeypatch.setattr(mod, 'DONO', 'dono')
    # Mesmo formato do --definir-senha, com menos iteracoes para o teste ser rapido.
    sal = secrets.token_bytes(16)
    cfg = {'sal': sal.hex(), 'iteracoes': 1000, 'segredo': secrets.token_hex(32),
           'hash': hashlib.pbkdf2_hmac('sha256', SENHA.encode(), sal, 1000).hex()}
    (dados / 'painel.json').write_text(json.dumps(cfg), encoding='utf-8')

    mod.nb = NetBirdFalso()
    monkeypatch.setattr(mod, 'netbird', mod.nb)
    mod.logins_testados = []

    def urlopen(req, timeout=None):
        mod.logins_testados.append(req.headers['Authorization'])
        return Resposta()

    monkeypatch.setattr(mod.urllib.request, 'urlopen', urlopen)
    mod.dados = dados
    mod.falhas.clear()
    return mod


def decodificar(codigo):
    assert codigo.startswith('JR1-')
    b = codigo[4:]
    return json.loads(base64.urlsafe_b64decode(b + '=' * (-len(b) % 4)))


# ---------- regras ----------

@pytest.mark.parametrize('nome', ['ana', 'Joao_2', 'a.b-c', 'x' * 32])
def test_nomes_validos(painel, nome):
    painel.validar_nome(nome)


@pytest.mark.parametrize('nome', ['a', 'x' * 33, 'com espaco', '../etc', 'a:b', 'ana\nbeto:{SSHA}x', '', None, 'DONO'])
def test_nomes_invalidos_nao_entram_no_htpasswd(painel, nome):
    with pytest.raises(ValueError):
        painel.validar_nome(nome)


def test_ssha_no_formato_do_nginx(painel):
    h = painel.ssha('segredo')
    bruto = base64.b64decode(h[len('{SSHA}'):])
    digest, sal = bruto[:20], bruto[20:]
    assert h.startswith('{SSHA}')
    assert hashlib.sha1(b'segredo' + sal).digest() == digest
    assert painel.ssha('segredo') != h  # sal novo a cada vez


def test_gravar_linhas_usa_so_lf(painel, tmp_path):
    arq = tmp_path / 'x.txt'
    painel.gravar_linhas(str(arq), ['a', '', 'b'])
    assert arq.read_bytes() == b'a\nb\n'


# ---------- convites ----------

def test_convite_tailscale_cria_login_e_codigo(painel):
    r = painel.novo_convite('ana', 'tailscale')

    assert r['loginNovo'] is True
    assert r['instalador'] == 'Instalar Jogos Retro (Tailscale).exe'
    c = decodificar(r['codigo'])
    assert c['u'] == 'ana' and len(c['s']) == 32 and c['k'] == ''
    assert painel.ler_linhas(painel.LOGINS) == ['ana ' + c['s']]
    [linha] = painel.ler_linhas(painel.HTPASSWD)
    assert linha.startswith('ana:{SSHA}')
    assert painel.ler_redes() == {'ana': 'tailscale'}
    assert painel.logins_testados == ['Basic ' + base64.b64encode(('ana:' + c['s']).encode()).decode()]
    assert painel.nb.pedidos == []  # Tailscale nao mexe no NetBird


def test_convite_de_novo_reaproveita_o_login(painel):
    primeiro = decodificar(painel.novo_convite('ana', 'tailscale')['codigo'])
    r = painel.novo_convite('ana', 'netbird')

    assert r['loginNovo'] is False
    assert decodificar(r['codigo'])['s'] == primeiro['s']
    assert len(painel.ler_linhas(painel.LOGINS)) == 1
    assert len(painel.ler_linhas(painel.HTPASSWD)) == 1
    assert painel.ler_redes() == {'ana': 'netbird'}


def test_convite_netbird_cria_chave_unica_e_revoga_a_anterior(painel):
    c1 = decodificar(painel.novo_convite('ana', 'netbird')['codigo'])
    c2 = decodificar(painel.novo_convite('ana', 'netbird')['codigo'])

    assert c1['k'] == 'CHAVE-NETBIRD-1' and c2['k'] == 'CHAVE-NETBIRD-2'
    assert [k['valid'] for k in painel.nb.chaves] == [False, True]
    criadas = [corpo for m, c, corpo in painel.nb.pedidos if m == 'POST']
    assert criadas[0] == {'name': 'convite-ana', 'type': 'one-off', 'expires_in': 604800, 'auto_groups': ['g-amigos'],
                          'usage_limit': 1, 'ephemeral': False}


def test_convite_netbird_sem_grupo_friends(painel):
    painel.nb.grupos = [{'id': 'g-all', 'name': 'All'}]
    with pytest.raises(ValueError, match='Friends'):
        painel.novo_convite('ana', 'netbird')


def test_convite_recusa_rede_invalida_e_nome_com_outras_maiusculas(painel):
    with pytest.raises(ValueError, match='Rede'):
        painel.novo_convite('ana', 'zerotier')
    painel.novo_convite('Ana', 'tailscale')
    with pytest.raises(ValueError, match='maiúsculas'):
        painel.novo_convite('ana', 'tailscale')


def test_convite_falha_se_o_servidor_de_jogos_recusar_o_login(painel, monkeypatch):
    def recusa(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 401, 'Unauthorized', {}, None)

    monkeypatch.setattr(painel.urllib.request, 'urlopen', recusa)
    with pytest.raises(ValueError, match='não aceitou o login'):
        painel.novo_convite('ana', 'tailscale')


def test_remover_amigo_tira_tudo_so_dele(painel):
    painel.novo_convite('ana', 'netbird')
    painel.novo_convite('anabela', 'netbird')
    painel.nb.peers = [{'id': 'p1', 'name': 'ANA-pc'}, {'id': 'p2', 'name': 'anabela-pc'}]

    feito = painel.remover_amigo('ana')

    assert feito == ['Login removido', 'PC removido do NetBird: ANA-pc', 'Convite cancelado']
    assert [l.split(' ')[0] for l in painel.ler_linhas(painel.LOGINS)] == ['anabela']
    assert [l.split(':')[0] for l in painel.ler_linhas(painel.HTPASSWD)] == ['anabela']
    assert [p['name'] for p in painel.nb.peers] == ['anabela-pc']
    assert painel.ler_redes() == {'anabela': 'netbird'}
    assert {k['name']: k['valid'] for k in painel.nb.chaves} == {'convite-ana': False, 'convite-anabela': True}


def test_listar_amigos_esconde_o_dono_e_mostra_situacao(painel):
    painel.gravar_linhas(painel.LOGINS, ['dono x', 'beto y', 'ana z'])
    painel.gravar_rede('ana', 'netbird')
    painel.nb.peers = [{'id': 'p1', 'name': 'ana-pc', 'connected': True, 'last_seen': '2026-11-01'},
                       {'id': 'p2', 'name': 'ana-note', 'connected': False, 'last_seen': '2026-11-10'}]
    painel.nb.chaves = [{'id': 'k1', 'name': 'convite-beto', 'valid': True, 'used_times': 0, 'expires': '2026-11-20'}]

    lista = painel.listar_amigos()

    assert [a['nome'] for a in lista] == ['ana', 'beto']
    ana, beto = lista
    assert ana['online'] is True and ana['vistoEm'] == '2026-11-10' and ana['rede'] == 'netbird'
    assert ana['pcs'] == ['ana-pc', 'ana-note'] and ana['conviteVence'] == ''
    assert beto['online'] is False and beto['conviteVence'] == '2026-11-20'


# ---------- sessao e senha ----------

def test_sessao(painel, monkeypatch):
    cookie = 'painel=' + painel.nova_sessao()
    assert painel.sessao_valida(cookie)
    assert painel.sessao_valida('outro=1; ' + cookie)
    validade, assinatura = cookie[len('painel='):].split('.')
    assert not painel.sessao_valida('painel=%d.%s' % (int(validade) + 1, assinatura))
    assert not painel.sessao_valida('painel=' + validade + '.' + '0' * 64)
    assert not painel.sessao_valida(None)
    assert not painel.sessao_valida('painel=lixo')
    monkeypatch.setattr(painel.time, 'time', lambda: int(validade) + 1)
    assert not painel.sessao_valida(cookie)


def test_senha_certa(painel):
    assert painel.senha_certa(SENHA)
    assert not painel.senha_certa(SENHA + 'x')
    assert not painel.senha_certa('')


# ---------- contrato com o instalador ----------

def test_codigo_de_convite_e_lido_pelo_instalador(painel):
    # O convite.ps1 roda no Windows PowerShell 5.1 do amigo; colado no meio de uma mensagem e com quebra de linha.
    painel.novo_convite('ana', 'netbird')
    codigo = painel.novo_convite('ana', 'netbird')['codigo']
    c = decodificar(codigo)
    mensagem = 'Oi! Seu codigo:\r\n' + codigo[:30] + '\r\n' + codigo[30:] + '\r\nAbraco'
    script = RAIZ / 'instalador' / 'arquivos' / 'convite.ps1'
    saida = powershell_51(". '%s'; ConvertFrom-Convite '%s' | ConvertTo-Json -Compress" % (script, mensagem.replace("'", "''")))
    assert json.loads(saida) == c


# ---------- HTTP ----------

@pytest.fixture
def cliente(painel, servidor_http, monkeypatch, tmp_path):
    monkeypatch.setattr(painel.time, 'sleep', lambda s: None)
    porta = servidor_http(painel.Painel)
    estado = {'cookie': None}

    def pedir(metodo, caminho, corpo=None, headers=None, cru=None):
        con = http.client.HTTPConnection('127.0.0.1', porta, timeout=10)
        h = {'Host': '127.0.0.1:%d' % porta}
        if corpo is not None:
            h['Content-Type'] = 'application/json'
            corpo = json.dumps(corpo)
        if cru is not None:
            h['Content-Type'] = 'application/json'
            corpo = cru
        if estado['cookie']:
            h['Cookie'] = estado['cookie']
        h.update(headers or {})
        con.request(metodo, caminho, body=corpo, headers=h)
        r = con.getresponse()
        r.corpo = r.read()
        con.close()
        return r

    def entrar(senha=SENHA):
        r = pedir('POST', '/api/entrar', {'senha': senha})
        if r.status == 200:
            estado['cookie'] = r.getheader('Set-Cookie').split(';')[0]
        return r

    pedir.entrar = entrar
    return pedir


def test_http_pagina_com_cabecalhos_de_seguranca(cliente):
    r = cliente('GET', '/')
    assert r.status == 200
    assert r.getheader('Content-Type') == 'text/html; charset=utf-8'
    assert r.getheader('X-Frame-Options') == 'DENY'
    assert r.getheader('X-Content-Type-Options') == 'nosniff'
    assert r.getheader('Cache-Control') == 'no-store'
    assert cliente('GET', '/../painel.py').status == 404


def test_http_login(cliente):
    assert cliente('GET', '/api/sessao').status == 401
    assert cliente.entrar('errada').status == 401
    r = cliente.entrar()
    assert r.status == 200
    assert 'HttpOnly' in r.getheader('Set-Cookie') and 'SameSite=Strict' in r.getheader('Set-Cookie')
    assert cliente('GET', '/api/sessao').status == 200
    assert cliente('POST', '/api/sair', {}).getheader('Set-Cookie').startswith('painel=;')


def test_http_bloqueia_depois_de_5_erros(cliente):
    for _ in range(5):
        assert cliente.entrar('errada').status == 401
    r = cliente.entrar()
    assert r.status == 429
    assert 'Espere 15 minutos' in json.loads(r.corpo)['erro']


def test_http_recusa_outra_origem_e_corpo_sem_json(cliente):
    assert cliente('POST', '/api/entrar', {'senha': SENHA}, {'Origin': 'http://site-mau.com'}).status == 403
    assert cliente('POST', '/api/entrar', None, {'Content-Type': 'text/plain'}).status == 415
    assert cliente('POST', '/api/entrar', cru=b'{nao e json').status == 400


def test_http_api_exige_login(cliente):
    assert cliente('POST', '/api/convite', {'nome': 'ana', 'rede': 'tailscale'}).status == 401
    assert cliente('POST', '/api/revogar', {'nome': 'ana'}).status == 401
    assert cliente('GET', '/api/amigos').status == 401
    assert cliente('GET', '/instaladores/x.exe').status == 401


def test_http_convite_e_lista(cliente, painel):
    cliente.entrar()
    r = cliente('POST', '/api/convite', {'nome': '  ana ', 'rede': 'tailscale'})
    assert r.status == 200
    assert decodificar(json.loads(r.corpo)['codigo'])['u'] == 'ana'
    r = cliente('POST', '/api/convite', {'nome': 'a b', 'rede': 'tailscale'})
    assert r.status == 400
    r = cliente('GET', '/api/amigos')
    assert [a['nome'] for a in json.loads(r.corpo)['amigos']] == ['ana']


def test_http_download_de_instalador_so_exe_da_pasta(cliente, painel, tmp_path):
    (tmp_path / 'instaladores' / 'Instalar Jogos Retro (NetBird).exe').write_bytes(b'MZ')
    (tmp_path / 'segredo.exe').write_bytes(b'nao')
    (painel.dados / 'logins.txt').write_text('ana x', encoding='utf-8')
    cliente.entrar()

    r = cliente('GET', '/instaladores/Instalar%20Jogos%20Retro%20(NetBird).exe')
    assert r.status == 200 and r.corpo == b'MZ'
    assert r.getheader('Content-Disposition').startswith("attachment; filename*=UTF-8''Instalar%20Jogos")
    assert cliente('GET', '/instaladores/..%2Fsegredo.exe').status == 404
    assert cliente('GET', '/instaladores/..%2Fdados%2Flogins.txt').status == 404
    assert json.loads(cliente('GET', '/api/amigos').corpo)['instaladores'] == ['Instalar Jogos Retro (NetBird).exe']


def test_tempo_de_bloqueio_expira(painel, cliente, monkeypatch):
    for _ in range(5):
        cliente.entrar('errada')
    agora = time.time()
    monkeypatch.setattr(painel.time, 'time', lambda: agora + 901)
    assert cliente.entrar().status == 200


# ---------- downloads dos amigos (relato que o nginx repassa) ----------

CHAVE = 'c' * 64


def relatar(cliente, corpo, amigo='ana', chave=CHAVE):
    return cliente('POST', '/relato', corpo, {'X-Amigo': amigo, 'X-Relato-Chave': chave})


def test_relato_exige_a_chave_do_nginx(cliente, painel):
    corpo = {'tipo': 'rom', 'jogo': 'Zelda', 'estado': 'baixando'}
    assert relatar(cliente, corpo).status == 403  # painel sem chave configurada recusa tudo
    (painel.dados / 'relato-chave.txt').write_text(CHAVE + '\n', encoding='utf-8')
    assert relatar(cliente, corpo, chave='errada').status == 403
    assert relatar(cliente, corpo, chave='').status == 403
    assert relatar(cliente, corpo, amigo='../x').status == 400
    assert relatar(cliente, dict(corpo, estado='hackeando')).status == 400
    assert relatar(cliente, corpo).status == 200
    assert list(painel.ativos) == [('ana', 'rom', 'Zelda')]


def test_relato_andamento_e_historico(cliente, painel):
    (painel.dados / 'relato-chave.txt').write_text(CHAVE, encoding='utf-8')
    base = {'tipo': 'rom', 'jogo': 'Pokemon - Emerald Version (USA)', 'console': 'gba', 'total': 16777216}
    relatar(cliente, dict(base, estado='baixando', baixado=4194304, velocidade=1000000))
    relatar(cliente, dict(base, estado='baixando', baixado=8388608, velocidade=2000000), amigo='beto')
    cliente.entrar()
    d = json.loads(cliente('GET', '/api/downloads').corpo)
    assert [(x['amigo'], x['baixado'], x['parado']) for x in d['ativos']] == [('ana', 4194304, False), ('beto', 8388608, False)]
    assert d['historico'] == []

    relatar(cliente, dict(base, estado='ok', baixado=16777216))
    relatar(cliente, dict(base, estado='ok', baixado=16777216))  # mesmo fim por outro caminho
    d = json.loads(cliente('GET', '/api/downloads').corpo)
    assert [x['amigo'] for x in d['ativos']] == ['beto']
    assert [(x['amigo'], x['estado'], x['console']) for x in d['historico']] == [('ana', 'ok', 'gba')]


def test_relato_cancelado_e_fim(cliente, painel):
    # O plugin manda 'cancelado' quando o usuario cancela (o worker e morto e nunca avisa o fim).
    (painel.dados / 'relato-chave.txt').write_text(CHAVE, encoding='utf-8')
    base = {'tipo': 'pc', 'jogo': 'Hades', 'console': '', 'total': 1000}
    relatar(cliente, dict(base, estado='baixando', baixado=300))
    assert list(painel.ativos) == [('ana', 'pc', 'Hades')]
    assert relatar(cliente, dict(base, estado='cancelado', baixado=300)).status == 200
    assert relatar(cliente, dict(base, estado='cancelado', baixado=300)).status == 200  # por outro caminho
    assert painel.ativos == {}
    assert [(x['jogo'], x['estado'], x['baixado']) for x in painel.ler_historico()] == [('Hades', 'cancelado', 300)]


def test_download_sem_noticia_aparece_como_parado(painel, monkeypatch):
    with painel.trava_downloads:
        painel.registrar_relato('ana', {'tipo': 'pc', 'jogo': 'Celeste', 'estado': 'baixando'})
    agora = time.time()
    monkeypatch.setattr(painel.time, 'time', lambda: agora + painel.PARADO_SEG + 1)
    assert painel.estado_downloads()['ativos'][0]['parado'] is True
    monkeypatch.setattr(painel.time, 'time', lambda: agora + 86401)
    assert painel.estado_downloads()['ativos'] == []


def test_historico_guarda_no_maximo_o_limite(painel, monkeypatch):
    monkeypatch.setattr(painel, 'HISTORICO_MAX', 3)
    for i in range(5):
        with painel.trava_downloads:
            painel.registrar_relato('ana', {'tipo': 'rom', 'jogo': 'Jogo %d' % i, 'estado': 'erro', 'msg': 'caiu'})
    assert [x['jogo'] for x in painel.ler_historico()] == ['Jogo 4', 'Jogo 3', 'Jogo 2']


# ---------- servidores de jogo (estado gravado pelo monitor) ----------

def test_servidores_e_pedido_de_reinicio(cliente, painel):
    cliente.entrar()
    r = cliente('GET', '/api/servidores')
    assert r.status == 503 and 'monitor' in json.loads(r.corpo)['erro']

    estado = {'atualizado': time.time(), 'servidores': [{'nome': 'psp-adhoc', 'titulo': 'PSP', 'rodando': True}], 'eventos': []}
    (painel.dados / 'servidores.json').write_text(json.dumps(estado), encoding='utf-8')
    s = json.loads(cliente('GET', '/api/servidores').corpo)
    assert s['servidores'][0]['nome'] == 'psp-adhoc' and s['pedidos'] == []

    assert cliente('POST', '/api/servidores/reiniciar', {'nome': '../../etc'}).status == 400
    assert cliente('POST', '/api/servidores/reiniciar', {'nome': 'romm'}).status == 400  # so os da lista do monitor
    r = cliente('POST', '/api/servidores/reiniciar', {'nome': 'psp-adhoc'})
    assert r.status == 200 and json.loads(r.corpo)['pedidos'] == ['psp-adhoc']
    assert (painel.dados / 'pedidos' / 'psp-adhoc').exists()


def test_servidores_repassa_os_recomps_do_monitor(cliente, painel):
    cliente.entrar()
    recomps = {'conferido': 1.5, 'avisos': [],
               'lista': [{'id': 'novo', 'nome': 'Novo', 'canal': 'teste', 'estado': 'versao-nova', 'casam': ['a.zip']}]}
    estado = {'atualizado': time.time(), 'servidores': [], 'eventos': [], 'recomps': recomps}
    (painel.dados / 'servidores.json').write_text(json.dumps(estado), encoding='utf-8')
    assert json.loads(cliente('GET', '/api/servidores').corpo)['recomps'] == recomps
    # Monitor antigo (sem a chave): o painel continua respondendo.
    del estado['recomps']
    (painel.dados / 'servidores.json').write_text(json.dumps(estado), encoding='utf-8')
    r = cliente('GET', '/api/servidores')
    assert r.status == 200 and 'recomps' not in json.loads(r.corpo)


def test_atualizacoes_so_dos_amigos_de_hoje(cliente, painel):
    cliente.entrar()
    r = cliente('GET', '/api/atualizacoes')
    assert r.status == 503 and 'monitor' in json.loads(r.corpo)['erro']

    (painel.dados / 'logins.txt').write_text('dono x\nbeto y\nana z\ncarla w\n', encoding='utf-8')
    (painel.dados / 'amigos.json').write_text(json.dumps({'ana': 'netbird', 'beto': 'tailscale'}), encoding='utf-8')
    estado = {'publicada': 23, 'lido_ate': 1, 'usuarios': {
        'ana': {'versao': 23, 'atualizou': 100, 'verificou': 200},
        'beto': {'versao': 22, 'atualizou': 50, 'verificou': 60},
        'dono': {'versao': 23}, 'TesteVelho': {'versao': 5}}}
    (painel.dados / 'atualizacoes.json').write_text(json.dumps(estado), encoding='utf-8')
    a = json.loads(cliente('GET', '/api/atualizacoes').corpo)
    assert a['publicada'] == 23
    assert [(x['nome'], x['rede'], x['versao']) for x in a['amigos']] == [('ana', 'netbird', 23), ('beto', 'tailscale', 22), ('carla', '', None)]


def test_servidores_e_downloads_exigem_login(cliente):
    assert cliente('GET', '/api/servidores').status == 401
    assert cliente('GET', '/api/downloads').status == 401
    assert cliente('GET', '/api/atualizacoes').status == 401
    assert cliente('POST', '/api/servidores/reiniciar', {'nome': 'psp-adhoc'}).status == 401


# ---------- erros do programa dos amigos (mesmo /relato) ----------

def test_erro_do_programa_agrupa_repetidos_e_some_ao_resolver(cliente, painel, monkeypatch):
    (painel.dados / 'relato-chave.txt').write_text(CHAVE, encoding='utf-8')
    erro = {'tipo': 'erro', 'etapa': 'atualizacao', 'msg': 'Assinatura invalida.', 'versao': 25}
    assert relatar(cliente, dict(erro, etapa='../x')).status == 400
    assert relatar(cliente, erro).status == 200
    assert relatar(cliente, erro).status == 200  # mesmo aviso pelo outro caminho: nao conta
    agora = time.time()
    monkeypatch.setattr(painel.time, 'time', lambda: agora + 60)
    assert relatar(cliente, dict(erro, versao=26)).status == 200  # abriu de novo e falhou de novo
    assert relatar(cliente, dict(erro, etapa='multiplayer', msg='x'), amigo='beto').status == 200
    assert painel.ativos == {}  # nao vira download

    cliente.entrar()
    d = json.loads(cliente('GET', '/api/erros').corpo)
    assert [(x['amigo'], x['etapa'], x['vezes'], x['versao']) for x in d['erros']] == [('beto', 'multiplayer', 1, 25), ('ana', 'atualizacao', 2, 26)]

    d = json.loads(cliente('POST', '/api/erros/resolver', {'id': d['erros'][1]['id']}).corpo)
    assert [x['amigo'] for x in d['erros']] == ['beto']
    d = json.loads(cliente('POST', '/api/erros/resolver', {}).corpo)
    assert d['erros'] == []


def test_erros_guardam_no_maximo_o_limite(painel, monkeypatch):
    monkeypatch.setattr(painel, 'ERROS_MAX', 3)
    for i in range(5):
        with painel.trava_downloads:
            painel.registrar_erro('ana', {'etapa': 'multiplayer', 'msg': 'falha %d' % i})
    assert [x['msg'] for x in painel.ler_erros()] == ['falha 4', 'falha 3', 'falha 2']


def test_erros_exigem_login(cliente):
    assert cliente('GET', '/api/erros').status == 401
    assert cliente('POST', '/api/erros/resolver', {}).status == 401


def test_nginx_repassa_o_relato_com_os_cabecalhos_que_o_painel_le():
    # Contrato nginx <-> painel: mesmos nomes de cabecalho e o amigo vem do login conferido.
    conf = (RAIZ / 'servidor' / 'jogos-pc' / 'nginx.conf').read_text(encoding='utf-8')
    bloco = conf[conf.index('location = /relato'):]
    bloco = bloco[:bloco.index('}')]
    assert 'proxy_set_header X-Amigo $remote_user;' in bloco
    assert 'proxy_set_header X-Relato-Chave' in bloco
    assert 'proxy_pass http://' in bloco and ':8094/relato;' in bloco
    fonte = (RAIZ / 'servidor' / 'amigos' / 'painel.py').read_text(encoding='utf-8')
    assert "'X-Amigo'" in fonte and "'X-Relato-Chave'" in fonte


# ---------- salas de multiplayer para os amigos (plugin JogosPc, via nginx) ----------

def test_salas_so_com_a_chave_do_nginx_e_sem_detalhes_internos(cliente, painel):
    assert cliente('GET', '/salas').status == 403
    (painel.dados / 'relato-chave.txt').write_text(CHAVE, encoding='utf-8')
    assert cliente('GET', '/salas', headers={'X-Relato-Chave': 'errada'}).status == 403
    r = cliente('GET', '/salas', headers={'X-Relato-Chave': CHAVE})
    assert r.status == 200 and json.loads(r.corpo) == {'salas': []}  # monitor ainda nao rodou

    estado = {'atualizado': time.time(), 'eventos': [], 'servidores': [
        {'nome': 'switch-room', 'titulo': 'Switch', 'rodando': True, 'jogadores': ['Beto'], 'detalhe': '10.0.0.5', 'reinicios': 2},
        {'nome': '3ds-room', 'titulo': '3DS', 'rodando': False, 'jogadores': []},
        {'nome': 'ponte-vpn', 'titulo': 'Ponte', 'rodando': True, 'jogadores': []}]}
    (painel.dados / 'servidores.json').write_text(json.dumps(estado), encoding='utf-8')
    r = cliente('GET', '/salas', headers={'X-Relato-Chave': CHAVE})
    assert json.loads(r.corpo) == {'salas': [{'titulo': 'Switch', 'jogadores': ['Beto']}]}


def test_nginx_repassa_as_salas_com_a_chave():
    conf = (RAIZ / 'servidor' / 'jogos-pc' / 'nginx.conf').read_text(encoding='utf-8')
    bloco = conf[conf.index('location = /salas'):]
    bloco = bloco[:bloco.index('\n        }')]
    assert 'proxy_set_header X-Relato-Chave' in bloco and ':8094/salas;' in bloco
    assert 'limit_except GET' in bloco
