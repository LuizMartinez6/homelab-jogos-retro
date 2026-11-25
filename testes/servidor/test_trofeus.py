import functools
import json
import urllib.error
import urllib.request

import pytest
from conftest import carregar


@pytest.fixture
def at(tmp_path, monkeypatch):
    mod = carregar('servidor/trofeus/atualizar.py', 'atualizar')
    site = tmp_path / 'site'
    monkeypatch.setattr(mod, 'AQUI', str(tmp_path))
    monkeypatch.setattr(mod, 'SITE', str(site))
    monkeypatch.setattr(mod, 'IMG', str(site / 'img'))
    (tmp_path / 'config.json').write_text(json.dumps({'apiKey': 'CHAVE', 'usuarios': ['Ana', 'SemEmail']}), encoding='utf-8')
    mod.site = site
    return mod


# Respostas no formato da API do RetroAchievements.
PERFIL = {'User': 'Ana', 'UserPic': '/UserPic/Ana.png', 'MemberSince': '2024-01-01', 'TotalPoints': '120',
          'TotalSoftcorePoints': 5, 'TotalTruePoints': None, 'RichPresenceMsg': 'Jogando', 'LastGameID': 10}
RESUMO = {
    'Rank': 42,
    'RecentlyPlayed': [
        {'GameID': '10', 'Title': 'Jogo A', 'ConsoleName': 'PlayStation', 'LastPlayed': '2026-11-10', 'ImageIcon': '/Images/a.png',
         'AchievementsTotal': 2},
        {'GameID': '20', 'Title': 'Jogo B', 'ConsoleName': 'SNES', 'LastPlayed': '2026-11-09', 'ImageIcon': '/Images/b.png',
         'AchievementsTotal': 3},
        {'GameID': '30', 'Title': 'Sem conquistas', 'ConsoleName': 'SNES', 'LastPlayed': '2026-11-08', 'ImageIcon': '/Images/c.png',
         'AchievementsTotal': 0},
    ],
    # A API manda dicionarios, nao listas.
    'RecentAchievements': {'10': {'1': {'GameID': '10', 'ID': '1', 'DateAwarded': '2026-11-01', 'HardcoreAchieved': '1'},
                                  '2': {'GameID': '10', 'ID': '2', 'DateAwarded': '2026-11-05', 'HardcoreAchieved': 0}}},
}
PROGRESSO = {'Results': [{'GameID': 10, 'NumAwarded': 2, 'NumAwardedHardcore': 1, 'MaxPossible': 2,
                          'HighestAwardKind': 'mastered', 'MostRecentAwardedDate': '2026-11-05'}]}


def jogo_info(gid):
    conquistas = {
        '2': {'ID': 2, 'Title': 'Segunda', 'Description': 'd2', 'Points': 10, 'BadgeName': 'b2', 'DisplayOrder': 1,
              'DateEarned': '2026-11-05'},
        '1': {'ID': 1, 'Title': 'Primeira', 'Description': 'd1', 'Points': 5, 'BadgeName': 'b1', 'DisplayOrder': 0,
              'DateEarned': '2026-11-01', 'DateEarnedHardcore': '2026-11-01 10:00', 'TrueRatio': 7, 'type': 'progression'},
    } if gid == 10 else {}
    return {'Title': 'Jogo %d' % gid, 'ConsoleName': 'X', 'ImageIcon': '/Images/%d.png' % gid, 'NumDistinctPlayers': '9',
            'Achievements': conquistas}


@pytest.fixture
def api(at, monkeypatch):
    pedidos = []

    def ra(chave, endpoint, **params):
        assert chave == 'CHAVE'
        pedidos.append((endpoint, params))
        if params.get('u') == 'SemEmail':
            raise urllib.error.HTTPError('u', 404, 'Not Found', {}, None)
        return {'API_GetUserProfile': PERFIL, 'API_GetUserSummary': RESUMO, 'API_GetUserCompletionProgress': PROGRESSO}.get(
            endpoint) or jogo_info(params['g'])

    monkeypatch.setattr(at, 'ra', ra)
    monkeypatch.setattr(at, 'imagem', lambda remoto, local: 'img/' + local)
    return pedidos


def test_atualizar_monta_dados_da_turma(at, api):
    assert at.atualizar() == '1 jogador(es), 2 jogo(s)'

    dados = json.loads((at.site / 'dados.json').read_text(encoding='utf-8'))
    assert not (at.site / 'dados.json.tmp').exists()
    [ana] = dados['usuarios']
    assert ana['nome'] == 'Ana' and ana['pontos'] == 120 and ana['pontosReais'] == 0 and ana['rank'] == 42
    assert ana['foto'] == 'img/user-Ana.png'
    # Jogo jogado sem conquista ganha entra; jogo sem conquistas nao.
    assert [(j['id'], j['ganhas'], j['total']) for j in ana['jogos']] == [(10, 2, 2), (20, 0, 3)]
    assert [r['conquista'] for r in ana['recentes']] == [2, 1]
    assert ana['recentes'][1]['hc'] is True and ana['recentes'][0]['hc'] is False
    assert len(ana['jogando']) == 3
    # Data hardcore tem preferencia.
    assert ana['ganhas'] == {'1': {'data': '2026-11-01 10:00', 'hc': True}, '2': {'data': '2026-11-05', 'hc': False}}
    jogo = dados['jogos']['10']
    assert [c['id'] for c in jogo['conquistas']] == [1, 2]
    assert jogo['conquistas'][0]['raridade'] == 7 and jogo['conquistas'][1]['raridade'] == 0
    assert jogo['conquistas'][0]['icone'] == 'img/badge-b1.png'
    assert dados['jogos']['20']['conquistas'] == []


def test_usuario_sem_email_confirmado_e_pulado(at, api, capsys):
    at.atualizar()
    assert 'SemEmail nao encontrado' in capsys.readouterr().out
    assert [p for e, p in api if p.get('u') == 'SemEmail' and e != 'API_GetUserProfile'] == []


def test_valores():
    at = carregar('servidor/trofeus/atualizar.py', 'atualizar')
    assert at.valores({'a': 1}) == [1]
    assert at.valores([2]) == [2]
    assert at.valores(None) == []


class Resposta:
    def __init__(self, dados):
        self.dados = dados

    def read(self):
        return self.dados

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_imagem_baixa_uma_vez_so(at, monkeypatch):
    (at.site / 'img').mkdir(parents=True)
    pedidos = []

    def urlopen(req, timeout=None):
        pedidos.append(req.full_url)
        return Resposta(b'PNG')

    monkeypatch.setattr(at.urllib.request, 'urlopen', urlopen)
    assert at.imagem('/Badge/x.png', 'badge-x.png') == 'img/badge-x.png'
    assert at.imagem('/Badge/x.png', 'badge-x.png') == 'img/badge-x.png'
    assert pedidos == ['https://media.retroachievements.org/Badge/x.png']
    assert (at.site / 'img' / 'badge-x.png').read_bytes() == b'PNG'


def test_imagem_que_falha_nao_derruba(at, monkeypatch):
    (at.site / 'img').mkdir(parents=True)

    def falha(req, timeout=None):
        raise OSError('sem internet')

    monkeypatch.setattr(at.urllib.request, 'urlopen', falha)
    assert at.imagem('/x.png', 'x.png') is None
    assert not (at.site / 'img' / 'x.png').exists()


def test_ra_monta_url_com_chave(at, monkeypatch):
    monkeypatch.setattr(at.time, 'sleep', lambda s: None)
    pedidos = []

    def urlopen(req, timeout=None):
        pedidos.append(req)
        return Resposta(b'{"ok": 1}')

    monkeypatch.setattr(at.urllib.request, 'urlopen', urlopen)
    assert at.ra('K', 'API_GetUserProfile', u='Ana B') == {'ok': 1}
    assert pedidos[0].full_url == 'https://retroachievements.org/API/API_GetUserProfile.php?u=Ana+B&y=K'
    assert pedidos[0].get_header('User-agent') == 'TrofeusDaTurma/1.0'


def test_site_cache_dados_curto_e_imagens_longo(tmp_path, servidor_http):
    srv = carregar('servidor/trofeus/servidor.py', 'servidor_trofeus')
    (tmp_path / 'img').mkdir()
    (tmp_path / 'img' / 'x.png').write_bytes(b'PNG')
    (tmp_path / 'dados.json').write_text('{}')
    (tmp_path / 'index.html').write_text('<html>')
    porta = servidor_http(functools.partial(srv.Pagina, directory=str(tmp_path)))

    def cache(caminho):
        with urllib.request.urlopen('http://127.0.0.1:%d%s' % (porta, caminho)) as r:
            return r.headers['Cache-Control']

    assert cache('/') == 'no-cache'
    assert cache('/dados.json?t=1') == 'no-cache'
    assert cache('/img/x.png') == 'max-age=86400'


def test_ciclo_sobrevive_a_falha(monkeypatch):
    srv = carregar('servidor/trofeus/servidor.py', 'servidor_trofeus')
    logs = []

    def falha():
        raise OSError('API fora')

    class Parar(Exception):
        pass

    def dormir(s):
        raise Parar

    monkeypatch.setattr(srv.atualizar, 'atualizar', falha)
    monkeypatch.setattr(srv, 'log', logs.append)
    monkeypatch.setattr(srv.time, 'sleep', dormir)
    with pytest.raises(Parar):
        srv.ciclo()
    assert logs == ["falha ao atualizar: OSError('API fora')"]
