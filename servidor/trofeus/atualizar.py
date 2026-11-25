"""Busca no RetroAchievements os perfis, jogos e conquistas da turma e grava
site/dados.json + site/img/* para a pagina "Troféus da Turma".
Amigos: acrescente o usuario deles em config.json ("usuarios")."""

import json
import os
import time
import urllib.parse
import urllib.request
from datetime import datetime

AQUI = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(AQUI, 'site')
IMG = os.path.join(SITE, 'img')
API = 'https://retroachievements.org/API'
MEDIA = 'https://media.retroachievements.org'


def ra(chave, endpoint, **params):
    time.sleep(0.3)  # gentil com o limite de requisicoes
    params['y'] = chave
    url = f'{API}/{endpoint}.php?{urllib.parse.urlencode(params)}'
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'TrofeusDaTurma/1.0'}), timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def imagem(remoto, local):
    """Baixa uma imagem do RetroAchievements uma vez so; devolve o caminho publicado."""
    destino = os.path.join(IMG, local)
    if not os.path.exists(destino):
        try:
            req = urllib.request.Request(MEDIA + remoto, headers={'User-Agent': 'TrofeusDaTurma/1.0'})
            with urllib.request.urlopen(req, timeout=30) as r:
                dados = r.read()
            with open(destino, 'wb') as f:
                f.write(dados)
        except Exception:
            return None
    return 'img/' + local


def valores(obj):
    return list(obj.values()) if isinstance(obj, dict) else list(obj or [])


def atualizar():
    with open(os.path.join(AQUI, 'config.json'), encoding='utf-8') as f:
        cfg = json.load(f)
    chave = cfg['apiKey']
    os.makedirs(IMG, exist_ok=True)

    usuarios, jogo_ids = [], set()
    for nome in cfg['usuarios']:
        # Conta nova so aparece na API depois de confirmar o e-mail: pula sem derrubar os outros.
        try:
            p = ra(chave, 'API_GetUserProfile', u=nome)
        except Exception:
            p = None
        if not isinstance(p, dict) or not p.get('User'):
            print(f'usuario {nome} nao encontrado no RetroAchievements (ainda); pulando', flush=True)
            continue
        s = ra(chave, 'API_GetUserSummary', u=nome, g=10, a=20)
        c = ra(chave, 'API_GetUserCompletionProgress', u=nome, c=500)
        jogos = []
        for j in c.get('Results') or []:
            jogo_ids.add(int(j['GameID']))
            jogos.append({'id': int(j['GameID']), 'ganhas': int(j['NumAwarded']), 'ganhasHc': int(j['NumAwardedHardcore']),
                          'total': int(j['MaxPossible']), 'premio': j.get('HighestAwardKind'), 'ultima': j.get('MostRecentAwardedDate')})
        # Jogos jogados recentemente que tem conquistas, mesmo sem nenhuma ganha ainda.
        for r in s.get('RecentlyPlayed') or []:
            gid = int(r['GameID'])
            if int(r.get('AchievementsTotal') or 0) > 0 and gid not in jogo_ids:
                jogo_ids.add(gid)
                jogos.append({'id': gid, 'ganhas': 0, 'ganhasHc': 0, 'total': int(r['AchievementsTotal']), 'premio': None, 'ultima': None})
        recentes = [{'jogo': int(a['GameID']), 'conquista': int(a['ID']), 'data': a['DateAwarded'], 'hc': bool(int(a.get('HardcoreAchieved') or 0))}
                    for jogo in valores(s.get('RecentAchievements')) for a in valores(jogo)]
        recentes.sort(key=lambda r: r['data'], reverse=True)
        usuarios.append({
            'nome': p['User'], 'foto': imagem(p['UserPic'], f"user-{p['User']}.png"), 'membroDesde': p.get('MemberSince'),
            'pontos': int(p.get('TotalPoints') or 0), 'pontosSoft': int(p.get('TotalSoftcorePoints') or 0),
            'pontosReais': int(p.get('TotalTruePoints') or 0), 'rank': s.get('Rank'), 'status': p.get('RichPresenceMsg'),
            'ultimoJogo': int(p.get('LastGameID') or 0),
            'jogando': [{'jogo': int(r['GameID']), 'titulo': r['Title'], 'console': r['ConsoleName'], 'quando': r['LastPlayed'],
                         'icone': imagem(r['ImageIcon'], f"jogo-{r['GameID']}.png")} for r in (s.get('RecentlyPlayed') or [])[:5]],
            'jogos': jogos, 'recentes': recentes, 'ganhas': {},
        })

    # Detalhes de cada jogo + o que cada um ganhou nele.
    jogos_info = {}
    for gid in sorted(jogo_ids):
        for u in usuarios:
            i = ra(chave, 'API_GetGameInfoAndUserProgress', u=u['nome'], g=gid, a=1)
            lista = sorted(valores(i.get('Achievements')), key=lambda a: (int(a.get('DisplayOrder') or 0), int(a['ID'])))
            if str(gid) not in jogos_info:
                jogos_info[str(gid)] = {
                    'titulo': i['Title'], 'console': i['ConsoleName'], 'icone': imagem(i['ImageIcon'], f'jogo-{gid}.png'),
                    'jogadores': int(i.get('NumDistinctPlayers') or 0),
                    'conquistas': [{'id': int(a['ID']), 'titulo': a['Title'], 'descricao': a['Description'], 'pontos': int(a['Points']),
                                    'raridade': int(a.get('TrueRatio') or 0), 'ganharam': int(a.get('NumAwarded') or 0),
                                    'ganharamHc': int(a.get('NumAwardedHardcore') or 0), 'tipo': a.get('type'),
                                    'icone': imagem(f"/Badge/{a['BadgeName']}.png", f"badge-{a['BadgeName']}.png")} for a in lista],
                }
            for a in lista:
                if a.get('DateEarned') or a.get('DateEarnedHardcore'):
                    u['ganhas'][str(a['ID'])] = {'data': a.get('DateEarnedHardcore') or a['DateEarned'], 'hc': bool(a.get('DateEarnedHardcore'))}

    dados = {'geradoEm': datetime.now().astimezone().isoformat(timespec='seconds'), 'usuarios': usuarios, 'jogos': jogos_info}
    tmp = os.path.join(SITE, 'dados.json.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(dados, f, ensure_ascii=False, separators=(',', ':'))
    os.replace(tmp, os.path.join(SITE, 'dados.json'))  # a pagina nunca le um arquivo pela metade
    return f'{len(usuarios)} jogador(es), {len(jogos_info)} jogo(s)'


if __name__ == '__main__':
    print(atualizar())
