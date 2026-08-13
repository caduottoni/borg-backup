# Borg Backup para Debian 13

[English summary](#english-summary)

Solução declarativa de backup e replicação baseada em Bash para Debian
GNU/Linux 13 e BorgBackup 1.4.x. O projeto privilegia falha segura, configuração
explícita e operação auditável.

Versão atual: **1.0.2**, o primeiro release público do projeto.

## O que o projeto oferece

- archives Borg em repositório local identificado por filesystem, UUID e
  sentinela;
- fontes e exclusões declaradas, sem autodiscovery;
- dumps lógicos PostgreSQL e SQLite;
- coordenação explícita de serviços e adaptadores Nextcloud/BIND;
- retenção, compactação, logs, relatórios e estado mínimo persistente;
- replicação fria sequencial por SSH e rsync restritos, com gerações
  `incoming`, `current` e `previous`;
- integração com systemd, `tmpfiles.d` e logrotate;
- testes isolados com fixtures sintéticas.

O projeto não é um instalador automático. Ele não provisiona discos, cria
filesystems, inicializa repositórios, gera credenciais ou decide quais dados de
uma instalação devem ser protegidos. Essas operações exigem revisão e
autorização administrativas.

## Requisitos principais

- Debian GNU/Linux 13;
- Bash 5.x;
- BorgBackup 1.4.x;
- systemd, GNU coreutils, OpenSSH e rsync;
- clientes PostgreSQL e/ou SQLite quando essas integrações forem usadas.

Veja os requisitos completos em
[`docs/02-REQUIREMENTS-AND-DEPENDENCIES.md`](docs/02-REQUIREMENTS-AND-DEPENDENCIES.md).

## Começando

1. Leia a [visão geral e arquitetura](docs/01-OVERVIEW-AND-ARCHITECTURE.md).
2. Revise os [requisitos](docs/02-REQUIREMENTS-AND-DEPENDENCIES.md) e o
   [layout de filesystem](docs/03-FILESYSTEM-LAYOUT-AND-PERMISSIONS.md).
3. Siga a [instalação por gates](docs/05-INSTALLATION.md); não copie a árvore
   diretamente sobre `/`.
4. Preencha somente os modelos de configuração aprovados. Nunca versione
   segredos, chaves privadas ou valores reais de uma instalação.
5. Execute validação, primeiro backup e restauração isolada antes de habilitar
   o timer.

A documentação técnica completa começa em [`docs/README.md`](docs/README.md).

## Estrutura do repositório

```text
src/         código do produto e integrações de sistema
tests/       regressão controlada
fixtures/    doubles e dados exclusivamente sintéticos
docs/        documentação técnica genérica
examples/    modelos de configuração públicos sem credenciais reais
packaging/   tooling de empacotamento reproduzível
.github/     governança e automação do repositório
```

Este repositório deliberadamente não contém documentação de instalações
reais, topologia privada, evidências operacionais nem histórico administrativo.

## Testes

Para executar a regressão disponível no ambiente:

```bash
./tests/run-tests.sh
```

Integrações que dependem de Borg, PostgreSQL ou SQLite reais podem registrar
`SKIP` quando a dependência não está instalada. Os gates de release são mais
restritos e devem exigir todas as dependências declaradas.

Os testes escrevem apenas em `test-runtime/`, que é descartável e não deve ser
versionado.

## Segurança e suporte

Não publique vulnerabilidades em issues. Use o procedimento descrito em
[`SECURITY.md`](SECURITY.md). Dúvidas de uso e limites de suporte estão em
[`SUPPORT.md`](SUPPORT.md).

`.gitignore` reduz erros acidentais, mas não é um controle de sigilo. Revise
sempre o diff e os objetos que serão enviados antes de qualquer push.

## Contribuições

Contribuições são aceitas sob o processo descrito em
[`CONTRIBUTING.md`](CONTRIBUTING.md). Cada commit deve conter `Signed-off-by`
compatível com o [Developer Certificate of Origin 1.1](DCO). Não é exigido
CLA.

Ao participar, observe o [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Licença

Copyright © 2026 Carlos (Du) Ottoni.

Este projeto é distribuído sob a licença
[GNU General Public License v3.0 ou posterior](LICENSE), identificador SPDX
`GPL-3.0-or-later`, sem garantia. Consulte também [`NOTICE`](NOTICE).

## English summary

This repository provides a defensive, declarative Bash-based backup and cold
replication solution for Debian GNU/Linux 13 and BorgBackup 1.4.x. It supports
explicit sources, PostgreSQL and SQLite logical dumps, controlled service
coordination, retention, reporting, and restricted SSH/rsync replication.

The project is not an automatic installer and contains no real deployment
configuration, credentials, private infrastructure documentation, or
operational evidence. Review the [technical documentation](docs/README.md),
[security policy](SECURITY.md), [support policy](SUPPORT.md), and
[contribution guide](CONTRIBUTING.md) before use.

Version 1.0.2 is the project's first public release. The project is licensed
under `GPL-3.0-or-later`.
