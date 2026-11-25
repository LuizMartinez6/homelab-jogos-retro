import hashlib
import json
import os
import re
import time

import pytest
from conftest import RAIZ, carregar


@pytest.fixture
def cat(tmp_path, monkeypatch):
    mod = carregar('servidor/jogos-pc/gerar-catalogo.py', 'gerar_catalogo')
    base = tmp_path / 'Game'
    base.mkdir()
    saida = tmp_path / 'instalador' / 'catalogo.json'
    saida.parent.mkdir()
    monkeypatch.setattr(mod, 'BASE', str(base))
    monkeypatch.setattr(mod, 'SAIDA', str(saida))
    monkeypatch.setattr(mod, 'CACHE', str(tmp_path / 'hashes.json'))
    monkeypatch.setattr(mod, 'MANUAIS', [])
    monkeypatch.setattr(mod, 'APELIDOS', {})
    mod.base = base
    mod.saida = saida
    return mod


def criar(base, rel, conteudo=b'x', idade=3600):
    caminho = base / rel
    caminho.parent.mkdir(parents=True, exist_ok=True)
    caminho.write_bytes(conteudo)
    antigo = time.time() - idade
    os.utime(caminho, (antigo, antigo))
    return caminho


def test_pasta_com_setup_vira_jogo_gog_com_dlc_depois(cat):
    criar(cat.base, 'Meu Jogo/setup_meu_jogo_1.0.exe', b'principal')
    criar(cat.base, 'Meu Jogo/setup_meu_jogo_1.0-1.bin', b'dados')
    criar(cat.base, 'Meu Jogo/DLC/setup_dlc.exe', b'dlc')

    [jogo] = cat.varrer({})

    assert jogo['id'] == 'meu-jogo'
    assert jogo['nome'] == 'Meu Jogo'
    assert jogo['tipo'] == 'gog'
    assert jogo['pasta'] == 'Meu Jogo'
    assert jogo['instaladores'] == ['setup_meu_jogo_1.0.exe', 'DLC/setup_dlc.exe']
    assert jogo['tamanho'] == len(b'principal') + len(b'dados') + len(b'dlc')
    por_caminho = {a['caminho']: a for a in jogo['arquivos']}
    assert por_caminho['DLC/setup_dlc.exe']['sha256'] == hashlib.sha256(b'dlc').hexdigest()
    assert por_caminho['setup_meu_jogo_1.0-1.bin']['tamanho'] == 5


def test_ignora_roms_no_topo_patches_e_backups(cat):
    criar(cat.base, 'Roms/psx/setup_nao_e_jogo.exe')
    criar(cat.base, 'Jogo/setup_jogo.exe')
    criar(cat.base, 'Jogo/patch_jogo_1.1.exe')
    criar(cat.base, 'Jogo/setup_jogo.exe.BACKUP_PRE_2024')

    jogos = cat.varrer({})

    assert [j['id'] for j in jogos] == ['jogo']
    assert [a['caminho'] for a in jogos[0]['arquivos']] == ['setup_jogo.exe']


def test_pasta_sem_setup_nao_vira_jogo_mas_subpasta_com_setup_vira(cat):
    criar(cat.base, 'Colecao/leia-me.txt')
    criar(cat.base, 'Colecao/Jogo 2 - A Volta/setup_jogo2.exe')

    [jogo] = cat.varrer({})

    assert jogo['pasta'] == 'Colecao/Jogo 2 - A Volta'
    assert jogo['id'] == 'jogo-2-a-volta'
    assert jogo['nome'] == 'Jogo 2 - A Volta'


def test_pasta_ainda_sendo_copiada_fica_para_a_proxima(cat):
    criar(cat.base, 'Antigo/setup_antigo.exe')
    criar(cat.base, 'Novo/setup_novo.exe', idade=60)

    assert [j['id'] for j in cat.varrer({})] == ['antigo']


def test_apelido_e_jogo_manual(cat, monkeypatch):
    monkeypatch.setattr(cat, 'APELIDOS', {'Pasta Feia': ('bonito', 'Nome Bonito')})
    monkeypatch.setattr(cat, 'MANUAIS', [('portatil', 'Jogo Portatil', 'Portatil', 'pasta', 'bin/jogo.exe')])
    criar(cat.base, 'Pasta Feia/setup_x.exe')
    criar(cat.base, 'Portatil/bin/jogo.exe')

    jogos = {j['id']: j for j in cat.varrer({})}

    assert jogos['bonito']['nome'] == 'Nome Bonito'
    assert jogos['portatil']['tipo'] == 'pasta'
    assert jogos['portatil']['executavel'] == 'bin/jogo.exe'
    assert 'instaladores' not in jogos['portatil']


def test_cache_evita_recalcular_hash(cat, monkeypatch):
    criar(cat.base, 'Jogo/setup_jogo.exe', b'abc')
    cache = {}
    cat.varrer(cache)

    chamadas = []
    monkeypatch.setattr(cat, 'sha256', lambda c: chamadas.append(c) or 'nao-devia')
    [jogo] = cat.varrer(cache)

    assert chamadas == []
    assert jogo['arquivos'][0]['sha256'] == hashlib.sha256(b'abc').hexdigest()


def test_rodar_grava_catalogo_e_nao_regrava_sem_mudanca(cat):
    criar(cat.base, 'Jogo/setup_jogo.exe')
    cat.rodar()
    primeiro = json.loads(cat.saida.read_text(encoding='utf-8'))
    assert primeiro['versao'] == 1
    assert [j['id'] for j in primeiro['jogos']] == ['jogo']
    assert os.path.exists(cat.CACHE)

    os.utime(cat.saida, (0, 0))
    cat.rodar()
    assert os.stat(cat.saida).st_mtime == 0

    criar(cat.base, 'Outro/setup_outro.exe')
    cat.rodar()
    assert len(json.loads(cat.saida.read_text(encoding='utf-8'))['jogos']) == 2


def campos_cs(classe):
    fonte = (RAIZ / 'ferramentas/plugin/JogosPc.cs').read_text(encoding='utf-8')
    corpo = re.search(r'public class %s\s*\{(.*?)\}' % classe, fonte, re.S).group(1)
    return set(re.findall(r'public [\w<>]+ (\w+);', corpo))


def test_contrato_com_o_plugin_do_playnite(cat):
    # O plugin (JogosPc.cs) desserializa o catalogo: todo campo gerado precisa existir la.
    criar(cat.base, 'Jogo/setup_jogo.exe')
    [jogo] = cat.varrer({})

    assert set(jogo) <= campos_cs('JogoCatalogo')
    assert set(jogo['arquivos'][0]) <= campos_cs('Arquivo')
