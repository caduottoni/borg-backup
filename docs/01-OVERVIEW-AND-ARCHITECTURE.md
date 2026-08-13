# Visão geral e arquitetura

**Finalidade:** explicar o problema, os componentes e as garantias arquiteturais da solução.

**Público-alvo:** administradores, arquitetos, revisores e mantenedores.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Problema resolvido

A solução transforma fontes declaradas e dumps lógicos validados em archives
Borg verificáveis. Ela coordena uma janela crítica de consistência, aplica a
retenção nativa e produz réplicas frias sem misturar o estado do backup
principal com o dos destinos remotos.

## Princípios

- Bash é a única linguagem operacional.
- A execução é sequencial e protegida por um lock global.
- A configuração é dado literal; nunca é executada pelo shell.
- Fontes, bancos, aplicações, services e destinos são explícitos.
- Não há autodiscovery, workflow genérico, plugins ou paralelismo.
- Cada módulo possui responsabilidade pequena e falha de forma segura.
- Estado persistente é mínimo; temporários pertencem a uma execução única.
- O repositório principal e as réplicas são semanticamente independentes.

## Componentes

```text
/usr/local/sbin/borg-backup
        |
        +-- common.sh         caminhos, permissões, temporários e flock
        +-- config.sh         parser literal e validações declarativas
        +-- logging.sh        eventos, relatórios e estado atômico
        +-- services.sh       estado inicial e restauração de units
        +-- applications.sh   Nextcloud e sincronização online BIND
        +-- databases.sh      dumps PostgreSQL e SQLite
        +-- backup.sh         Borg create/info e capacidade local
        +-- maintenance.sh    list/check/prune/compact
        +-- replication.sh    transporte sequencial e consolidação
        +-- replica-receiver.sh  protocolo SSH remoto fechado
```

O ponto de entrada sanitiza ambiente, aliases e funções herdadas; fixa locale e
`PATH`; carrega apenas módulos administrativos instalados; adquire o lock; e
delega cada operação. Configurações nunca passam por `source`, `eval` ou
substituição de comando.

## Fluxo completo de `run`

1. Validar layout FHS, configuração, dependências, storage, repositório e alvos.
2. Registrar o estado inicial de todas as units e aplicações declaradas.
3. Parar somente units declaradas que estavam ativas.
4. Habilitar manutenção Nextcloud somente quando necessário.
5. Gerar e validar os dumps configurados.
6. Executar `rndc sync` para cada BIND, sem interromper DNS.
7. Executar `borg create`; somente retorno zero é válido.
8. Confirmar o archive exato com `borg info`; somente retorno zero é válido.
9. Restaurar units e aplicações exatamente ao estado inicial.
10. Executar `borg prune` e, após sucesso, `borg compact`.
11. Reavaliar a capacidade local.
12. Manter o lock nativo Borg com `borg with-lock` durante todas as réplicas.
13. Processar destinos remotos pela ordem lexical, sem interromper os seguintes
    quando um destino falhar.
14. Consolidar relatório, estado mínimo, limpeza e código de saída.

Qualquer falha anterior à confirmação do archive impede manutenção e
replicação. Uma falha de restauração de estado é crítica e também bloqueia as
etapas seguintes. Uma advertência de capacidade após uma operação válida não
invalida retroativamente o backup ou a réplica.

## Locks

O lock local em `/run/borg-backup/backup.lock` usa `flock` sobre descritor e é
liberado pelo kernel na saída. Ele impede execuções incompatíveis concorrentes.
O Borg conserva seu lock nativo durante a leitura do repositório para réplica.
Cada receptor mantém ainda um lock próprio na raiz dedicada. Esses três níveis
protegem responsabilidades diferentes e não substituem uns aos outros.

## Replicação e generations

Cada destino recebe uma árvore integral do repositório em
`incoming-<EXECUTION_ID>/repo`. O `rsync` pode reutilizar arquivos imutáveis de
`current/repo` por `--link-dest`, mas nunca modifica `current` in-place. Depois
da validação básica, o receptor promove no mesmo filesystem:

```text
previous  ← current anterior
current   ← incoming validada
```

`generation.meta` fica ao lado de `repo`, não dentro do repositório Borg. Um
estado ambíguo ou uma generation inválida é preservado para diagnóstico e
bloqueia promoção automática. Recuperação ou `borg check` devem ocorrer numa
cópia independente, nunca sobre `current` ou `previous` com hard links vivos.

## Fronteiras de confiança

```text
administrador/root local
        |
        +-- configuração e segredo Borg locais
        +-- repositório principal ext4
        +-- chave SSH privada de uma direção
                    |
                    v
           sshd + authorized_keys restrito
                    |
           receptor sem shell irrestrito
                    |
           raiz remota exclusiva da origem
```

O emissor confia numa host key previamente registrada. O receptor confia apenas
na chave pública autorizada, na origem permitida e no protocolo fechado. A
mídia de custódia permanece fora do ciclo diário.

## Limitações e fora de escopo

A implementação não monta storage, não cria filesystems, não inicializa
repositórios, não instala dependências, não repara Borg, não executa backup
físico de SGBD, não oferece shell remoto, não envia notificações e não gerencia
custódia offline automaticamente. Apenas PostgreSQL e SQLite são bancos
suportados; apenas Nextcloud e BIND possuem adaptadores técnicos.
