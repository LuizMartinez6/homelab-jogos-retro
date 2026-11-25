"""Servidor HTTP para os testes do instalador (Pester): entrega os arquivos de --raiz
com Basic auth opcional, suporte a Range e falhas de rede simuladas. Escreve a porta
na primeira linha da saida e registra cada pedido em --log ("METODO caminho range"; num
POST, o corpo no lugar do range)."""

import argparse
import base64
import os
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

p = argparse.ArgumentParser()
p.add_argument('--raiz', required=True)
p.add_argument('--usuario')
p.add_argument('--senha')
p.add_argument('--log')
p.add_argument('--cair-apos', type=int, default=0, help='no primeiro download, fecha a conexao depois de N bytes')
p.add_argument('--ignorar-range', action='store_true', help='responde 200 com o arquivo inteiro mesmo pedindo Range')
p.add_argument('--status', type=int, default=0, help='responde sempre este status de erro')
args = p.parse_args()

trava = threading.Lock()
estado = {'caiu': False}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def registrar(self, extra=None):
        if args.log:
            with trava, open(args.log, 'a', encoding='utf-8') as f:
                f.write('%s %s %s\n' % (self.command, self.path, extra or self.headers.get('Range') or '-'))

    def autorizado(self):
        # Igual ao nginx: o "return 200" do /saude roda antes da checagem de login.
        if not args.usuario or self.path == '/saude':
            return True
        esperado = 'Basic ' + base64.b64encode(('%s:%s' % (args.usuario, args.senha)).encode()).decode()
        return self.headers.get('Authorization') == esperado

    def do_POST(self):
        # Como o /relato do nginx: registra o corpo (no lugar do Range) e responde {}.
        corpo = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8')
        self.registrar(corpo)
        if not self.autorizado():
            return self.erro(401)
        self.send_response(200)
        self.send_header('Content-Length', '2')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(b'{}')

    def erro(self, status):
        self.send_response(status)
        self.send_header('Content-Length', '0')
        if status == 401:
            self.send_header('WWW-Authenticate', 'Basic realm="teste"')
        self.end_headers()

    def do_GET(self):
        self.registrar()
        if not self.autorizado():
            return self.erro(401)
        if args.status:
            return self.erro(args.status)
        rel = urllib.parse.unquote(self.path.split('?')[0]).lstrip('/')
        arquivo = os.path.realpath(os.path.join(args.raiz, rel))
        # Pasta pedida com "/" no fim: entrega o _lista.json dela (como o autoindex json do nginx).
        if rel.endswith('/') and os.path.isdir(arquivo):
            arquivo = os.path.join(arquivo, '_lista.json')
            rel = '_lista.json'
        if not arquivo.startswith(os.path.realpath(args.raiz)) or not os.path.isfile(arquivo):
            return self.erro(404)
        with open(arquivo, 'rb') as f:
            dados = f.read()
        inicio = 0
        intervalo = self.headers.get('Range')
        if intervalo and not args.ignorar_range:
            inicio = int(intervalo.split('=')[1].split('-')[0])
            self.send_response(206)
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (inicio, len(dados) - 1, len(dados)))
        else:
            self.send_response(200)
        corpo = dados[inicio:]
        tipo = 'application/json' if rel.endswith('.json') or '/api/' in '/' + rel else 'application/octet-stream'
        self.send_header('Content-Type', tipo)
        self.send_header('Content-Length', str(len(corpo)))
        self.send_header('Connection', 'close')
        self.end_headers()
        with trava:
            cair = args.cair_apos and not estado['caiu'] and len(corpo) > args.cair_apos
            estado['caiu'] = estado['caiu'] or bool(cair)
        if cair:
            self.wfile.write(corpo[:args.cair_apos])
            self.wfile.flush()
            self.close_connection = True
            return
        self.wfile.write(corpo)


srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
