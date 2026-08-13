#!/bin/bash
# Finalidade: capturar o argv servidor produzido pelo rsync real sem usar rede.
# Entradas: host sintético seguido do comando remoto construído pelo rsync.
# Saídas: uma linha literal no arquivo de captura declarado pelo teste.
# Efeitos colaterais: grava somente um arquivo validado sob a raiz controlada.
# Dependências: Bash, readlink e printf.
# Privilégios: usuário comum.
# Códigos: 12 intencionalmente, para encerrar antes de qualquer transporte.
# Sigilo: registra somente protocolo de repositório sintético, sem credenciais.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

capture_root=${BB_RSYNC_CAPTURE_ROOT:?raiz de captura ausente}
capture_file=${BB_RSYNC_CAPTURE_FILE:?arquivo de captura ausente}
canonical_root=$(readlink -e -- "$capture_root") || exit 2
canonical_parent=$(readlink -e -- "$(dirname -- "$capture_file")") || exit 2
[[ $canonical_parent == "$canonical_root" || $canonical_parent == "$canonical_root"/* ]] || exit 2
(( $# >= 2 )) || exit 2

# O primeiro argumento é o host da camada rsh; somente o argv remoto restante
# interessa à validação da interface forçada.
shift
printf '%s\n' "$*" >"$capture_file"
exit 12
