# Bancos de dados

**Finalidade:** definir geração, validação e restauração dos dumps suportados.

**Público-alvo:** administradores de banco, aplicações e recuperação.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Regra canônica

Arquivos internos de SGBD não substituem dump lógico. Cada artefato é criado em
`/var/tmp/borg-backup/<EXECUTION_ID>.<SUFFIX>/dumps`, com `umask 077`, validado
antes de ser renomeado de parcial para final e removido no encerramento. Somente
dumps finais da execução corrente entram no archive.

## PostgreSQL

O registro declarativo informa banco, conta local, socket Unix e porta. A rotina
executa `pg_dump --format=custom` por `runuser` sob a identidade local indicada,
sem senha na linha de comando. `pg_restore --list` deve ler o resultado; qualquer
retorno não zero invalida o dump e bloqueia `borg create`.

Objetos globais são independentes e usam `pg_dumpall --globals-only`. Eles
preservam roles e definições necessárias à recuperação, mas devem ser revisados
antes da restauração por poderem conter atributos administrativos. Diretórios
físicos do cluster permanecem excluídos como fonte canônica quando o dump é a
estratégia aprovada.

### Validação de restauração

Use um cluster efêmero e isolado, nunca o cluster de produção:

```text
diretório temporário privado
→ initdb
→ listen_addresses='' e socket Unix privado
→ iniciar cluster sem TCP
→ criar database temporário e owners necessários
→ pg_restore
→ consultar schemas, tabelas e catálogos esperados
→ parar cluster
→ remover toda a área
```

O teste falha se o cluster abrir TCP, o restore retornar não zero ou estruturas
esperadas estiverem ausentes. A restauração de globais deve ser analisada e
limitada ao ambiente isolado.

## SQLite

O processo capaz de escrever no banco deve corresponder a uma unit explicitada
em `services.conf`. A unit originalmente ativa é parada e permanece assim até a
confirmação do archive. A rotina então:

1. executa `.dump` em texto para arquivo parcial;
2. restaura o texto em um banco temporário novo;
3. executa `PRAGMA integrity_check`;
4. exige a resposta exata `ok`;
5. promove o dump parcial para final;
6. inclui o dump no Borg;
7. restaura a unit ao estado original após `borg info`.

O banco vivo, `<DATABASE>-wal` e `<DATABASE>-shm` são exclusões literais
obrigatórias. Um teste de recuperação extrai o dump para um arquivo novo e
repete `integrity_check`; nunca sobrescreve o banco vivo.

## Falha segura

Falha de cliente, autenticação local, leitura, validação, integridade ou limpeza
impede que um parcial seja tratado como dump. A rotina tenta restaurar units e
aplicações, não executa archive/manutenção/réplica dependentes e retorna código
2. Logs registram ID, tipo, tamanho e estado, jamais conteúdo.

## Extensibilidade controlada

Somente `postgresql`, `postgresql-globals` e `sqlite` são aceitos. MySQL e
MariaDB estão fora de escopo. Um tipo futuro exigirá decisão normativa, formato
de configuração fechado, função pequena, dependências explícitas, validação de
restore e testes de falha segura. Não se admite framework de plugins, comando
livre ou hook shell vindo da configuração.
