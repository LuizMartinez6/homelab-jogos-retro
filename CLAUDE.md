# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Visão geral

Homelab de jogos retro: as ROMs ficam num servidor em casa (ZimaOS + Docker, com RomM, Syncthing, nginx `jogos-pc`, painel Amigos e site de Troféus). Os PCs com Windows (o do dono e os dos amigos) recebem um instalador de um clique que monta Playnite + emuladores portáteis ligados ao RomM. Código, comentários, nomes de funções e mensagens são em **português**, sem acentos nos scripts. Mantenha esse padrão. O README.md explica cada peça e a tabela "Problemas que tive" registra bugs já resolvidos. Leia antes de mudar o comportamento correspondente.

Processo do time, regras de negócio vigentes e incidentes: `docs/regras-de-negocio.md`. Leia antes de mudar comportamento e atualize ao fim de cada rodada.

Este repositório é a versão **publicada e sem segredos** do setup. Endereços como `192.168.0.10`, `100.64.0.10`, `usuario@...` e `meu-servidor.tailnet-exemplo.ts.net` são placeholders. A cópia de trabalho com valores reais fica fora do repo (ex.: `..\Servidor-Jogos-PC`).

## Lint e testes

```powershell
pwsh -File testes.ps1            # tudo: PSScriptAnalyzer + ruff + pytest + Pester (o mesmo que o GitHub Actions roda)
pwsh -File testes.ps1 -SoLint    # só o lint
python -m pytest testes/servidor/test_painel.py -k convite                                     # um teste Python
powershell -File testes\Executar-Pester.ps1 -Caminho testes\instalador\atualizador.Tests.ps1   # um arquivo Pester
powershell -File testes\Executar-Pester.ps1 -Nome '*Range*'                                    # Pester por nome
```

Dependências: `Install-Module Pester,PSScriptAnalyzer -Scope CurrentUser` e `pip install ruff pytest`. Configuração do lint em `PSScriptAnalyzerSettings.psd1` (com `PSUseCompatibleSyntax` para o 5.1) e `ruff.toml`.

- **O Pester roda no Windows PowerShell 5.1**, de propósito: é o PowerShell do PC dos amigos. `Executar-Pester.ps1` acha o Pester 5+ mesmo instalado só para o PowerShell 7.
- **Os testes rodam o código de verdade em processos separados.** Os workers e o `launcher.ps1` rodam como o plugin os chama, contra `testes\ajuda\servidor_http.py`, um servidor de teste com Basic auth, Range e quedas simuladas (`-CairApos`, `-IgnorarRange`, `-Status`). Playnite, `scp` e `ssh` são substituídos por um `.exe` falso (`New-ExeFalso`) que só registra a chamada. Nas ferramentas, `Copy-ScriptTrocado` troca o caminho do `scp` na cópia do script.
- Para testar funções de scripts que não podem ser carregados inteiros (abrem janela, instalam coisas), use `Get-Funcao arquivo.ps1 Nome`, que extrai pela AST. Para tabelas como `$Downloads`, use `Get-Atribuicao`. Os dois ficam em `testes\Ajuda.psm1`.
- **São pulados sem Playnite** (procura em `$env:PLAYNITE_DIR`, `C:\`, `D:\`, `E:\Playnite`): compilação do `JogosPc.cs`, perfis do `$PerfilPorSlug` contra as definições oficiais de emuladores, e o `games.db`. **São pulados sem Docker com containers Linux:** os testes do `nginx.conf` em container. Feche o Playnite para rodar os testes do launcher.
- Há testes de contrato entre partes que não se enxergam: painel ↔ `convite.ps1` (código `JR1-`), painel ↔ nginx (`{SSHA}`), `gerar-catalogo.py` ↔ classes do `JogosPc.cs`, `publicar-atualizacao.ps1` → `atualizador.ps1` (pacote assinado de ponta a ponta) e plugin ↔ workers (JSON do trabalho). Ao mudar um lado, rode os dois.

## Build e publicação

Nada de `npm`/projeto .NET: tudo é script, e o C# é compilado com o `csc.exe` do .NET Framework 4 que vem no Windows.

| Tarefa | Comando (rodar de `ferramentas\`) |
|---|---|
| Gerar o par de chaves RSA das atualizações | `pwsh -File gerar-chaves.ps1` (cole a pública em `atualizador.ps1`) |
| Publicar nova versão dos scripts do instalador | `pwsh -File publicar-atualizacao.ps1` |
| Publicar só para o canal de teste (`"canal": "teste"` no `launcher.json`) e depois liberar | `pwsh -File publicar-atualizacao.ps1 -Teste`, depois `-Liberar` |
| Desfazer uma versão ruim (republica o conteúdo da N com número novo) | `pwsh -File publicar-atualizacao.ps1 -Voltar N` |
| Gerar uma correção por jogo do Eden do dono (cole em `instalador\arquivos\correcoes.json`) | `pwsh -File correcao-eden.ps1 <TitleID> -Id nome-curto` |
| Gerar os instaladores NetBird/Tailscale (`.zip` + `.exe`) em `saida\` | `pwsh -File gerar-zips.ps1` |
| Compilar o plugin do Playnite e publicar tudo | `powershell -ExecutionPolicy Bypass -File publicar-plugin.ps1` (com o **Playnite fechado** e nenhum download em andamento) |
| Gerar o `RomMSemInstalador.dll` | `powershell -File plugin\gerar-romm-sem-instalador.ps1 <pasta com Mono.Cecil.dll>` |

`publicar-plugin.ps1` é o teste de ponta a ponta mais completo: compila `JogosPc.cs` → publica → aplica a atualização na instalação local (`C:\Jogos PC`) → regera os zips e confere o hash da DLL dentro deles → abre o Playnite em tela cheia por 60 s e mostra os `|ERROR|` do `playnite.log`/`extensions.log` daquela abertura.

Antes de cada commit ou push, rode a varredura de segredos de `docs/seguranca.md`:
```bash
git grep -nIiE "senha|password|token|apikey|BEGIN .*PRIVATE|<D>|<P>" -- . ':!docs/seguranca.md'
```

## Arquitetura

### Lado cliente (`instalador/`)
- Os `.bat` só desbloqueiam `arquivos\` (`Unblock-File`) e abrem um `.ps1` oculto com `-STA` (WPF).
- `instalador-ui.ps1` (WPF) coleta as opções e roda `setup.ps1` como processo separado. A UI lê a linha `ERRO: ...` que a função `Fail` do setup imprime.
- `setup.ps1` tem 6 passos. Ele baixa cada programa do site oficial e confere o SHA-256 (tabela `$Downloads`), instala os emuladores portáteis em `<Base>\Emuladores`, instala o Playnite e configura os mapeamentos de plataforma do RomM. Também copia `arquivos\*` (menos `config.json`) para `<Base>\programa\`, grava `<Base>\launcher.json` e cria o atalho "Jogos Retro", que chama `programa\launcher.ps1`.
- `catalogo.ps1`: consoles oferecidos → emulador e cores. `$PerfilPorSlug` em `setup.ps1`: `fs_slug` do RomM → emulador e perfil do Playnite. Ao adicionar um console, atualize os dois.
- `playnite-helper.psm1` é uma **extensão temporária de script do Playnite**. O setup a instala, abre o Playnite, e ela cadastra os emuladores pela API oficial e grava os IDs em `result.txt`, que o setup lê de volta.
- `launcher.ps1` roda a cada abertura do atalho. Ele (1) chama `Update-JogosRetro` (`atualizador.ps1`), (2) escolhe o endereço do RomM testando a porta na ordem LAN → NetBird → Tailscale, (3) completa os mapeamentos de plataforma que faltam, (4) instala ou atualiza a extensão `JogosPc` e troca o `RomM.dll` pelo `RomMSemInstalador.dll` (só se o hash for o da 0.9.0 esperada) e (5) chama `Set-Multiplayer` (`multiplayer.ps1`), que aponta PPSSPP, RetroArch, Eden, Azahar e RPCS3 para os servidores de multiplayer do homelab, e `Invoke-Correcoes` (`correcoes.ps1`), que aplica uma vez só cada ajuste por jogo de `correcoes.json` no `config\custom\<TitleID>.ini` do Eden (lista anotada em `correcoes-aplicadas.txt`). Depois abre o Playnite. Quem abre o Playnite por outro atalho não passa pelo launcher: o plugin `JogosPc` roda `programa\ao-abrir.ps1` no `OnApplicationStarted` (atualização e multiplayer; o que exige o Playnite fechado fica só no launcher). O launcher grava `launcher-abriu.txt` antes de abrir o Playnite, e o `ao-abrir.ps1` não faz nada se essa marca tem menos de 5 min.
- `multiplayer.ps1` nunca troca o que a pessoa escolheu: o apelido só é preenchido quando está vazio (ou é o padrão `PPSSPP`), e o RPCN só vira o servidor padrão sem conta criada (`NPID` vazio). Ele pula emulador aberto, porque o emulador sobrescreveria a config ao fechar. Ele reaproveita `Set-IniValue`/`Set-CfgValue` do `conquistas.ps1`; o `qt-config.ini` do Eden e do Azahar usa `chave=valor` sem espaços e precisa do par `chave\default=false`. DS: grava `melonDS DS.opt` (Wiimmfi + MAC `from-username`). GBA: `Set-PokemonGpsp` edita `emulators.db`/`games.db` (LiteDB do Playnite) e só roda com o Playnite fechado. Ela troca para gpSP apenas os Pokémon da 3ª geração e nunca move saves, só copia do mGBA.
- **Atualização automática:** busca `versao.json` (`versao`, `arquivo`, `sha256`, `assinatura`). A assinatura é RSA-SHA256 sobre `"versao|sha256"`, verificada com a chave pública embutida. Antes de trocar, `Test-PacoteAtualizacao` confere que todo `.ps1`/`.psm1` abre no PowerShell 5.1 e todo `.json` é válido (o `publicar-atualizacao.ps1` roda a mesma conferência antes de subir). Com `"canal": "teste"` no `launcher.json`, também lê `versao-teste.json` e fica com a maior. Depois troca a pasta `programa` de forma atômica, com rollback. O nome do pacote precisa casar com `^programa-\d+\.zip$`. Mudar esse formato quebra os clientes já instalados.
- **Avisos ao painel (`relato.ps1`):** os workers mandam o andamento dos downloads e o launcher/`ao-abrir.ps1` mandam as falhas de cada etapa (`Send-Erro`: `atualizacao`, `multiplayer`, `gpsp`) por `POST /relato` no servidor de jogos. O nginx confere o login e repassa ao painel com `X-Amigo`, e o painel separa por `tipo` (`erro` vai para `erros.json`, o resto para downloads). Avisar nunca pode derrubar o launcher: chame sempre por `Send-Falha`, que engole tudo.
- `instalacao.ps1` é o módulo compartilhado pelas ferramentas pós-instalação (`Find-Instalacao` pelo atalho, `Get-RommConexao`). Ele marca `IsInstalled` direto no `games.db` (LiteDB) do Playnite.

### Plugin do Playnite (`ferramentas/plugin/JogosPc.cs`)
É uma biblioteca "Jogos de PC" (GameLibrary, Id `JogosPc_c5b3a8d2-7f41-4e6a-9b1c-2d7e4a90f1a3`) em **C# 5** (csc do .NET Framework, ou seja, sem interpolação `$""`, `?.` ou `nameof`). Ela lê `/instalador/catalogo.json` do servidor `jogos-pc` e acha a instalação por `instalacao.txt` na pasta da extensão. O trabalho pesado fica em PowerShell: o plugin grava um JSON de trabalho e inicia `programa\jogos-pc-worker.ps1` (instaladores GOG) ou `programa\baixar-worker.ps1` (ROMs do RomM com retomada). O progresso volta por `progresso.json`. A fila roda **um download por vez**.

### Servidor (`servidor/`)
Cada pasta tem um `docker-compose.yml`. Os blocos `x-casaos` só servem ao painel do ZimaOS. Os serviços Python usam só a biblioteca padrão.
- `jogos-pc/gerar-catalogo.py`: toda pasta com `setup_*.exe` em `BASE` vira um jogo em `catalogo.json`, com SHA-256 em cache (`hashes.json`). Com `--servico`, repete a cada 15 min.
- `amigos/painel.py`: cria o login htpasswd por amigo, a setup key do NetBird e o código de convite `JR1-` (base64 de JSON, lido por `convite.ps1`).
- `trofeus/`: ranking do RetroAchievements.
- As ferramentas publicam via `scp`/`ssh` com `~\.ssh\id_servidor` em `/DATA/AppData/...`.

## Armadilhas (já custaram bugs)

- **O cliente roda no Windows PowerShell 5.1**, nunca no pwsh. Só as ferramentas do dono usam `pwsh`. Não use sintaxe exclusiva do PS 7 em `instalador/`.
- Arquivos lidos pelo Playnite precisam de **UTF-8 sem BOM**. Use `Out-Utf8` ou `[IO.File]::WriteAllText(..., New-Object UTF8Encoding $false)`, nunca `-Encoding UTF8` do PS 5.1.
- Use sempre `-LiteralPath` com caminhos de ROM: nomes com `[ ]` viram curinga.
- RetroArch usa `input_joypad_driver = sdl2` (DualSense não funciona com `dinput`).
- Os setups da GOG podem "crashar" depois de instalar com sucesso. O worker decide pelo `/LOG` (`Installation process succeeded`).
- RPCS3: crie a pasta e o `CurrentSettings.ini` antes de editar, dentro de `try/catch`.
- `.gitattributes`: `.ps1`/`.psm1`/`.bat`/`.cs`/`.txt` usam **CRLF**; `.py`/`.yml`/`.conf` usam **LF**. O teste `repo.Tests.ps1` confere que a cópia de trabalho segue essas regras. O `sed` do Git Bash troca CRLF por LF, então use a ferramenta de edição nesses arquivos. O `gerar-zips.ps1` normaliza o `LEIA-ME.txt` para CRLF e procura nele os trechos de `$TrocasTailscale`: ao editar o LEIA-ME, atualize os trechos (o teste avisa se algum sumir).
- Script `.ps1` com acento precisa de **BOM**, senão o 5.1 lê como ANSI. Sem acento, deixe sem BOM (há teste para isso).
- `config.json` vai dentro do zip/exe (senha do usuário Viewer do RomM, que é compartilhada). `gerar-zips.ps1` recusa um `config.json` que tenha `jogos.usuario`. O login individual vem só pelo convite.
- Nunca versionar: segredos (`config.json`, `atualizacao-privada.xml`, `*.htpasswd`, tokens), binários gerados (`saida/`, `*.zip`, `*.exe`, `*.dll`), ROMs, BIOS ou chaves. Veja `.gitignore` e `docs/seguranca.md`.
