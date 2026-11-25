"""Serve a pasta site/ na porta 8090 e atualiza as conquistas a cada 30 minutos."""

import functools
import http.server
import os
import threading
import time
from datetime import datetime

import atualizar

PORTA = 8090
INTERVALO = 30 * 60


def log(msg):
    print(f'{datetime.now():%Y-%m-%d %H:%M:%S} {msg}', flush=True)


def ciclo():
    while True:
        try:
            log('atualizado: ' + atualizar.atualizar())
        except Exception as e:  # sem internet ou API fora: mantem os dados anteriores
            log(f'falha ao atualizar: {e!r}')
        time.sleep(INTERVALO)


class Pagina(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Dados mudam a cada atualizacao; imagens nunca mudam.
        self.send_header('Cache-Control', 'no-cache' if self.path.split('?')[0].endswith(('.json', '.html', '/')) else 'max-age=86400')
        super().end_headers()

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    os.makedirs(atualizar.IMG, exist_ok=True)
    threading.Thread(target=ciclo, daemon=True).start()
    handler = functools.partial(Pagina, directory=atualizar.SITE)
    log(f'servindo na porta {PORTA}')
    http.server.ThreadingHTTPServer(('0.0.0.0', PORTA), handler).serve_forever()
