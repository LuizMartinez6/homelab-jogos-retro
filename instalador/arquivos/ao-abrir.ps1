# Roda quando o Playnite abre, chamado pelo plugin Jogos de PC (OnApplicationStarted), para
# quem abre o Playnite por outro atalho que nao o "Jogos Retro". Faz o que o launcher.ps1 faz
# e funciona com o Playnite aberto: atualiza o programa e liga o multiplayer.
# Trocar plugins e o gpSP dos Pokemon exige o Playnite fechado e fica so
# no launcher. Se foi o launcher que abriu o Playnite agora ha pouco, nao faz nada.

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Base = Split-Path -Parent $PSScriptRoot
$marca = Join-Path $Base 'launcher-abriu.txt'
if ((Test-Path -LiteralPath $marca) -and ((Get-Date) - (Get-Item -LiteralPath $marca).LastWriteTime).TotalMinutes -lt 5) { exit 0 }
$L = Get-Content (Join-Path $Base 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Depois de atualizar, os scripts carregados abaixo ja sao os da versao nova.
$erroAtualizacao = $null
try { . (Join-Path $Base 'programa\atualizador.ps1'); [void](Update-JogosRetro $Base) } catch { $erroAtualizacao = $_ }
# Falhas vao para a aba Erros do painel do dono (relato.ps1), como no launcher.
try { . (Join-Path $Base 'programa\relato.ps1') } catch { }
function Send-Falha($etapa, $erro) { try { [void](Send-Erro $Base $etapa $erro) } catch { } }
if ($erroAtualizacao) { Send-Falha 'atualizacao' $erroAtualizacao }
try { . (Join-Path $Base 'programa\multiplayer.ps1'); [void](Set-Multiplayer $Base $L) } catch { Send-Falha 'multiplayer' $_ }
try { . (Join-Path $Base 'programa\correcoes.ps1'); [void](Invoke-Correcoes $Base) } catch { Send-Falha 'correcoes' $_ }
