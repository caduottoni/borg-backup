# Glossário

**Finalidade:** padronizar os termos usados na documentação da solução.

**Público-alvo:** todos os administradores, revisores e operadores.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Termos

**Archive:** snapshot lógico criado pelo Borg dentro de um repository, nomeado
por prefixo e timestamp UTC.

**Repository:** árvore de armazenamento gerenciada pelo Borg que contém config,
índices, segmentos e archives.

**Primary repository:** repository local no qual `borg create`, retenção e
compactação são executados.

**Cold replica:** cópia física passiva e integral da árvore do primary
repository, produzida somente sem escrita Borg concorrente.

**Incoming:** generation remota em construção, identificada pela execução e
ainda não promovida.

**Current:** última generation remota validada e promovida.

**Previous:** generation válida imediatamente anterior a `current`, mantida
como fallback.

**Generation:** árvore completa `repo` acompanhada de `generation.meta` fora do
repository Borg.

**Storage:** filesystem que hospeda repository ou raiz de réplica e é validado
por mountpoint, UUID, tipo, sentinela e capacidade.

**Sentinel:** arquivo estruturado de duas chaves que associa um storage a um ID
e à finalidade `borg-backup`.

**Dump:** export lógico de banco, validado antes de entrar no archive.

**Critical window:** intervalo entre a primeira mudança de estado de aplicação
e a confirmação do archive seguida da restauração dos estados.

**Application service:** unit explicitamente autorizada em `services.conf` para
interrupção durante a critical window.

**Protected service:** rede, firewall, SSH, DNS ou VPN, que o parser impede de
ser interrompido.

**Primary failure:** causa que impediu ou invalidou a etapa principal da
execução, preservada separadamente de falha de restauração.

**Warning:** resultado com artefato válido, mas capacidade baixa ou falha de
destino opcional; corresponde ao código 1.

**Receiver:** comando Bash forçado pelo SSH que implementa protocolo remoto
fechado e acesso restrito à raiz da réplica.

**Forced command:** comando fixado em `authorized_keys`, executado pelo SSH em
lugar de qualquer comando solicitado livremente pelo cliente.

**Custody:** controles, local e responsabilidade que mantêm material de
recuperação disponível fora do sistema protegido.

**Restore test:** extração e reconstrução controladas, em área isolada, usadas
para comprovar recuperabilidade.

**Fallback:** seleção deliberada de uma fonte válida anterior, como `previous`,
quando a fonte preferencial não pode ser aprovada.

**Gate:** condição objetiva e documentada que deve passar antes de uma etapa
dependente, especialmente quando há efeito destrutivo ou entrada em produção.
