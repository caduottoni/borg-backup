# Borg Backup para Debian 13 — documentação técnica

**Finalidade:** servir como índice canônico e ponto de entrada da solução de backup.

**Público-alvo:** administradores Linux, revisores de segurança e responsáveis por recuperação de desastre.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Finalidade e escopo

A solução cria archives Borg de fontes explicitamente declaradas, produz dumps
lógicos PostgreSQL e SQLite, preserva a consistência de aplicações e replica a
árvore integral do repositório para destinos SSH restritos. A implementação é
exclusivamente Bash, sequencial, sem autodiscovery, sem paralelismo e sem hooks
arbitrários provenientes da configuração.

A primeira versão suporta:

- repositório Borg local sobre ext4 identificado por UUID e sentinela;
- fontes e exclusões literais;
- PostgreSQL, objetos globais PostgreSQL e SQLite;
- adaptadores técnicos Nextcloud e BIND;
- interrupção explícita de units de aplicação;
- retenção diária, semanal e mensal com compactação nativa do Borg;
- réplica fria sequencial para múltiplos destinos;
- generations remotas `incoming`, `current` e `previous`;
- logs, relatórios atômicos, estado mínimo e códigos de saída estáveis;
- agendamento diário por systemd e rotação convencional de log.

Não fazem parte desta versão MySQL/MariaDB, plugins, descoberta automática,
backup físico de banco como fonte canônica, montagem automática de storage,
reparo Borg automático, notificação externa ou gestão automática da mídia de
custódia.

## Princípios operacionais

O fluxo resumido é:

```text
validar → preservar estados → preparar aplicações → parar units declaradas
→ gerar e validar dumps → criar e confirmar archive → restaurar estados
→ prune → compact → replicar destinos em sequência → relatar e limpar
```

Uma falha crítica interrompe as etapas dependentes. O backup principal e cada
réplica mantêm estados independentes. A rotina nunca presume que um diretório é
o storage correto apenas porque ele existe.

## Avisos essenciais

Operações de provisionamento de disco, criptografia, inicialização de
repositório, restauração sobre dados existentes e remoção de artefatos podem ser
irreversíveis. Elas exigem autorização, identificação inequívoca do alvo,
pré-flight e plano de retorno próprios.

Segredos não pertencem a exemplos, logs, relatórios ou manifestos. A
credencial que abre o repositório, a exportação da chave Borg e as chaves SSH
privadas exigem custódias compatíveis com suas funções.

Esta documentação descreve somente o produto genérico. Cada instalação deve
manter, fora deste repositório, seu registro as-built com UUID, hostnames,
contas, caminhos, horários e evidências locais. O contrato normativo público é
a [especificação `PUB-SPEC-1`](reference/SPECIFICATION.md).

## Sequência de leitura

1. Comece pela especificação, arquitetura, requisitos e layout.
2. Leia instalação e referência de configuração antes de provisionar.
3. Consulte lifecycle, bancos e replicação antes do primeiro backup.
4. Valide segurança e recuperação antes de habilitar o timer.
5. Use runbook, troubleshooting e checklist na operação contínua.

## Índice canônico

- [Especificação pública `PUB-SPEC-1`](reference/SPECIFICATION.md)
- [Visão geral e arquitetura](01-OVERVIEW-AND-ARCHITECTURE.md)
- [Requisitos e dependências](02-REQUIREMENTS-AND-DEPENDENCIES.md)
- [Layout de filesystem e permissões](03-FILESYSTEM-LAYOUT-AND-PERMISSIONS.md)
- [Contrato de layout do pacote](04-PACKAGE-LAYOUT-CONTRACT.md)
- [Instalação](05-INSTALLATION.md)
- [Referência de configuração](06-CONFIGURATION-REFERENCE.md)
- [Referência de comandos](07-COMMAND-REFERENCE.md)
- [Lifecycle e consistência](08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md)
- [Bancos de dados](09-DATABASES.md)
- [systemd, agendamento e logrotate](10-SYSTEMD-SCHEDULING-AND-LOGROTATE.md)
- [Replicação e receptor remoto](11-REPLICATION-AND-REMOTE-RECEIVER.md)
- [Segurança e custódia de segredos](12-SECURITY-AND-SECRET-CUSTODY.md)
- [Logging, relatórios, estado e códigos](13-LOGGING-REPORTS-STATE-AND-EXIT-CODES.md)
- [Restauração e validação de recuperação](14-RESTORE-AND-RECOVERY-VALIDATION.md)
- [Runbook de operações](15-OPERATIONS-RUNBOOK.md)
- [Troubleshooting](16-TROUBLESHOOTING.md)
- [Upgrade, rollback e desinstalação](17-UPGRADE-ROLLBACK-AND-UNINSTALL.md)
- [Checklist de validação pós-deploy](18-POST-DEPLOY-VALIDATION-CHECKLIST.md)
- [Glossário](GLOSSARY.md)
- [Matriz fonte-documento](SOURCE-TO-DOCUMENT-MATRIX.md)
- [Manifesto documental](DOCUMENTATION-MANIFEST.tsv)

## Regra não circular do manifesto

`DOCUMENTATION-MANIFEST.tsv` contém uma linha para cada um dos 22 documentos
canônicos restantes. Ele não inclui uma linha para si próprio, pois qualquer
hash interno mudaria o próprio arquivo. O hash do manifesto é calculado depois
de sua geração e registrado na evidência externa ao conjunto de release.
