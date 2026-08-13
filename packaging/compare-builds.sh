#!/bin/bash
# Finalidade: provar reprodutibilidade integral entre os builds públicos A e B.
# Entradas: VERSION da raiz e saídas fixas em packaging/work/build-{a,b}.
# Saídas: hashes, tamanho, contagem de entradas e classificação em stdout.
# Arquivos alterados: nenhum; todas as operações são de leitura.
# Efeitos colaterais: apenas leitura de árvores, gzip e tar.
# Dependências: Bash, findutils, coreutils, GNU tar, gzip, awk e sort.
# Privilégios: usuário comum.
# Códigos: 0 para identidade integral; 2 para ausência ou divergência.
# Sigilo: examina apenas artefatos públicos do workspace.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export TZ=UTC
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(readlink -e -- "$SCRIPT_DIR/..")
readonly SCRIPT_DIR PROJECT_ROOT
readonly WORK_DIR="$SCRIPT_DIR/work"

# Encerra a comparação com mensagem de contrato e falha técnica.
fail() {
    printf '%s\n' "$1" >&2
    exit 2
}

[[ $# -eq 0 ]] || { printf 'uso: %s\n' "$0" >&2; exit 64; }
[[ -f $PROJECT_ROOT/VERSION && ! -L $PROJECT_ROOT/VERSION ]] || fail VERSION_FILE_MISSING_OR_UNSAFE
IFS= read -r PACKAGE_VERSION <"$PROJECT_ROOT/VERSION"
[[ $PACKAGE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail VERSION_NOT_SEMVER
readonly PACKAGE_VERSION
readonly ROOT_NAME="borg-backup-debian13-$PACKAGE_VERSION"
readonly ARCHIVE_NAME="$ROOT_NAME.tar.gz"
readonly BUILD_A="$WORK_DIR/build-a"
readonly BUILD_B="$WORK_DIR/build-b"
readonly TREE_A="$BUILD_A/$ROOT_NAME"
readonly TREE_B="$BUILD_B/$ROOT_NAME"
readonly ARCHIVE_A="$BUILD_A/$ARCHIVE_NAME"
readonly ARCHIVE_B="$BUILD_B/$ARCHIVE_NAME"

# Emite representação NUL-safe de tipos, modos, tamanhos e hashes.
fingerprint_tree() {
    local root=$1 entry path type mode size hash
    while IFS= read -r -d '' entry; do
        path=${entry#"$root/"}
        if [[ -d $entry && ! -L $entry ]]; then
            type=directory; size=-; hash=-
        elif [[ -f $entry && ! -L $entry ]]; then
            type=file; size=$(stat -c '%s' -- "$entry")
            hash=$(sha256sum <"$entry"); hash=${hash%% *}
        else
            fail PACKAGE_BUILD_TREE_FORBIDDEN_TYPE
        fi
        mode=$(printf '%04d' "$(stat -c '%a' -- "$entry")")
        printf '%s\0%s\0%s\0%s\0%s\0' "$path" "$type" "$mode" "$size" "$hash"
    done < <(find -P "$root" -mindepth 1 -print0 | sort -z)
}

[[ -d $TREE_A && -d $TREE_B && -f $ARCHIVE_A && -f $ARCHIVE_B ]] \
    || fail PACKAGE_BUILD_OUTPUT_MISSING
cmp -s <(fingerprint_tree "$TREE_A") <(fingerprint_tree "$TREE_B") \
    || fail PACKAGE_BUILD_TREE_NOT_REPRODUCIBLE
cmp -s -- "$BUILD_A/SOURCE-INVENTORY.tsv" "$BUILD_B/SOURCE-INVENTORY.tsv" \
    || fail SOURCE_INVENTORY_NOT_REPRODUCIBLE
cmp -s -- "$TREE_A/MANIFEST.tsv" "$TREE_B/MANIFEST.tsv" \
    || fail INTERNAL_MANIFEST_NOT_REPRODUCIBLE
cmp -s -- "$TREE_A/MANIFEST.sha256" "$TREE_B/MANIFEST.sha256" \
    || fail INTERNAL_CHECKSUMS_NOT_REPRODUCIBLE
cmp -s -- "$ARCHIVE_A.sha256" "$ARCHIVE_B.sha256" \
    || fail EXTERNAL_CHECKSUM_NOT_REPRODUCIBLE

(cd "$BUILD_A" && sha256sum -c -- "$ARCHIVE_NAME.sha256") >/dev/null
(cd "$BUILD_B" && sha256sum -c -- "$ARCHIVE_NAME.sha256") >/dev/null
gzip -t -- "$ARCHIVE_A"
gzip -t -- "$ARCHIVE_B"

hash_a=$(sha256sum <"$ARCHIVE_A"); hash_a=${hash_a%% *}
hash_b=$(sha256sum <"$ARCHIVE_B"); hash_b=${hash_b%% *}
[[ $hash_a == "$hash_b" ]] || fail PACKAGE_ARCHIVE_NOT_REPRODUCIBLE
size_a=$(stat -c '%s' -- "$ARCHIVE_A")
size_b=$(stat -c '%s' -- "$ARCHIVE_B")
[[ $size_a == "$size_b" ]] || fail PACKAGE_ARCHIVE_SIZE_NOT_REPRODUCIBLE
entries_a=$(tar -tzf "$ARCHIVE_A" | wc -l)
entries_b=$(tar -tzf "$ARCHIVE_B" | wc -l)
[[ $entries_a == "$entries_b" ]] || fail PACKAGE_ARCHIVE_ENTRY_COUNT_NOT_REPRODUCIBLE
list_hash_a=$(tar -tzf "$ARCHIVE_A" | sha256sum | awk '{print $1}')
list_hash_b=$(tar -tzf "$ARCHIVE_B" | sha256sum | awk '{print $1}')
[[ $list_hash_a == "$list_hash_b" ]] || fail PACKAGE_ARCHIVE_LIST_NOT_REPRODUCIBLE

printf 'PACKAGE_VERSION=%s\n' "$PACKAGE_VERSION"
printf 'SHA256_BUILD_A=%s\n' "$hash_a"
printf 'SHA256_BUILD_B=%s\n' "$hash_b"
printf 'ARCHIVE_SIZE_BYTES=%s\n' "$size_a"
printf 'ARCHIVE_ENTRY_COUNT=%s\n' "$entries_a"
printf 'TAR_LIST_SHA256=%s\n' "$list_hash_a"
printf 'PACKAGE_REPRODUCIBILITY=PASS\n'
