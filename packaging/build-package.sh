#!/bin/bash
# Finalidade: materializar um pacote público determinístico do Borg Backup.
# Entradas: slot `a` ou `b`, VERSION da raiz e SOURCE_DATE_EPOCH no ambiente.
# Saídas: árvore, tar.gz, checksum e inventários sob packaging/work/build-{a,b}.
# Arquivos alterados: somente o slot de build selecionado sob packaging/work.
# Efeitos colaterais: recria a saída controlada; não toca FHS, rede ou hosts.
# Dependências: Bash, coreutils, findutils, GNU tar, gzip, awk, sed e sort.
# Privilégios: usuário comum; saídas fora de packaging/work são recusadas.
# Códigos: 0 em sucesso; 64 para entrada inválida; 2 para contrato violado.
# Sigilo: inclui somente fontes públicas e aplica nomes relativos na proveniência.

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
readonly VERSION_FILE="$PROJECT_ROOT/VERSION"
readonly SPECIFICATION="$PROJECT_ROOT/docs/reference/SPECIFICATION.md"

# Encerra o build com uma mensagem de contrato e código de falha técnica.
fail() {
    printf '%s\n' "$1" >&2
    exit 2
}

[[ $# -eq 1 ]] || {
    printf 'uso: SOURCE_DATE_EPOCH=<epoch> %s a|b\n' "$0" >&2
    exit 64
}

case $1 in
    a|b) BUILD_SLOT=$1 ;;
    *) printf 'slot de build inválido: %s\n' "$1" >&2; exit 64 ;;
esac
readonly BUILD_SLOT

[[ -f $VERSION_FILE && ! -L $VERSION_FILE ]] || fail VERSION_FILE_MISSING_OR_UNSAFE
[[ $(awk 'END { print NR }' "$VERSION_FILE") -eq 1 ]] || fail VERSION_FILE_NOT_SINGLE_LINE
IFS= read -r PACKAGE_VERSION <"$VERSION_FILE"
[[ $PACKAGE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail VERSION_NOT_SEMVER
readonly PACKAGE_VERSION

[[ ${SOURCE_DATE_EPOCH+x} == x && $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || {
    printf 'SOURCE_DATE_EPOCH decimal é obrigatório; o build não consulta o relógio\n' >&2
    exit 64
}
RELEASE_DATE=$(date -u -d "@$SOURCE_DATE_EPOCH" +%F 2>/dev/null) \
    || fail SOURCE_DATE_EPOCH_OUT_OF_RANGE
export SOURCE_DATE_EPOCH
readonly SOURCE_DATE_EPOCH RELEASE_DATE

readonly PACKAGE_ROOT_NAME="borg-backup-debian13-$PACKAGE_VERSION"
readonly ARCHIVE_NAME="$PACKAGE_ROOT_NAME.tar.gz"
readonly BUILD_DIR="$WORK_DIR/build-$BUILD_SLOT"
readonly PACKAGE_ROOT="$BUILD_DIR/$PACKAGE_ROOT_NAME"
readonly PROVENANCE="$BUILD_DIR/PROVENANCE.tsv"
readonly SOURCE_INVENTORY="$BUILD_DIR/SOURCE-INVENTORY.tsv"
readonly ARCHIVE="$BUILD_DIR/$ARCHIVE_NAME"
readonly ARCHIVE_CHECKSUM="$ARCHIVE.sha256"

[[ -f $SPECIFICATION && ! -L $SPECIFICATION ]] || fail PUBLIC_SPECIFICATION_MISSING_OR_UNSAFE
[[ -f $PROJECT_ROOT/LICENSE && ! -L $PROJECT_ROOT/LICENSE ]] || fail LICENSE_MISSING_OR_UNSAFE
[[ -f $PROJECT_ROOT/NOTICE && ! -L $PROJECT_ROOT/NOTICE ]] || fail NOTICE_MISSING_OR_UNSAFE

runtime_version=$(sed -n 's/^declare -gr BB_VERSION="\([^"]*\)"$/\1/p' \
    "$PROJECT_ROOT/src/usr/local/lib/borg-backup/common.sh")
[[ $runtime_version == "$PACKAGE_VERSION" ]] || fail RUNTIME_VERSION_MISMATCH

# Cria a raiz confinada ou rejeita um objeto inseguro no mesmo path.
prepare_work_directory() {
    if [[ -e $WORK_DIR || -L $WORK_DIR ]]; then
        [[ -d $WORK_DIR && ! -L $WORK_DIR && $(readlink -e -- "$WORK_DIR") == "$WORK_DIR" ]] \
            || fail WORK_DIRECTORY_UNSAFE
    else
        mkdir -p -- "$WORK_DIR"
        chmod 0700 -- "$WORK_DIR"
    fi
}

# Recria exclusivamente o slot A ou B resolvido sob packaging/work.
reset_build_directory() {
    local canonical
    canonical=$(readlink -m -- "$BUILD_DIR")
    [[ $canonical == "$WORK_DIR/build-$BUILD_SLOT" ]] || fail BUILD_DIRECTORY_UNSAFE
    if [[ -e $canonical || -L $canonical ]]; then
        [[ ! -L $canonical ]] || fail BUILD_DIRECTORY_IS_SYMLINK
        find -P "$canonical" -depth -delete
    fi
    mkdir -p -- "$canonical"
    chmod 0700 -- "$canonical"
}

# Registra uma entrada normalizada na proveniência interna do pacote.
register_entry() {
    local path=$1 type=$2 mode=$3 class=$4 source=$5 justification=$6 value
    for value in "$path" "$type" "$mode" "$class" "$source" "$justification"; do
        [[ $value != *$'\t'* && $value != *$'\n'* ]] || fail PROVENANCE_FIELD_UNSAFE
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$type" "$mode" "$class" "$source" "$justification" >>"$PROVENANCE"
}

# Materializa um diretório do pacote com modo e proveniência explícitos.
make_package_directory() {
    local path=$1 mode=$2 class=$3 source=$4 justification=$5 target
    if [[ $path == . ]]; then target=$PACKAGE_ROOT; else target=$PACKAGE_ROOT/$path; fi
    mkdir -p -- "$target"
    chmod "$mode" -- "$target"
    register_entry "$path" directory "$mode" "$class" "$source" "$justification"
}

# Instala um arquivo público regular com modo controlado.
install_package_file() {
    local source=$1 path=$2 mode=$3 class=$4 justification=$5 source_label parent
    [[ -f $source && ! -L $source ]] || fail SOURCE_FILE_MISSING_OR_UNSAFE
    parent=${path%/*}
    [[ $parent != "$path" ]] || parent=.
    [[ -d $PACKAGE_ROOT/$parent ]] || fail PACKAGE_PARENT_MISSING
    install -m "$mode" -- "$source" "$PACKAGE_ROOT/$path"
    source_label=${source#"$PROJECT_ROOT/"}
    register_entry "$path" file "$mode" "$class" "$source_label" "$justification"
}

# Renderiza um template apenas com metadados determinísticos.
render_template() {
    local source=$1 path=$2 mode=$3 class=$4 justification=$5
    [[ -f $source && ! -L $source ]] || fail TEMPLATE_MISSING_OR_UNSAFE
    sed -e "s/@PACKAGE_VERSION@/$PACKAGE_VERSION/g" \
        -e "s/@SOURCE_DATE_EPOCH@/$SOURCE_DATE_EPOCH/g" \
        -e "s/@RELEASE_DATE@/$RELEASE_DATE/g" \
        -e "s/@SPECIFICATION_SHA256@/$SPECIFICATION_SHA256/g" \
        -- "$source" >"$PACKAGE_ROOT/$path"
    chmod "$mode" -- "$PACKAGE_ROOT/$path"
    register_entry "$path" file "$mode" "$class" \
        "${source#"$PROJECT_ROOT/"}" "$justification"
}

# Recupera classe e origem já registradas na proveniência.
lookup_provenance() {
    local path=$1
    awk -F '\t' -v wanted="$path" '
        $1 == wanted { print $4 "\t" $5; found=1; exit }
        END { if (!found) exit 2 }
    ' "$PROVENANCE"
}

# Gera o manifesto interno não circular da árvore materializada.
generate_internal_manifest() {
    local manifest="$PACKAGE_ROOT/MANIFEST.tsv" entry path type mode size hash metadata class source
    printf 'PATH\tTYPE\tMODE\tOWNER\tGROUP\tSIZE\tSHA256\tSOURCE_CLASS\tSOURCE_PATH\n' >"$manifest"
    while IFS= read -r -d '' entry; do
        path=${entry#"$PACKAGE_ROOT/"}
        [[ $path == MANIFEST.tsv || $path == MANIFEST.sha256 ]] && continue
        if [[ -d $entry && ! -L $entry ]]; then
            type=directory; size=-; hash=-
        elif [[ -f $entry && ! -L $entry ]]; then
            type=file
            size=$(stat -c '%s' -- "$entry")
            hash=$(sha256sum <"$entry"); hash=${hash%% *}
        else
            fail PACKAGE_FORBIDDEN_FILE_TYPE
        fi
        mode=$(printf '%04d' "$(stat -c '%a' -- "$entry")")
        metadata=$(lookup_provenance "$path") || fail PROVENANCE_ENTRY_MISSING
        IFS=$'\t' read -r class source <<<"$metadata"
        printf '%s\t%s\t%s\troot\troot\t%s\t%s\t%s\t%s\n' \
            "$path" "$type" "$mode" "$size" "$hash" "$class" "$source" >>"$manifest"
    done < <(find -P "$PACKAGE_ROOT" -mindepth 1 -print0 | sort -z)
    chmod 0644 -- "$manifest"
    register_entry MANIFEST.tsv file 0644 PACKAGE_METADATA GENERATED:MANIFEST.tsv \
        'Manifesto interno não circular.'
}

# Gera checksums, autoexcluindo somente o próprio arquivo.
generate_internal_checksums() {
    local checksum="$PACKAGE_ROOT/MANIFEST.sha256" file path hash
    : >"$checksum"
    while IFS= read -r -d '' file; do
        path=${file#"$PACKAGE_ROOT/"}
        [[ $path == MANIFEST.sha256 ]] && continue
        hash=$(sha256sum <"$file"); hash=${hash%% *}
        printf '%s  %s\n' "$hash" "$path" >>"$checksum"
    done < <(find -P "$PACKAGE_ROOT" -type f -print0 | sort -z)
    chmod 0644 -- "$checksum"
    register_entry MANIFEST.sha256 file 0644 PACKAGE_METADATA GENERATED:MANIFEST.sha256 \
        'Checksums internos; somente este arquivo se autoexclui.'
}

# Gera o inventário de fontes e destinos a partir da proveniência.
generate_source_inventory() {
    local path type mode class source justification sha package_path
    printf 'SOURCE_PATH\tPACKAGE_PATH\tTYPE\tEXPECTED_OWNER\tEXPECTED_GROUP\tEXPECTED_MODE\tSHA256\tSOURCE_CLASS\tINCLUDE_STATUS\tJUSTIFICATION\n' \
        >"$SOURCE_INVENTORY"
    while IFS=$'\t' read -r path type mode class source justification; do
        [[ $path == PATH ]] && continue
        if [[ $path == . ]]; then
            package_path=$PACKAGE_ROOT_NAME; sha=-
        else
            package_path=$PACKAGE_ROOT_NAME/$path
            if [[ $type == file ]]; then
                sha=$(sha256sum <"$PACKAGE_ROOT/$path"); sha=${sha%% *}
            else
                sha=-
            fi
        fi
        printf '%s\t%s\t%s\troot\troot\t%s\t%s\t%s\tINCLUDED\t%s\n' \
            "$source" "$package_path" "$type" "$mode" "$sha" "$class" "$justification"
    done < <(LC_ALL=C sort -t $'\t' -k1,1 "$PROVENANCE") >>"$SOURCE_INVENTORY"
    chmod 0644 -- "$SOURCE_INVENTORY"
}

# Normaliza todos os mtimes da árvore para SOURCE_DATE_EPOCH.
normalize_timestamps() {
    local entry
    while IFS= read -r -d '' entry; do
        touch -h -d "@$SOURCE_DATE_EPOCH" -- "$entry"
    done < <(find -P "$PACKAGE_ROOT" -depth -print0)
}

# Cria tar e gzip determinísticos e o checksum externo.
create_archive() {
    local tar_path="$BUILD_DIR/$PACKAGE_ROOT_NAME.tar" archive_hash
    tar --sort=name --format=posix --owner=root --group=root \
        --mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime --no-acls --no-xattrs --no-selinux \
        --pax-option='delete=atime,delete=ctime,delete=SCHILY.xattr.*,delete=LIBARCHIVE.xattr.*' \
        -C "$BUILD_DIR" -cf "$tar_path" -- "$PACKAGE_ROOT_NAME"
    gzip -n -9 -c -- "$tar_path" >"$ARCHIVE"
    rm -- "$tar_path"
    chmod 0644 -- "$ARCHIVE"
    archive_hash=$(sha256sum <"$ARCHIVE"); archive_hash=${archive_hash%% *}
    printf '%s  %s\n' "$archive_hash" "$ARCHIVE_NAME" >"$ARCHIVE_CHECKSUM"
    chmod 0644 -- "$ARCHIVE_CHECKSUM"
}

prepare_work_directory
reset_build_directory
mkdir -p -- "$PACKAGE_ROOT"
printf 'PATH\tTYPE\tMODE\tSOURCE_CLASS\tSOURCE_PATH\tJUSTIFICATION\n' >"$PROVENANCE"
SPECIFICATION_SHA256=$(sha256sum <"$SPECIFICATION"); SPECIFICATION_SHA256=${SPECIFICATION_SHA256%% *}
readonly SPECIFICATION_SHA256

make_package_directory . 0755 PACKAGE_METADATA GENERATED:PACKAGE_ROOT 'Raiz versionada do release.'
make_package_directory docs 0755 GENERIC_DOCUMENTATION docs 'Documentação técnica pública.'
make_package_directory docs/reference 0755 PUBLIC_SPECIFICATION docs/reference 'Especificação pública autocontida.'
make_package_directory etc 0755 CONFIGURATION_TEMPLATE GENERATED:FHS 'Prefixo FHS de configuração.'
make_package_directory etc/borg-backup 0750 CONFIGURATION_TEMPLATE examples/etc/borg-backup 'Configuração operacional a revisar.'
make_package_directory etc/borg-backup/replication.d 0750 CONFIGURATION_TEMPLATE examples/etc/borg-backup/replication.d 'Destinos declarados.'
make_package_directory etc/borg-backup/ssh 0700 CONFIGURATION_TEMPLATE examples/etc/borg-backup/ssh 'Metadados SSH dedicados.'
make_package_directory etc/borg-backup/ssh/keys 0700 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_KEYS_DIRECTORY 'Diretório vazio para chaves provisionadas externamente.'
make_package_directory etc/systemd 0755 SYSTEMD_UNIT GENERATED:FHS 'Prefixo FHS systemd.'
make_package_directory etc/systemd/system 0755 SYSTEMD_UNIT src/etc/systemd/system 'Units locais não ativadas.'
make_package_directory etc/logrotate.d 0755 LOGROTATE_POLICY src/etc/logrotate.d 'Política de rotação.'
make_package_directory usr 0755 PRODUCT_CODE GENERATED:FHS 'Prefixo FHS de código.'
make_package_directory usr/local 0755 PRODUCT_CODE GENERATED:FHS 'Prefixo de software local.'
make_package_directory usr/local/sbin 0755 PRODUCT_CODE src/usr/local/sbin 'Ponto de entrada administrativo.'
make_package_directory usr/local/lib 0755 PRODUCT_CODE GENERATED:FHS 'Prefixo de bibliotecas.'
make_package_directory usr/local/lib/borg-backup 0755 PRODUCT_CODE src/usr/local/lib/borg-backup 'Módulos internos Bash.'
make_package_directory usr/local/lib/tmpfiles.d 0755 SYSTEMD_TMPFILES src/usr/local/lib/tmpfiles.d 'Regra de runtime volátil.'
make_package_directory var 0755 EMPTY_RUNTIME_DIRECTORY GENERATED:FHS 'Prefixo FHS variável.'
make_package_directory var/lib 0755 EMPTY_RUNTIME_DIRECTORY GENERATED:FHS 'Prefixo de estado.'
make_package_directory var/lib/borg-backup 0750 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_STATE 'Estado persistente inicialmente vazio.'
make_package_directory var/lib/borg-backup/state 0750 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_STATE 'Estado geral inicialmente vazio.'
make_package_directory var/lib/borg-backup/state/replication 0750 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_STATE 'Estado de replicação inicialmente vazio.'
make_package_directory var/log 0755 EMPTY_RUNTIME_DIRECTORY GENERATED:FHS 'Prefixo de logs.'
make_package_directory var/log/borg-backup 0750 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_LOG 'Log inicialmente vazio.'
make_package_directory var/tmp 0755 EMPTY_RUNTIME_DIRECTORY GENERATED:FHS 'Prefixo de temporários.'
make_package_directory var/tmp/borg-backup 0700 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_TMP 'Temporários privados inicialmente vazios.'
make_package_directory run 0755 EMPTY_RUNTIME_DIRECTORY GENERATED:FHS 'Prefixo de runtime.'
make_package_directory run/borg-backup 0750 EMPTY_RUNTIME_DIRECTORY GENERATED:EMPTY_RUN 'Lock e runtime inicialmente vazios.'
make_package_directory install 0755 INSTALLATION_RUNBOOK packaging/templates 'Runbooks sem instalador automático.'

install_package_file "$VERSION_FILE" VERSION 0644 PACKAGE_METADATA 'Fonte única da versão.'
install_package_file "$PROJECT_ROOT/LICENSE" LICENSE 0644 LICENSE_TEXT 'Licença GPL-3.0 do projeto.'
install_package_file "$PROJECT_ROOT/NOTICE" NOTICE 0644 LICENSE_NOTICE 'Identidade autoral e opção or-later.'
render_template "$TEMPLATE_ROOT/PACKAGE-METADATA.tsv.in" PACKAGE-METADATA.tsv 0644 PACKAGE_METADATA 'Metadados determinísticos do release.'
render_template "$TEMPLATE_ROOT/PACKAGE-README.md" README.md 0644 PACKAGE_METADATA 'Entrada pública do pacote.'
render_template "$TEMPLATE_ROOT/RELEASE-NOTES.md" RELEASE-NOTES.md 0644 PACKAGE_METADATA 'Notas públicas do release.'
install_package_file "$TEMPLATE_ROOT/INSTALL-README.md" install/README.md 0644 INSTALLATION_RUNBOOK 'Procedimento de instalação controlada.'
install_package_file "$TEMPLATE_ROOT/FHS-DIRECTORIES.tsv" install/FHS-DIRECTORIES.tsv 0644 INSTALLATION_RUNBOOK 'Mapa de ownership e modos.'
install_package_file "$TEMPLATE_ROOT/POST-INSTALL-CHECKLIST.md" install/POST-INSTALL-CHECKLIST.md 0644 INSTALLATION_RUNBOOK 'Checklist administrativo.'

while IFS= read -r -d '' document; do
    install_package_file "$document" "docs/${document##*/}" 0644 GENERIC_DOCUMENTATION 'Documento técnico público.'
done < <(find -P "$PROJECT_ROOT/docs" -maxdepth 1 -type f -print0 | sort -z)
install_package_file "$SPECIFICATION" docs/reference/SPECIFICATION.md 0644 PUBLIC_SPECIFICATION 'Especificação pública sanitizada.'

for config in applications backup databases excludes replication services sources; do
    install_package_file "$PROJECT_ROOT/examples/etc/borg-backup/$config.conf.example" \
        "etc/borg-backup/$config.conf" 0640 CONFIGURATION_TEMPLATE 'Modelo público materializado no path operacional.'
done
install_package_file "$PROJECT_ROOT/examples/etc/borg-backup/replication.d/10-destination.conf.example" \
    etc/borg-backup/replication.d/10-destination.conf 0640 CONFIGURATION_TEMPLATE 'Destino público materializado no path operacional.'
install_package_file "$PROJECT_ROOT/examples/etc/borg-backup/ssh/known_hosts.example" \
    etc/borg-backup/ssh/known_hosts 0640 CONFIGURATION_TEMPLATE 'Known-hosts vazio e comentado.'
install_package_file "$PROJECT_ROOT/examples/etc/borg-backup/secrets.conf.example" \
    etc/borg-backup/secrets.conf 0600 CONFIGURATION_TEMPLATE 'Placeholder inválido no path operacional até provisionamento.'

install_package_file "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.service" \
    etc/systemd/system/borg-backup.service 0644 SYSTEMD_UNIT 'Unit oneshot pública e não ativada.'
install_package_file "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.timer" \
    etc/systemd/system/borg-backup.timer 0644 SYSTEMD_UNIT 'Timer público e não ativado.'
install_package_file "$PROJECT_ROOT/src/etc/logrotate.d/borg-backup" \
    etc/logrotate.d/borg-backup 0644 LOGROTATE_POLICY 'Política pública de logs.'
install_package_file "$PROJECT_ROOT/src/usr/local/lib/tmpfiles.d/borg-backup.conf" \
    usr/local/lib/tmpfiles.d/borg-backup.conf 0644 SYSTEMD_TMPFILES 'Recriação de /run/borg-backup.'
install_package_file "$PROJECT_ROOT/src/usr/local/sbin/borg-backup" \
    usr/local/sbin/borg-backup 0755 PRODUCT_CODE 'Ponto de entrada administrativo.'
for module in applications.sh backup.sh common.sh config.sh databases.sh logging.sh maintenance.sh replication.sh services.sh; do
    install_package_file "$PROJECT_ROOT/src/usr/local/lib/borg-backup/$module" \
        "usr/local/lib/borg-backup/$module" 0644 PRODUCT_CODE 'Módulo interno carregado pelo ponto de entrada.'
done
install_package_file "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replica-receiver.sh" \
    usr/local/lib/borg-backup/replica-receiver.sh 0755 PRODUCT_CODE 'Receptor SSH restrito.'

generate_internal_manifest
generate_internal_checksums
generate_source_inventory
normalize_timestamps
create_archive

printf 'PACKAGE_VERSION=%s\n' "$PACKAGE_VERSION"
printf 'PACKAGE_ROOT=%s\n' "$PACKAGE_ROOT"
printf 'ARCHIVE=%s\n' "$ARCHIVE"
printf 'ARCHIVE_CHECKSUM=%s\n' "$ARCHIVE_CHECKSUM"
printf 'SOURCE_INVENTORY=%s\n' "$SOURCE_INVENTORY"
printf 'ARCHIVE_SHA256=%s\n' "$(sha256sum <"$ARCHIVE" | awk '{print $1}')"
