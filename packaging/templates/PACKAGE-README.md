# Borg Backup para Debian 13 — pacote @PACKAGE_VERSION@

Este pacote público contém a implementação Bash, modelos operacionais ainda não
provisionados e documentação genérica para Debian GNU/Linux 13. A documentação
técnica começa em [`docs/README.md`](docs/README.md), e os termos de distribuição
estão em [`LICENSE`](LICENSE) e [`NOTICE`](NOTICE).

Não extraia a árvore diretamente sobre `/`. Primeiro valide o checksum externo,
extraia em área isolada e execute `sha256sum -c MANIFEST.sha256` a partir da raiz
do pacote. Em seguida, siga `docs/05-INSTALLATION.md` e o checklist em `install/`.

Os arquivos sob `etc/borg-backup/` são modelos nos paths operacionais finais.
`secrets.conf` contém apenas um marcador deliberadamente inválido; a instalação
exige revisão e provisionamento seguro antes do primeiro uso. O pacote não cria
storage, repositório, contas, chaves SSH, credenciais nem ativa o timer.

`MANIFEST.tsv` não lista a si próprio nem `MANIFEST.sha256`. O segundo cobre todos
os demais arquivos regulares, inclusive `MANIFEST.tsv`, e exclui somente a si.
