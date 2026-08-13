# Instalação controlada

Este diretório contém somente orientação administrativa. Ele não oferece
`install.sh`, `deploy.sh`, `uninstall.sh` nem qualquer comando que modifique o
sistema.

Antes de instalar, leia `../docs/05-INSTALLATION.md`, valide os hashes internos,
revise `FHS-DIRECTORIES.tsv` e conclua `POST-INSTALL-CHECKLIST.md`. Storage,
filesystem, repositório, secrets, chaves, contas e ativação do timer exigem
gates próprios e não são criados pelo pacote.

A instalação deve copiar a regra `tmpfiles.d`, aplicá-la e confirmar
`/run/borg-backup` antes de qualquer comando `borg-backup`. O repositório é
inicializado no gate próprio; somente depois disso `borg-backup validate` pode
ser exigido com sucesso.
