#!/bin/bash
# Finalidade: validar ponta a ponta um build público e seu archive determinístico.
# Entradas: slot `a` ou `b`, VERSION da raiz e SOURCE_DATE_EPOCH do build.
# Saídas: protocolo de checks e evidências sob packaging/work/validation-{a,b}.
# Arquivos alterados: somente raízes descartáveis sob packaging/work.
# Efeitos colaterais: parser, systemd, tmpfiles e logrotate usam raízes sintéticas.
# Dependências: Bash, core/findutils, tar, gzip, Python 3, acl, systemd e logrotate.
# Privilégios: usuário comum; não usa sudo, systemctl ativo, rede ou host remoto.
# Códigos: 0 em conformidade; 64 em uso inválido; 2 em divergência.
# Sigilo: scanners não imprimem conteúdo e o parser usa marcador sintético.

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
readonly TEMPLATE_ROOT="$SCRIPT_DIR/templates"

# Encerra a validação com uma asserção negativa e falha técnica.
fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 2
}

# Registra uma asserção positiva numerada.
pass() {
    ((CHECK_COUNT += 1))
    printf 'ok %d - %s\n' "$CHECK_COUNT" "$1"
}

[[ $# -eq 1 ]] || { printf 'uso: SOURCE_DATE_EPOCH=<epoch> %s a|b\n' "$0" >&2; exit 64; }
case $1 in
    a|b) BUILD_SLOT=$1 ;;
    *) printf 'slot de build inválido: %s\n' "$1" >&2; exit 64 ;;
esac
readonly BUILD_SLOT

[[ ${SOURCE_DATE_EPOCH+x} == x && $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || {
    printf 'SOURCE_DATE_EPOCH decimal é obrigatório\n' >&2
    exit 64
}
EXPECTED_DATE=$(date -u -d "@$SOURCE_DATE_EPOCH" +%F 2>/dev/null) || fail SOURCE_DATE_EPOCH_OUT_OF_RANGE
EXPECTED_TIME=$(date -u -d "@$SOURCE_DATE_EPOCH" +%T 2>/dev/null) || fail SOURCE_DATE_EPOCH_OUT_OF_RANGE
readonly SOURCE_DATE_EPOCH EXPECTED_DATE EXPECTED_TIME

[[ -f $PROJECT_ROOT/VERSION && ! -L $PROJECT_ROOT/VERSION ]] || fail VERSION_FILE_MISSING_OR_UNSAFE
IFS= read -r PACKAGE_VERSION <"$PROJECT_ROOT/VERSION"
[[ $PACKAGE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail VERSION_NOT_SEMVER
readonly PACKAGE_VERSION
readonly PACKAGE_ROOT_NAME="borg-backup-debian13-$PACKAGE_VERSION"
readonly ARCHIVE_NAME="$PACKAGE_ROOT_NAME.tar.gz"
readonly BUILD_DIR="$WORK_DIR/build-$BUILD_SLOT"
readonly PACKAGE_TREE="$BUILD_DIR/$PACKAGE_ROOT_NAME"
readonly ARCHIVE="$BUILD_DIR/$ARCHIVE_NAME"
readonly ARCHIVE_CHECKSUM="$ARCHIVE.sha256"
readonly VALIDATION_DIR="$WORK_DIR/validation-$BUILD_SLOT"
readonly EXTRACT_DIR="$WORK_DIR/extract-$BUILD_SLOT"
readonly EXTRACTED_TREE="$EXTRACT_DIR/$PACKAGE_ROOT_NAME"
declare -i CHECK_COUNT=0

for command in bash find stat sha256sum awk sed grep sort tar gzip python3 getfacl \
    systemd-analyze systemd-tmpfiles logrotate; do
    command -v "$command" >/dev/null 2>&1 || fail "DEPENDENCY_MISSING_${command//-/_}"
done
[[ -d $PACKAGE_TREE && ! -L $PACKAGE_TREE ]] || fail PACKAGE_TREE_MISSING_OR_UNSAFE
[[ -f $ARCHIVE && ! -L $ARCHIVE ]] || fail ARCHIVE_MISSING_OR_UNSAFE
[[ -f $ARCHIVE_CHECKSUM && ! -L $ARCHIVE_CHECKSUM ]] || fail ARCHIVE_CHECKSUM_MISSING_OR_UNSAFE

# Recria somente o diretório descartável previamente confinado.
safe_reset_directory() {
    local target=$1 canonical
    canonical=$(readlink -m -- "$target")
    case $canonical in
        "$WORK_DIR/validation-$BUILD_SLOT"|"$WORK_DIR/extract-$BUILD_SLOT") ;;
        *) fail UNSAFE_VALIDATION_ROOT ;;
    esac
    if [[ -e $canonical || -L $canonical ]]; then
        [[ ! -L $canonical ]] || fail VALIDATION_ROOT_IS_SYMLINK
        find -P "$canonical" -depth -delete
    fi
    mkdir -p -- "$canonical"
    chmod 0700 -- "$canonical"
}

# Emite representação NUL-safe dos metadados e hashes de uma árvore.
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
            type=forbidden; size=-; hash=-
        fi
        mode=$(printf '%04d' "$(stat -c '%a' -- "$entry")")
        printf '%s\0%s\0%s\0%s\0%s\0' "$path" "$type" "$mode" "$size" "$hash"
    done < <(find -P "$root" -mindepth 1 -print0 | sort -z)
}

# Confere presença e ausência das subárvores previstas no contrato.
validate_structure() {
    local root=$1 required leaf config module
    for required in VERSION LICENSE NOTICE PACKAGE-METADATA.tsv RELEASE-NOTES.md README.md \
        MANIFEST.tsv MANIFEST.sha256 docs/README.md docs/DOCUMENTATION-MANIFEST.tsv \
        docs/reference/SPECIFICATION.md etc/borg-backup/secrets.conf \
        etc/borg-backup/replication.d/10-destination.conf etc/borg-backup/ssh/known_hosts \
        etc/systemd/system/borg-backup.service etc/systemd/system/borg-backup.timer \
        etc/logrotate.d/borg-backup usr/local/sbin/borg-backup \
        usr/local/lib/borg-backup/replica-receiver.sh \
        usr/local/lib/tmpfiles.d/borg-backup.conf install/README.md \
        install/FHS-DIRECTORIES.tsv install/POST-INSTALL-CHECKLIST.md; do
        [[ -f $root/$required && ! -L $root/$required ]] || fail STRUCTURE_REQUIRED_FILE_MISSING
    done
    for config in applications backup databases excludes replication services sources; do
        [[ -f $root/etc/borg-backup/$config.conf ]] || fail OPERATIONAL_CONFIG_MISSING
    done
    for module in applications.sh backup.sh common.sh config.sh databases.sh logging.sh \
        maintenance.sh replication.sh services.sh; do
        [[ -f $root/usr/local/lib/borg-backup/$module ]] || fail PRODUCT_MODULE_MISSING
    done
    [[ ! -e $root/examples && ! -e $root/srv ]] || fail PROHIBITED_PACKAGE_SUBTREE
    [[ -z $(find -P "$root" -name '*.example' -print -quit) ]] || fail EXAMPLE_SUFFIX_IN_PACKAGE
    for leaf in etc/borg-backup/ssh/keys var/lib/borg-backup/state/replication \
        var/log/borg-backup var/tmp/borg-backup run/borg-backup; do
        [[ -d $root/$leaf && ! -L $root/$leaf ]] || fail EMPTY_DIRECTORY_MISSING
        [[ -z $(find -P "$root/$leaf" -mindepth 1 -print -quit) ]] || fail EMPTY_DIRECTORY_NOT_EMPTY
    done
}

# Confere modos, executabilidade e ausência de bits inseguros.
validate_modes() {
    local root=$1 path expected file
    while IFS=$'\t' read -r path expected; do
        [[ $(stat -c '%a' -- "$root/$path") == "$expected" ]] || fail MODE_MISMATCH
    done <<'EOF'
etc/borg-backup	750
etc/borg-backup/replication.d	750
etc/borg-backup/ssh	700
etc/borg-backup/ssh/keys	700
etc/borg-backup/secrets.conf	600
etc/borg-backup/ssh/known_hosts	640
usr/local/lib/borg-backup	755
usr/local/lib/tmpfiles.d	755
var/lib/borg-backup	750
var/lib/borg-backup/state	750
var/lib/borg-backup/state/replication	750
var/log/borg-backup	750
var/tmp/borg-backup	700
run/borg-backup	750
usr/local/sbin/borg-backup	755
usr/local/lib/borg-backup/replica-receiver.sh	755
usr/local/lib/tmpfiles.d/borg-backup.conf	644
VERSION	644
LICENSE	644
NOTICE	644
PACKAGE-METADATA.tsv	644
RELEASE-NOTES.md	644
README.md	644
MANIFEST.tsv	644
MANIFEST.sha256	644
EOF
    while IFS= read -r -d '' file; do
        case $file in
            "$root/usr/local/sbin/borg-backup"|"$root/usr/local/lib/borg-backup/replica-receiver.sh") ;;
            *) [[ ! -x $file ]] || fail UNEXPECTED_EXECUTABLE_FILE ;;
        esac
    done < <(find -P "$root" -type f -print0 | sort -z)
    [[ -z $(find -P "$root" -perm /6000 -print -quit) ]] || fail SETUID_SETGID_FOUND
    [[ -z $(find -P "$root" -perm -0002 -print -quit) ]] || fail WORLD_WRITABLE_FOUND
}

# Rejeita tipos especiais, hard links, arquivos esparsos, ACLs e xattrs.
validate_types_and_metadata() {
    local root=$1 file size blocks
    [[ -z $(find -P "$root" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print -quit) ]] \
        || fail FORBIDDEN_FILE_TYPE
    while IFS= read -r -d '' file; do
        [[ $(stat -c '%h' -- "$file") -eq 1 ]] || fail UNEXPECTED_HARD_LINK
        size=$(stat -c '%s' -- "$file")
        blocks=$(stat -c '%b' -- "$file")
        (( size == 0 || blocks * 512 >= size )) || fail UNEXPECTED_SPARSE_FILE
    done < <(find -P "$root" -type f -print0 | sort -z)
    getfacl -R -s -p -- "$root" >"$VALIDATION_DIR/acl.txt"
    [[ ! -s $VALIDATION_DIR/acl.txt ]] || fail NONTRIVIAL_ACL_FOUND
    python3 - "$root" <<'PY' || fail XATTR_OR_CAPABILITY_FOUND
import os, sys
root = os.fsencode(sys.argv[1])
for directory, subdirs, files in os.walk(root, followlinks=False):
    for path in [directory, *(os.path.join(directory, name) for name in subdirs),
                 *(os.path.join(directory, name) for name in files)]:
        if os.listxattr(path, follow_symlinks=False):
            raise SystemExit(1)
PY
}

# Renderiza um template para compará-lo com o resultado empacotado.
render_expected_template() {
    local source=$1 output=$2 spec_hash release_date
    spec_hash=$(sha256sum <"$PROJECT_ROOT/docs/reference/SPECIFICATION.md"); spec_hash=${spec_hash%% *}
    release_date=$(date -u -d "@$SOURCE_DATE_EPOCH" +%F)
    sed -e "s/@PACKAGE_VERSION@/$PACKAGE_VERSION/g" \
        -e "s/@SOURCE_DATE_EPOCH@/$SOURCE_DATE_EPOCH/g" \
        -e "s/@RELEASE_DATE@/$release_date/g" \
        -e "s/@SPECIFICATION_SHA256@/$spec_hash/g" -- "$source" >"$output"
}

# Compara o pacote com cada fonte pública que lhe deu origem.
validate_source_identity() {
    local root=$1 document config module runtime_version metadata_version metadata_epoch
    local metadata_spec_hash actual_spec_hash expected
    cmp -s -- "$PROJECT_ROOT/VERSION" "$root/VERSION" || fail VERSION_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/LICENSE" "$root/LICENSE" || fail LICENSE_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/NOTICE" "$root/NOTICE" || fail NOTICE_IDENTITY_MISMATCH
    metadata_version=$(awk -F '\t' '$1 == "PACKAGE_VERSION" { print $2 }' "$root/PACKAGE-METADATA.tsv")
    metadata_epoch=$(awk -F '\t' '$1 == "SOURCE_DATE_EPOCH" { print $2 }' "$root/PACKAGE-METADATA.tsv")
    metadata_spec_hash=$(awk -F '\t' '$1 == "SPECIFICATION_SHA256" { print $2 }' "$root/PACKAGE-METADATA.tsv")
    actual_spec_hash=$(sha256sum <"$PROJECT_ROOT/docs/reference/SPECIFICATION.md"); actual_spec_hash=${actual_spec_hash%% *}
    [[ $metadata_version == "$PACKAGE_VERSION" && $metadata_epoch == "$SOURCE_DATE_EPOCH" \
        && $metadata_spec_hash == "$actual_spec_hash" ]] || fail PACKAGE_METADATA_INCOHERENT
    runtime_version=$(sed -n 's/^declare -gr BB_VERSION="\([^"]*\)"$/\1/p' \
        "$root/usr/local/lib/borg-backup/common.sh")
    [[ $runtime_version == "$PACKAGE_VERSION" ]] || fail RUNTIME_PACKAGE_VERSION_MISMATCH
    for pair in 'PACKAGE-METADATA.tsv.in:PACKAGE-METADATA.tsv' \
        'PACKAGE-README.md:README.md' 'RELEASE-NOTES.md:RELEASE-NOTES.md'; do
        expected="$VALIDATION_DIR/expected-${pair##*:}"
        render_expected_template "$TEMPLATE_ROOT/${pair%%:*}" "$expected"
        cmp -s -- "$expected" "$root/${pair##*:}" || fail RENDERED_TEMPLATE_MISMATCH
    done
    for document in "$PROJECT_ROOT"/docs/*; do
        [[ -f $document && ! -L $document ]] || continue
        cmp -s -- "$document" "$root/docs/${document##*/}" || fail DOCUMENT_IDENTITY_MISMATCH
    done
    cmp -s -- "$PROJECT_ROOT/docs/reference/SPECIFICATION.md" "$root/docs/reference/SPECIFICATION.md" \
        || fail SPECIFICATION_IDENTITY_MISMATCH
    for config in applications backup databases excludes replication services sources; do
        cmp -s -- "$PROJECT_ROOT/examples/etc/borg-backup/$config.conf.example" \
            "$root/etc/borg-backup/$config.conf" || fail CONFIG_IDENTITY_MISMATCH
    done
    cmp -s -- "$PROJECT_ROOT/examples/etc/borg-backup/replication.d/10-destination.conf.example" \
        "$root/etc/borg-backup/replication.d/10-destination.conf" || fail DESTINATION_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/examples/etc/borg-backup/ssh/known_hosts.example" \
        "$root/etc/borg-backup/ssh/known_hosts" || fail KNOWN_HOSTS_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/examples/etc/borg-backup/secrets.conf.example" \
        "$root/etc/borg-backup/secrets.conf" || fail SECRET_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.service" \
        "$root/etc/systemd/system/borg-backup.service" || fail SYSTEMD_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.timer" \
        "$root/etc/systemd/system/borg-backup.timer" || fail SYSTEMD_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/src/etc/logrotate.d/borg-backup" \
        "$root/etc/logrotate.d/borg-backup" || fail LOGROTATE_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/src/usr/local/lib/tmpfiles.d/borg-backup.conf" \
        "$root/usr/local/lib/tmpfiles.d/borg-backup.conf" || fail TMPFILES_IDENTITY_MISMATCH
    cmp -s -- "$PROJECT_ROOT/src/usr/local/sbin/borg-backup" \
        "$root/usr/local/sbin/borg-backup" || fail ENTRYPOINT_IDENTITY_MISMATCH
    for module in "$PROJECT_ROOT"/src/usr/local/lib/borg-backup/*.sh; do
        cmp -s -- "$module" "$root/usr/local/lib/borg-backup/${module##*/}" \
            || fail MODULE_IDENTITY_MISMATCH
    done
}

# Confere formato, cobertura, ordem, modos e hashes dos manifestos.
validate_internal_manifests() {
    local root=$1 manifest=$1/MANIFEST.tsv header path type mode owner group size hash class source extra
    local actual_mode actual_size actual_hash listed="$VALIDATION_DIR/manifest-listed.txt"
    local actual="$VALIDATION_DIR/manifest-actual.txt"
    IFS= read -r header <"$manifest"
    [[ $header == $'PATH\tTYPE\tMODE\tOWNER\tGROUP\tSIZE\tSHA256\tSOURCE_CLASS\tSOURCE_PATH' ]] \
        || fail MANIFEST_HEADER_INVALID
    : >"$listed"
    while IFS=$'\t' read -r path type mode owner group size hash class source extra; do
        [[ -n $path && -z ${extra:-} && $path != /* && $path != *..* ]] || fail MANIFEST_ROW_INVALID
        [[ $path != MANIFEST.tsv && $path != MANIFEST.sha256 ]] || fail MANIFEST_CIRCULAR_ENTRY
        [[ $owner == root && $group == root ]] || fail MANIFEST_OWNER_INVALID
        [[ $class =~ ^[A-Z_]+$ ]] || fail MANIFEST_SOURCE_CLASS_INVALID
        [[ -e $root/$path && ! -L $root/$path ]] || fail MANIFEST_PATH_MISSING
        actual_mode=$(printf '%04d' "$(stat -c '%a' -- "$root/$path")")
        [[ $actual_mode == "$mode" ]] || fail MANIFEST_MODE_INVALID
        if [[ $type == directory ]]; then
            [[ -d $root/$path && $size == - && $hash == - ]] || fail MANIFEST_DIRECTORY_INVALID
        elif [[ $type == file ]]; then
            actual_size=$(stat -c '%s' -- "$root/$path")
            actual_hash=$(sha256sum <"$root/$path"); actual_hash=${actual_hash%% *}
            [[ -f $root/$path && $actual_size == "$size" && $actual_hash == "$hash" ]] \
                || fail MANIFEST_FILE_INVALID
        else
            fail MANIFEST_TYPE_INVALID
        fi
        printf '%s\n' "$path" >>"$listed"
    done < <(sed -n '2,$p' "$manifest")
    LC_ALL=C sort -c -u "$listed" || fail MANIFEST_NOT_SORTED_OR_DUPLICATE
    find -P "$root" -mindepth 1 -printf '%P\n' | grep -v -x -e MANIFEST.tsv -e MANIFEST.sha256 \
        | LC_ALL=C sort >"$actual"
    cmp -s -- "$listed" "$actual" || fail MANIFEST_COVERAGE_INVALID
    (cd "$root" && sha256sum -c -- MANIFEST.sha256) >"$VALIDATION_DIR/internal-sha256.txt"
    awk '{print $2}' "$root/MANIFEST.sha256" >"$VALIDATION_DIR/sha-listed.txt"
    find -P "$root" -type f ! -name MANIFEST.sha256 -printf '%P\n' | LC_ALL=C sort \
        >"$VALIDATION_DIR/sha-actual.txt"
    cmp -s -- "$VALIDATION_DIR/sha-listed.txt" "$VALIDATION_DIR/sha-actual.txt" \
        || fail SHA_MANIFEST_COVERAGE_INVALID
}

# Valida sintaxe e quantidade esperada dos scripts Bash distribuídos.
validate_bash() {
    local root=$1 file count=0
    while IFS= read -r -d '' file; do
        bash -n -- "$file" || fail EXTRACTED_BASH_SYNTAX
        ((count += 1))
    done < <(find -P "$root/usr/local/sbin" "$root/usr/local/lib/borg-backup" \
        -maxdepth 1 -type f -print0 | sort -z)
    [[ $count -eq 11 ]] || fail EXTRACTED_BASH_COUNT
}

# Exercita o parser em uma raiz FHS inteiramente sintética.
validate_configuration_parser() {
    local root=$1 runtime="$VALIDATION_DIR/fhs" config
    mkdir -p -- "$runtime/etc" "$runtime/usr/local" "$runtime/var/lib/borg-backup/state" \
        "$runtime/var/log/borg-backup" "$runtime/var/tmp/borg-backup" "$runtime/run/borg-backup" \
        "$runtime/srv/borg-storage/repositories/host-example/repo" "$runtime/test-bin" "$runtime/home"
    cp -a -- "$root/etc/borg-backup" "$runtime/etc/"
    cp -a -- "$root/usr/local/sbin" "$runtime/usr/local/"
    mkdir -p -- "$runtime/usr/local/lib"
    cp -a -- "$root/usr/local/lib/borg-backup" "$runtime/usr/local/lib/"
    cp -a -- "$PROJECT_ROOT/fixtures/bin/." "$runtime/test-bin/"
    chmod 0750 -- "$runtime/var/lib/borg-backup" "$runtime/var/lib/borg-backup/state" \
        "$runtime/var/log/borg-backup" "$runtime/run/borg-backup"
    chmod 0700 -- "$runtime/var/tmp/borg-backup"
    chmod 0755 -- "$runtime/test-bin" "$runtime/test-bin"/*
    config=$runtime/etc/borg-backup
    sed -i 's/SUBSTITUIR_POR_VALOR_SOB_CUSTODIA/public-synthetic-marker/' "$config/secrets.conf"
    sed -i 's|BORG_REPOSITORY=.*|BORG_REPOSITORY=/srv/borg-storage/repositories/host-example/repo|' "$config/backup.conf"
    sed -i 's|REPOSITORY_STORAGE_ID=.*|REPOSITORY_STORAGE_ID=host-example|' "$config/backup.conf"
    sed -i 's/^REPLICATION_ENABLED=yes$/REPLICATION_ENABLED=no/' \
        "$config/replication.d/10-destination.conf"
    {
        printf 'STORAGE_ID=host-example\n'
        printf 'PURPOSE=borg-backup\n'
    } >"$runtime/srv/borg-storage/.borg-storage"
    chmod 0640 -- "$runtime/srv/borg-storage/.borg-storage"
    sed -i 's/11111111-1111-1111-1111-111111111111/00000000-0000-0000-0000-000000000000/g' \
        "$runtime/test-bin/findmnt"
    env -i HOME="$runtime/home" BORG_BACKUP_TEST_MODE=yes \
        BORG_BACKUP_TEST_ROOT="$runtime" BORG_BACKUP_TEST_BIN="$runtime/test-bin" \
        "$runtime/usr/local/sbin/borg-backup" validate >"$VALIDATION_DIR/parser.txt" 2>&1 \
        || fail CONFIG_PARSER_FAILED
    grep -q 'EXECUTION.*OK' "$runtime/var/log/borg-backup/last-run.report" \
        || fail CONFIG_PARSER_REPORT_FAILED
}

# Valida units e logrotate sem alterar serviços ativos do host.
validate_integration_artifacts() {
    local root=$1 calendar controlled_logrotate="$VALIDATION_DIR/borg-backup.logrotate"
    local controlled_service="$VALIDATION_DIR/borg-backup.service"
    grep -Fxq 'ExecStart=/usr/local/sbin/borg-backup run' \
        "$root/etc/systemd/system/borg-backup.service" || fail SYSTEMD_EXECSTART_INVALID
    sed "s|ExecStart=/usr/local/sbin/borg-backup run|ExecStart=$root/usr/local/sbin/borg-backup run|" \
        "$root/etc/systemd/system/borg-backup.service" >"$controlled_service"
    systemd-analyze verify --man=no --generators=no "$controlled_service" \
        "$root/etc/systemd/system/borg-backup.timer" >"$VALIDATION_DIR/systemd-verify.txt" 2>&1 \
        || fail SYSTEMD_VERIFY_FAILED
    calendar=$(awk -F= '$1 == "OnCalendar" { print $2 }' "$root/etc/systemd/system/borg-backup.timer")
    [[ $calendar == daily ]] || fail TIMER_NOT_GENERIC_DAILY
    systemd-analyze calendar "$calendar" >"$VALIDATION_DIR/calendar.txt" 2>&1 \
        || fail CALENDAR_PARSE_FAILED
    mkdir -p -- "$VALIDATION_DIR/log"
    sed "s|/var/log/borg-backup/backup.log|$VALIDATION_DIR/log/backup.log|" \
        "$root/etc/logrotate.d/borg-backup" >"$controlled_logrotate"
    logrotate --debug --state "$VALIDATION_DIR/logrotate.state" "$controlled_logrotate" \
        >"$VALIDATION_DIR/logrotate-debug.txt" 2>&1 || fail LOGROTATE_DEBUG_FAILED
}

# Exercita a regra tmpfiles dentro de uma raiz sintética.
validate_tmpfiles_artifact() {
    local root=$1 runtime="$VALIDATION_DIR/tmpfiles-root" test_config
    mkdir -p -- "$runtime/usr/local/lib/tmpfiles.d" "$runtime/run"
    test_config="$runtime/usr/local/lib/tmpfiles.d/borg-backup.conf"
    sed "s/ root root / $(id -u) $(id -g) /" \
        "$root/usr/local/lib/tmpfiles.d/borg-backup.conf" >"$test_config"
    chmod 0644 -- "$test_config"
    systemd-tmpfiles --create --root="$runtime" borg-backup.conf \
        >"$VALIDATION_DIR/tmpfiles-create.txt" 2>&1 || fail TMPFILES_CREATE_FAILED
    [[ -d $runtime/run/borg-backup && ! -L $runtime/run/borg-backup \
        && $(stat -c '%a' -- "$runtime/run/borg-backup") == 750 ]] || fail TMPFILES_RUNTIME_INVALID
}

# Confere manifesto, links e exemplos da documentação pública.
validate_documentation() {
    local root=$1 docs=$1/docs manifest=$1/docs/DOCUMENTATION-MANIFEST.tsv
    local path title purpose audience requirements hash status extra file target token rows=0 index name
    local document base resolved header
    IFS= read -r header <"$manifest"
    [[ $header == $'PATH\tTITLE\tPURPOSE\tAUDIENCE\tREQUIREMENTS\tSHA256\tSTATUS' ]] \
        || fail DOC_MANIFEST_HEADER
    : >"$VALIDATION_DIR/documented.txt"
    while IFS=$'\t' read -r path title purpose audience requirements hash status extra; do
        [[ $path == PATH ]] && continue
        [[ $path == docs/* && $path != *..* && -z ${extra:-} && $status == PUBLIC_CANONICAL ]] \
            || fail DOC_MANIFEST_ROW
        file=$root/$path
        [[ -f $file && $(sha256sum <"$file" | awk '{print $1}') == "$hash" ]] || fail DOC_MANIFEST_HASH
        [[ $(sed -n '1s/^# //p' "$file") == "$title" ]] || fail DOC_TITLE
        printf '%s\n' "${path#docs/}" >>"$VALIDATION_DIR/documented.txt"
        ((rows += 1))
    done <"$manifest"
    (( rows > 0 )) || fail DOC_MANIFEST_EMPTY
    find -P "$docs" -type f ! -name DOCUMENTATION-MANIFEST.tsv -printf '%P\n' \
        | LC_ALL=C sort >"$VALIDATION_DIR/docs-actual.txt"
    LC_ALL=C sort -u "$VALIDATION_DIR/documented.txt" >"$VALIDATION_DIR/docs-listed.txt"
    cmp -s -- "$VALIDATION_DIR/docs-listed.txt" "$VALIDATION_DIR/docs-actual.txt" \
        || fail DOC_MANIFEST_COVERAGE
    while IFS= read -r -d '' document; do
        base=${document%/*}
        while IFS= read -r token; do
            target=${token#*(}; target=${target%)}; target=${target%%#*}
            [[ -n $target ]] || continue
            case $target in *://*|mailto:*|/*) fail DOC_LINK_UNSAFE ;; esac
            resolved=$(readlink -m -- "$base/$target")
            [[ $resolved == "$docs"/* && -f $resolved && ! -L $resolved ]] || fail DOC_LINK_BROKEN
        done < <(grep -hoE '\[[^]]+\]\([^)]+\)' "$document" || true)
    done < <(find -P "$docs" -type f -name '*.md' -print0 | sort -z)
    mkdir -p -- "$VALIDATION_DIR/documented-examples"
    index=0
    for name in backup sources excludes databases applications services replication 10-server-b secrets; do
        ((index += 1))
        awk -v wanted="$index" '
            BEGIN { inside=0; number=0 }
            /^```ini$/ { inside=1; number+=1; next }
            /^```$/ && inside { inside=0; next }
            inside && number==wanted { print }
        ' "$docs/06-CONFIGURATION-REFERENCE.md" >"$VALIDATION_DIR/documented-examples/$name.conf.example"
        cmp -s -- "$VALIDATION_DIR/documented-examples/$name.conf.example" \
            "$PROJECT_ROOT/fixtures/documentation/full-config/$name.conf.example" \
            || fail DOCUMENTED_EXAMPLE_MISMATCH
    done
}

# Rejeita identificadores e paths operacionais não genéricos.
validate_genericity() {
    local root=$1 list="$VALIDATION_DIR/generic-files.list"
    find -P "$root" -type f -print0 >"$list"
    if xargs -0 -r grep -IqE \
        '[[:alnum:].-]+\.(lan|local|internal|net\.br)([^[:alnum:].-]|$)|(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)|/home/[[:alnum:]_.-]+|/dev/(sd[a-z][0-9]+|nvme[0-9]+n[0-9]+p[0-9]+)' \
        <"$list"; then
        fail NON_GENERIC_OPERATIONAL_IDENTIFIER
    fi
}

# Rejeita chaves, tokens, passphrases utilizáveis e arquivos secretos.
validate_secrecy() {
    local root=$1 assignments="$VALIDATION_DIR/passphrase-assignments.txt"
    if grep -R -IqiE 'BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY|ssh-(rsa|ed25519)[[:space:]]+[A-Za-z0-9+/]{20,}|AKIA[0-9A-Z]{16}' "$root"; then
        fail KEY_OR_TOKEN_MATERIAL
    fi
    grep -R -Ih 'BORG_PASSPHRASE=' "$root" >"$assignments" || true
    if grep -Fv 'BORG_PASSPHRASE=<SECRET_VALUE>' "$assignments" \
        | grep -Fv 'BORG_PASSPHRASE=SUBSTITUIR_POR_VALOR_SOB_CUSTODIA' \
        | grep -Fv 'BORG_PASSPHRASE=${BB_SECRET_CONFIG[BORG_PASSPHRASE]}' | grep -q .; then
        fail USABLE_PASSPHRASE_ASSIGNMENT
    fi
    cmp -s -- "$root/etc/borg-backup/secrets.conf" \
        "$PROJECT_ROOT/examples/etc/borg-backup/secrets.conf.example" || fail ACTIVE_SECRET_NOT_PLACEHOLDER
    if awk '!/^[[:space:]]*(#|$)/ { exit 2 }' "$root/etc/borg-backup/ssh/known_hosts"; then :;
    else fail ACTIVE_KNOWN_HOST; fi
    [[ -z $(find -P "$root" -type f \( -name '.env' -o -name authorized_keys -o -name '*repokey*' \
        -o -name '*.key' -o -name credential -o -name passphrases \) -print -quit) ]] \
        || fail PROHIBITED_SECRET_FILENAME
}

# Confere checksum, confinamento, ordem, ownership, mtime e tipos.
validate_archive_headers() {
    local archive=$1 listing="$VALIDATION_DIR/archive-paths.txt" verbose="$VALIDATION_DIR/archive-verbose.txt"
    local named="$VALIDATION_DIR/archive-named.txt"
    (cd "$BUILD_DIR" && sha256sum -c -- "$ARCHIVE_NAME.sha256") >/dev/null \
        || fail EXTERNAL_CHECKSUM_FAILED
    gzip -t -- "$archive" || fail GZIP_TEST_FAILED
    tar -tzf "$archive" >"$listing" || fail TAR_LIST_FAILED
    [[ -s $listing ]] || fail EMPTY_ARCHIVE
    grep -Eq '(^/|(^|/)\.\.(/|$))' "$listing" && fail ARCHIVE_PATH_TRAVERSAL
    [[ $(cut -d/ -f1 "$listing" | LC_ALL=C sort -u | wc -l) -eq 1 ]] \
        || fail ARCHIVE_MULTIPLE_ROOTS
    [[ $(cut -d/ -f1 "$listing" | head -n1) == "$PACKAGE_ROOT_NAME" ]] || fail ARCHIVE_ROOT_NAME
    cmp -s -- "$listing" <(LC_ALL=C sort "$listing") || fail ARCHIVE_NOT_LEXICAL
    tar --numeric-owner --full-time -tvzf "$archive" >"$verbose" || fail TAR_VERBOSE_FAILED
    awk '$2 != "0/0" { exit 2 }' "$verbose" || fail ARCHIVE_OWNER_NOT_ROOT
    tar --full-time -tvzf "$archive" >"$named" || fail TAR_NAMED_VERBOSE_FAILED
    awk '$2 != "root/root" { exit 2 }' "$named" || fail ARCHIVE_OWNER_NAMES_NOT_ROOT
    awk -v date="$EXPECTED_DATE" -v time="$EXPECTED_TIME" \
        '$4 != date || $5 != time { exit 2 }' "$verbose" || fail ARCHIVE_MTIME_NOT_NORMALIZED
    if awk 'substr($1,1,1) ~ /[hlbcps]/ { exit 2 }' "$verbose"; then :;
    else fail ARCHIVE_FORBIDDEN_TYPE; fi
}

safe_reset_directory "$VALIDATION_DIR"
safe_reset_directory "$EXTRACT_DIR"

validate_structure "$PACKAGE_TREE"; pass 'estrutura pública completa e operacional'
validate_modes "$PACKAGE_TREE"; pass 'modos POSIX do staging aprovados'
validate_types_and_metadata "$PACKAGE_TREE"; pass 'tipos, ACL e xattrs do staging aprovados'
validate_source_identity "$PACKAGE_TREE"; pass 'identidade com fontes públicas aprovada'
validate_internal_manifests "$PACKAGE_TREE"; pass 'manifestos internos íntegros'
validate_archive_headers "$ARCHIVE"; pass 'archive determinístico, confinado e íntegro'

tar --no-same-owner --same-permissions -xzf "$ARCHIVE" -C "$EXTRACT_DIR" \
    || fail ARCHIVE_EXTRACTION_FAILED
[[ -d $EXTRACTED_TREE && $(find -P "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 | wc -l) -eq 1 ]] \
    || fail EXTRACTION_ROOT_INVALID
cmp -s <(fingerprint_tree "$PACKAGE_TREE") <(fingerprint_tree "$EXTRACTED_TREE") \
    || fail STAGING_EXTRACTION_MISMATCH
pass 'extração limpa idêntica ao staging'

validate_structure "$EXTRACTED_TREE"
validate_modes "$EXTRACTED_TREE"
validate_types_and_metadata "$EXTRACTED_TREE"
validate_source_identity "$EXTRACTED_TREE"
validate_internal_manifests "$EXTRACTED_TREE"
pass 'estrutura, modos, origens e hashes extraídos aprovados'
validate_bash "$EXTRACTED_TREE"; pass 'Bash extraído 11/11'
validate_configuration_parser "$EXTRACTED_TREE"; pass 'parser em FHS sintético aprovado'
validate_integration_artifacts "$EXTRACTED_TREE"; pass 'systemd e logrotate aprovados'
validate_tmpfiles_artifact "$EXTRACTED_TREE"; pass 'tmpfiles em raiz controlada aprovado'
validate_documentation "$EXTRACTED_TREE"; pass 'documentação e exemplos aprovados'
validate_genericity "$EXTRACTED_TREE"; pass 'genericidade integral sem exceções aprovada'
validate_secrecy "$EXTRACTED_TREE"; pass 'segredos, chaves e host keys reais ausentes'

printf 'PACKAGE_VERSION=%s\n' "$PACKAGE_VERSION"
printf 'PACKAGE_VALIDATION_CHECKS=%d\n' "$CHECK_COUNT"
printf 'PACKAGE_VALIDATION=PASS\n'
