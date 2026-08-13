# Especificação pública do Borg Backup

**Identificador:** `PUB-SPEC-1`

**Estado:** normativa para o código, os exemplos, os testes e o empacotamento deste repositório.

**Público-alvo:** mantenedores, administradores Debian, revisores de segurança e responsáveis por recuperação.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x.

## 1. Como interpretar este documento

As palavras **DEVE**, **NÃO DEVE**, **DEVERIA** e **PODE** indicam, nessa
ordem, obrigação, proibição, recomendação e permissão. Cada requisito possui um
identificador estável `PUB-REQ-*`. Mudanças de comportamento exigem atualizar
este documento, a matriz de rastreabilidade e os testes afetados.

A versão do produto é a registrada no arquivo `VERSION` da raiz. A licença do
repositório é `GPL-3.0-or-later`. Nenhum inventário de instalação, endereço de
infraestrutura, credencial ou evidência operacional integra esta especificação.

## 2. Objetivo, escopo e limites

O produto coordena backups Borg locais em Debian 13. Ele reúne fontes
declaradas, dumps lógicos validados e estados consistentes de aplicações;
confirma o archive criado; aplica retenção; e, quando configurado, replica a
árvore integral do repositório por SSH para destinos restritos.

- **PUB-REQ-001 — Plataforma.** A implementação operacional DEVE usar Bash 5.x
  e BorgBackup 1.4.x em Debian GNU/Linux 13.
- **PUB-REQ-002 — Escopo funcional.** O produto DEVE oferecer as operações
  administrativas `validate`, `run`, `list`, `check`, `prune` e `replicate`.
- **PUB-REQ-003 — Execução previsível.** A execução DEVE ser sequencial, com
  fontes, bancos, aplicações, units e destinos declarados explicitamente; NÃO
  DEVE haver descoberta automática, plugins, paralelismo ou hooks arbitrários.
- **PUB-REQ-004 — Limites.** O produto NÃO DEVE formatar, cifrar ou montar
  discos; inicializar repositórios; instalar dependências; reparar Borg;
  alterar `authorized_keys`; ou enviar notificações externas automaticamente.
- **PUB-REQ-005 — Adaptadores suportados.** A primeira série pública DEVE
  suportar PostgreSQL, objetos globais PostgreSQL, SQLite, Nextcloud e BIND. Os
  demais SGBDs e aplicações ficam fora do contrato até nova especificação.

## 3. Disciplina de implementação

- **PUB-REQ-006 — Ambiente.** O ponto de entrada DEVE usar `set -Eeuo pipefail`,
  `umask 077`, locale `C` e `PATH` administrativo fixo; DEVE remover variáveis,
  funções e aliases herdados que possam alterar Borg, PostgreSQL, rsync ou SSH.
- **PUB-REQ-007 — Configuração como dado.** Arquivos de configuração NÃO DEVEM
  passar por `source`, `eval` ou expansão de shell. O parser DEVE aceitar apenas
  a gramática literal documentada e rejeitar chaves desconhecidas, duplicatas,
  valores vazios, quebras de linha e metacaracteres de expansão.
- **PUB-REQ-008 — Código carregável.** Somente módulos regulares, não
  simbólicos, instalados em `/usr/local/lib/borg-backup` PODEM ser carregados
  pelo ponto de entrada.
- **PUB-REQ-009 — Concorrência.** Toda operação mutável DEVE adquirir um lock
  global por `flock`; o lock nativo Borg e o lock do receptor remoto DEVEM ser
  preservados em seus respectivos limites.

## 4. Layout, propriedade e temporários

- **PUB-REQ-010 — Layout FHS.** Executáveis DEVEM residir em `/usr/local/sbin`,
  módulos em `/usr/local/lib/borg-backup`, configuração em
  `/etc/borg-backup`, estado em `/var/lib/borg-backup`, logs em
  `/var/log/borg-backup`, lock em `/run/borg-backup` e temporários em
  `/var/tmp/borg-backup`.
- **PUB-REQ-011 — Permissões.** A instalação DEVE pertencer a `root:root`.
  Configurações comuns DEVEM usar `0640`; segredo e chaves de identidade,
  `0600`; diretórios sensíveis, `0700`; estado e log, modos restritivos
  documentados. Symlinks em caminhos gerenciados DEVEM ser recusados.
- **PUB-REQ-012 — Runtime após boot.** Uma regra `tmpfiles.d` DEVE criar
  `/run/borg-backup` como `root:root 0750` antes do primeiro uso.
- **PUB-REQ-013 — Temporários por execução.** Cada execução DEVE usar diretório
  exclusivo, criado com modo `0700`, sob `/var/tmp/borg-backup`; arquivos
  parciais NÃO DEVEM se tornar entradas válidas antes da validação e da
  renomeação atômica.
- **PUB-REQ-014 — Reconciliação.** Sob lock global exclusivo, o produto DEVE
  remover somente diretórios temporários reconhecíveis e pertencentes a
  execuções abandonadas. Symlinks, tipos inesperados ou metadados divergentes
  DEVEM causar falha segura, sem travessia nem remoção ampla.

## 5. Contrato de configuração

Arquivos distribuídos em `examples/etc/borg-backup` são modelos sintéticos. Na
instalação, a extensão `.example` é removida somente depois de preencher e
validar valores específicos do ambiente.

- **PUB-REQ-015 — Configuração global.** `backup.conf` DEVE declarar
  `BORG_REPOSITORY`, `ARCHIVE_PREFIX`, `BORG_COMPRESSION`, `KEEP_DAILY`,
  `KEEP_WEEKLY`, `KEEP_MONTHLY`, `REPOSITORY_FILESYSTEM_UUID`,
  `REPOSITORY_FILESYSTEM_TYPE`, `REPOSITORY_STORAGE_ID`,
  `REPOSITORY_MIN_FREE_MIB`, `REPOSITORY_SENTINEL` e `FILE_LOG_ENABLED`.
- **PUB-REQ-016 — Fontes e exclusões.** `sources.conf` e `excludes.conf` DEVEM
  conter uma entrada literal por linha. Fontes DEVEM ser caminhos absolutos,
  existentes e seguros. O repositório, temporários, segredo, chaves e cache
  Borg DEVEM ficar excluídos.
- **PUB-REQ-017 — Bancos.** `databases.conf` DEVE aceitar apenas os registros
  `postgresql|ID|DATABASE|USER|SOCKET|PORT`,
  `postgresql-globals|ID|USER|SOCKET|PORT` e `sqlite|ID|PATH`.
- **PUB-REQ-018 — Aplicações.** `applications.conf` DEVE aceitar somente
  `nextcloud|ID|DIRECTORY|USER` e `bind|ID|DIRECTORY|USER`.
- **PUB-REQ-019 — Units.** `services.conf` DEVE conter uma unit de aplicação
  por linha. SSH, DNS, rede, firewall e VPN DEVEM ser rejeitados como alvos de
  parada.
- **PUB-REQ-020 — Segredo Borg.** `secrets.conf` DEVE conter somente
  `BORG_PASSPHRASE`, com modo `0600`, e seu valor NÃO DEVE aparecer em logs,
  relatórios, erros, exemplos efetivos ou manifestos.
- **PUB-REQ-021 — Replicação.** `replication.conf` DEVE declarar habilitação,
  origem, verificação e piso de espaço. Cada arquivo regular em
  `replication.d` DEVE declarar ID, habilitação, obrigatoriedade, host, conta,
  porta, destino, identidade, `known_hosts` e modo de verificação.
- **PUB-REQ-022 — Validação integral.** Antes de qualquer mutação, o produto
  DEVE validar arquivos, dono, modos, gramática, relações entre valores,
  dependências condicionais, storage, sentinela, repositório e destinos.

## 6. Storage, capacidade e Borg

- **PUB-REQ-023 — Identidade do storage.** O repositório local DEVE estar em um
  filesystem `ext4` cujo UUID corresponda à configuração. O mount exato DEVE
  conter sentinela regular `root:root 0640` com o ID e a finalidade esperados.
  A simples existência do diretório NÃO comprova o storage.
- **PUB-REQ-024 — Capacidade.** O piso de espaço livre configurado DEVE ser
  verificado antes de operações que aumentem dados e reavaliado depois. Falha
  de precheck DEVE impedir a mutação; queda posterior DEVE ser registrada como
  advertência sem invalidar uma geração já confirmada.
- **PUB-REQ-025 — Criação.** `run` DEVE executar `borg create` com compressão,
  fontes e exclusões declaradas. Somente código zero é sucesso.
- **PUB-REQ-026 — Confirmação.** O archive recém-criado DEVE ser confirmado por
  consulta exata com `borg info`. Somente após essa confirmação o backup
  principal é válido.
- **PUB-REQ-027 — Manutenção.** `prune` DEVE usar retenções declaradas e
  `compact` só PODE ocorrer após prune bem-sucedido. Falha antes da confirmação
  do archive DEVE bloquear manutenção e replicação dependentes.
- **PUB-REQ-028 — Check seguro.** `check` DEVE usar o mecanismo nativo do Borg.
  Reparo automático é proibido; diagnóstico destrutivo ou recuperação DEVEM
  ocorrer em cópia independente.

## 7. Consistência de aplicações e bancos

- **PUB-REQ-029 — Preservação de estado.** Antes de modificar uma unit ou
  aplicação, o produto DEVE registrar seu estado inicial. Na saída normal,
  falha ou sinal, DEVE tentar restaurar cada recurso exatamente a esse estado.
- **PUB-REQ-030 — Janela crítica.** Somente units declaradas que estavam ativas
  PODEM ser paradas. Serviços de SSH, DNS, rede, firewall e VPN NÃO DEVEM ser
  interrompidos. Falha de restauração é crítica e bloqueia etapas seguintes.
- **PUB-REQ-031 — Nextcloud e BIND.** Nextcloud DEVE entrar e sair do modo de
  manutenção conforme seu estado inicial. BIND DEVE usar sincronização online
  por `rndc sync`, sem parada do serviço DNS.
- **PUB-REQ-032 — Dumps.** Dumps DEVEM nascer como parciais no diretório da
  execução, ser validados por ferramenta apropriada e só então receber nome
  final. PostgreSQL DEVE usar formato custom; objetos globais, SQL textual;
  SQLite, cópia lógica consistente pela interface do próprio SQLite.
- **PUB-REQ-033 — Limpeza.** Dumps e saídas transitórias DEVEM ser removidos ao
  final quando a restauração de recursos não depender mais deles. Falhas de
  limpeza DEVEM ser registradas e resultar em estado conservador.

## 8. Replicação fria e receptor SSH

- **PUB-REQ-034 — Transporte restrito.** O emissor DEVE usar identidade
  dedicada, `BatchMode`, verificação estrita de host key e arquivo
  `known_hosts` declarado. O receptor DEVE ser exposto por forced command, sem
  shell irrestrito nem encaminhamentos.
- **PUB-REQ-035 — Protocolo fechado.** O receptor DEVE aceitar somente a
  gramática e as operações internas documentadas pelo código. IDs e caminhos
  DEVEM ser validados; a raiz remota DEVE ser exclusiva para uma origem.
- **PUB-REQ-036 — Gerações.** Cada envio DEVE construir
  `incoming-<EXECUTION_ID>/repo`. Após validação, promoção atômica no mesmo
  filesystem DEVE resultar em `current` válido e, quando existente, em
  `previous` válido. Metadados de geração DEVEM ficar fora do repositório Borg.
- **PUB-REQ-037 — Integridade.** `rsync` PODE reutilizar arquivos imutáveis de
  `current/repo` por hard link, mas NÃO DEVE modificar `current` in-place. O
  receptor DEVE validar estrutura, metadados e modo de verificação antes da
  promoção.
- **PUB-REQ-038 — Independência.** Destinos DEVEM ser processados em ordem
  lexical. Uma falha NÃO DEVE impedir a tentativa dos destinos seguintes. A
  obrigatoriedade de cada destino DEVE determinar se o resultado agregado é
  advertência ou falha crítica.

## 9. Observabilidade, estado e códigos

- **PUB-REQ-039 — Eventos.** Eventos DEVEM ir para `stderr` e, sob systemd, ao
  journal. Log em arquivo PODE ser habilitado. Mensagens DEVEM ser concisas,
  sanitizadas e não reproduzir configuração sensível nem comandos completos.
- **PUB-REQ-040 — Relatórios atômicos.** Relatórios e estado mínimo DEVEM ser
  escritos em arquivo temporário regular no mesmo filesystem, validados e
  publicados por renomeação atômica. Symlinks e arquivos com modo ou dono
  inesperado DEVEM ser recusados.
- **PUB-REQ-041 — Resultado.** Os códigos públicos DEVEM ser `0` para sucesso,
  `1` para execução válida com advertência, `2` para falha crítica e `64` para
  uso inválido. O relatório DEVE distinguir backup, archive, manutenção,
  restauração, replicação, capacidade e resultado agregado.
- **PUB-REQ-042 — Agendamento e rotação.** O pacote DEVE fornecer unit e timer
  systemd, regra `tmpfiles.d` e configuração logrotate. O timer só DEVE ser
  habilitado após configuração, validação, backup manual e teste de restore.

## 10. Restauração, segurança e ciclo de release

- **PUB-REQ-043 — Restore isolado.** Testes de recuperação DEVEM extrair para
  destino vazio e isolado. Bancos DEVEM ser restaurados em instâncias ou
  arquivos temporários; réplicas com hard links DEVEM ser copiadas antes de
  qualquer `borg check` ou intervenção.
- **PUB-REQ-044 — Custódia.** Passphrase, exportação da chave Borg, identidades
  SSH e cópias de custódia DEVEM ter controles separados. Nenhum desses
  materiais PODE ser incluído no repositório Git ou no pacote público.
- **PUB-REQ-045 — Conteúdo publicável.** Código, exemplos e fixtures DEVEM ser
  genéricos e sintéticos. O repositório NÃO DEVE conter logs, relatórios de
  execução, dumps, inventários, nomes internos, IDs reais, dados pessoais ou
  caminhos de diretórios pessoais.
- **PUB-REQ-046 — Pacote.** O pacote DEVE possuir versão, licença, manifesto de
  hashes e layout contratual; NÃO DEVE conter arquivos extras, symlinks que
  escapem da raiz ou material operacional.
- **PUB-REQ-047 — Reprodutibilidade.** Duas construções a partir do mesmo commit
  e ambiente declarado DEVEM produzir árvores equivalentes e artefatos com
  conteúdo determinístico. O tooling DEVE derivar caminhos da raiz do próprio
  repositório.
- **PUB-REQ-048 — Testes.** A suíte pública DEVE cobrir análise estática,
  parser, lifecycle principal, bancos, temporários, systemd/tmpfiles,
  replicação e contrato dos artefatos. Dependências ausentes DEVEM gerar skip
  explícito quando o teste permitir; gates de release exigem Borg real.
- **PUB-REQ-049 — Upgrade e rollback.** Uma atualização DEVE preservar
  configuração e segredos existentes, validar antes de habilitar o timer e
  oferecer retorno dos arquivos gerenciados. Desinstalação NÃO DEVE remover
  repositórios, archives ou configuração sem autorização separada.
- **PUB-REQ-050 — Documentação verificável.** Todo requisito DEVE apontar para
  implementação, teste e documentação na
  [matriz de rastreabilidade](../SOURCE-TO-DOCUMENT-MATRIX.md). O
  [manifesto documental](../DOCUMENTATION-MANIFEST.tsv) DEVE cobrir todos os
  documentos canônicos, exceto ele próprio, para evitar circularidade.

## 11. Sequência normativa de `run`

```text
validar layout/configuração/dependências/storage/repositório/destinos
→ adquirir lock e reconciliar temporários reconhecidos
→ registrar estados iniciais
→ preparar aplicações e parar somente units declaradas
→ gerar e validar dumps
→ criar e confirmar archive
→ restaurar todos os estados
→ prune e compact, quando elegíveis
→ reavaliar capacidade
→ replicar destinos em sequência sob lock Borg
→ publicar relatório/estado, limpar temporários e liberar lock
```

Uma falha crítica interrompe somente etapas que dependem do resultado falho.
A restauração de recursos e a finalização segura sempre devem ser tentadas. O
backup principal e cada destino de réplica mantêm estados independentes.

## 12. Critério de conformidade

Uma revisão de release só pode declarar conformidade com `PUB-SPEC-1` quando:

1. todos os `PUB-REQ-*` aplicáveis estiverem `COVERED` na matriz;
2. a suíte pública terminar sem falhas inesperadas;
3. os exemplos permanecerem sintéticos e desabilitados por padrão quando
   produzirem efeito externo;
4. a varredura do commit e do tar de release não encontrar material proibido;
5. os hashes documentais e do pacote forem regenerados a partir da árvore
   exata aprovada; e
6. uma instalação limpa puder executar `validate`, backup manual e restore
   isolado antes da habilitação do timer.
