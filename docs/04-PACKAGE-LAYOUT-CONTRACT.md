# Contrato de layout do pacote

**Finalidade:** especificar o conteúdo que um futuro pacote de deploy deve materializar.

**Público-alvo:** mantenedores, empacotadores e revisores de release.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Estrutura contratual

```text
<PACKAGE_ROOT>/
├── VERSION
├── LICENSE
├── NOTICE
├── PACKAGE-METADATA.tsv
├── RELEASE-NOTES.md
├── MANIFEST.tsv
├── MANIFEST.sha256
├── README.md
├── docs/
├── etc/
│   ├── borg-backup/
│   ├── systemd/system/
│   └── logrotate.d/
├── usr/local/
│   ├── sbin/
│   └── lib/
│       ├── borg-backup/
│       └── tmpfiles.d/borg-backup.conf
├── install/
├── run/borg-backup/
└── var/
    ├── lib/borg-backup/state/replication/
    ├── log/borg-backup/
    └── tmp/borg-backup/
```

Este documento define o contrato; não cria pacote, versão, manifesto de pacote
ou instalador.

## Conteúdo obrigatório

- `VERSION`, definido pelo processo de release e conferido com
  `PACKAGE-METADATA.tsv`;
- `LICENSE` e `NOTICE`, coerentes com `GPL-3.0-or-later`;
- `RELEASE-NOTES.md` e README do pacote com escopo e verificação;
- `MANIFEST.tsv`, cobrindo tipos, modos, owner, group, tamanhos, hashes e
  proveniência sem listar os dois manifestos;
- `MANIFEST.sha256` cobrindo todo arquivo distribuído conforme regra sem
  circularidade;
- cópia sem alteração dos documentos aprovados desta árvore genérica;
- configurações-modelo comentadas em `etc/borg-backup`;
- regra `tmpfiles.d`, units systemd e configuração logrotate aprovadas;
- ponto de entrada e módulos Bash idênticos às origens aprovadas;
- instalação e validação documentadas sob `install/`;
- diretórios inicialmente vazios de estado, log, temporários, runtime e chaves,
  com os modos definidos em `MANIFEST.tsv` e `install/FHS-DIRECTORIES.tsv`.

## Conteúdo opcional

Podem existir exemplos adicionais sintéticos, checklist de release e utilitários
de validação que não alterem o comportamento do produto. Todo item opcional
deve estar no manifesto e possuir finalidade explícita.

## Conteúdo proibido

O pacote não pode conter:

- segredos, chaves privadas, exports Borg ou host keys de uma instalação;
- UUID, hostname, usuário, archive, repository ID ou horário operacional real;
- reports, logs, estados, caches, dumps ou evidências de ambiente;
- repositório Borg, réplica, storage provisionado ou mídia de custódia;
- configuração específica de aplicação ou host;
- arquivo executável não documentado;
- symlink que escape da raiz do pacote.

## Identidade com origens aprovadas

O ponto de entrada, módulos, configs modelo, units, logrotate e documentos
genéricos devem ser copiados byte a byte das origens aprovadas. O construtor
calcula hashes depois de montar uma árvore limpa e falha diante de arquivo
ausente, extra ou divergente. Placeholders permanecem inequívocos; não são
substituídos durante o build.

## Responsabilidades do instalador futuro

O instalador deverá:

- verificar plataforma, privilégios, manifesto e ausência de symlinks;
- apresentar plano antes de escrever;
- criar diretórios e instalar arquivos com owner/mode normativos;
- preservar configurações e segredos existentes por política explícita;
- usar arquivos temporários no mesmo filesystem e rename atômico;
- aplicar a regra `tmpfiles.d` e confirmar `/run/borg-backup` como
  `root:root 0750` antes do primeiro comando da solução;
- validar Bash, parser, units e logrotate após instalação;
- produzir rollback dos arquivos gerenciados quando possível;
- deixar timer desabilitado até aceite operacional.

Ele nunca deverá formatar disco, criar LUKS, montar storage, inicializar
repositório, gerar segredo, exportar chave, criar conta remota, alterar
`authorized_keys`, habilitar replicação ou timer sem gates e autorizações
específicos.
