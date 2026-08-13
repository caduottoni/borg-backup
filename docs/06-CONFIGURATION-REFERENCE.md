# Referência de configuração

**Finalidade:** documentar integralmente os arquivos declarativos e suas validações.

**Público-alvo:** administradores de implantação, operadores e revisores.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Parser declarativo

Configurações são lidas como dados. Há três formatos:

- atribuições `CHAVE=valor` para configurações globais e destinos;
- uma entrada literal por linha para fontes, exclusões e units;
- tabelas literais delimitadas por `|` para bancos e aplicações.

Somente linhas vazias e comentários que começam na primeira coluna são
ignorados. Comentário ao fim da linha, espaços nas bordas, chaves duplicadas ou
desconhecidas, campos vazios, `$`, crase, `#` no valor, `()` e qualquer sintaxe
de shell são recusados. Não existem defaults implícitos: toda chave obrigatória
deve aparecer exatamente uma vez. Arquivos não podem ser symlinks.

Arquivos normais e `known_hosts` usam `root:root 0640`; segredo e chaves
privadas usam `root:root 0600`. Os diretórios `replication.d`, `ssh` e
`ssh/keys` usam, respectivamente, `0750`, `0700` e `0700`.

## `backup.conf`

| Campo | Valor aceito e unidade | Relação/validação |
|---|---|---|
| `BORG_REPOSITORY` | path absoluto seguro | diretório existente; não recursivo com fontes |
| `ARCHIVE_PREFIX` | ID minúsculo com números/hífen | prefixo exclusivo |
| `BORG_COMPRESSION` | `auto,zstd,3` | conjunto fechado |
| `KEEP_DAILY` | `14` archives diários | valor fixo desta versão |
| `KEEP_WEEKLY` | `8` archives semanais | valor fixo desta versão |
| `KEEP_MONTHLY` | `12` archives mensais | valor fixo desta versão |
| `REPOSITORY_FILESYSTEM_UUID` | UUID ext4 | comparado case-insensitive com `findmnt` |
| `REPOSITORY_FILESYSTEM_TYPE` | `ext4` | conjunto fechado |
| `REPOSITORY_STORAGE_ID` | ID portátil | deve coincidir com sentinela |
| `REPOSITORY_MIN_FREE_MIB` | inteiro positivo em MiB | piso pré e pós-operação; modelo `51200` |
| `REPOSITORY_SENTINEL` | path absoluto seguro | raiz deve ser o mount exato |
| `FILE_LOG_ENABLED` | `yes` ou `no` | journal permanece disponível |

Exemplo completo com UUID deliberadamente fictício:

```ini
# Repositório local explícito.
BORG_REPOSITORY=/srv/borg-storage/repositories/server-a/repo
# Prefixo portátil dos archives.
ARCHIVE_PREFIX=server-a
# Compressão fechada da primeira versão.
BORG_COMPRESSION=auto,zstd,3
# Retenção diária nativa.
KEEP_DAILY=14
# Retenção semanal nativa.
KEEP_WEEKLY=8
# Retenção mensal nativa.
KEEP_MONTHLY=12
# UUID fictício usado apenas no exemplo validado.
REPOSITORY_FILESYSTEM_UUID=00000000-0000-0000-0000-000000000000
# Filesystem obrigatório.
REPOSITORY_FILESYSTEM_TYPE=ext4
# Identidade esperada da sentinela.
REPOSITORY_STORAGE_ID=server-a
# Piso inicial de 50 GiB em MiB.
REPOSITORY_MIN_FREE_MIB=51200
# Sentinela na raiz do mount.
REPOSITORY_SENTINEL=/srv/borg-storage/.borg-storage
# Log persistente habilitado.
FILE_LOG_ENABLED=yes
```

## `sources.conf` e `excludes.conf`

Cada linha ativa é um path absoluto literal. Fontes devem existir, não ser
symlinks e não conter nem estar contidas no repositório. Pelo menos uma fonte é
obrigatória.

```ini
# Configuração do sistema.
/etc
# Código administrativo local.
/usr/local
# Conteúdo web explicitamente protegido.
/var/www
# Dados persistentes da aplicação de exemplo.
/srv/app-data
```

Exclusões mínimas e SQLite de exemplo:

```ini
# Impede recursão do repositório.
/srv/borg-storage/repositories/server-a/repo
# Exclui toda a área transitória.
/var/tmp/borg-backup
# Mantém a credencial Borg fora do archive.
/etc/borg-backup/secrets.conf
# Mantém chaves SSH privadas fora do archive.
/etc/borg-backup/ssh/keys
# Cache Borg regenerável.
/var/cache/borg
# Banco SQLite vivo; o dump validado é canônico.
/srv/app-data/database.sqlite3
# WAL do banco vivo.
/srv/app-data/database.sqlite3-wal
# SHM do banco vivo.
/srv/app-data/database.sqlite3-shm
```

## `databases.conf`

Formatos fechados:

```text
postgresql|<ID>|<DATABASE>|<LOCAL_USER>|<UNIX_SOCKET_DIR>|<PORT>
postgresql-globals|<ID>|<LOCAL_USER>|<UNIX_SOCKET_DIR>|<PORT>
sqlite|<ID>|<LIVE_DATABASE_PATH>
```

IDs são únicos por tipo. Porta é decimal entre 1 e 65535. PostgreSQL usa conta
local e socket Unix; SQLite exige as três exclusões correspondentes.

```ini
# Banco PostgreSQL por socket e autenticação local.
postgresql|app-db|app_database|postgres|/var/run/postgresql|5432
# Roles e tablespaces do cluster necessário à restauração.
postgresql-globals|main-cluster|postgres|/var/run/postgresql|5432
# Banco SQLite vivo associado a uma unit declarada.
sqlite|local-db|/srv/app-data/database.sqlite3
```

## `applications.conf`

Formatos implementados:

```text
nextcloud|<ID>|<APPLICATION_DIRECTORY>|<OCC_LOCAL_USER>
bind|<ID>|<DYNAMIC_STATE_DIRECTORY>|<RNDC_LOCAL_USER>
```

O diretório Nextcloud deve conter `occ`. O diretório BIND deve existir. Usuários
são identificadores locais; nenhuma credencial é armazenada aqui.

```ini
# Instância técnica Nextcloud de exemplo.
nextcloud|cloud-app|/var/www/cloud-app|www-data
# Estado dinâmico BIND sincronizado online.
bind|dns-state|/var/lib/bind|root
```

## `services.conf`

Uma unit de aplicação por linha, sem associação a etapa ou comando:

```ini
# Serviço web da aplicação.
web-app.service
# Escritor do banco SQLite.
sqlite-app.service
```

Somente nomes terminados em `.service` são aceitos. Padrões associados a rede,
firewall, SSH, DNS ou VPN são sempre recusados. Units repetidas ou com
argumentos também falham.

## `replication.conf`

| Campo | Valor | Observação |
|---|---|---|
| `REPLICATION_ENABLED` | `yes`/`no` | gate global |
| `REPLICATION_SOURCE` | path absoluto | deve ser idêntico a `BORG_REPOSITORY` |
| `REPLICATION_VERIFY_MODE` | `basic` | único modo implementado |
| `REPLICATION_MIN_FREE_MIB` | inteiro positivo em MiB | modelo `51200` |

```ini
# Replicação começa desabilitada até provisionamento completo.
REPLICATION_ENABLED=no
# Árvore local integral do repositório.
REPLICATION_SOURCE=/srv/borg-storage/repositories/server-a/repo
# Validação fechada de estrutura e transporte.
REPLICATION_VERIFY_MODE=basic
# Piso remoto de 50 GiB em MiB.
REPLICATION_MIN_FREE_MIB=51200
```

## `replication.d/*.conf`

Arquivos terminados em `.conf` são processados pela ordem lexical. IDs e pares
host/destino não podem se repetir. Todos os dez campos abaixo são obrigatórios:

```ini
# Identificador único do destino.
REPLICATION_ID=server-b
# Destino desabilitado enquanto o receptor não estiver aprovado.
REPLICATION_ENABLED=no
# Falha será advertência quando este valor for no.
REPLICATION_REQUIRED=no
# Host reservado de documentação.
REPLICATION_HOST=server-b.example.invalid
# Conta técnica dedicada à recepção.
REPLICATION_USER=replica-receiver
# Porta SSH declarada.
REPLICATION_SSH_PORT=22
# Raiz exclusiva da origem remota.
REPLICATION_DESTINATION=/srv/borg-storage/replicas/server-a
# Chave privada dedicada.
REPLICATION_IDENTITY_FILE=/etc/borg-backup/ssh/keys/server-b
# Base dedicada de host keys.
REPLICATION_KNOWN_HOSTS_FILE=/etc/borg-backup/ssh/known_hosts
# Único modo de verificação implementado.
REPLICATION_VERIFY_MODE=basic
```

Quando o destino está habilitado, chave privada `0600` e `known_hosts` `0640`
devem existir. Falha de destino obrigatório produz código 2; falha de destino
opcional, com backup válido, produz código 1. Os destinos seguintes ainda são
tentados.

## `secrets.conf`

Contém exatamente a atribuição abaixo, com valor criado diretamente no destino:

```ini
# Credencial Borg fornecida ao subprocesso por ambiente mínimo.
BORG_PASSPHRASE=<SECRET_VALUE>
```

Não há default. O marcador distribuído pelo modelo é recusado para impedir uso
acidental. O arquivo é sensível, `root:root 0600`, excluído do archive e nunca
reproduzido em log ou relatório.

## `ssh/known_hosts` e `ssh/keys/`

`known_hosts` contém apenas entradas previamente verificadas, no formato
OpenSSH, por exemplo `<HOST_KEY_ENTRY>`. Cada destino habilitado aponta para uma
chave privada dedicada em `ssh/keys/`; o material público correspondente é
instalado no receptor com comando forçado. Aceitação automática de host key é
proibida.

## Erros esperados

Qualquer chave/tipo desconhecido, duplicata, valor vazio, sintaxe shell, modo
inseguro, symlink, fonte recursiva, SQLite sem exclusões, unit protegida,
filesystem divergente, sentinela inválida ou destino duplicado retorna código 2
antes da operação dependente.
