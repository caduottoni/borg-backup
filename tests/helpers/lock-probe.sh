#!/bin/bash
# Finalidade: manter ou sondar o lock global em um caso controlado.
# Entradas: raiz sintética e quantidade de segundos a manter o lock.
# Saídas: arquivo `lock-ready` dentro da raiz após aquisição.
# Efeitos colaterais: apenas lock e marcador sob test-runtime.
# Dependências: Bash, flock e common.sh staged.
# Privilégios: usuário comum.
# Códigos: 0 se adquiriu; 2 quando outra instância mantém o lock.
# Sigilo: nenhuma configuração ou credencial é lida.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

root=${1:?raiz controlada obrigatória}
hold_seconds=${2:?duração obrigatória}
BB_BOOTSTRAP_TEST_MODE=yes
BB_BOOTSTRAP_TEST_ROOT=$root
source "$root/usr/local/lib/borg-backup/common.sh"
bb_initialize_paths
trap bb_release_global_lock EXIT
bb_acquire_global_lock
: >"$root/lock-ready"
sleep "$hold_seconds"
