# Logging, relatórios, estado e códigos de saída

**Finalidade:** definir a observabilidade persistente e a semântica de resultados.

**Público-alvo:** operadores, monitoramento, auditores e suporte.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Eventos

Cada evento essencial é escrito em stderr, capturado pelo journal sob systemd,
e opcionalmente em `/var/log/borg-backup/backup.log`. Formato:

```text
<TIMESTAMP_UTC> <LEVEL> <EXECUTION_ID> <COMPONENT> <EVENT> <MESSAGE>
```

Níveis são `INFO`, `WARNING` e `ERROR`. A mensagem é uma linha sanitizada e não
contém conteúdo de configuração sensível ou saída integral de ferramenta.

## Relatórios

`last-run.report` é substituído atomicamente em toda execução preparada.
`last-success.report` só é promovido quando o backup principal foi confirmado.
Campos relevantes incluem:

```text
EXECUTION_ID
HOST
OPERATION
BACKUP
ARCHIVE
MAINTENANCE
REPLICATION_SUMMARY
REPLICATION[<DESTINATION_ID>]
CAPACITY
RESTORE
PRIMARY_FAILURE
LAST_VALID_PRIMARY
EXECUTION
```

Resultados de backup, manutenção, capacidade e cada destino permanecem
separados. Uma falha posterior não reescreve `BACKUP=OK`.

## Estado mínimo

`/var/lib/borg-backup/state/last-success.state` registra apenas execution ID,
archive, resultado e timestamp UTC do último backup válido. Cada destino pode
ter `replication/<DESTINATION_ID>.state` com resultado, capacidade, generation e
timestamp. Escritas usam arquivo temporário e rename no mesmo diretório.

Estado não é banco de dados nem fonte para reconstruir configuração. Se estiver
ausente ou inválido, uma operação que dele dependa falha de forma segura.

## Códigos

| Código | Classificação | Exemplos |
|---:|---|---|
| 0 | sucesso | validate válido; backup e destinos sem warning |
| 1 | advertência válida | capacidade pós-operação baixa; réplica opcional falha |
| 2 | falha crítica | parser, storage, dump, Borg, restore, manutenção ou destino obrigatório |
| 64 | uso inválido | quantidade de argumentos ou operação desconhecida |

Código 1 significa que o artefato indicado como `OK` é válido; não significa que
tudo esteja saudável. systemd aceita 0 e 1, enquanto monitoramento deve alertar
por `EXECUTION=WARNING` e `CAPACITY=WARNING`.

## Exemplos de interpretação

```text
BACKUP=OK
MAINTENANCE=OK
REPLICATION_SUMMARY=WARNING_OPTIONAL
REPLICATION[offsite-a]=FAILED
CAPACITY=OK
EXECUTION=WARNING
```

O exemplo representa backup válido e destino opcional falho; a ação é reparar a
réplica, não recriar nem apagar o archive.

```text
BACKUP=FAILED_DUMP
MAINTENANCE=SKIPPED
REPLICATION_SUMMARY=SKIPPED
RESTORE=OK
EXECUTION=FAILED
```

Aqui nenhum novo archive válido foi produzido; o último sucesso anterior
permanece referenciado.

## Consultas

```bash
systemctl status borg-backup.service
journalctl -u borg-backup.service --since today
sed -n '1,200p' /var/log/borg-backup/last-run.report
sed -n '1,200p' /var/log/borg-backup/last-success.report
find /var/lib/borg-backup/state -type f -maxdepth 2 -print
```

Não copie para tickets valores de segredo, ambiente completo, dumps, dados de
usuário, saída integral de Borg ou conteúdo de chaves. Redija evidências antes
de compartilhá-las.
