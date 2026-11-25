#!/usr/bin/env python3
# Gera instalador/catalogo.json procurando sozinho os instaladores da GOG na pasta
# BASE: qualquer pasta com um setup_*.exe vira um jogo. Guarda os hashes em
# hashes.json e so recalcula o que mudou. Com --servico, repete a cada 15 minutos.

import hashlib
import json
import os
import re
import sys
import time

BASE = '/media/HD/Game'
AQUI = os.path.dirname(os.path.abspath(__file__))
SAIDA = os.path.join(AQUI, 'instalador', 'catalogo.json')
CACHE = os.path.join(AQUI, 'hashes.json')
INTERVALO = 15 * 60
# Pasta mexida ha menos tempo que isto ainda pode estar sendo copiada.
ESPERA_COPIA = 10 * 60

IGNORAR_NO_TOPO = {'Roms'}

# Jogos fora do padrao de instalador da GOG.
MANUAIS = [
    # ('id-do-jogo', 'Nome bonito', 'Pasta/relativa/a/BASE', 'pasta', 'Subpasta/Jogo.exe'),
]

# Nomes mais bonitos; o resto usa o nome da pasta.
APELIDOS = {
    # 'Pasta Do Jogo': ('id-do-jogo', 'Nome bonito'),
    # 'Colecao/Jogo 2': ('jogo-2', 'Jogo 2: Subtitulo'),
}


def ignorar(nome):
    return nome.startswith('patch_') or '.BACKUP_PRE_' in nome


def sha256(caminho):
    h = hashlib.sha256()
    with open(caminho, 'rb') as f:
        for bloco in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(bloco)
    return h.hexdigest()


def gravar_json(caminho, dados):
    tmp = caminho + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(dados, f, ensure_ascii=False, indent=1)
    os.replace(tmp, caminho)


def descobrir():
    jogos = list(MANUAIS)
    for atual, subpastas, nomes in os.walk(BASE):
        rel = os.path.relpath(atual, BASE).replace(os.sep, '/')
        if rel == '.':
            subpastas[:] = sorted(p for p in subpastas if p not in IGNORAR_NO_TOPO)
            continue
        subpastas.sort()
        if any(n.lower().startswith('setup_') and n.lower().endswith('.exe') for n in nomes):
            # Subpastas de um jogo (DLC) fazem parte dele.
            subpastas[:] = []
            jogo_id, nome = APELIDOS.get(rel, (re.sub(r'[^a-z0-9]+', '-', os.path.basename(rel).lower()).strip('-'), os.path.basename(rel)))
            jogos.append((jogo_id, nome, rel, 'gog', None))
    return jogos


def varrer(cache):
    catalogo = []
    for jogo_id, nome, pasta, tipo, exe in descobrir():
        raiz = os.path.join(BASE, pasta)
        if not os.path.isdir(raiz):
            print('FALTA:', raiz, flush=True)
            continue
        lista = []
        for atual, subpastas, nomes in os.walk(raiz):
            subpastas.sort()
            lista += [os.path.join(atual, n) for n in sorted(nomes) if not ignorar(n)]
        if time.time() - max(os.stat(c).st_mtime for c in lista) < ESPERA_COPIA:
            print('Ainda copiando, fica para a proxima:', pasta, flush=True)
            continue
        arquivos = []
        for caminho in lista:
            st = os.stat(caminho)
            chave = '%s|%d|%d' % (caminho, st.st_size, int(st.st_mtime))
            if chave not in cache:
                print(time.strftime('%H:%M:%S'), 'hash', caminho, flush=True)
                cache[chave] = sha256(caminho)
                gravar_json(CACHE, cache)
            arquivos.append({
                'caminho': os.path.relpath(caminho, raiz).replace(os.sep, '/'),
                'tamanho': st.st_size,
                'sha256': cache[chave],
            })
        item = {
            'id': jogo_id,
            'nome': nome,
            'tipo': tipo,
            'pasta': pasta,
            'tamanho': sum(a['tamanho'] for a in arquivos),
            'arquivos': arquivos,
        }
        if tipo == 'gog':
            # Jogo principal primeiro; depois os instaladores das subpastas (DLC).
            setups = [a['caminho'] for a in arquivos if os.path.basename(a['caminho']).lower().endswith('.exe')]
            item['instaladores'] = sorted(setups, key=lambda c: (c.count('/'), c))
        else:
            item['executavel'] = exe
        catalogo.append(item)
    return catalogo


def rodar():
    cache = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding='utf-8') as f:
            cache = json.load(f)
    catalogo = varrer(cache)
    atual = None
    if os.path.exists(SAIDA):
        with open(SAIDA, encoding='utf-8') as f:
            atual = json.load(f)
    if atual is None or atual['jogos'] != catalogo:
        gravar_json(SAIDA, {'versao': 1, 'gerado': time.strftime('%Y-%m-%dT%H:%M:%S'), 'jogos': catalogo})
        print('Catalogo atualizado:', len(catalogo), 'jogos', flush=True)


if __name__ == '__main__':
    if '--servico' in sys.argv:
        while True:
            try:
                rodar()
            except Exception as e:
                print('ERRO:', repr(e), flush=True)
            time.sleep(INTERVALO)
    else:
        rodar()
        print('PRONTO', flush=True)
