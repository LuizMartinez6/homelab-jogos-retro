import base64
import shutil
import subprocess
import time
import urllib.error
import urllib.request

import pytest
from conftest import RAIZ, carregar

COMPOSES = sorted(RAIZ.glob('servidor/*/docker-compose*.yml'))


def docker(*args, **kw):
    return subprocess.run(['docker', *args], capture_output=True, text=True, timeout=kw.pop('timeout', 120), **kw)


def docker_rodando():
    # Precisa rodar container Linux (no GitHub Actions o Docker do Windows so roda container Windows).
    if not shutil.which('docker'):
        return False
    r = docker('info', '--format', '{{.OSType}}', timeout=20)
    return r.returncode == 0 and r.stdout.strip() == 'linux'


@pytest.mark.parametrize('compose', COMPOSES, ids=lambda p: str(p.relative_to(RAIZ)))
def test_compose_valido(compose):
    if not shutil.which('docker'):
        pytest.skip('docker nao instalado')
    r = docker('compose', '-f', str(compose), 'config', '-q')
    assert r.returncode == 0, r.stderr


@pytest.mark.parametrize('compose', COMPOSES, ids=lambda p: str(p.relative_to(RAIZ)))
def test_compose_volta_sozinho_depois_de_reiniciar(compose):
    texto = compose.read_text(encoding='utf-8')
    servicos = texto.count('    image:')
    assert texto.count('    restart: unless-stopped') == servicos


@pytest.fixture(scope='module')
def nginx(tmp_path_factory):
    if not docker_rodando():
        pytest.skip('Docker parado ou sem containers Linux: abra o Docker Desktop para testar o nginx')
    pasta = tmp_path_factory.mktemp('nginx')
    (pasta / 'instalador').mkdir()
    (pasta / 'instalador' / 'versao.json').write_text('{"versao":1}')
    jogos = pasta / 'jogos'
    (jogos / 'Jogo').mkdir(parents=True)
    (jogos / 'Jogo' / 'setup_jogo.exe').write_bytes(b'0123456789' * 100)
    (jogos / 'solto.exe').write_bytes(b'x')
    (jogos / 'Roms' / 'psx').mkdir(parents=True)
    (jogos / 'Roms' / 'psx' / 'jogo.bin').write_bytes(b'x')
    # Senha no mesmo formato que o painel Amigos grava (contrato painel -> nginx).
    painel = carregar('servidor/amigos/painel.py', 'painel_nginx')
    (pasta / 'logins.htpasswd').write_text('ana:' + painel.ssha('certa') + '\n', newline='\n')
    conf = pasta / 'nginx.conf'
    conf.write_bytes((RAIZ / 'servidor/jogos-pc/nginx.conf').read_bytes().replace(b'\r\n', b'\n'))

    nome = 'teste-jogos-pc-%d' % time.time_ns()
    r = docker('run', '-d', '--rm', '--name', nome, '-p', '127.0.0.1::8095',
               '-v', '%s:/etc/nginx/nginx.conf:ro' % conf, '-v', '%s:/etc/nginx/logins.htpasswd:ro' % (pasta / 'logins.htpasswd'),
               '-v', '%s:/srv/instalador:ro' % (pasta / 'instalador'), '-v', '%s:/srv/jogos:ro' % jogos,
               _imagem(), timeout=300)
    assert r.returncode == 0, r.stderr
    try:
        porta = docker('port', nome, '8095').stdout.strip().rsplit(':', 1)[1]
        url = 'http://127.0.0.1:' + porta
        for _ in range(50):
            try:
                urllib.request.urlopen(url + '/saude', timeout=1)
                break
            except OSError:
                time.sleep(0.2)
        yield url, nome
    finally:
        docker('rm', '-f', nome)


def _imagem():
    texto = (RAIZ / 'servidor/jogos-pc/docker-compose.yml').read_text(encoding='utf-8')
    return next(l.split('image:')[1].strip() for l in texto.splitlines() if 'image: nginx' in l)


def pedir(url, caminho, senha=None, headers=None):
    h = dict(headers or {})
    if senha:
        h['Authorization'] = 'Basic ' + base64.b64encode(('ana:' + senha).encode()).decode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url + caminho, headers=h), timeout=10) as r:
            return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


def test_nginx_conf_valido(nginx):
    r = docker('exec', nginx[1], 'nginx', '-t')
    assert r.returncode == 0, r.stderr


def test_saude_sem_login(nginx):
    assert pedir(nginx[0], '/saude')[:2] == (200, b'ok\n')


def test_instalador_exige_login_e_nao_vai_para_cache(nginx):
    assert pedir(nginx[0], '/instalador/versao.json')[0] == 401
    assert pedir(nginx[0], '/instalador/versao.json', 'errada')[0] == 401
    status, corpo, h = pedir(nginx[0], '/instalador/versao.json', 'certa')
    assert (status, corpo) == (200, b'{"versao":1}')
    assert h['Cache-Control'] == 'no-store'


def test_jogos_so_dentro_de_pasta_e_sem_roms(nginx):
    assert pedir(nginx[0], '/jogos/Jogo/setup_jogo.exe', 'certa')[0] == 200
    assert pedir(nginx[0], '/jogos/solto.exe', 'certa')[0] == 403
    assert pedir(nginx[0], '/jogos/Roms/psx/jogo.bin', 'certa')[0] == 403
    assert pedir(nginx[0], '/qualquer/coisa', 'certa')[0] == 403


def test_jogos_retomam_com_range(nginx):
    status, corpo, h = pedir(nginx[0], '/jogos/Jogo/setup_jogo.exe', 'certa', {'Range': 'bytes=990-'})
    assert status == 206
    assert corpo == b'0123456789'
    assert h['Content-Range'] == 'bytes 990-999/1000'
