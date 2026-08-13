# systemd, agendamento e logrotate

**Finalidade:** documentar execução automática, calendário e rotação de logs.

**Público-alvo:** administradores e operadores Debian.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Runtime volátil com tmpfiles

`/run` não sobrevive a reboot. O pacote instala a seguinte regra comentada em
`/usr/local/lib/tmpfiles.d/borg-backup.conf`:

```text
# Cria no boot o diretório volátil usado pelo lock global do Borg Backup.
d /run/borg-backup 0750 root root -
```

Na instalação, aplique e verifique a regra antes do primeiro comando:

```bash
systemd-tmpfiles --create /usr/local/lib/tmpfiles.d/borg-backup.conf
stat -c '%U:%G %a' /run/borg-backup
```

O resultado esperado é `root:root 750`. Um teste de aceitação pós-reboot deve
confirmar o diretório antes da primeira ocorrência do timer e executar
`borg-backup validate`. A regra atende também execuções manuais, sem vincular o
lifecycle do diretório ao término do service.

## Unit de execução

O service é `oneshot` e não duplica lógica:

```ini
[Unit]
Description=Rotina diária de backup Borg
Wants=network-online.target
After=network-online.target local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/borg-backup run
TimeoutStartSec=infinity
SuccessExitStatus=0 1
```

`SuccessExitStatus=0 1` reconhece advertência válida sem ocultá-la dos relatórios.
Não há timeout de manutenção. SSH, DNS e demais serviços de rede permanecem
ativos.

## Timer

O modelo genérico é diário, persistente e possui jitter:

```ini
[Unit]
Description=Agendamento diário da rotina Borg Backup

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
```

`Persistent=true` pode disparar logo após boot quando uma ocorrência foi
perdida. `RandomizedDelaySec=30m` desloca o início, sem criar paralelismo dentro
da rotina. Em múltiplos hosts, escolha calendários distintos depois de medir
backup, manutenção e réplica; considere o pior caso mais jitter.

Valide antes de habilitar:

```bash
systemd-analyze verify /etc/systemd/system/borg-backup.service
systemd-analyze verify /etc/systemd/system/borg-backup.timer
systemd-analyze calendar daily
systemctl list-timers --all borg-backup.timer
```

Após instalar ou alterar units, execute `systemctl daemon-reload`. Habilite o
timer apenas depois do aceite de backup, restore e replicação:

```bash
systemctl enable --now borg-backup.timer
```

Para pausa administrativa, use `systemctl disable --now borg-backup.timer` e
confirme que o service não está em execução. Retome somente após resolver o gate.
Não execute `systemctl start borg-backup.service` apenas para simular semântica
de timer; valide o calendário e observe uma ocorrência automática real.

## Diagnóstico do agendamento

```bash
systemctl status borg-backup.timer borg-backup.service
systemctl show borg-backup.timer -p ActiveState -p NextElapseUSecRealtime
journalctl -u borg-backup.timer -u borg-backup.service --since today
```

Se o timer não disparar, verifique carga, calendário, timezone, próxima
ocorrência, condição persistente e falha anterior do service. Se disparar após
boot, determine se é comportamento esperado de `Persistent=true` antes de
intervir.

## Logrotate

Política distribuída:

```text
/var/log/borg-backup/backup.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
```

Valide a cópia em modo debug, que não efetua rotação:

```bash
logrotate -d /etc/logrotate.d/borg-backup
```

A rotação real pertence ao mecanismo do sistema. A solução não implementa
retenção própria de logs e não precisa reiniciar processo residente, pois abre o
arquivo a cada evento.
