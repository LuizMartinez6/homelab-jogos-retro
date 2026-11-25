# 🔐 Segurança: o que conferir antes de abrir o servidor para amigos

Este checklist saiu de uma varredura feita no meu próprio setup antes de publicar este repositório. Cada item diz **o risco** e **o que fazer**.

## 1. Segredos fora do git

| Arquivo | O que tem | Onde deve ficar |
|---|---|---|
| `instalador/arquivos/config.json` | endereços do servidor + senha do usuário do RomM dos amigos | só no seu PC (`.gitignore`) |
| `ferramentas/atualizacao-privada.xml` | chave **privada** que assina as atualizações | só no seu PC, com backup offline |
| `servidor/trofeus/config.json` | Web API Key do RetroAchievements | só no servidor (`chmod 600`) |
| `/DATA/AppData/amigos/dados/` | logins dos amigos, token do NetBird, hash da senha do painel | só no servidor (`chmod 700`) |
| `logins.htpasswd` | hashes das senhas do nginx | só no servidor |

Antes de cada `git push`, rode:

```bash
git grep -nIiE "senha|password|token|apikey|BEGIN .*PRIVATE|<D>|<P>" -- . ':!docs/seguranca.md'
```

Na chave RSA em XML, `<D>` e `<P>` só aparecem na parte **privada**.

## 2. O que o instalador leva para o PC do amigo

- O `config.json` vai **dentro do zip/exe**. Ou seja, a senha do usuário do RomM dos amigos é **compartilhada** e qualquer pessoa com o instalador pode ler.
  - Deixe esse usuário com papel **Viewer** (só leitura) no RomM.
  - Se um instalador vazar, **troque a senha** desse usuário e gere os zips de novo.
  - O login do servidor de jogos (nginx) **não** vai no zip: vem no código de convite, que é **individual** e revogável.
- O código de convite (`JR1-…`) é base64 de um JSON, **não é criptografado**. Trate como senha: mande no privado.
- A setup key do NetBird no convite é de **uso único** e vale 7 dias. Um novo convite revoga o anterior que não foi usado.

## 3. Rede

- **Nenhuma porta aberta no roteador.** Acesso de fora é só por VPN.
- **NetBird**: desligue a política `Default` (todo mundo fala com todo mundo) e crie uma política que permita ao grupo dos amigos acessar **só as portas necessárias** (aqui: 1080 RomM, 8095 jogos, 8090 troféus).
- **Tailscale**: com o Tailscale rodando em container (sem `network_mode: host`), só as portas publicadas por `tailscale serve` ficam acessíveis pela tailnet. Se o Tailscale estiver no host, configure **ACLs**. O padrão do Tailscale libera tudo entre os dispositivos da sua tailnet, inclusive os dos amigos.
- **Revise as portas abertas na rede local** (`ss -tlnp`). Coisas para olhar com atenção:
  - **banco de dados** (ex.: 3306) exposto na LAN: o RomM não precisa dele aberto, remova o `ports:` do banco;
  - **terminal web** (ttyd, porta 7681 no ZimaOS): roda como root e só pede login. Desligue se não usa;
  - **Syncthing GUI** (8384): confirme que tem usuário e senha;
  - redes extras do sistema (o ZimaOS cria uma interface **ZeroTier** para o acesso remoto dele): confira quem mais está nessa rede.
- Variáveis como `NB_ALLOW_SERVER_SSH=true` / `NB_ENABLE_SSH_ROOT=true` no container do NetBird permitem SSH pela VPN. Desligue se não precisa.

## 4. Painel Amigos

O que já está feito em `servidor/amigos/painel.py`:

- senha guardada como **PBKDF2-SHA256, 300 mil iterações**;
- sessão em cookie **HMAC** com `HttpOnly` e `SameSite=Strict`;
- conferência de `Origin` nos POSTs (contra CSRF);
- **5 erros = 15 min bloqueado** por IP;
- nomes validados por regex (sem path traversal nem injeção no htpasswd);
- downloads só de `.exe` da pasta de instaladores, com `basename`.

Limitações conhecidas:

- roda em **HTTP** na LAN, então a senha trafega sem TLS dentro de casa. Para acesso remoto, coloque atrás de HTTPS (`tailscale serve`, Caddy...) e adicione `Secure` ao cookie;
- a tabela de tentativas erradas fica em memória e cresce sem limite (risco baixo numa rede fechada);
- não deixe o grupo dos amigos alcançar a porta do painel.

## 5. Atualizações automáticas

- O cliente só aceita pacote cuja assinatura **RSA-SHA256** de `versao|sha256` confere com a chave pública embutida. Ele também confere o SHA-256 do zip e a versão dentro do pacote.
- O nome do pacote é validado por regex (`^programa-\d+\.zip$`).
- Qualquer falha mantém a versão atual.
- **Se a chave privada vazar**, gere outra com `gerar-chaves.ps1`, mande a nova chave pública numa última atualização assinada com a chave antiga e apague a antiga.

## 6. Arquivos que não podem ser publicados

- ROMs, ISOs, BIOS, `prod.keys`, firmware, saves;
- DLLs de terceiros modificadas (ex.: o plugin do RomM com o instalador desligado). Publique o **script** que faz a modificação, não o binário;
- `games.db` do Playnite, músicas e vídeos baixados;
- zips e `.exe` gerados, porque eles contêm o `config.json`.

## 7. Repositório público e pipeline

O que roda sozinho no GitHub:

| Workflow | Quando | O que pega |
|---|---|---|
| `testes.yml` → `segredos` | todo push e PR | gitleaks no histórico inteiro (qualquer formato conhecido de segredo) |
| `testes.yml` → lint | todo push e PR | ruff com as regras `S` (Bandit) no Python; PSScriptAnalyzer no PowerShell |
| `seguranca.yml` → `codeql` | PR, push na `main` e toda segunda | CodeQL `security-extended` em Python, C# e nos próprios workflows (só em repo público) |
| `seguranca.yml` → `workflows` | PR, push na `main` e toda segunda | zizmor: injeção em `run:`, permissão demais, Action sem SHA |
| `dependabot.yml` | toda semana | versão nova das Actions (presas por SHA) e das imagens Docker |

Regras para os workflows:

- toda Action presa pelo **SHA do commit**, com a versão em comentário;
- `permissions: contents: read` no topo; permissão a mais só no job que precisa;
- `persist-credentials: false` no checkout;
- nunca `pull_request_target` nem `${{ github.event.* }}` direto dentro de `run:`;
- nenhum segredo nos workflows: a pipeline só lê e testa, nunca publica.

Configurações do GitHub (Settings), a fazer ao deixar público:

- **Code security**: ligar *Secret scanning*, *Push protection*, *Private vulnerability reporting*, *Dependabot alerts* e *Dependabot security updates*;
- **Branches → main**: exigir PR, exigir os checks `segredos`, `servidor-linux`, `testes` e `workflows` passando, bloquear *force push* e exclusão;
- **Actions → General**: *Workflow permissions* = somente leitura; não deixar o Actions aprovar PR; exigir aprovação para workflows de PR vindos de fork (*Require approval for all outside collaborators*).
