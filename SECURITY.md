# Segurança

Este é um projeto pessoal (homelab de jogos retro para mim e alguns amigos), sem suporte
comercial. Mesmo assim, se você achar uma falha de segurança, quero saber.

## Como avisar

**Não abra uma issue pública.** Use o aviso privado do GitHub:
aba **Security** → **Report a vulnerability** neste repositório.

Diga o arquivo, o que dá para fazer com a falha e, se puder, como reproduzir.
Respondo assim que conseguir; não há prazo garantido.

## O que interessa

- o painel Amigos (`servidor/amigos/painel.py`) e o nginx do servidor de jogos;
- a atualização automática dos clientes (assinatura RSA do pacote, `atualizador.ps1`);
- os workers que baixam e instalam coisas no PC dos amigos (`instalador/arquivos/`);
- o plugin do Playnite (`ferramentas/plugin/`);
- qualquer segredo que tenha escapado para o repositório.

## Fora do escopo

- endereços como `192.168.0.10`, `100.64.0.10` e `meu-servidor.tailnet-exemplo.ts.net`: são exemplos;
- falhas do RomM, Playnite, NetBird, Tailscale ou dos emuladores: avise o projeto de cada um.

O checklist do que eu confiro antes de abrir o servidor está em [docs/seguranca.md](docs/seguranca.md).
