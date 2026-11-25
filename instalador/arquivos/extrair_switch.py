r"""Extrai um jogo de Switch base em <saida>\exefs e <saida>\romfs, com o NSTool.

Uso: extrair_switch.py <nstool> <prod.keys> <base.nsp> <saida>
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

nstool, keys, base, saida = sys.argv[1:5]
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
saida = Path(saida)
work = saida / '_nca'


def run(args, env=None):
    print('>', ' '.join(str(a) for a in args[:3]), '...', flush=True)
    r = subprocess.run([str(a) for a in args], env=env, capture_output=True, text=True, errors='replace')  # noqa: S603 lista de argumentos, sem shell
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-2000:])
        sys.exit(f'nstool falhou ({r.returncode})')
    return r.stdout


def unpack(nsp, pasta, tipo='Program'):
    if not any(pasta.glob('*.nca')):
        pasta.mkdir(parents=True, exist_ok=True)
        run([nstool, '-k', keys, '-x', '/', str(pasta) + os.sep, nsp])
    tik = next(iter(sorted(pasta.glob('*.tik'))), None)
    program = None
    for nca in sorted(pasta.glob('*.nca')):
        if nca.name.endswith('.cnmt.nca'):
            continue
        info = run([nstool, '-k', keys, *(['--tik', tik] if tik else []), '-v', nca])
        if any(l.strip().replace(' ', '').startswith('ContentType:') and tipo in l for l in info.splitlines()):
            program = nca
    if not program:
        sys.exit(f'sem NCA {tipo} em {nsp}')
    print(tipo + ':', program.name, 'tik:', tik and tik.name, flush=True)
    return program, tik


bp, bt = unpack(base, work / 'base')

home = work / 'home'
(home / '.switch').mkdir(parents=True, exist_ok=True)
linhas = []
if bt:
    d = bt.read_bytes()
    linhas.append(f'{d[0x2A0:0x2B0].hex()} = {d[0x180:0x190].hex()}\n')
(home / '.switch' / 'title.keys').write_text(''.join(linhas), encoding='ascii')
env = {**os.environ, 'USERPROFILE': str(home), 'HOME': str(home)}

for p in ('exefs', 'romfs'):
    shutil.rmtree(saida / p, ignore_errors=True)
run([nstool, '-k', keys, *(['--tik', bt] if bt else []), '--part0', saida / 'exefs', bp], env=env)
run([nstool, '-k', keys, *(['--tik', bt] if bt else []), '--part1', saida / 'romfs', bp], env=env)

shutil.rmtree(work, ignore_errors=True)
n = sum(1 for _ in (saida / 'romfs').rglob('*') if _.is_file())
print('OK exefs:', sorted(x.name for x in (saida / 'exefs').iterdir()), 'romfs arquivos:', n)
