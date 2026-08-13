# Checklist de validação pós-deploy

**Finalidade:** comprovar que uma nova instalação está apta antes do agendamento automático.

**Público-alvo:** implantadores, revisores independentes e responsáveis pelo aceite.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Uso

Preencha a coluna de evidência com path ou ID sanitizado e marque `PASS` ou
`FAIL`. Um `FAIL` impede avanço ao gate dependente. Comandos destrutivos não
fazem parte deste checklist pós-deploy.

| Critério | Comando/verificação | Resultado esperado | Evidência | PASS/FAIL |
|---|---|---|---|---|
| Especificação e pacote | comparar `VERSION`, especificação e manifesto | origem normativa inequívoca | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Dependências | `borg --version` e `command -v` conforme perfil | Borg 1.4.x e ferramentas declaradas presentes | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Hashes instalados | `sha256sum` dos arquivos gerenciados | igualdade com manifesto aprovado | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Layout FHS | inventário de paths sem symlinks | todos os alvos obrigatórios presentes | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Permissões | `stat -c '%U:%G %a %n' <PATH>` | matriz owner/group/mode integral | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Bash | `bash -n` no ponto de entrada e módulos | zero erro | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Configurações | `borg-backup validate` | código 0 e `EXECUTION=OK` | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Parser negativo | fixture controlada com chave desconhecida | código 2, sem efeito lateral | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Storage | `findmnt --target <STORAGE_MOUNT>` | mountpoint, UUID e ext4 esperados | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Sentinela | `stat` e parser das duas chaves | owner/mode/conteúdo exatos | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Capacidade | `df -Pm <STORAGE_MOUNT>` | livre maior ou igual ao piso | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Segredo | `stat` sem leitura de conteúdo | arquivo regular `root:root 0600` e excluído | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Repositório | consulta Borg controlada | repositório criptografado acessível | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Primeiro archive | `borg-backup run` manual autorizado | create/info, restore de estados e manutenção válidos | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Restore de arquivos | extração em área isolada | conteúdo e amostra de metadados válidos | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Restore PostgreSQL | cluster efêmero sem TCP | schemas/tabelas e consultas aprovados | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Restore SQLite | banco temporário + `integrity_check` | resposta `ok` | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Receptor SSH | comando permitido e comando hostil controlado | permitido funciona; hostil é recusado | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Primeira réplica | `borg-backup replicate` | `current` válida e relatório por destino | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Segunda generation | segunda réplica após novo ciclo | `current` e `previous` válidas | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Fallback | restore de cópia independente de `previous` | arquivo/dump recuperável | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Destinos múltiplos | falha opcional controlada seguida de destino válido | ordem lexical e isolamento comprovados | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Unit systemd | `systemd-analyze verify <UNIT_PATHS>` | zero erro | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Calendário | `systemd-analyze calendar <ON_CALENDAR>` | próxima ocorrência coerente e sem sobreposição | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Logrotate | `logrotate -d <CONFIG_PATH>` | parsing válido sem rotação | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Timer | `systemctl list-timers --all borg-backup.timer` | habilitado somente após gates; próxima ocorrência esperada | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Ciclo automático | journal + `last-run.report` | execução automática completa e serviços restaurados | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Observabilidade | journal, log, reports e state | campos completos, atômicos e coerentes | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Auditoria de segredos | busca por padrões sem registrar valores | zero achado não autorizado | `<EVIDENCE>` | `<PASS_OR_FAIL>` |
| Handoff | as-built, contatos, custódia e runbook | responsáveis aceitam rotina e escalonamento | `<EVIDENCE>` | `<PASS_OR_FAIL>` |

## Aceite

O deploy só entra em operação automática quando todos os itens aplicáveis estão
`PASS`, não há decisão funcional aberta e o revisor confirma que evidências não
contêm segredos ou dados desnecessários.
