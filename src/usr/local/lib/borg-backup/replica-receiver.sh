#!/bin/bash
# Finalidade: atuar como comando SSH forçado para uma única origem de réplica.
# Entradas: raiz, origem, UUID, ID de storage e sentinela fixados pelo
# administrador, além de SSH_ORIGINAL_COMMAND; nenhum caminho é livre no cliente.
# Saídas: respostas curtas de protocolo, nunca listagens do repositório.
# Efeitos colaterais: cria incoming, valida, promove current/previous e remove
# apenas incoming identificado; protocolo rsync fica limitado à raiz dedicada.
# Dependências: Bash, flock, rsync, findmnt, coreutils e findutils.
# Privilégios: conta receptora dedicada proprietária somente da raiz atribuída.
# Códigos: 0 em operação autorizada; 2 para protocolo/estado/caminho inválido.
# Sigilo: não lê passphrase Borg, chave privada ou conteúdo de arquivos do backup.

set -Eeuo pipefail
umask 077

RECEIVER_ORIGINAL_COMMAND=${SSH_ORIGINAL_COMMAND:-""}
RECEIVER_TEST_MODE=${BB_RECEIVER_TEST_MODE:-"no"}
RECEIVER_TEST_BIN=${BB_RECEIVER_TEST_BIN:-""}
RECEIVER_CONTROL_ROOT=${BB_BOOTSTRAP_TEST_ROOT:-""}
unset SSH_ORIGINAL_COMMAND SSH_AUTH_SOCK SSH_AGENT_PID
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ $RECEIVER_TEST_MODE == "yes" ]]; then
    (( EUID != 0 )) || exit 2
    [[ $RECEIVER_CONTROL_ROOT == /* && $RECEIVER_CONTROL_ROOT != "/" \
        && -d $RECEIVER_CONTROL_ROOT && ! -L $RECEIVER_CONTROL_ROOT ]] || exit 2
    [[ $(readlink -e -- "$RECEIVER_CONTROL_ROOT") == "$RECEIVER_CONTROL_ROOT" ]] || exit 2
    [[ $(readlink -e -- "${BASH_SOURCE[0]}") == "$RECEIVER_CONTROL_ROOT/usr/local/lib/borg-backup/replica-receiver.sh" ]] || exit 2
    [[ $RECEIVER_TEST_BIN == "$RECEIVER_CONTROL_ROOT/test-bin" \
        && -d $RECEIVER_TEST_BIN && ! -L $RECEIVER_TEST_BIN ]] || exit 2
    export PATH="$RECEIVER_TEST_BIN:$PATH"
    RECEIVER_RSYNC_BINARY="$RECEIVER_TEST_BIN/rsync"
else
    RECEIVER_RSYNC_BINARY=/usr/bin/rsync
fi

RECEIVER_ROOT=""
RECEIVER_ORIGIN=""
RECEIVER_SENTINEL=""
RECEIVER_STORAGE_ID=""
RECEIVER_FILESYSTEM_UUID=""
RECEIVER_MIN_FREE_MIB=""
RECEIVER_STORAGE_PURPOSE="borg-backup"

# Valida identificador portátil usado na configuração forçada.
# Parâmetros: valor candidato.
# Resultado: 0 somente para minúsculas, números e hífen.
receiver_valid_id() {
    [[ ${1-} =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# Valida token de execução gerado localmente, sem aceitar barra ou metacaractere.
# Parâmetros: valor candidato.
# Resultado: 0 para o formato UTC-host-pid da solução.
receiver_valid_execution() {
    [[ ${1-} =~ ^[0-9]{8}T[0-9]{6}Z-[a-z0-9.-]+-[0-9]+$ ]]
}

# Valida caminho absoluto fixado pelo administrador, nunca pelo cliente.
# Parâmetros: caminho candidato e `yes` se raiz `/` fosse aceita (não usada).
# Resultado: 0 para alfabeto fechado e componentes não ambíguos.
receiver_valid_path() {
    local path=${1-}
    [[ -n $path && $path == /* && $path != "/" && $path != *[[:space:]]* ]] || return 2
    [[ $path =~ ^/[A-Za-z0-9._@+/:,-]+$ ]] || return 2
    [[ $path != *//* && $path != */./* && $path != */../* && $path != */.. ]]
}

# Normaliza e confirma contenção antes de qualquer remoção/rename.
# Parâmetros: pai fixo e alvo composto internamente.
# Resultado: 0 quando o alvo está estritamente dentro do pai.
receiver_path_within() {
    local parent child normalized_parent normalized_child
    parent=$(readlink -m -- "$1") || return 2
    child=$(readlink -m -- "$2") || return 2
    normalized_parent=$parent
    normalized_child=$child
    [[ $normalized_child == "$normalized_parent"/* && $normalized_child != "$normalized_parent" ]]
}

# Remove árvore conhecida sem seguir links simbólicos.
# Parâmetros: alvo estritamente sob RECEIVER_ROOT.
# Resultado: 0 quando ausente/removido; 2 se a salvaguarda falhar.
receiver_safe_remove_tree() {
    local target=$1
    receiver_path_within "$RECEIVER_ROOT" "$target" || return 2
    if [[ -e $target || -L $target ]]; then
        find -P "$target" -depth -delete
    fi
}

# Promove stdin para arquivo administrativo por rename no mesmo diretório.
# Parâmetros: alvo sob RECEIVER_ROOT e modo octal.
# Resultado: 0 após gravação privada e rename.
receiver_atomic_write() {
    local target=$1 mode=$2 directory temporary
    receiver_path_within "$RECEIVER_ROOT" "$target" || return 2
    directory=$(dirname -- "$target")
    [[ -d $directory && ! -L $directory ]] || return 2
    temporary=$(mktemp -- "$directory/.receiver.$(basename -- "$target").XXXXXX") || return 2
    cat >"$temporary"
    chmod "$mode" -- "$temporary"
    sync -f "$temporary" 2>/dev/null || true
    mv -fT -- "$temporary" "$target"
}

# Lê uma chave de arquivo de estado literal sem executar seu conteúdo.
# Parâmetros: arquivo sob a raiz e chave maiúscula.
# Resultado: imprime valor único ou retorna 2.
receiver_state_get() {
    local file=$1 wanted=$2 line key value found="no"
    receiver_path_within "$RECEIVER_ROOT" "$file" || return 2
    [[ -f $file && ! -L $file && $wanted =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || return 2
        key=${line%%=*}; value=${line#*=}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ && $value != *$'\n'* && $value != *$'\r'* ]] || return 2
        if [[ $key == "$wanted" ]]; then
            [[ $found == "no" ]] || return 2
            printf '%s\n' "$value"
            found="yes"
        fi
    done <"$file"
    [[ $found == "yes" ]]
}

# Valida a sentinela do receptor como duas atribuições literais e únicas.
# Parâmetros: arquivo e STORAGE_ID esperado, ambos fixados no comando forçado.
# Resultado: 0 para owner/mode/conteúdo exatos; 2 para qualquer campo extra.
receiver_validate_sentinel() {
    local file=$1 expected_id=$2 line key value count=0 owner group mode
    local expected_owner="root" expected_group="root"
    local -A seen=()
    receiver_valid_id "$expected_id" || return 2
    [[ -f $file && ! -L $file ]] || return 2
    if [[ $RECEIVER_TEST_MODE == "yes" ]]; then
        expected_owner=$(id -un)
        expected_group=$(id -gn)
    fi
    owner=$(stat -c '%U' -- "$file") || return 2
    group=$(stat -c '%G' -- "$file") || return 2
    mode=$(stat -c '%a' -- "$file") || return 2
    [[ $owner == "$expected_owner" && $group == "$expected_group" && $mode == "640" ]] || return 2
    while IFS= read -r line || [[ -n $line ]]; do
        ((count += 1))
        [[ ${line//[^=]/} == "=" && $line != "="* ]] || return 2
        key=${line%%=*}
        value=${line#*=}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ && -n $value && ! -v "seen[$key]" ]] || return 2
        seen["$key"]=1
        case $key in
            STORAGE_ID)
                receiver_valid_id "$value" || return 2
                [[ $value == "$expected_id" ]] || return 2
                ;;
            PURPOSE)
                [[ $value == "$RECEIVER_STORAGE_PURPOSE" ]] || return 2
                ;;
            *) return 2 ;;
        esac
    done <"$file"
    (( count == 2 )) || return 2
    [[ -v 'seen[STORAGE_ID]' && -v 'seen[PURPOSE]' ]]
}

# Mede espaço livre do filesystem receptor sem aplicar política de resultado.
# Parâmetros: nome da variável de saída.
# Resultado: 0 com MiB decimal; 2 para saída inválida do sistema.
receiver_available_mib() {
    local output_name=$1 available
    local -n output_ref=$output_name
    available=$(df -m --output=avail "$RECEIVER_ROOT" | tail -n 1 | tr -d '[:space:]') || return 2
    [[ $available =~ ^(0|[1-9][0-9]*)$ ]] || return 2
    output_ref=$available
}

# Valida mount ext4, UUID, sentinela e diretórios dedicados do receptor.
# Parâmetros: nenhum; usa somente argumentos forçados.
# Resultado: 0 antes do protocolo; o piso livre é verificado apenas em prepare.
receiver_validate_storage() {
    local mount_target mount_uuid mount_type
    receiver_valid_path "$RECEIVER_ROOT" || return 2
    receiver_valid_path "$RECEIVER_SENTINEL" || return 2
    receiver_valid_id "$RECEIVER_ORIGIN" || return 2
    receiver_valid_id "$RECEIVER_STORAGE_ID" || return 2
    [[ $RECEIVER_FILESYSTEM_UUID =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || return 2
    [[ $RECEIVER_MIN_FREE_MIB =~ ^[1-9][0-9]*$ ]] || return 2
    [[ -d $RECEIVER_ROOT && ! -L $RECEIVER_ROOT ]] || return 2
    receiver_validate_sentinel "$RECEIVER_SENTINEL" "$RECEIVER_STORAGE_ID" || return 2
    read -r mount_target mount_uuid mount_type < <(findmnt --noheadings --output TARGET,UUID,FSTYPE --target "$RECEIVER_ROOT") || return 2
    [[ $mount_type == "ext4" ]] || return 2
    [[ ${mount_uuid,,} == "${RECEIVER_FILESYSTEM_UUID,,}" ]] || return 2
    receiver_path_within "$mount_target" "$RECEIVER_ROOT" || return 2
    [[ $RECEIVER_SENTINEL == "$mount_target/.borg-storage" ]] || return 2
    mkdir -p -- "$RECEIVER_ROOT/state"
    chmod 0750 -- "$RECEIVER_ROOT/state"
}

# Confirma estrutura mínima e marcador de uma geração promovível.
# Parâmetros: diretório `current`, `previous` ou incoming.
# Resultado: 0 somente para meta válida da origem e repositório Borg estrutural.
receiver_generation_valid() {
    local generation=$1 meta="$1/generation.meta" format origin execution status count bytes
    [[ -d $generation && ! -L $generation && -d $generation/repo && ! -L $generation/repo ]] || return 2
    [[ -f $generation/repo/config && -d $generation/repo/data ]] || return 2
    find "$generation/repo" -maxdepth 1 -type f -name 'index.*' -print -quit | grep -q . || return 2
    format=$(receiver_state_get "$meta" FORMAT) || return 2
    origin=$(receiver_state_get "$meta" ORIGIN) || return 2
    execution=$(receiver_state_get "$meta" EXECUTION_ID) || return 2
    status=$(receiver_state_get "$meta" STATUS) || return 2
    count=$(receiver_state_get "$meta" FILE_COUNT) || return 2
    bytes=$(receiver_state_get "$meta" FILE_BYTES) || return 2
    [[ $format == "BORG-REPLICA-GENERATION-V1" && $origin == "$RECEIVER_ORIGIN" && $status == "VALID" ]] || return 2
    receiver_valid_execution "$execution" || return 2
    [[ $count =~ ^[0-9]+$ && $bytes =~ ^[0-9]+$ ]]
}

# Reconcilia apenas ausência de current com previous válida.
# Parâmetros: nenhum; lock remoto já adquirido.
# Resultado: 0 para estado conhecido; 2 sem remover estado ambíguo.
receiver_reconcile_generations() {
    local current="$RECEIVER_ROOT/current" previous="$RECEIVER_ROOT/previous"
    if [[ -e $current || -L $current ]]; then
        receiver_generation_valid "$current" || return 2
        if [[ -e $previous || -L $previous ]]; then
            receiver_generation_valid "$previous" || return 2
        fi
        return 0
    fi
    if [[ -e $previous || -L $previous ]]; then
        receiver_generation_valid "$previous" || return 2
        mv -T -- "$previous" "$current"
        sync -f "$RECEIVER_ROOT" 2>/dev/null || true
    fi
}

# Calcula métricas de arquivos regulares sem expor seus nomes.
# Parâmetros: repo e nomes de variáveis de saída.
# Resultado: 0 com count/bytes decimais.
receiver_repository_metrics() {
    local repository=$1 count_name=$2 bytes_name=$3 computed_count computed_bytes
    local -n count_ref=$count_name bytes_ref=$bytes_name
    computed_count=$(find -P "$repository" -type f -printf '.\n' | wc -l)
    computed_bytes=$(find -P "$repository" -type f -printf '%s\n' | awk '{ total += $1 } END { printf "%.0f\n", total + 0 }')
    [[ $computed_count =~ ^[0-9]+$ && $computed_bytes =~ ^[0-9]+$ ]] || return 2
    count_ref=$computed_count
    bytes_ref=$computed_bytes
}

# Injeta falha somente no modo controlado para provar pontos de interrupção.
# Parâmetros: nome fixo do ponto.
# Resultado: 2 quando control/receiver-failpoint contém o mesmo nome; 0 fora de
# teste ou quando não solicitado. Nenhum caminho de produção consulta esse dado.
receiver_test_failpoint() {
    local point=$1 control_root=${BB_BOOTSTRAP_TEST_ROOT:-""} configured=""
    [[ $RECEIVER_TEST_MODE == "yes" && -n $control_root ]] || return 0
    [[ -f $control_root/control/receiver-failpoint ]] || return 0
    configured=$(<"$control_root/control/receiver-failpoint")
    [[ $configured != "$point" ]] || return 2
}

# Prepara incoming vazio e registra token que serializa todo o protocolo.
# Parâmetros: execução, origem e mínimo livre declarados pelo emissor.
# Resultado: `READY CURRENT=yes|no`.
receiver_prepare() {
    local execution=$1 declared_origin=$2 declared_minimum=$3
    local active="$RECEIVER_ROOT/state/active.state" old_execution incoming current_flag="no" stray free_mib
    receiver_valid_execution "$execution" || return 2
    receiver_valid_id "$declared_origin" || return 2
    [[ $declared_origin == "$RECEIVER_ORIGIN" ]] || return 2
    [[ $declared_minimum =~ ^[1-9][0-9]*$ && $declared_minimum == "$RECEIVER_MIN_FREE_MIB" ]] || return 2
    receiver_available_mib free_mib || return 2
    (( 10#$free_mib >= 10#$RECEIVER_MIN_FREE_MIB )) || return 2
    receiver_reconcile_generations || return 2
    if [[ -f $active ]]; then
        # O token cobre os intervalos entre conexões SSH. Somente `abort` com o
        # ID exato pode classificá-lo e remover seu incoming sem corrida.
        old_execution=$(receiver_state_get "$active" EXECUTION_ID) || return 2
        receiver_valid_execution "$old_execution" || return 2
        return 2
    fi
    for stray in "$RECEIVER_ROOT"/incoming-*; do
        [[ -e $stray || -L $stray ]] || continue
        return 2
    done
    incoming="$RECEIVER_ROOT/incoming-$execution"
    mkdir -- "$incoming" "$incoming/repo"
    chmod 0750 -- "$incoming" "$incoming/repo"
    {
        printf 'FORMAT=RECEIVER-ACTIVE-V1\n'
        printf 'ORIGIN=%s\n' "$RECEIVER_ORIGIN"
        printf 'EXECUTION_ID=%s\n' "$execution"
        printf 'STATUS=PREPARED\n'
    } | receiver_atomic_write "$active" 0640
    receiver_generation_valid "$RECEIVER_ROOT/current" >/dev/null 2>&1 && current_flag="yes"
    printf 'READY CURRENT=%s\n' "$current_flag"
}

# Valida incoming por estrutura e métricas e grava generation.meta atômica.
# Parâmetros: execução, quantidade e bytes esperados.
# Resultado: `VALIDATED` após marcador externo ao repo.
receiver_validate_incoming() {
    local execution=$1 expected_count=$2 expected_bytes=$3 active="$RECEIVER_ROOT/state/active.state"
    local incoming="$RECEIVER_ROOT/incoming-$1" repo count bytes
    receiver_valid_execution "$execution" || return 2
    [[ $expected_count =~ ^[0-9]+$ && $expected_bytes =~ ^[0-9]+$ ]] || return 2
    [[ $(receiver_state_get "$active" EXECUTION_ID) == "$execution" ]] || return 2
    [[ $(receiver_state_get "$active" STATUS) == "PREPARED" ]] || return 2
    repo="$incoming/repo"
    [[ -f $repo/config && -d $repo/data ]] || return 2
    find "$repo" -maxdepth 1 -type f -name 'index.*' -print -quit | grep -q . || return 2
    receiver_repository_metrics "$repo" count bytes || return 2
    [[ $count == "$expected_count" && $bytes == "$expected_bytes" ]] || return 2
    {
        printf 'FORMAT=BORG-REPLICA-GENERATION-V1\n'
        printf 'ORIGIN=%s\n' "$RECEIVER_ORIGIN"
        printf 'EXECUTION_ID=%s\n' "$execution"
        printf 'STATUS=VALID\n'
        printf 'FILE_COUNT=%s\n' "$count"
        printf 'FILE_BYTES=%s\n' "$bytes"
        printf 'TIMESTAMP_UTC=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    } | receiver_atomic_write "$incoming/generation.meta" 0640
    {
        printf 'FORMAT=RECEIVER-ACTIVE-V1\n'
        printf 'ORIGIN=%s\n' "$RECEIVER_ORIGIN"
        printf 'EXECUTION_ID=%s\n' "$execution"
        printf 'STATUS=VALIDATED\n'
    } | receiver_atomic_write "$active" 0640
    printf 'VALIDATED\n'
}

# Promove incoming validada, mantendo current anterior como previous.
# Parâmetros: execução.
# Resultado: `PROMOTED` após fsync do diretório pai.
receiver_promote() {
    local execution=$1 active="$RECEIVER_ROOT/state/active.state" incoming="$RECEIVER_ROOT/incoming-$1"
    local current="$RECEIVER_ROOT/current" previous="$RECEIVER_ROOT/previous" free_mib capacity="OK"
    receiver_valid_execution "$execution" || return 2
    [[ $(receiver_state_get "$active" EXECUTION_ID) == "$execution" ]] || return 2
    [[ $(receiver_state_get "$active" STATUS) == "VALIDATED" ]] || return 2
    receiver_generation_valid "$incoming" || return 2
    receiver_reconcile_generations || return 2
    if [[ -e $previous || -L $previous ]]; then
        receiver_generation_valid "$current" || return 2
        receiver_safe_remove_tree "$previous" || return 2
        receiver_test_failpoint after-remove-previous || return 2
    fi
    if [[ -e $current || -L $current ]]; then
        receiver_generation_valid "$current" || return 2
        mv -T -- "$current" "$previous"
        receiver_test_failpoint after-current-to-previous || return 2
    fi
    mv -T -- "$incoming" "$current"
    receiver_test_failpoint after-incoming-to-current || return 2
    sync -f "$RECEIVER_ROOT" 2>/dev/null || true
    find -P "$active" -delete
    receiver_available_mib free_mib || return 2
    if (( 10#$free_mib < 10#$RECEIVER_MIN_FREE_MIB )); then
        capacity="WARNING"
    fi
    printf 'PROMOTED CAPACITY=%s\n' "$capacity"
}

# Cancela somente incoming ativa e incompleta da execução indicada.
# Parâmetros: execução.
# Resultado: `ABORTED`; geração já validada não é removida automaticamente.
receiver_abort() {
    local execution=$1 active="$RECEIVER_ROOT/state/active.state" incoming="$RECEIVER_ROOT/incoming-$1"
    receiver_valid_execution "$execution" || return 2
    [[ -f $active && $(receiver_state_get "$active" EXECUTION_ID) == "$execution" ]] || return 2
    [[ ! -e $incoming/generation.meta ]] || return 2
    receiver_safe_remove_tree "$incoming" || return 2
    find -P "$active" -delete
    printf 'ABORTED\n'
}

# Informa apenas presença das gerações válidas e token ativo.
# Parâmetros: nenhum.
# Resultado: linha sem paths ou conteúdo do repositório.
receiver_status() {
    local current="no" previous="no" active="no"
    receiver_generation_valid "$RECEIVER_ROOT/current" >/dev/null 2>&1 && current="yes"
    receiver_generation_valid "$RECEIVER_ROOT/previous" >/dev/null 2>&1 && previous="yes"
    [[ -f $RECEIVER_ROOT/state/active.state ]] && active="yes"
    printf 'CURRENT=%s PREVIOUS=%s ACTIVE=%s\n' "$current" "$previous" "$active"
}

# Autoriza somente argv servidor rsync sem remoção, inplace ou path livre.
# Parâmetros: palavras já separadas de SSH_ORIGINAL_COMMAND.
# Resultado: substitui o processo pelo rsync permitido, mantendo o flock aberto.
receiver_rsync_server() {
    local -a words=("$@")
    local index=2 expected active execution transfer_mode current_valid="no"
    (( ${#words[@]} >= 8 )) || return 2
    [[ ${words[0]} == "rsync" && ${words[1]} == "--server" ]] || return 2
    active="$RECEIVER_ROOT/state/active.state"
    execution=$(receiver_state_get "$active" EXECUTION_ID) || return 2
    [[ $(receiver_state_get "$active" STATUS) == "PREPARED" ]] || return 2
    expected="$RECEIVER_ROOT/incoming-$execution/repo/"
    receiver_generation_valid "$RECEIVER_ROOT/current" >/dev/null 2>&1 && current_valid="yes"

    # Debian 13/rsync 3.x converte exatamente as opções fixas do emissor nestes
    # dois blobs servidor. Aceitar outros flags curtos ampliaria a interface.
    case ${words[$index]} in
        -lHtpre.iLsfxCIvu) transfer_mode="write" ;;
        -nlHtpre.iLsfxCIvu) transfer_mode="dry-run" ;;
        *) return 2 ;;
    esac
    ((index += 1))
    if [[ $transfer_mode == "dry-run" ]]; then
        [[ ${words[$index]:-} == "--log-format=%i" ]] || return 2
        ((index += 1))
    fi
    [[ ${words[$index]:-} == "--partial-dir" && ${words[$((index + 1))]:-} == ".rsync-partial" ]] || return 2
    ((index += 2))
    [[ ${words[$index]:-} == "--delay-updates" ]] || return 2
    ((index += 1))
    [[ ${words[$index]:-} == "--fsync" ]] || return 2
    ((index += 1))
    if [[ $current_valid == "yes" ]]; then
        [[ ${words[$index]:-} == "--link-dest" ]] || return 2
        [[ ${words[$((index + 1))]:-} == "$RECEIVER_ROOT/current/repo" ]] || return 2
        ((index += 2))
    fi
    [[ ${words[$index]:-} == "." ]] || return 2
    ((index += 1))
    [[ ${words[$index]:-} == "$expected" ]] || return 2
    ((index += 1))
    (( index == ${#words[@]} )) || return 2
    [[ -x $RECEIVER_RSYNC_BINARY ]] || return 2
    exec "$RECEIVER_RSYNC_BINARY" "${words[@]:1}"
}

# Analisa somente os argumentos administrativos do comando forçado.
# Parâmetros: argv do script.
# Resultado: preenche seis constantes obrigatórias ou retorna 2.
receiver_parse_fixed_arguments() {
    while (( $# > 0 )); do
        case $1 in
            --root) (( $# >= 2 )) || return 2; RECEIVER_ROOT=$2; shift 2 ;;
            --origin) (( $# >= 2 )) || return 2; RECEIVER_ORIGIN=$2; shift 2 ;;
            --sentinel) (( $# >= 2 )) || return 2; RECEIVER_SENTINEL=$2; shift 2 ;;
            --storage-id) (( $# >= 2 )) || return 2; RECEIVER_STORAGE_ID=$2; shift 2 ;;
            --filesystem-uuid) (( $# >= 2 )) || return 2; RECEIVER_FILESYSTEM_UUID=$2; shift 2 ;;
            --min-free-mib) (( $# >= 2 )) || return 2; RECEIVER_MIN_FREE_MIB=$2; shift 2 ;;
            *) return 2 ;;
        esac
    done
    [[ -n $RECEIVER_ROOT && -n $RECEIVER_ORIGIN && -n $RECEIVER_SENTINEL \
        && -n $RECEIVER_STORAGE_ID && -n $RECEIVER_FILESYSTEM_UUID \
        && -n $RECEIVER_MIN_FREE_MIB ]]
}

receiver_parse_fixed_arguments "$@" || exit 2
if [[ $RECEIVER_TEST_MODE == "yes" ]]; then
    receiver_path_within "$RECEIVER_CONTROL_ROOT/remotes" "$RECEIVER_ROOT" || exit 2
    receiver_path_within "$RECEIVER_CONTROL_ROOT/remotes" "$RECEIVER_SENTINEL" || exit 2
fi
receiver_validate_storage || exit 2
exec 9>"$RECEIVER_ROOT/state/replication.lock"
flock -n 9 || exit 2

[[ -n $RECEIVER_ORIGINAL_COMMAND && $RECEIVER_ORIGINAL_COMMAND != *$'\n'* && $RECEIVER_ORIGINAL_COMMAND != *$'\r'* ]] || exit 2
[[ $RECEIVER_ORIGINAL_COMMAND =~ ^[A-Za-z0-9_./%@=:+,[:space:]-]+$ ]] || exit 2
read -r -a RECEIVER_WORDS <<<"$RECEIVER_ORIGINAL_COMMAND"

case ${RECEIVER_WORDS[0]:-} in
    prepare)
        (( ${#RECEIVER_WORDS[@]} == 4 )) || exit 2
        receiver_prepare "${RECEIVER_WORDS[1]}" "${RECEIVER_WORDS[2]}" "${RECEIVER_WORDS[3]}"
        ;;
    validate)
        (( ${#RECEIVER_WORDS[@]} == 4 )) || exit 2
        receiver_validate_incoming "${RECEIVER_WORDS[1]}" "${RECEIVER_WORDS[2]}" "${RECEIVER_WORDS[3]}"
        ;;
    promote)
        (( ${#RECEIVER_WORDS[@]} == 2 )) || exit 2
        receiver_promote "${RECEIVER_WORDS[1]}"
        ;;
    abort)
        (( ${#RECEIVER_WORDS[@]} == 2 )) || exit 2
        receiver_abort "${RECEIVER_WORDS[1]}"
        ;;
    status)
        (( ${#RECEIVER_WORDS[@]} == 1 )) || exit 2
        receiver_status
        ;;
    rsync)
        receiver_rsync_server "${RECEIVER_WORDS[@]}"
        ;;
    *)
        exit 2
        ;;
esac
