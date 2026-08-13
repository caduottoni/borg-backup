# Segurança e custódia de segredos

**Finalidade:** definir o modelo de ameaça, as fronteiras e o tratamento do material sensível.

**Público-alvo:** administradores, segurança, auditores e responsáveis por custódia.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Modelo de ameaça

As salvaguardas consideram erro administrativo, configuração executável,
symlink, path amplo, disco ausente, concorrência, comprometimento de conta de
réplica, host key divergente, exposição em argv/env/log e perda simultânea de
servidor e storage. Criptografia não substitui permissões, custódia externa,
teste de restore ou cópia fora do host.

## Fronteiras administrativas

Código e configuração pertencem a root e não são graváveis por operadores não
autorizados. O runtime real executa como root; a conta remota recebe apenas uma
interface forçada e uma árvore. Configurações são dados literais, nunca shell.
O ambiente herdado é sanitizado, aliases/funções são removidos e subprocessos
Borg recebem um ambiente mínimo.

## Credencial e chave Borg

`secrets.conf` contém a credencial local, modo `0600`, e fica fora do archive.
Ela é passada ao subprocesso Borg por variável de ambiente no `env -i`, nunca
por argumento. O repositório usa criptografia `repokey-blake2`; portanto a
exportação da chave e a credencial são ambas necessárias à recuperação e devem
ter custódia externa offline.

Não registre valores, hashes de valores ou cabeçalhos de chave privada como
prova de controle. Auditorias trabalham com presença, modo, owner, tamanho e
padrões, sem ler ou copiar o conteúdo para evidência.

## Mídia offline

A mídia de custódia usa:

```text
dispositivo identificado → LUKS2 → volume aberto → ext4 → material Borg
```

Ela permanece normalmente fechada, desmontada e desconectada. Não é requisito
para `validate`, `run`, `list`, `check`, `prune` ou `replicate`. Seu procedimento
administrativo valida identidade física, owner/mode da credencial LUKS e
autorização antes de abrir. O valor não aparece em argumento, log, próprio
pendrive ou arquivo intermediário persistente.

Deve existir segunda custódia independente da credencial LUKS: fora dos hosts,
fora da mídia, fora dos repositórios Borg e recuperável sem depender da
infraestrutura protegida. A forma concreta pertence ao registro administrativo
de cada instalação.

## O que entra e o que fica fora

Entram no archive criptografado, quando incluídos por fontes explícitas:
configurações de aplicações, arquivos `.env` operacionais, certificados e
chaves necessários à restauração, DNSSEC/KASP, RNDC, PKI de VPN, host keys SSH
e demais segredos operacionais da aplicação.

Ficam fora:

- credenciais e exports das chaves Borg;
- chaves privadas SSH de replicação;
- chaves administrativas pessoais;
- credenciais, sessões e caches de ferramentas de IA;
- credencial da mídia LUKS;
- conteúdo de custódia offline.

## SSH de replicação

Uma chave ED25519 sem credencial interativa é dedicada a cada direção e pode ser
recriada em desastre. O emissor exige host key conhecida e identidade explícita.
O receptor não fornece shell, PTY ou forwarding, valida origem, argumentos,
storage e raiz, e não possui privilégio administrativo.

## Logs, argv e ambiente

Mensagens aceitam somente fatos operacionais necessários e passam por redação
defensiva dos segredos conhecidos. Saídas integrais de Borg e ferramentas ficam
em staging privado e são apagadas. Relatórios e estados não guardam comando
completo, conteúdo de dump, chave, token ou variável de ambiente.

## Processo seguro de criação e uso

1. Criar valor aleatório por método administrativo aprovado.
2. Gravá-lo diretamente no destino de modo restrito.
3. Verificar owner/mode sem imprimir conteúdo.
4. Testar abertura e exportação da chave em sessão controlada.
5. Registrar custódia e teste de recuperação sem registrar valor.
6. Desmontar/fechar mídia e eliminar temporários autorizados.
7. Auditar logs, reports, estado e histórico de shell por padrões.

## Suspeita de vazamento

Interrompa novas operações, preserve evidências sem copiar o segredo, delimite
quais materiais foram expostos e trate repositório, SSH e aplicações de forma
independente. Rotacione credenciais/chaves sob plano aprovado, atualize
`known_hosts` apenas depois de verificar identidade, teste recuperação com novo
material e documente o incidente. Não apague logs nem tente ocultar a exposição.
