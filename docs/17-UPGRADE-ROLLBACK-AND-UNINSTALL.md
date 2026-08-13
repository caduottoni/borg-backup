# Upgrade, rollback e desinstalação

**Finalidade:** definir mudanças de ciclo de vida sem perder configuração ou dados válidos.

**Público-alvo:** administradores de release, implantação e recuperação.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Upgrade

1. Pausar o timer e confirmar que o service não está ativo.
2. Verificar versão e manifesto do pacote candidato.
3. Comparar `VERSION`, notas de release e compatibilidade do formato de configuração.
4. Criar snapshot recuperável dos arquivos gerenciados em `/etc`, `/usr/local`,
   units e logrotate; não copiar valor secreto para evidência.
5. Validar o pacote numa árvore staged.
6. Instalar cada arquivo por escrita temporária no mesmo filesystem e rename.
7. Preservar configs locais, segredo, chaves e `known_hosts`, salvo migração
   explicitamente aprovada.
8. Aplicar owner/mode normativos e executar `bash -n`.
9. Executar `systemd-analyze verify`, `systemctl daemon-reload`, logrotate debug
   e `borg-backup validate`.
10. Executar backup manual e restore adequado antes de retomar o timer.

Não faça upgrade durante `run`, `prune`, `check` ou `replicate`. O instalador
deve recusar lock ativo e arquivo divergente não previsto.

## Rollback

Rollback de código/configuração é possível quando a versão anterior suporta o
mesmo formato declarativo e a série Borg/repository format em uso. Restaure
somente arquivos gerenciados, reaplique modos, faça `daemon-reload` e valide.

Não reverta formato de repositório, não apague archive válido criado pela versão
nova e não substitua estado de aplicação por snapshot administrativo. Preserve
reports, logs e estado necessários a explicar a falha. Se uma migração de
configuração não for reversível, pare e elabore plano específico.

## Desinstalação

1. Desabilitar e parar apenas `borg-backup.timer`.
2. Confirmar que `borg-backup.service` não está executando.
3. Registrar o último archive e generations recuperáveis.
4. Remover somente arquivos de código, units e logrotate gerenciados.
5. Executar `systemctl daemon-reload`.
6. Decidir explicitamente sobre configs e estado; preservar por padrão.
7. Verificar ausência de timer/cron concorrente deixado pelo produto.

Por padrão, não remover:

- repositórios e réplicas;
- configs, segredos e chaves;
- material de custódia;
- reports/logs exigidos por retenção administrativa;
- mounts, fstab, sentinelas ou filesystems;
- contas e `authorized_keys` de réplica.

Esses itens exigem decisões independentes porque podem ser necessários à
recuperação. A desinstalação nunca desmonta, formata, executa prune/delete,
remove conta remota ou apaga storage automaticamente.

## Checklist pós-remoção

- timer e service ausentes/inativos;
- nenhum processo/lock da solução ativo;
- repositórios e generations preservados e identificados;
- segredo/custódia protegidos;
- rollback documentado ou decisão de retenção registrada;
- monitoramento atualizado sem ocultar o fim da rotina;
- plano para continuidade do backup aprovado.
