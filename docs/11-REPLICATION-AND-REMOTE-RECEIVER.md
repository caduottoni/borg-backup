# Replicação fria e receptor remoto

**Finalidade:** explicar transporte, generations, protocolo SSH restrito e recuperação.

**Público-alvo:** administradores de backup, SSH e recuperação de desastre.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Modelo

A réplica é uma cópia física integral e passiva do repositório principal. Ela
não cria archive, não aplica retenção e não altera o resultado do backup
principal. A primeira transferência envia praticamente toda a árvore; ciclos
seguintes usam rsync e hard links para reduzir tráfego e espaço, mantendo cada
generation logicamente completa.

## Pré-condições

- backup principal confirmado e manutenção concluída;
- lock global local e `borg with-lock` ativos;
- destino explícito, único e habilitado;
- ext4, UUID, sentinela e piso remoto válidos;
- conta técnica sem `sudo` ou senha interativa;
- chave ED25519 dedicada à direção;
- host key verificada em arquivo dedicado;
- raiz exclusiva e nenhuma operação concorrente.

## Transporte

O SSH usa conjunto fechado: `BatchMode=yes`, `IdentitiesOnly=yes`,
`StrictHostKeyChecking=yes`, `UserKnownHostsFile` dedicado, timeout e tentativas
limitados, forwardings desabilitados e sem PTY. Não se usa
`StrictHostKeyChecking=no`.

O rsync preserva recursão, links, permissões, tempos e hard links; usa diretório
parcial, atualização postergada e `fsync`. Não usa `--inplace` nem opções livres
vindas da configuração. Se houver `current` válida, `--link-dest` aponta para
`current/repo`. Um segundo rsync em dry-run deve apresentar zero diferenças.

## Protocolo fechado

O emissor só solicita operações administrativas reconhecidas:

```text
prepare <EXECUTION_ID> <ORIGIN_ID> <MIN_FREE_MIB>
validate <EXECUTION_ID> <FILE_COUNT> <FILE_BYTES>
promote <EXECUTION_ID>
abort <EXECUTION_ID>
status
```

O receptor também aceita exclusivamente os dois formatos de argv servidor
rsync que o transporte real necessita. Shell, opção extra, path divergente,
`--inplace`, origem divergente ou execução concorrente retornam código 2.

## `incoming`, `current` e `previous`

`prepare` cria `incoming-<EXECUTION_ID>/repo` vazio e um token ativo. Depois do
transporte, `validate` confirma estrutura Borg mínima, contagem de arquivos,
bytes e dry-run; então grava `generation.meta` com formato, origem, execução,
estado e métricas. `promote` valida tudo novamente e usa renames no mesmo
filesystem:

```text
remover previous antiga somente quando current é válida
→ current para previous
→ incoming validada para current
→ remover token ativo
```

Uma falha em qualquer ponto conserva pelo menos uma generation recuperável.
`abort` só remove a incoming incompleta cujo ID coincide com o token e nunca
remove generation validada. Se `current` estiver ausente e `previous` for
válida, a reconciliação pode renomeá-la para `current`; qualquer outro estado
ambíguo bloqueia automação.

## Receptor e `authorized_keys`

A chave pública fica vinculada ao receptor por comando forçado. Exemplo de
forma, com placeholders e sem chave real:

```text
from="<SOURCE_ADDRESS>",restrict,command="/usr/local/lib/borg-backup/replica-receiver.sh --root <REMOTE_DESTINATION> --origin <ORIGIN_ID> --sentinel <REMOTE_SENTINEL> --storage-id <REMOTE_STORAGE_ID> --filesystem-uuid <FILESYSTEM_UUID> --min-free-mib 51200" <PUBLIC_KEY>
```

`restrict` desabilita PTY, agent forwarding, port forwarding e X11 forwarding.
Quando a origem for estável, `from=` restringe o endereço. A conta possui
travessia mínima nos ancestrais, leitura da sentinela e escrita somente na raiz
da origem; não acessa repositórios locais nem outra réplica.

## Destinos e resultado

Arquivos em `replication.d` são processados lexicalmente. Destino desabilitado
fica `DISABLED`; sucesso, `OK`; falha, `FAILED`. Todos os seguintes são tentados.
Falha opcional gera `WARNING_OPTIONAL` e código 1; falha obrigatória,
`FAILED_REQUIRED` e código 2. Capacidade pós-promoção abaixo do piso preserva
`REPLICATION[id]=OK`, marca capacidade/execução como warning e retorna 1.

## Recuperação e rollback

Nunca execute Borg modificador diretamente em `current` ou `previous`, pois
hard links podem compartilhar arquivos. Copie a generation escolhida para área
independente, remova apenas locks copiados quando necessário e valide nessa
cópia. `previous` é fallback controlado quando `current` não passa na validação.
Reparo, corrupção simulada e promoção manual exigem procedimento separado.
