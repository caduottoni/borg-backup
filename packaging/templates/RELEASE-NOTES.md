# Notas do release @PACKAGE_VERSION@

## Escopo

Primeiro release preparado a partir da árvore pública autocontida do Borg Backup
para Debian GNU/Linux 13, implementado em Bash e compatível com BorgBackup 1.4.x.

## Empacotamento público

- versão lida exclusivamente de `VERSION` na raiz do repositório;
- builds A/B sob `packaging/work`, com comparação byte a byte;
- `SOURCE_DATE_EPOCH` explícito, sem consulta ao relógio durante o build;
- especificação pública em `docs/reference/SPECIFICATION.md`;
- `LICENSE` e `NOTICE` incluídos no archive;
- modelos `.example` materializados nos paths operacionais do tar;
- genericidade e ausência de segredos verificadas sobre todo o pacote, sem exceções.

## Funcionalidades

- backup Borg sequencial, lock global e falha segura;
- dumps lógicos PostgreSQL e SQLite;
- controle declarativo de serviços e aplicações;
- retenção, compactação, logs, relatórios e estado mínimo;
- replicação fria por SSH/rsync com `incoming`, `current` e `previous`;
- integração com systemd, tmpfiles.d e logrotate.

## Limites

O pacote não é instalador e não provisiona storage, repositório, segredo, chave,
conta ou configuração real de host. Leia `docs/README.md`, valide os manifestos e
siga os gates em `install/` antes de qualquer implantação.
