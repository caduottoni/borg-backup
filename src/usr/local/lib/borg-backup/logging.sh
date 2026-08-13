#!/bin/bash
# Finalidade: produzir eventos legíveis, relatórios atômicos e estado mínimo.
# Entradas: IDs e estados não sensíveis; diretórios definidos por common.sh.
# Saídas: stderr (capturado pelo journal), backup.log quando habilitado,
# last-run.report, last-success.report e pequenos arquivos de estado.
# Efeitos colaterais: somente append no log e promoção atômica de relatórios.
# Dependências: Bash e funções de common.sh.
# Privilégios: os mesmos do ponto de entrada.
# Códigos: 0 em sucesso e 2 quando a persistência administrativa falha.
# Sigilo: mensagens são normalizadas e qualquer segredo conhecido é redigido.

set -Eeuo pipefail
umask 077

declare -g BB_EXECUTION_ID="not-started"
declare -g BB_FILE_LOG_ENABLED="no"
declare -g BB_LOG_FILE=""
declare -ga BB_SECRET_VALUES=()
declare -gA BB_REPORT_VALUES=()
declare -g BB_REPORT_FINALIZED="no"

# Prepara o arquivo de log somente quando a configuração o habilita.
# Parâmetros: nenhum; usa BB_FILE_LOG_ENABLED e BB_LOG_DIR.
# Resultado: 0 com arquivo regular modo 0640, ou 2 sem seguir link simbólico.
bb_initialize_logging() {
    local expected_owner="root" expected_group="root"
    BB_LOG_FILE="$BB_LOG_DIR/backup.log"
    if [[ $BB_TEST_MODE == "yes" ]]; then
        expected_owner=$(id -un)
        expected_group=$(id -gn)
    fi
    if [[ $BB_FILE_LOG_ENABLED == "yes" ]]; then
        [[ ! -L $BB_LOG_FILE ]] || return "$BB_EXIT_CRITICAL"
        if [[ ! -e $BB_LOG_FILE ]]; then
            : >"$BB_LOG_FILE"
            chmod 0640 -- "$BB_LOG_FILE"
        fi
        [[ -f $BB_LOG_FILE \
            && $(stat -c '%U' -- "$BB_LOG_FILE") == "$expected_owner" \
            && $(stat -c '%G' -- "$BB_LOG_FILE") == "$expected_group" \
            && $(stat -c '%a' -- "$BB_LOG_FILE") == "640" ]] || return "$BB_EXIT_CRITICAL"
    fi
}

# Registra um valor secreto apenas para redação defensiva de mensagens.
# Parâmetros: valor; vazio é ignorado.
# Resultado: sempre 0 e nunca imprime o valor.
bb_register_secret_for_redaction() {
    local secret=${1-}
    [[ -n $secret ]] && BB_SECRET_VALUES+=("$secret")
    return "$BB_EXIT_OK"
}

# Remove quebras de linha e substitui segredos conhecidos por marcador fixo.
# Parâmetros: texto potencialmente não confiável.
# Resultado: imprime uma única linha sanitizada.
bb_sanitize_log_message() {
    local message=${1-}
    local secret
    message=${message//$'\n'/ }
    message=${message//$'\r'/ }
    for secret in "${BB_SECRET_VALUES[@]}"; do
        [[ -n $secret ]] || continue
        message=${message//"$secret"/[REDACTED]}
    done
    printf '%s\n' "$message"
}

# Emite o mesmo evento essencial para stderr/journal e log persistente.
# Parâmetros: nível, componente, evento e mensagem já sem dados desnecessários.
# Resultado: 0; falha de append é reportada e retorna 2.
bb_log() {
    local level=$1 component=$2 event=$3 message=$4
    local timestamp sanitized line
    timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    sanitized=$(bb_sanitize_log_message "$message")
    line="$timestamp $level $BB_EXECUTION_ID $component $event $sanitized"
    printf '%s\n' "$line" >&2
    if [[ $BB_FILE_LOG_ENABLED == "yes" ]]; then
        printf '%s\n' "$line" >>"$BB_LOG_FILE" || return "$BB_EXIT_CRITICAL"
    fi
}

# Define um campo não sensível do relatório final.
# Parâmetros: chave em maiúsculas e valor de uma linha.
# Resultado: 0; 2 para chave ou valor inseguros.
bb_report_set() {
    local key=$1 value=$2
    [[ $key =~ ^[A-Z][A-Z0-9_.-]*$ || $key =~ ^REPLICATION\[[a-z0-9-]+\]$ ]] || return "$BB_EXIT_CRITICAL"
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || return "$BB_EXIT_CRITICAL"
    BB_REPORT_VALUES["$key"]=$value
}

# Serializa o relatório em ordem lexical e o promove atomicamente.
# Parâmetros: caminho final.
# Resultado: 0 após gravação; 2 em falha.
bb_write_report() {
    local target=$1 key padding_width padding
    {
        while IFS= read -r key; do
            padding_width=$((30 - ${#key}))
            (( padding_width >= 1 )) || padding_width=1
            printf -v padding '%*s' "$padding_width" ''
            padding=${padding// /.}
            printf '%s%s %s\n' "$key" "$padding" "${BB_REPORT_VALUES[$key]}"
        done < <(printf '%s\n' "${!BB_REPORT_VALUES[@]}" | LC_ALL=C sort)
    } | bb_atomic_write_from_stdin "$target" 0640
}

# Atualiza last-run e, quando permitido, last-success sem misturar resultados.
# Parâmetros: `yes` quando o backup principal desta execução é válido.
# Resultado: 0 quando os arquivos requeridos foram promovidos.
bb_finalize_reports() {
    local primary_valid=$1
    bb_write_report "$BB_LOG_DIR/last-run.report" || return "$BB_EXIT_CRITICAL"
    if [[ $primary_valid == "yes" ]]; then
        bb_write_report "$BB_LOG_DIR/last-success.report" || return "$BB_EXIT_CRITICAL"
    fi
    BB_REPORT_FINALIZED="yes"
}

# Persiste pares chave-valor não sensíveis em estado mínimo e atômico.
# Parâmetros: arquivo relativo seguro e pares `CHAVE=valor` subsequentes.
# Resultado: 0 em sucesso; 2 para nome inseguro ou conteúdo multilinha.
bb_write_state() {
    local relative=$1
    shift
    local target line
    [[ $relative =~ ^[a-z0-9][a-z0-9./-]*\.state$ && $relative != *..* ]] || return "$BB_EXIT_CRITICAL"
    target="$BB_STATE_DIR/$relative"
    bb_path_is_within "$BB_STATE_DIR" "$target" || return "$BB_EXIT_CRITICAL"
    mkdir -p -- "$(dirname -- "$target")"
    chmod 0750 -- "$(dirname -- "$target")"
    for line in "$@"; do
        [[ $line =~ ^[A-Z][A-Z0-9_]*=[^[:cntrl:]]*$ ]] || return "$BB_EXIT_CRITICAL"
    done
    printf '%s\n' "$@" | bb_atomic_write_from_stdin "$target" 0640
}

# Lê uma chave simples de estado gerado pela própria solução sem executar shell.
# Parâmetros: caminho relativo e chave esperada.
# Resultado: imprime o último valor único; 1 se arquivo/chave não existirem.
bb_state_get() {
    local relative=$1 wanted_key=$2 target line key value found="no"
    [[ $relative =~ ^[a-z0-9][a-z0-9./-]*\.state$ && $relative != *..* ]] || return "$BB_EXIT_CRITICAL"
    [[ $wanted_key =~ ^[A-Z][A-Z0-9_]*$ ]] || return "$BB_EXIT_CRITICAL"
    target="$BB_STATE_DIR/$relative"
    [[ -f $target && ! -L $target ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || return "$BB_EXIT_CRITICAL"
        key=${line%%=*}; value=${line#*=}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ && $value != *$'\n'* && $value != *$'\r'* ]] || return "$BB_EXIT_CRITICAL"
        if [[ $key == "$wanted_key" ]]; then
            [[ $found == "no" ]] || return "$BB_EXIT_CRITICAL"
            printf '%s\n' "$value"
            found="yes"
        fi
    done <"$target"
    [[ $found == "yes" ]]
}
