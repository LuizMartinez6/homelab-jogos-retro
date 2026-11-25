import json
import pathlib
import re
import struct
import zipfile
from http.server import BaseHTTPRequestHandler

import pytest
from conftest import carregar


@pytest.fixture
def monitor(tmp_path, monkeypatch):
    mod = carregar('servidor/monitor/monitor.py', 'monitor')
    monkeypatch.setattr(mod, 'DADOS', str(tmp_path))
    monkeypatch.setattr(mod, 'DONO_ARQUIVOS', (-1, -1))
    return mod


def bloco(fluxo, texto):
    dados = texto.encode()
    return bytes([fluxo, 0, 0, 0]) + struct.pack('>I', len(dados)) + dados


def test_separar_logs_do_docker_sem_tty_e_tira_cores(monitor):
    bruto = bloco(1, '\x1b[0;37m[ 1.0] Network <Info> Room is open.\n') + bloco(2, 'erro\n')
    assert monitor.separar_logs(bruto) == '[ 1.0] Network <Info> Room is open.\nerro\n'
    assert monitor.separar_logs(b'log com tty\n') == 'log com tty\n'


def test_jogadores_da_sala(monitor):
    log = ('[ 1] Network <Info> [100.64.0.22] Beto has joined.\n'
           '[ 2] Network <Info> [100.64.0.21] Carla (carla) has joined.\n'
           '[ 3] Network <Info> [100.64.0.22] Beto has left.\n'
           '[ 4] Network <Info> [100.64.0.23] Ana has joined.\n'
           '[ 5] Network <Info> [100.64.0.23] Ana has been kicked.\n'
           '[ 6] Network <Info> [100.64.0.22] Beto has joined.\n')
    assert monitor.jogadores_sala(log) == ['Carla (carla)', 'Beto']


def test_jogadores_do_psp(monitor):
    dados = {'games': [{'name': 'Monster Hunter Freedom Unite', 'groups': [
        {'name': 'G1', 'users': [{'name': 'Carla'}, {'name': 'Beto'}]}]}]}
    assert monitor.jogadores_psp(dados) == ['Carla (Monster Hunter Freedom Unite)', 'Beto (Monster Hunter Freedom Unite)']
    assert monitor.jogadores_psp({'games': []}) == []


def test_salas_do_relay_contam_so_depois_do_inicio(monitor):
    log = ('(13/11/2026 10:00:00) [INFO] Tunnel session created for: 1.1.1.1|1\n'
           '(13/11/2026 17:00:00) [INFO] Tunnel session created for: 1.1.1.1|2\n'
           '(13/11/2026 17:01:00) [INFO] Tunnel session created for: 1.1.1.1|3\n'
           '(13/11/2026 17:02:00) [INFO] Tunnel session closed for: 1.1.1.1|2\n')
    desde = monitor.iso_para_epoch('2026-11-13T12:00:00.123456789Z')
    assert monitor.sessoes_relay(log, desde) == 1
    assert monitor.sessoes_relay(log, None) == 2  # sem data de inicio conta o saldo do log inteiro
    assert monitor.iso_para_epoch('0001-01-01T00:00:00Z') is None


def test_portas_abertas_le_o_proc_net(monitor, tmp_path):
    proc = tmp_path / 'net'
    proc.mkdir()
    cab = '  sl  local_address rem_address   st\n'
    (proc / 'tcp').write_text(cab + '   0: 00000000:6AB0 00000000:0000 0A x\n   1: 00000000:1F90 0100007F:1234 01 x\n')
    (proc / 'udp').write_text(cab + '   0: 00000000:6148 00000000:0000 07 x\n')
    (proc / 'tcp6').write_text(cab + '   0: 00000000000000000000000000000000:7A69 00000000000000000000000000000000:0000 0A x\n')
    assert monitor.portas_abertas(str(proc)) == {('tcp', 27312), ('udp', 24904), ('tcp', 31337)}


LOG_JOGOS = '\n'.join([
    '100.64.0.22 - ana [13/Nov/2026:18:00:00 +0000] "GET /instalador/versao.json HTTP/1.1" 200 645 "-" "PS"',
    '100.64.0.22 - ana [13/Nov/2026:18:00:01 +0000] "GET /instalador/programa-22.zip HTTP/1.1" 200 170000 "-" "PS"',
    '100.64.0.22 - ana [14/Nov/2026:09:00:00 +0000] "GET /instalador/versao.json HTTP/1.1" 200 645 "-" "PS"',
    '100.64.0.22 - ana [14/Nov/2026:09:00:01 +0000] "GET /instalador/programa-23.zip HTTP/1.1" 200 170708 "-" "PS"',
    '100.64.0.23 - beto [13/Nov/2026:10:00:00 +0000] "GET /instalador/programa-23.zip HTTP/1.1" 401 0 "-" "PS"',
    '100.64.0.23 - beto [13/Nov/2026:10:00:05 +0000] "GET /instalador/versao.json HTTP/1.1" 200 645 "-" "PS"',
    '100.64.0.23 - - [13/Nov/2026:10:00:06 +0000] "GET /instalador/versao.json HTTP/1.1" 401 0 "-" "PS"',
    '100.64.0.23 - beto [13/Nov/2026:10:00:07 +0000] "GET /jogos/Celeste/setup.exe HTTP/1.1" 200 9 "-" "PS"',
    # Teste de login do painel ao gerar o convite: o amigo ainda nao abriu nada.
    '172.23.0.1 - caio [13/Nov/2026:20:09:21 +0000] "GET /instalador/versao.json HTTP/1.1" 200 645 "-" "Python-urllib/3.12"',
])


def test_atualizacoes_tiradas_do_log_do_nginx(monitor):
    u = monitor.ler_atualizacoes(LOG_JOGOS, {})
    quando = monitor.datetime.strptime('14/Nov/2026:09:00:01 +0000', '%d/%b/%Y:%H:%M:%S %z').timestamp()
    assert u['ana']['versao'] == 23 and u['ana']['atualizou'] == quando
    assert u['beto'] == {'verificou': monitor.datetime.strptime('13/Nov/2026:10:00:05 +0000', '%d/%b/%Y:%H:%M:%S %z').timestamp()}
    assert '-' not in u  # pedido sem login nao e de ninguem
    assert 'caio' not in u  # convite gerado nao e programa aberto
    # Ler de novo o mesmo trecho (o monitor sobrepoe 1 minuto) nao muda nada.
    assert monitor.ler_atualizacoes(LOG_JOGOS, json.loads(json.dumps(u))) == u


def test_atualizacoes_guardadas_com_a_versao_publicada(monitor, monkeypatch, tmp_path):
    (tmp_path / 'versao.json').write_text('{"versao": 23, "arquivo": "programa-23.zip"}', encoding='utf-8')
    monkeypatch.setattr(monitor, 'VERSAO_PUBLICADA', str(tmp_path / 'versao.json'))
    monkeypatch.setattr(monitor, 'docker', lambda metodo, caminho: (200, bloco(1, LOG_JOGOS + '\n')))
    monitor.atualizar_atualizacoes()
    salvo = json.loads((tmp_path / 'atualizacoes.json').read_text(encoding='utf-8'))
    assert salvo['publicada'] == 23 and salvo['usuarios']['ana']['versao'] == 23 and salvo['lido_ate'] > 0
    # Container recriado (log vazio): o que ja se sabia continua guardado.
    monkeypatch.setattr(monitor, 'docker', lambda metodo, caminho: (200, b''))
    monitor.atualizar_atualizacoes()
    assert json.loads((tmp_path / 'atualizacoes.json').read_text(encoding='utf-8'))['usuarios']['ana']['versao'] == 23


def test_atualizacoes_antigas_refazem_as_conferencias(monitor, monkeypatch, tmp_path):
    # Arquivo de antes do filtro do painel: o "verificou" do caio era o teste do convite.
    antigo = {'lido_ate': 9e9, 'usuarios': {'caio': {'verificou': 1}, 'ana': {'verificou': 1, 'versao': 21, 'atualizou': 1}}}
    (tmp_path / 'atualizacoes.json').write_text(json.dumps(antigo), encoding='utf-8')
    monkeypatch.setattr(monitor, 'VERSAO_PUBLICADA', str(tmp_path / 'nao-existe.json'))
    pedidos = []

    def docker(metodo, caminho):
        pedidos.append(caminho)
        return 200, bloco(1, LOG_JOGOS + '\n')

    monkeypatch.setattr(monitor, 'docker', docker)
    monitor.atualizar_atualizacoes()
    assert '&since=0' in pedidos[0]  # le o log desde o comeco
    u = json.loads((tmp_path / 'atualizacoes.json').read_text(encoding='utf-8'))['usuarios']
    assert u['caio'] == {}
    assert u['ana']['versao'] == 23 and u['ana']['verificou'] > 1
    # Na volta seguinte nao refaz.
    monitor.atualizar_atualizacoes()
    assert '&since=0' not in pedidos[1]


class DockerFalso:
    def __init__(self):
        self.pedidos = []
        self.containers = {}

    def __call__(self, metodo, caminho):
        self.pedidos.append((metodo, caminho))
        nome = caminho.split('/')[2].split('?')[0]
        if caminho.endswith('/json'):
            if nome not in self.containers:
                return 404, b'{}'
            rodando = self.containers[nome]
            return 200, json.dumps({'State': {'Running': rodando, 'Restarting': False, 'StartedAt': '2026-11-13T17:00:00.5Z'},
                                    'RestartCount': 2}).encode()
        if '/logs' in caminho:
            return 200, bloco(1, '[1.2.3.4] Beto has joined.\nponte ativa\n')
        if '/restart' in caminho:
            return 204, b''
        raise AssertionError(caminho)


def test_conferir_e_gravar(monitor, monkeypatch, tmp_path):
    d = DockerFalso()
    d.containers = {'psp-adhoc': True, 'switch-room': True, '3ds-room': False, 'rpcn': True, 'ponte-vpn': True}
    monkeypatch.setattr(monitor, 'docker', d)
    monkeypatch.setattr(monitor, 'portas_abertas', lambda: {('tcp', 27312), ('udp', 24872)})
    monkeypatch.setattr(monitor, 'ler_url_json', lambda url: {'games': []})
    eventos, anterior = [], {}
    lista = {s['nome']: s for s in monitor.conferir(eventos, anterior)}

    assert lista['psp-adhoc']['rodando'] and lista['psp-adhoc']['responde'] is True
    assert lista['switch-room']['jogadores'] == ['Beto']
    assert lista['3ds-room']['rodando'] is False and lista['3ds-room']['jogadores'] == []
    assert lista['rpcn']['responde'] is False  # rodando, mas a porta nao esta aberta
    assert lista['retroarch-relay']['detalhe'] == 'container não existe'
    assert lista['ponte-vpn']['responde'] is True
    assert lista['psp-adhoc']['reinicios'] == 2 and lista['psp-adhoc']['desde'] == monitor.iso_para_epoch('2026-11-13T17:00:00Z')
    assert eventos == []  # primeira volta nao gera aviso

    d.containers['psp-adhoc'] = False
    monitor.conferir(eventos, anterior)
    assert eventos[0]['texto'] == 'PSP (ad hoc) parou'

    monitor.gravar(list(lista.values()), eventos)
    salvo = json.loads((tmp_path / 'servidores.json').read_text(encoding='utf-8'))
    assert [s['nome'] for s in salvo['servidores']][:2] == ['psp-adhoc', 'switch-room']
    assert salvo['eventos'][0]['texto'] == 'PSP (ad hoc) parou'


def test_atende_so_pedidos_de_containers_da_lista(monitor, monkeypatch, tmp_path):
    d = DockerFalso()
    monkeypatch.setattr(monitor, 'docker', d)
    pedidos = tmp_path / 'pedidos'
    pedidos.mkdir()
    for nome in ('rpcn', 'romm', 'amigos'):
        (pedidos / nome).write_text('1')
    eventos = []
    monitor.atender_pedidos(eventos)
    assert d.pedidos == [('POST', '/containers/rpcn/restart?t=10')]
    assert list(pedidos.iterdir()) == []  # pedido estranho e apagado sem fazer nada
    assert eventos[0]['texto'] == 'PS3 (RPCN) reiniciado pelo painel'


# ---------- Recomps: releases no GitHub ----------

def rel(tag, *assets, draft=False, pre=False):
    return {'tag_name': tag, 'draft': draft, 'prerelease': pre, 'published_at': '2026-11-10T12:00:00Z',
            'assets': [{'name': n, 'digest': d} for n, d in assets]}


SHA = 'sha256:' + 'ab' * 32


def test_recomps_estados_e_regex_sem_diferenciar_maiusculas(monitor):
    jogo = {'id': 'novo', 'nome': 'Novo', 'repo': 'dono/novo', 'asset': r'-win64\.zip$', 'versao': 'v1'}

    def estado(releases, j=jogo, cache=None, vistas=None):
        c = cache if cache is not None else {'ultima': monitor.ultima_release(releases), 'conferido': 10}
        return monitor.estado_recomp(j, 'liberado', c, {} if vistas is None else vistas, 10)

    s = estado([rel('v1', ('JOGO-WIN64.ZIP', SHA), ('jogo-linux.zip', SHA))])
    assert s['estado'] == 'ok' and s['casam'] == ['JOGO-WIN64.ZIP'] and s['ultima']['tag'] == 'v1'
    assert estado([rel('v2', ('jogo-win64.zip', SHA))])['estado'] == 'versao-nova'
    assert estado([rel('v1', ('jogo-linux.zip', SHA))])['estado'] == 'regex-nenhum'
    assert estado([rel('v1', ('a-win64.zip', SHA), ('b-win64.zip', SHA))])['estado'] == 'regex-varios'
    assert estado([rel('v1', ('a-win64.zip', None))])['estado'] == 'sem-sha'
    # Rascunho nao conta; pre-release conta (como o recomp.ps1).
    s = estado([rel('v9', ('a-win64.zip', SHA), draft=True), rel('v1', ('a-win64.zip', SHA), pre=True)])
    assert s['estado'] == 'ok' and s['ultima']['prerelease'] is True
    assert estado([])['estado'] == 'sem-release'
    assert estado(None, cache={'erro': 'HTTP 500'})['estado'] == 'erro-github'
    assert estado([rel('v1', ('a-win64.zip', SHA))], j=dict(jogo, asset='('))['estado'] == 'regex-nenhum'
    # Sem "versao" no catalogo: a referencia e a 1a tag vista, com a data.
    vistas = {}
    s = estado([rel('v1', ('a-win64.zip', SHA))], j=dict(jogo, versao=None), vistas=vistas)
    assert s['estado'] == 'ok' and s['versao_ref'] == 'v1' and s['vista_em'] == 10
    assert estado([rel('v2', ('a-win64.zip', SHA))], j=dict(jogo, versao=None), vistas=vistas)['estado'] == 'versao-nova'


def test_regex_do_catalogo_compilam_no_python_com_ignorecase():
    cat = json.loads((pathlib.Path(__file__).resolve().parents[2] / 'instalador/arquivos/recomps.json').read_text(encoding='utf-8'))
    assert cat['jogos']
    for j in cat['jogos']:
        re.compile(j['asset'], re.IGNORECASE)


def publicar(tmp_path, monitor, monkeypatch, liberado, teste=None):
    # Pacotes e manifestos como os do /instalador do servidor de jogos (None: sem esse canal).
    for canal, catalogo in (('liberado', liberado), ('teste', teste)):
        if catalogo is None:
            continue
        manifesto = tmp_path / ('versao.json' if canal == 'liberado' else 'versao-teste.json')
        nome = catalogo.get('_arquivo') or 'programa-%d.zip' % (5 if canal == 'liberado' else 6)
        if PACOTE_OK.match(nome):
            with zipfile.ZipFile(tmp_path / nome, 'w') as z:
                z.writestr('recomp.ps1', 'x')
                if catalogo.get('jogos') is not None:
                    z.writestr('recomps.json', json.dumps({'jogos': catalogo['jogos']}))
        manifesto.write_text(json.dumps({'versao': 5, 'arquivo': nome}), encoding='utf-8')
    monkeypatch.setattr(monitor, 'VERSAO_PUBLICADA', str(tmp_path / 'versao.json'))
    monkeypatch.setattr(monitor, 'VERSAO_TESTE', str(tmp_path / 'versao-teste.json'))


PACOTE_OK = re.compile(r'^programa-\d+\.zip$')


@pytest.fixture
def github(servidor_http, monitor, monkeypatch):
    estado = {'pedidos': [], 'status': None, 'releases': [rel('v1', ('jogo-win64.zip', SHA))]}

    class GitHub(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            estado['pedidos'].append({'caminho': self.path, 'etag': self.headers.get('If-None-Match'), 'agente': self.headers.get('User-Agent')})
            if estado['status']:
                self.send_response(estado['status'])
                self.send_header('X-RateLimit-Reset', '9999999999')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            if self.headers.get('If-None-Match') == '"e1"':
                self.send_response(304)
                self.end_headers()
                return
            corpo = json.dumps(estado['releases']).encode()
            self.send_response(200)
            self.send_header('ETag', '"e1"')
            self.send_header('Content-Length', str(len(corpo)))
            self.end_headers()
            self.wfile.write(corpo)

    monkeypatch.setattr(monitor, 'GITHUB_API', 'http://127.0.0.1:%d' % servidor_http(GitHub))
    return estado


def test_recomps_304_reaproveita_e_403_nao_apaga(monitor, github, monkeypatch, tmp_path):
    jogo = {'id': 'novo', 'nome': 'Novo', 'repo': 'dono/novo', 'asset': r'-WIN64\.zip$', 'versao': 'v1'}
    publicar(tmp_path, monitor, monkeypatch, {'jogos': [jogo]})
    r = monitor.conferir_recomps(agora=1000)
    assert [x['estado'] for x in r['lista']] == ['ok'] and r['lista'][0]['canal'] == 'liberado' and r['avisos'] == []
    assert github['pedidos'][0]['caminho'] == '/repos/dono/novo/releases?per_page=10' and github['pedidos'][0]['etag'] is None
    assert github['pedidos'][0]['agente']

    # 304: reaproveita o que tinha (e conta como conferido agora).
    r = monitor.conferir_recomps(agora=2000)
    assert github['pedidos'][1]['etag'] == '"e1"'
    assert r['lista'][0]['estado'] == 'ok' and r['lista'][0]['casam'] == ['jogo-win64.zip'] and r['lista'][0]['conferido'] == 2000

    # 403 (limite): nao apaga o ultimo, avisa e espera o X-RateLimit-Reset sem consultar de novo.
    github['status'] = 403
    r = monitor.conferir_recomps(agora=3000)
    assert r['lista'][0]['estado'] == 'ok' and 'limitou' in r['lista'][0]['detalhe']
    salvo = json.loads((tmp_path / 'recomps-github.json').read_text(encoding='utf-8'))
    assert salvo['repos']['dono/novo']['ultima']['tag'] == 'v1'
    n = len(github['pedidos'])
    monitor.conferir_recomps(agora=4000)
    assert len(github['pedidos']) == n


def test_recomps_github_fora_sem_conferencia_anterior_e_erro(monitor, github, monkeypatch, tmp_path):
    publicar(tmp_path, monitor, monkeypatch, {'jogos': [{'id': 'novo', 'repo': 'dono/novo', 'asset': 'x'}]})
    github['status'] = 500
    assert monitor.conferir_recomps(agora=1000)['lista'][0]['estado'] == 'erro-github'


def test_recomps_zip_sem_catalogo_vira_aviso_e_canal_de_teste(monitor, github, monkeypatch, tmp_path):
    jogo = {'id': 'novo', 'repo': 'dono/novo', 'asset': r'-win64\.zip$', 'versao': 'v1'}
    publicar(tmp_path, monitor, monkeypatch, {'jogos': None}, {'jogos': [jogo]})
    r = monitor.conferir_recomps(agora=1000)
    assert r['avisos'] == ['liberado: programa-5.zip sem recomps.json']
    assert [(x['id'], x['canal']) for x in r['lista']] == [('novo', 'teste')]
    # Nome de pacote fora do formato: aviso, sem abrir nada.
    publicar(tmp_path, monitor, monkeypatch, {'jogos': [jogo], '_arquivo': '../fora.zip'})
    r = monitor.conferir_recomps(agora=2000)
    assert 'liberado: pacote com nome inesperado' in r['avisos']


def test_gravar_leva_os_recomps_ao_painel(monitor, tmp_path):
    monitor.gravar([], [], {'conferido': 1, 'lista': [{'id': 'x', 'estado': 'ok'}], 'avisos': []})
    assert json.loads((tmp_path / 'servidores.json').read_text(encoding='utf-8'))['recomps']['lista'][0]['id'] == 'x'
    monitor.gravar([], [])
    assert 'recomps' not in json.loads((tmp_path / 'servidores.json').read_text(encoding='utf-8'))
