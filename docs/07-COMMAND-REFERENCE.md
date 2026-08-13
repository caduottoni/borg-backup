# Referência de comandos

**Finalidade:** definir a interface administrativa pública e seus efeitos.

**Público-alvo:** operadores e administradores Linux.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Interface

O único ponto de entrada é `/usr/local/sbin/borg-backup`. Ele aceita exatamente
uma operação pública. Todas as operações validam contexto, layout, configuração,
dependências, storage e repositório, usam o lock global e atualizam
`last-run.report`. Modos internos não são interface administrativa.

## `validate`

```bash
/usr/local/sbin/borg-backup validate
```

Consulta layout, parser, dependências declaradas, targets, mount, sentinela,
capacidade e acesso ao repositório por `borg info`. Não cria archive, não altera
aplicações, não executa manutenção nem replica. Retorna 0 ou 2 e não atualiza
`last-success`.

## `run`

```bash
/usr/local/sbin/borg-backup run
```

Executa o lifecycle diário completo: janela crítica, dumps, create/info,
restauração, prune/compact, capacidade e replicação habilitada. Pode alterar
units declaradas temporariamente e modifica o repositório. Retorna 0 em sucesso,
1 em advertência válida ou 2 em falha crítica. Um archive confirmado continua
válido mesmo se manutenção ou réplica obrigatória posterior falhar.

## `list`

```bash
/usr/local/sbin/borg-backup list
```

Lista no stdout somente archives que correspondem ao prefixo configurado. Não
cria, remove ou compacta dados. Retorna 0 ou 2.

## `check`

```bash
/usr/local/sbin/borg-backup check
```

Executa `borg check` explícito no repositório principal, sem `--repair`. Não
integra o ciclo diário. Pode ser intensivo; planeje janela e capacidade. Retorna
0 somente quando o Borg retorna zero; qualquer outro resultado vira 2.

## `prune`

```bash
/usr/local/sbin/borg-backup prune
```

Aplica a retenção configurada ao prefixo e executa `borg compact` somente após
`prune` retornar zero. Não cria archive, não replica e não altera aplicações.
É uma operação modificadora; use-a apenas sob procedimento autorizado. Retorna
0 ou 2.

## `replicate`

```bash
/usr/local/sbin/borg-backup replicate
```

Confirma por estado e `borg info` o último archive principal válido e replica a
árvore integral do repositório sem criar novo archive ou executar manutenção.
Usa `borg with-lock`, processa todos os destinos habilitados em sequência e
retorna 0, 1 ou 2 conforme resultado consolidado.

## Locks, logs e estado

Se outra operação mantém o lock, o comando falha com código 2 sem aguardar
indefinidamente. Eventos vão para stderr/journal e, se habilitado, para
`/var/log/borg-backup/backup.log`. Relatórios ficam em
`/var/log/borg-backup/`; estado mínimo, em `/var/lib/borg-backup/state/`.

## Códigos comuns

| Código | Semântica |
|---:|---|
| 0 | operação concluída sem advertência |
| 1 | backup/réplica válida com advertência de capacidade ou destino opcional |
| 2 | falha crítica, configuração inválida, lock ocupado ou destino obrigatório falho |
| 64 | argumento ausente, extra ou operação pública desconhecida |

O unit systemd considera 0 e 1 como término bem-sucedido. O operador deve ainda
ler `EXECUTION`, `BACKUP`, `MAINTENANCE`, `CAPACITY` e os campos de replicação.
