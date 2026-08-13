# Matriz de rastreabilidade pública

**Finalidade:** relacionar cada requisito público à implementação, aos modelos, aos testes e à documentação que o explicam.

**Público-alvo:** revisores, mantenedores, auditores e empacotadores.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Regra de rastreabilidade

A fonte normativa é a
[especificação `PUB-SPEC-1`](reference/SPECIFICATION.md). `COVERED` indica que
o requisito possui implementação ou contrato verificável no repositório e ao
menos uma forma de validação indicada. A matriz não autoriza uma operação em
ambiente real e não substitui os gates do runbook.

| Requisito | Implementação ou contrato | Configuração/modelo | Teste/evidência | Documento explicativo | Status |
|---|---|---|---|---|---|
| `PUB-REQ-001`, `PUB-REQ-002`, `PUB-REQ-003`, `PUB-REQ-004`, `PUB-REQ-005` — plataforma, interface, escopo e limites | `src/usr/local/sbin/borg-backup`; módulos sob `src/usr/local/lib/borg-backup` | `examples/etc/borg-backup/` | `tests/static.sh`; `tests/artifacts.sh` | [README](README.md); [arquitetura](01-OVERVIEW-AND-ARCHITECTURE.md); [requisitos](02-REQUIREMENTS-AND-DEPENDENCIES.md) | COVERED |
| `PUB-REQ-006` — ambiente controlado | `src/usr/local/sbin/borg-backup`; `common.sh` | não aplicável | `tests/static.sh`; `tests/checkpoint-01.sh` | [arquitetura](01-OVERVIEW-AND-ARCHITECTURE.md); [segurança](12-SECURITY-AND-SECRET-CUSTODY.md) | COVERED |
| `PUB-REQ-007`, `PUB-REQ-008` — parser literal e módulos confiáveis | `config.sh`; ponto de entrada | todos os modelos `.example` | `tests/checkpoint-01.sh`; `tests/static.sh` | [configuração](06-CONFIGURATION-REFERENCE.md); [segurança](12-SECURITY-AND-SECRET-CUSTODY.md) | COVERED |
| `PUB-REQ-009` — locks | `common.sh`; `replication.sh`; `replica-receiver.sh` | configuração global e destinos | `tests/checkpoint-01.sh`; `tests/checkpoint-03.sh`; `tests/helpers/lock-probe.sh` | [arquitetura](01-OVERVIEW-AND-ARCHITECTURE.md); [lifecycle](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md) | COVERED |
| `PUB-REQ-010`, `PUB-REQ-011`, `PUB-REQ-012` — FHS, permissões e runtime após boot | `common.sh`; `config.sh`; `src/usr/local/lib/tmpfiles.d/borg-backup.conf` | árvore `src/` e modelos | `tests/artifacts.sh`; `tests/tmpfiles-lifecycle.sh`; `tests/checkpoint-01.sh` | [layout FHS](03-FILESYSTEM-LAYOUT-AND-PERMISSIONS.md); [systemd](10-SYSTEMD-SCHEDULING-AND-LOGROTATE.md) | COVERED |
| `PUB-REQ-013`, `PUB-REQ-014` — temporários e reconciliação | `common.sh`; ponto de entrada | raiz temporária definida pelo produto | `tests/runtime-lifecycle.sh`; `tests/checkpoint-01.sh` | [lifecycle](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md); [troubleshooting](16-TROUBLESHOOTING.md) | COVERED |
| `PUB-REQ-015` — configuração global | `config.sh`; `backup.sh`; `maintenance.sh` | `examples/etc/borg-backup/backup.conf.example` | `tests/checkpoint-01.sh`; `tests/checkpoint-02.sh` | [configuração](06-CONFIGURATION-REFERENCE.md) | COVERED |
| `PUB-REQ-016` — fontes e exclusões | `config.sh`; `backup.sh` | `sources.conf.example`; `excludes.conf.example` | `tests/checkpoint-01.sh`; `tests/checkpoint-02.sh` | [configuração](06-CONFIGURATION-REFERENCE.md); [layout FHS](03-FILESYSTEM-LAYOUT-AND-PERMISSIONS.md) | COVERED |
| `PUB-REQ-017` — bancos declarativos | `config.sh`; `databases.sh` | `databases.conf.example` | `tests/checkpoint-02.sh`; `tests/postgresql-restore.sh`; `tests/sqlite-restore.sh` | [bancos](09-DATABASES.md); [restore](14-RESTORE-AND-RECOVERY-VALIDATION.md) | COVERED |
| `PUB-REQ-018`, `PUB-REQ-019` — aplicações e units | `config.sh`; `applications.sh`; `services.sh` | `applications.conf.example`; `services.conf.example` | `tests/checkpoint-01.sh`; `tests/checkpoint-02.sh` | [configuração](06-CONFIGURATION-REFERENCE.md); [lifecycle](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md) | COVERED |
| `PUB-REQ-020` — segredo Borg | `config.sh`; `logging.sh`; `backup.sh` | `secrets.conf.example` | `tests/static.sh`; `tests/checkpoint-01.sh` | [configuração](06-CONFIGURATION-REFERENCE.md); [segurança](12-SECURITY-AND-SECRET-CUSTODY.md) | COVERED |
| `PUB-REQ-021` — configuração de réplica | `config.sh`; `replication.sh` | `replication.conf.example`; `replication.d/10-destination.conf.example`; `ssh/known_hosts.example` | `tests/checkpoint-01.sh`; `tests/checkpoint-03.sh` | [replicação](11-REPLICATION-AND-REMOTE-RECEIVER.md) | COVERED |
| `PUB-REQ-022` — validação integral | ponto de entrada; `common.sh`; `config.sh` | todos os modelos | checkpoints 01–03 | [instalação](05-INSTALLATION.md); [checklist](18-POST-DEPLOY-VALIDATION-CHECKLIST.md) | COVERED |
| `PUB-REQ-023`, `PUB-REQ-024` — identidade e capacidade do storage | `common.sh`; `backup.sh`; `replication.sh`; `replica-receiver.sh` | `backup.conf.example`; `replication.conf.example` | checkpoints 01–03 | [layout FHS](03-FILESYSTEM-LAYOUT-AND-PERMISSIONS.md); [lifecycle](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md) | COVERED |
| `PUB-REQ-025`, `PUB-REQ-026`, `PUB-REQ-027`, `PUB-REQ-028` — criação, confirmação, retenção e check | `backup.sh`; `maintenance.sh`; ponto de entrada | `backup.conf.example` | `tests/checkpoint-02.sh` | [comandos](07-COMMAND-REFERENCE.md); [lifecycle](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md) | COVERED |
| `PUB-REQ-029`, `PUB-REQ-030`, `PUB-REQ-031` — estados, janela crítica e aplicações | `services.sh`; `applications.sh`; ponto de entrada | `services.conf.example`; `applications.conf.example` | `tests/checkpoint-02.sh`; `tests/runtime-lifecycle.sh` | [lifecycle](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md); [runbook](15-OPERATIONS-RUNBOOK.md) | COVERED |
| `PUB-REQ-032`, `PUB-REQ-033` — dumps e limpeza | `databases.sh`; `common.sh`; ponto de entrada | `databases.conf.example`; `excludes.conf.example` | `tests/checkpoint-02.sh`; testes de restore PostgreSQL e SQLite; `tests/runtime-lifecycle.sh` | [bancos](09-DATABASES.md); [restore](14-RESTORE-AND-RECOVERY-VALIDATION.md) | COVERED |
| `PUB-REQ-034`, `PUB-REQ-035` — SSH e protocolo fechado | `replication.sh`; `replica-receiver.sh` | modelos de réplica, identidade e `known_hosts` | `tests/checkpoint-03.sh`; `tests/helpers/capture-rsync-rsh.sh` | [replicação](11-REPLICATION-AND-REMOTE-RECEIVER.md); [segurança](12-SECURITY-AND-SECRET-CUSTODY.md) | COVERED |
| `PUB-REQ-036`, `PUB-REQ-037`, `PUB-REQ-038` — generations, integridade e destinos independentes | `replication.sh`; `replica-receiver.sh` | modelos de réplica | `tests/checkpoint-03.sh` | [replicação](11-REPLICATION-AND-REMOTE-RECEIVER.md); [restore](14-RESTORE-AND-RECOVERY-VALIDATION.md) | COVERED |
| `PUB-REQ-039`, `PUB-REQ-040`, `PUB-REQ-041` — eventos, relatórios, estado e códigos | `logging.sh`; `common.sh`; ponto de entrada | `FILE_LOG_ENABLED` | checkpoints 01–03; `tests/runtime-lifecycle.sh` | [observabilidade](13-LOGGING-REPORTS-STATE-AND-EXIT-CODES.md) | COVERED |
| `PUB-REQ-042` — systemd, tmpfiles e logrotate | arquivos sob `src/etc`; regra sob `src/usr/local/lib/tmpfiles.d` | unit, timer e logrotate distribuídos | `tests/artifacts.sh`; `tests/tmpfiles-lifecycle.sh` | [systemd](10-SYSTEMD-SCHEDULING-AND-LOGROTATE.md); [instalação](05-INSTALLATION.md) | COVERED |
| `PUB-REQ-043` — restore isolado | `maintenance.sh`; `databases.sh`; receptor | configuração declarativa | `tests/postgresql-restore.sh`; `tests/sqlite-restore.sh`; `tests/checkpoint-03.sh` | [restore](14-RESTORE-AND-RECOVERY-VALIDATION.md) | COVERED |
| `PUB-REQ-044`, `PUB-REQ-045` — custódia e conteúdo publicável | sanitização em `logging.sh`; exclusões em `backup.sh`; política do repositório | `secrets.conf.example`; `excludes.conf.example`; `.gitignore` | `tests/static.sh`; `tests/artifacts.sh`; gate de saneamento do release | [segurança](12-SECURITY-AND-SECRET-CUSTODY.md); [contrato do pacote](04-PACKAGE-LAYOUT-CONTRACT.md) | COVERED |
| `PUB-REQ-046`, `PUB-REQ-047` — pacote e reprodutibilidade | `packaging/build-package.sh`; `packaging/validate-package.sh`; `packaging/compare-builds.sh` | `packaging/templates/` | `tests/artifacts.sh`; comparação de duas construções limpas | [contrato do pacote](04-PACKAGE-LAYOUT-CONTRACT.md); [upgrade](17-UPGRADE-ROLLBACK-AND-UNINSTALL.md) | COVERED |
| `PUB-REQ-048` — suíte pública | todos os arquivos sob `tests/` | fixtures sintéticas criadas pelo harness | `tests/run-tests.sh` | [checklist](18-POST-DEPLOY-VALIDATION-CHECKLIST.md); [restore](14-RESTORE-AND-RECOVERY-VALIDATION.md) | COVERED |
| `PUB-REQ-049` — upgrade, rollback e desinstalação | contrato do pacote e runbooks sob `packaging/templates/` | mapa FHS do pacote | `tests/artifacts.sh`; validação do pacote | [upgrade e rollback](17-UPGRADE-ROLLBACK-AND-UNINSTALL.md); [instalação](05-INSTALLATION.md) | COVERED |
| `PUB-REQ-050` — documentação verificável | `docs/`; esta matriz; manifesto não circular | não aplicável | conferência de links, cobertura e SHA-256 | [README](README.md); [manifesto](DOCUMENTATION-MANIFEST.tsv) | COVERED |

## Cobertura dos comandos e módulos

Os comandos públicos `validate`, `run`, `list`, `check`, `prune` e `replicate`
estão em [Referência de comandos](07-COMMAND-REFERENCE.md). Todos os módulos
distribuídos aparecem na matriz. O protocolo entre emissor e receptor é uma
interface interna e não deve ser apresentado como comando administrativo.

## Manutenção desta matriz

Ao incluir ou alterar um `PUB-REQ-*`, o mantenedor deve, no mesmo change set:

1. atualizar a implementação ou declarar explicitamente o contrato afetado;
2. adicionar ou ajustar a validação correspondente;
3. atualizar o documento explicativo;
4. manter a linha desta matriz sem intervalos de requisitos descobertos; e
5. regenerar `DOCUMENTATION-MANIFEST.tsv` somente depois de estabilizar todos
   os documentos.
