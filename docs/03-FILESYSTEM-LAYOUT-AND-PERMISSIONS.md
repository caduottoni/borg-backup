# Layout de filesystem e permissões

**Finalidade:** definir a árvore FHS, os modos e as salvaguardas de armazenamento.

**Público-alvo:** administradores de implantação, segurança e operação.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Árvore operacional

```text
/etc/borg-backup/
├── backup.conf
├── sources.conf
├── excludes.conf
├── databases.conf
├── applications.conf
├── services.conf
├── replication.conf
├── replication.d/*.conf
├── secrets.conf
└── ssh/
    ├── known_hosts
    └── keys/<DESTINATION_ID>

/usr/local/sbin/borg-backup
/usr/local/lib/borg-backup/*.sh
/usr/local/lib/tmpfiles.d/borg-backup.conf
/etc/systemd/system/borg-backup.service
/etc/systemd/system/borg-backup.timer
/etc/logrotate.d/borg-backup

/var/lib/borg-backup/state/
├── last-success.state
└── replication/<DESTINATION_ID>.state
/var/log/borg-backup/
├── backup.log
├── last-run.report
└── last-success.report
/var/tmp/borg-backup/<EXECUTION_ID>.<SUFFIX>/{dumps,staging}/
/run/borg-backup/backup.lock

/srv/borg-storage/
├── .borg-storage
├── repositories/<HOST_ID>/repo/
└── replicas/<ORIGIN_ID>/
    ├── incoming-<EXECUTION_ID>/
    ├── current/{repo,generation.meta}
    ├── previous/{repo,generation.meta}
    └── state/
```

O repositório e a raiz de réplica podem usar outros caminhos absolutos seguros,
desde que a configuração, o mount e as salvaguardas permaneçam coerentes.

## Matriz de propriedade e modo

| Alvo | Owner:group | Modo | Observação |
|---|---|---:|---|
| `/etc/borg-backup` | `root:root` | `0750` | configuração administrativa |
| `*.conf` não secreto | `root:root` | `0640` | arquivo regular, sem symlink |
| `secrets.conf` | `root:root` | `0600` | credencial Borg local |
| `replication.d` | `root:root` | `0750` | ordem lexical de destinos |
| `ssh` e `ssh/keys` | `root:root` | `0700` | material SSH privado |
| chave privada por destino | `root:root` | `0600` | nunca entra no Borg |
| `ssh/known_hosts` | `root:root` | `0640` | base dedicada |
| `/usr/local/sbin/borg-backup` | `root:root` | `0755` | único comando público |
| módulos `*.sh` | `root:root` | `0644` | carregados, não executados diretamente |
| `/usr/local/lib/tmpfiles.d/borg-backup.conf` | `root:root` | `0644` | recria o runtime volátil |
| units e logrotate | `root:root` | `0644` | artefatos do sistema |
| `/var/lib/borg-backup/state` | `root:root` | `0750` | estado persistente mínimo |
| `/var/log/borg-backup` | `root:root` | `0750` | log e relatórios |
| `backup.log` e relatórios | `root:root` | `0640` | sem segredos |
| `/var/tmp/borg-backup` | `root:root` | `0700` | dumps e staging privados |
| área de execução | `root:root` | `0700` | nome aleatório sob raiz validada |
| `/run/borg-backup` | `root:root` | `0750` | estado volátil |
| sentinela | `root:root` | `0640` | exatamente duas atribuições |

`/run` é volátil. O diretório `/run/borg-backup` não pode depender da cópia de
uma árvore de staging nem da execução anterior ao boot. A instalação coloca a
regra comentada `borg-backup.conf` em `/usr/local/lib/tmpfiles.d/`, executa
`systemd-tmpfiles --create` para materializá-la e confirma `root:root 0750`.
O mesmo mecanismo o recria durante o boot e atende tanto o service quanto
comandos administrativos manuais.

A raiz receptora dedicada pertence à conta técnica que recebe aquela direção;
ACLs concedem apenas travessia nos ancestrais e leitura da sentinela. Ela não
deve acessar repositórios locais nem árvores de outras origens.

## Sentinela e mount

O arquivo `<STORAGE_MOUNT>/.borg-storage` contém exatamente:

```text
STORAGE_ID=<STORAGE_ID>
PURPOSE=borg-backup
```

Antes de qualquer escrita, a rotina confirma:

1. repositório existente, regular quanto à árvore e não simbólico;
2. mountpoint retornado por `findmnt` igual à raiz da sentinela;
3. UUID igual ao declarado;
4. filesystem `ext4`;
5. owner, group, modo e conteúdo exatos da sentinela;
6. espaço livre maior ou igual ao piso;
7. ausência de relação recursiva entre fontes e repositório.

Isso é especialmente importante quando `/srv/borg-storage` é um mount filho de
`/srv`: a ausência do disco não pode transformar o diretório subjacente em alvo
de escrita.

## Paths e symlinks

Configuração, módulos, diretórios gerenciados, storage, chaves e sentinela não
podem ser links simbólicos. Paths administrativos críticos devem ser absolutos,
sem componentes ambíguos, metacaracteres ou destino raiz. A limpeza temporária
usa uma raiz canônica validada e nunca remove a própria raiz de temporários.

## Reconciliação de temporários abandonados

Uma execução que produzir dumps adquire primeiro o lock global exclusivo, cria
e valida sua própria área temporária e só então reconcilia filhos deixados em
`/var/tmp/borg-backup`, antes de interromper serviços ou aplicações. A posse do
lock prova que nenhuma outra execução legítima está ativa; a área corrente deve
ser reencontrada, validada e preservada durante a reconciliação.

Somente um filho direto cujo nome obedeça ao formato fechado de execução, cujo
caminho canônico permaneça sob a raiz, que seja diretório real sem symlink e
tenha `root:root 0700` pode ser classificado como abandonado e removido. Entrada
desconhecida ou metadado divergente bloqueia a operação e exige intervenção; a
rotina nunca amplia o alvo, remove a própria raiz nem apaga a área corrente.
Essa reconciliação a cada novo ciclo é a política de expiração. A capacidade de
`/var/tmp` deve integrar o monitoramento operacional do host.

## Exclusões obrigatórias

Devem ser excluídos literalmente:

- o próprio repositório;
- `/var/tmp/borg-backup`;
- `/etc/borg-backup/secrets.conf`;
- `/etc/borg-backup/ssh/keys`.

Também se excluem o cache Borg, credenciais/caches de ferramentas de IA e o
segredo que abre a mídia de custódia quando seus caminhos estiverem sob alguma
fonte. Para cada SQLite declarado, o arquivo vivo, `-wal` e `-shm` são exclusões
obrigatórias; o dump validado é a fonte canônica.
