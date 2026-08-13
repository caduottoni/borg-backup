# Checklist pós-instalação

- [ ] Validar plataforma e dependências conforme `../docs/02-REQUIREMENTS-AND-DEPENDENCIES.md`.
- [ ] Validar `MANIFEST.sha256` antes de copiar qualquer arquivo.
- [ ] Instalar somente os paths aprovados com owner e mode do manifesto FHS.
- [ ] Instalar e aplicar `borg-backup.conf` com `systemd-tmpfiles --create`.
- [ ] Confirmar `/run/borg-backup` como `root:root 0750`, inclusive após reboot controlado.
- [ ] Criar `secrets.conf` administrativamente com owner `root:root` e modo `0600`.
- [ ] Confirmar storage externo, UUID, filesystem, sentinela, espaço e mountpoint.
- [ ] Revisar configuração e dependências sem exigir `validate` antes de o repositório existir.
- [ ] Inicializar o repositório com `repokey-blake2` e estabelecer a custódia aprovada.
- [ ] Executar `borg-backup validate` somente após `borg init` e exigir `EXECUTION=OK`.
- [ ] Confirmar que temporários abandonados são reconciliados somente sob o lock global.
- [ ] Validar units e logrotate sem iniciar serviços.
- [ ] Executar backup e restauração controlados antes de habilitar replicação.
- [ ] Validar replicação e gerações antes de ativar o timer.
- [ ] Registrar aceite operacional; não manter valores secretos no relatório.
