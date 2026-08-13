# Runbook de operações

**Finalidade:** fornecer rotinas seguras para operação contínua e intervenções autorizadas.

**Público-alvo:** operadores de backup e administradores de plantão.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Verificação diária

```bash
systemctl status borg-backup.timer borg-backup.service
systemctl list-timers --all borg-backup.timer
sed -n '1,200p' /var/log/borg-backup/last-run.report
sed -n '1,200p' /var/log/borg-backup/last-success.report
df -Pm /srv/borg-storage
```

Confirme próxima ocorrência, última execução, `BACKUP`, `MAINTENANCE`,
`CAPACITY`, `RESTORE`, resumo e cada destino. Código 1 precisa de ação mesmo
quando o service aparece concluído.

## Validação e archives

```bash
/usr/local/sbin/borg-backup validate
/usr/local/sbin/borg-backup list
```

Use `validate` depois de mudança autorizada e antes de backup manual. `list` é a
interface pública para archives do prefixo; não invoque módulos internos.

## Capacidade e storage

```bash
findmnt --target /srv/borg-storage -o TARGET,UUID,FSTYPE,OPTIONS
stat -c '%U:%G %a %n' /srv/borg-storage/.borg-storage
df -Pm /srv/borg-storage
```

Compare UUID, ext4, mountpoint, sentinela e piso com o as-built. Não crie a
sentinela para contornar disco ausente. Se o piso estiver baixo, suspenda novas
operações, estime crescimento e expanda/substitua storage por procedimento; não
apague archives manualmente.

## Réplicas

```bash
/usr/local/sbin/borg-backup replicate
sed -n '1,200p' /var/log/borg-backup/last-run.report
find /var/lib/borg-backup/state/replication -maxdepth 1 -type f -print
```

No receptor, use o comando `status` somente pela interface restrita aprovada.
Confirme `CURRENT=yes`, `PREVIOUS=yes` após a segunda generation e ausência de
token ativo fora de uma transferência. Não execute Borg modificador nas
generations.

## Locks

```bash
ls -l /run/borg-backup/backup.lock
systemctl status borg-backup.service
ps -eo pid,ppid,user,etime,args | grep '[b]org-backup'
```

A existência do arquivo não prova lock órfão; `flock` está associado ao
descritor do processo. Identifique o processo antes de agir. Nunca remova locks
Borg do repositório vivo sem diagnóstico específico.

## Backup manual autorizado

1. Confirmar que timer/service não estão ativos e não há operação externa.
2. Executar `borg-backup validate` e exigir zero.
3. Registrar autorização e motivo.
4. Executar `/usr/local/sbin/borg-backup run`.
5. Interpretar código e relatório, não apenas stdout.
6. Confirmar estados das aplicações e capacidade.
7. Realizar restore de amostra quando o procedimento exigir.

## Pausar e retomar agendamento

```bash
systemctl disable --now borg-backup.timer
systemctl is-active borg-backup.service
```

Espere uma execução ativa terminar ou siga plano de interrupção que preserve
estados. Para retomar, valide configuração, calcule próxima ocorrência e use:

```bash
systemctl enable --now borg-backup.timer
systemctl list-timers --all borg-backup.timer
```

## Substituir storage

Pausar timer, provar último backup/replica recuperável, identificar um disco por
caminho estável, obter autorização destrutiva, criar ext4, obter novo UUID,
atualizar fstab/configuração, montar, criar sentinela, validar, criar novo
repositório e executar backup/restore. Não reutilize UUID antigo nem copie
sentinela antes de confirmar o novo mount.

## Atualizar custódia

Abra a mídia somente sob procedimento autorizado. Confirme identidade física,
LUKS2, ext4 e ausência de mount inesperado; grave e verifique export/credencial,
sincronize, desmonte, feche e desconecte. Confirme também a segunda custódia
independente. O ciclo diário nunca procura essa mídia.

## Teste de restore

Siga [Restauração e validação de recuperação](14-RESTORE-AND-RECOVERY-VALIDATION.md).
Registre fonte, amostra, banco, resultado, duração e limpeza. Alterações e falhas
só são simuladas em cópias independentes.

## Frequência mínima de revisão

| Frequência | Verificações |
|---|---|
| diária | timer, último relatório, capacidade, services e destinos |
| semanal | archives, logrotate, crescimento e warnings recorrentes |
| mensal | restore isolado, `current`/`previous`, custódia e versões suportadas |
| após mudança | validate, hashes, unit/calendar, backup manual e restore adequado |

Escale diante de falha crítica repetida, restore inválido, erro de I/O/SMART,
host key inesperada, estado remoto ambíguo, serviço não restaurado, suspeita de
vazamento ou necessidade de comando destrutivo não coberto.
