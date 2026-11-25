#!/bin/sh
# Publica no homelab so o painel Amigos (site/index.html) e o monitor (monitor.py). Roda NO homelab, com o seu
# usuario: o index.html e do dono do painel (uid 999) e troca sem root; o sudo so e usado no monitor (a pasta
# /DATA/AppData/monitor e do root). Nunca toca no painel.py, no nginx.conf, no relato-chave.txt nem nos
# docker-compose.yml. Substitui o antigo deploy-painel (que trocava tudo isso de uma vez).
# O painel.py NAO e publicado por este script (so conferido). O do repo e a versao sem segredos: se um dia for
# publicado, producao precisa de DONO=<seu login> e JOGOS_URL=<endereco real do servidor de jogos> no ambiente do
# container amigos (docker-compose.yml), senao o dono aparece na lista e o teste de login vai para o endereco errado.
#
# Antes de trocar qualquer coisa, confere o SHA-256 do painel.py, do index.html e do monitor.py que estao em producao
# contra o esperado.sha256 da pasta de envio. Se producao nao e o que voce espera (alguem mudou direto no servidor, ou
# a versao no ar e outra), para sem mexer em nada. Cada arquivo trocado ganha um .bak-<data> ao lado.
#
# Como usar (do PC, no pwsh, na pasta do repositorio):
#   1. Pasta de envio com os arquivos novos:
#        $p = "$env:TEMP\publicar-painel"; New-Item $p -ItemType Directory -Force | Out-Null
#        Copy-Item servidor\amigos\site\index.html, servidor\monitor\monitor.py, servidor\publicar-painel.sh $p
#   2. O esperado: os arquivos que ESTAO em producao hoje, byte a byte como foram enviados (painel.py e index.html da
#      copia de trabalho ..\Servidor-Jogos-PC\painel; monitor.py do ultimo commit, a versao publicada):
#        $w = '..\Servidor-Jogos-PC\painel'
#        $l = foreach ($a in @(@('painel.py', "$w\painel.py"), @('index.html', "$w\site\index.html"))) { "$((Get-FileHash $a[1]).Hash.ToLower())  $($a[0])" }
#        $l += (python -c "import hashlib,subprocess;print(hashlib.sha256(subprocess.check_output(['git','show','HEAD:servidor/monitor/monitor.py'])).hexdigest())") + '  monitor.py'
#        [IO.File]::WriteAllText("$p\esperado.sha256", ($l -join "`n") + "`n")
#      (se o monitor.py no ar for outro, o script para: confira com sha256sum /DATA/AppData/monitor/monitor.py)
#   3. Envie e rode (o sudo pede a senha no fim):
#        scp -r $p usuario@meu-servidor:/tmp/
#        ssh -t usuario@meu-servidor sh /tmp/publicar-painel/publicar-painel.sh
#   4. Painel conferido: copie o index.html novo para ..\Servidor-Jogos-PC\painel\site\ (o esperado da proxima vez).
#   Para voltar: cp -p <arquivo>.bak-<data> <arquivo> (e, no monitor, sudo docker restart monitor-jogos).
set -eu
S=$(cd "$(dirname "$0")" && pwd)
A=/DATA/AppData/amigos
M=/DATA/AppData/monitor
T=$(date +%Y-%m-%d-%H%M%S)

for f in index.html monitor.py esperado.sha256; do
    [ -f "$S/$f" ] || { echo "ABORTADO: falta $S/$f"; exit 1; }
done

echo "== conferindo o que esta em producao"
esperado() { awk -v n="$1" '$2 == n { print $1 }' "$S/esperado.sha256"; }
for par in "painel.py:$A/painel.py" "index.html:$A/site/index.html" "monitor.py:$M/monitor.py"; do
    nome=${par%%:*}
    arq=${par#*:}
    e=$(esperado "$nome")
    a=$(sha256sum "$arq" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$e" ] || [ "$e" != "$a" ]; then
        echo "ABORTADO: $arq em producao nao e o esperado; nada foi trocado"
        echo "  esperado: ${e:-(nenhum no esperado.sha256)}"
        echo "  producao: ${a:-(arquivo nao existe)}"
        exit 1
    fi
done
[ -w "$A/site" ] || { echo "ABORTADO: sem permissao em $A/site (rode com o usuario dono do painel, uid 999); nada foi trocado"; exit 1; }
echo "ok: producao e a esperada"

echo "== painel (so o index.html; o painel le o arquivo a cada pedido, sem reiniciar)"
cp -p "$A/site/index.html" "$A/site/index.html.bak-$T"
cp "$S/index.html" "$A/site/index.html.novo"
chmod 644 "$A/site/index.html.novo"
mv "$A/site/index.html.novo" "$A/site/index.html"
echo "index.html trocado (backup: $A/site/index.html.bak-$T)"

echo "== monitor (sudo)"
sudo cp -p "$M/monitor.py" "$M/monitor.py.bak-$T"
sudo install -m 644 "$S/monitor.py" "$M/monitor.py.novo"
sudo mv "$M/monitor.py.novo" "$M/monitor.py"
sudo docker restart monitor-jogos >/dev/null
echo "monitor.py trocado e monitor-jogos reiniciado (backup: $M/monitor.py.bak-$T)"

echo "== verificacao (20 s)"
sleep 20
sudo docker ps --filter name=monitor-jogos --format '{{.Names}} | {{.Status}}'
sudo docker logs --tail 5 monitor-jogos 2>&1 || true
python3 -c "import json; d = json.load(open('$A/dados/servidores.json')); r = d.get('recomps') or {}; print('recomps no servidores.json:', len(r.get('lista') or []), 'avisos:', r.get('avisos'))" 2>&1 || true
case "$S" in /tmp/publicar-painel) rm -rf "$S" ;; esac
