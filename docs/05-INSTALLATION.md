# Instalação

**Finalidade:** descrever uma implantação genérica, controlada por gates e validada antes da produção.

**Público-alvo:** administradores Linux autorizados a provisionar storage e instalar software local.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Regra geral

Separe implantação de produto, provisionamento de storage e entrada em
produção. Cada gate deve registrar alvo, autorização, comandos, resultado e
critério de parada. O timer permanece desabilitado até backup, restauração e
replicação aprovados.

## Gate 1 — pré-flight

1. Confirmar Debian 13, arquitetura, relógio e espaço.
2. Verificar versões e dependências descritas em
   [Requisitos e dependências](02-REQUIREMENTS-AND-DEPENDENCIES.md).
3. Confirmar que não existe execução ou rotina legada concorrente.
4. Inventariar fontes, exclusões, bancos, aplicações e units sem autodiscovery.
5. Registrar hostname, storage ID, UUID esperado, paths e destinos no as-built.
6. Validar hashes do pacote e revisar o plano de mudanças.

Pare diante de alvo ambíguo, dependência ausente, configuração não aprovada,
erro de I/O, storage montado inesperadamente ou ausência de plano de retorno.

## Gate 2 — storage

Criar ou substituir filesystem é uma operação destrutiva. Exige autorização
específica e reconfirmação ao vivo de modelo, serial, capacidade, caminho
estável por `/dev/disk/by-id`, partição, filesystem e estado de montagem. Nunca
decida apenas por um nome volátil `/dev/sdX`.

Exemplo sintático, deliberadamente parametrizado e não executável sem valores
administrativos explícitos:

```bash
readonly DEVICE_BY_ID_PARTITION='<DEVICE_BY_ID_PARTITION>'
readonly STORAGE_LABEL='<STORAGE_LABEL>'

# OPERAÇÃO DESTRUTIVA: execute somente após autorização e pre-flight repetido.
mkfs.ext4 -L "$STORAGE_LABEL" "$DEVICE_BY_ID_PARTITION"
```

Depois de criar ext4, obtenha o UUID real por consulta. Registre uma entrada
fstab aprovada; opções como `nodev`, `nosuid`, `noexec`, `nofail` e automount
são decisões de implantação, não inferências do runtime. Exemplo de artefato:

```fstab
UUID=<FILESYSTEM_UUID> /srv/borg-storage ext4 <APPROVED_MOUNT_OPTIONS> 0 2
```

Valide sintaxe, execute o mecanismo administrativo de mount e confirme com
`findmnt`. A rotina diária não monta o disco.

Crie a sentinela somente no filesystem confirmado:

```text
STORAGE_ID=<STORAGE_ID>
PURPOSE=borg-backup
```

Aplique `root:root 0640` e valide mountpoint, UUID, ext4, conteúdo e espaço.

## Gate 3 — instalação FHS

1. Produzir snapshot recuperável apenas dos arquivos gerenciados já existentes.
2. Verificar que alvos e ancestrais não são symlinks inesperados.
3. Criar diretórios com modos definidos no layout.
4. Instalar módulos e arquivos por cópia temporária no mesmo filesystem,
   `fsync` quando disponível e rename atômico.
5. Instalar configs não secretas ainda com replicação desabilitada.
6. Instalar a regra `tmpfiles.d`, unit, timer e logrotate sem habilitar o timer.
7. Executar o comando abaixo e confirmar `/run/borg-backup` como
   `root:root 0750`:

   ```bash
   systemd-tmpfiles --create /usr/local/lib/tmpfiles.d/borg-backup.conf
   ```
8. Executar `bash -n`, validação estática do parser,
   `systemd-analyze verify` e logrotate em debug.
9. Comparar os hashes instalados aos arquivos aprovados.

Se a validação falhar, reverta somente os arquivos gerenciados a partir do
snapshot e preserve logs da tentativa. Não toque no storage para corrigir uma
falha de instalação de código.

## Gate 4 — configuração e segredo

Preencha os arquivos conforme a
[Referência de configuração](06-CONFIGURATION-REFERENCE.md). Crie
`secrets.conf` diretamente no destino `root:root 0600`, sem linha de comando
que revele o valor e sem arquivo intermediário persistente. Neste gate, confira
sintaxe declarativa, chaves, modos, paths, storage e dependências sem executar o
subcomando público `validate`: ele consulta o repositório com `borg info` e, por
contrato, não pode ter sucesso antes de `borg init`.

## Gate 5 — repositório e custódia

Inicialize um repositório novo somente depois das salvaguardas de storage. A
criptografia normativa é `repokey-blake2`; a credencial deve chegar ao processo
por ambiente mínimo e nunca por argumento visível. Exporte a chave Borg,
verifique o export e estabeleça custódia offline independente juntamente com a
credencial. O material que destranca o repositório não entra nele.

Depois de `borg init` e da confirmação da custódia, execute:

```bash
/usr/local/sbin/borg-backup validate
```

Exija código zero e `EXECUTION=OK`. Qualquer falha impede o primeiro backup. A
sequência normativa é, portanto, configurar e revisar → inicializar o
repositório → validar integralmente; nunca exigir sucesso de `validate` contra
um repositório ainda inexistente.

Mídia LUKS2 usa a cadeia `dispositivo → LUKS2 → mapeamento → ext4`. Tanto
`luksFormat` quanto `mkfs` são destrutivos e precisam de gate próprio. A mídia
offline e a segunda custódia da credencial LUKS não participam do backup diário.

## Gate 6 — primeiro backup e restauração

1. Manter replicação e timer desabilitados.
2. Executar `validate`.
3. Executar manualmente `borg-backup run` sob autorização.
4. Exigir archive confirmado, serviços restaurados, manutenção válida e
   relatório sem falha crítica.
5. Restaurar arquivos e cada dump numa área isolada.
6. Validar metadados, PostgreSQL efêmero e SQLite conforme o runbook.
7. Registrar `PASS` antes de prosseguir.

## Gate 7 — replicação

Provisione conta técnica, chave dedicada, `known_hosts`, comando forçado, ACL e
raiz exclusiva. Teste o receptor fechado. Habilite um destino por vez, execute
`replicate`, valide `current`, faça segunda geração, valide `previous` e prove
fallback numa cópia independente.

## Gate 8 — agendamento

Meça backup completo, primeira réplica e ciclo incremental. Escolha horários
sem sobreposição intencional, aplique `RandomizedDelaySec`, valide o calendário
e só então habilite o timer. Observe pelo menos um ciclo automático completo
antes do handoff.
