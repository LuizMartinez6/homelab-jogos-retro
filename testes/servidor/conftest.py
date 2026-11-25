# Ajuda comum dos testes do servidor: carrega os scripts pelo caminho (os nomes tem
# traco, entao nao da para importar normalmente) e sobe servidores HTTP de teste.

import importlib.util
import pathlib
import shutil
import subprocess
import sys
import threading
from http.server import ThreadingHTTPServer

import pytest

RAIZ = pathlib.Path(__file__).resolve().parents[2]


def carregar(rel, nome):
    caminho = RAIZ / rel
    sys.path.insert(0, str(caminho.parent))
    try:
        spec = importlib.util.spec_from_file_location(nome, caminho)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[nome] = mod
        spec.loader.exec_module(mod)
        return mod
    finally:
        sys.path.remove(str(caminho.parent))


@pytest.fixture
def servidor_http():
    """Sobe um ThreadingHTTPServer numa porta livre e devolve a URL base."""
    abertos = []

    def subir(handler):
        srv = ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        abertos.append(srv)
        return srv.server_address[1]

    yield subir
    for srv in abertos:
        srv.shutdown()
        srv.server_close()


def powershell_51(comando):
    """Roda um comando no Windows PowerShell 5.1, o mesmo do PC dos amigos."""
    exe = shutil.which('powershell.exe')
    if not exe:
        pytest.skip('Windows PowerShell 5.1 nao disponivel')
    r = subprocess.run([exe, '-NoProfile', '-NonInteractive', '-Command', comando],
                       capture_output=True, text=True, encoding='utf-8', timeout=120)
    assert r.returncode == 0, r.stderr
    return r.stdout
