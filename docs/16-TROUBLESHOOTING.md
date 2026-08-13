# Troubleshooting

**Finalidade:** orientar diagnóstico seguro sem ampliar o dano ou ocultar falhas.

**Público-alvo:** operadores de plantão, administradores e suporte técnico.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Método

Leia primeiro `last-run.report`, journal e capacidade. Preserve o erro primário,
confirme estados de aplicações e evite comandos modificadores. A tabela usa:
`D` diagnóstico; `S` ação segura; `P` ação proibida; `E` escalonamento.

| Cenário e sintomas | Causa provável | D / S / P / E |
|---|---|---|
| Configuração inválida; código 2 antes do ciclo | chave, literal, modo, duplicata ou relação recusada | D: `borg-backup validate` e linha indicada. S: comparar com referência e corrigir por mudança aprovada. P: usar `source`, comentário inline ou relaxar parser. E: formato necessário não suportado. |
| Segredo ausente/inseguro | arquivo, owner ou `0600` divergente | D: `stat` sem ler conteúdo. S: restaurar arquivo pelo processo de custódia. P: imprimir/copiar para log. E: material perdido ou exposto. |
| Storage não montado | mount ausente ou path subjacente visível | D: `findmnt --target /srv/borg-storage`. S: manter operação bloqueada e corrigir mount pelo SO. P: criar sentinela no diretório pai. E: dispositivo ausente/erro. |
| UUID divergente | disco errado ou configuração desatualizada | D: `findmnt -o TARGET,UUID,FSTYPE`. S: identificar fisicamente e reconciliar as-built. P: aceitar qualquer UUID. E: identidade não inequívoca. |
| Sentinela inválida | conteúdo, modo ou owner divergente | D: `stat` e leitura das duas linhas não secretas. S: corrigir somente após confirmar mount. P: acrescentar chaves extras. E: possível storage errado. |
| Pouco espaço | crescimento, generations ou retenção insuficiente | D: `df -Pm` e relatórios. S: pausar novo ciclo e planejar capacidade. P: apagar arquivo Borg/previous manualmente. E: piso não pode ser recomposto. |
| Lock ocupado | execução legítima ou processo travado | D: `systemctl status`, `ps`, descritores. S: aguardar ou investigar processo. P: apagar lock Borg vivo. E: execução sem progresso e estados alterados. |
| Dump PostgreSQL falho | peer, socket, owner, cliente ou banco | D: journal sanitizado, `systemctl status postgresql`, consulta de socket. S: validar identidade/configuração. P: expor senha ou copiar data directory. E: restore/list também falha. |
| SQLite falho | unit escrevendo, cliente ausente ou integridade | D: estado da unit, path e log. S: preservar banco vivo e investigar numa cópia. P: sobrescrever banco vivo com parcial. E: `integrity_check` diferente de `ok`. |
| Service não para | unit incorreta, timeout ou processo resistente | D: `systemctl status <SYSTEMD_UNIT>`. S: interromper o ciclo e restaurar estados possíveis. P: matar infraestrutura protegida. E: parada exige ação não prevista. |
| Service não restaura | erro de start ou dependência | D: relatório `RESTORE`, status e journal da unit. S: priorizar recuperação do serviço e bloquear manutenção/réplica. P: mascarar backup como sucesso pleno. E: indisponibilidade persiste. |
| Nextcloud permanece em manutenção | restauração `occ` falhou | D: estado por `occ` sob usuário declarado e journal. S: restaurar ao estado registrado após corrigir causa. P: alterar banco diretamente. E: estado inicial desconhecido. |
| `create`/`info` falho | Borg rc não zero, fonte ou storage | D: evento resumido, capacidade, `borg info` autorizado. S: preservar último sucesso e corrigir causa. P: aceitar rc 1 como archive válido. E: repositório ilegível. |
| `prune`/`compact` falho | lock, I/O, Borg ou capacidade | D: `BACKUP`, `MAINTENANCE`, journal. S: preservar archive confirmado; bloquear réplica da rodada. P: remover segmentos manualmente. E: recorrência ou I/O. |
| Host key SSH divergente | rebuild legítimo ou ataque | D: comparar fingerprint por canal independente. S: manter réplica bloqueada até ratificação. P: usar `StrictHostKeyChecking=no`. E: identidade não comprovada. |
| Autenticação da réplica falha | chave, conta, `from=` ou modo | D: log SSH/receptor sem revelar chave. S: conferir chave pública e restrições. P: liberar shell/senha. E: requer mudança de conta/SSH. |
| Receiver recusa comando | argv, origem, storage ou protocolo divergente | D: evento e `status`. S: comparar emissor/receptor aprovados. P: aceitar comando livre. E: versões incompatíveis. |
| Incoming órfã | queda antes de abort ou token residual | D: `status`, token e nome exato. S: preservar e usar abort somente para execução correspondente após análise. P: `rm -rf` amplo. E: token/generation não conciliáveis. |
| `current`/`previous` ambíguos | promoção interrompida ou corrupção | D: `generation.meta`, estrutura e `status`. S: copiar generations e validar independentemente. P: promoção/remoção automática. E: nenhum estado inequivocamente válido. |
| Timer não dispara | desabilitado, calendário, load ou unit inválida | D: `list-timers`, `systemd-analyze calendar`, journal. S: corrigir unit e `daemon-reload`. P: criar cron concorrente. E: service manual também falha. |
| Timer dispara imediatamente | `Persistent=true` após ocorrência perdida | D: próxima/última ocorrência e boot. S: avaliar se esperado; pausar antes de mudança. P: matar ciclo sem restaurar estados. E: sobreposição inesperada. |
| Código 1 | warning de capacidade ou destino opcional | D: campos `CAPACITY` e replicação. S: tratar causa preservando artefato válido. P: ignorar porque systemd aceitou. E: warning recorrente. |
| Código 2 | falha crítica ou destino obrigatório | D: `PRIMARY_FAILURE`, `RESTORE`, manutenção e destino. S: estabilizar serviços e último sucesso. P: forçar etapas dependentes. E: restore/repositório/serviço afetado. |
| I/O, SMART ou kernel | mídia, cabo, controladora ou filesystem | D: `journalctl -k`, SMART e contadores em consulta. S: parar novas escritas e preservar cópia recuperável. P: `fsck`/reparo sem plano. E: qualquer erro recorrente/reset. |
| Suspeita de vazamento | segredo apareceu em arquivo, argv, log ou ticket | D: auditoria por padrões sem reproduzir valor. S: conter, preservar evidência e rotacionar sob plano. P: publicar hash/valor ou apagar evidência. E: resposta de segurança imediata. |

## Critério de encerramento

Um incidente só encerra quando a causa foi documentada, serviços voltaram ao
estado correto, `validate` passa, último artefato recuperável foi identificado e
uma nova execução/restore aplicável comprova o saneamento.
