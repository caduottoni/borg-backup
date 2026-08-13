#!/bin/bash
# Finalidade: replicar friamente o repositório para N destinos em ordem lexical.
# Entradas: configuração global/por destino já validada e repositório local.
# Saídas: resultado por destino, resumo global, relatório e estado mínimo.
# Efeitos colaterais: invoca SSH restrito, rsync para `incoming` e promoção pelo
# receptor; nunca modifica `current` diretamente nem executa backup lógico.
# Dependências: Bash, Borg with-lock, rsync, OpenSSH Client e módulos internos.
# Privilégios: root no emissor; doubles controlados no harness público.
# Códigos: 0 para todos OK/desabilitados, 1 para falha opcional e 2 para falha
# obrigatória ou de protocolo.
# Sigilo: chave e known_hosts não são registrados; passphrase permanece apenas
# no ambiente dos processos Borg construídos por backup.sh.

set -Eeuo pipefail
umask 077

declare -gA BB_REPLICATION_STATUS=()
declare -g BB_REPLICATION_SUMMARY="NOT_RUN"
declare -g BB_REPLICATION_CAPACITY="OK"
declare -g BB_REPLICATION_RESULT_FILE=""

# Calcula quantidade e soma de bytes dos arquivos regulares da origem Borg.
# Parâmetros: caminho físico e nomes de variáveis de saída.
# Resultado: 0 com inteiros decimais; não enumera nomes no log.
bb_repository_metrics() {
    local repository=$1 count_name=$2 bytes_name=$3
    local -n count_ref=$count_name bytes_ref=$bytes_name
    local count bytes
    [[ -d $repository && -f $repository/config && -d $repository/data ]] || return "$BB_EXIT_CRITICAL"
    if ! find "$repository" -maxdepth 1 -type f -name 'index.*' -print -quit | grep -q .; then
        return "$BB_EXIT_CRITICAL"
    fi
    count=$(find -P "$repository" -type f -printf '.\n' | wc -l)
    bytes=$(find -P "$repository" -type f -printf '%s\n' | awk '{ total += $1 } END { printf "%.0f\n", total + 0 }')
    bb_validate_uint "$count" && bb_validate_uint "$bytes" || return "$BB_EXIT_CRITICAL"
    count_ref=$count
    bytes_ref=$bytes
}

# Constrói as opções SSH fechadas para um destino já validado.
# Parâmetros: ID e nome do array de saída.
# Resultado: opções não interativas, host key estrita e forwarding desabilitado.
bb_build_ssh_options() {
    local destination_id=$1 output_name=$2 identity known_hosts
    local -n output_ref=$output_name
    identity=$(bb_system_path "${BB_REPL_IDENTITY[$destination_id]}") || return "$BB_EXIT_CRITICAL"
    known_hosts=$(bb_system_path "${BB_REPL_KNOWN_HOSTS[$destination_id]}") || return "$BB_EXIT_CRITICAL"
    output_ref=(
        -p "${BB_REPL_PORT[$destination_id]}"
        -i "$identity"
        -o BatchMode=yes
        -o IdentitiesOnly=yes
        -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=$known_hosts"
        -o ConnectTimeout=15
        -o ConnectionAttempts=1
        -o ClearAllForwardings=yes
        -T
    )
}

# Executa uma operação fechada do receptor e separa stdout de diagnóstico.
# Parâmetros: ID, comando remoto seguro e nome-base do arquivo de staging.
# Resultado: imprime stdout somente em sucesso e retorna exatamente o código SSH.
bb_receiver_command() {
    local destination_id=$1 remote_command=$2 output_basename=$3
    local output_file error_file target rc
    local -a ssh_options=()
    [[ $remote_command =~ ^(prepare|validate|promote|abort|status)([[:space:]][A-Za-z0-9.-]+)*$ ]] || return "$BB_EXIT_CRITICAL"
    [[ $output_basename =~ ^[a-z0-9-]+$ ]] || return "$BB_EXIT_CRITICAL"
    bb_build_ssh_options "$destination_id" ssh_options || return "$BB_EXIT_CRITICAL"
    output_file="$BB_EXECUTION_DIR/staging/replication-$destination_id-$output_basename.stdout"
    error_file="$BB_EXECUTION_DIR/staging/replication-$destination_id-$output_basename.stderr"
    target="${BB_REPL_USER[$destination_id]}@${BB_REPL_HOST[$destination_id]}"
    if ssh "${ssh_options[@]}" -- "$target" "$remote_command" >"$output_file" 2>"$error_file"; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
        cat -- "$output_file"
    fi
    return "$rc"
}

# Constrói a string `-e` do rsync exclusivamente a partir de campos validados.
# Parâmetros: ID.
# Resultado: imprime transporte SSH fixo; nenhum campo aceita espaços.
bb_rsync_transport() {
    local destination_id=$1 identity known_hosts
    identity=$(bb_system_path "${BB_REPL_IDENTITY[$destination_id]}") || return "$BB_EXIT_CRITICAL"
    known_hosts=$(bb_system_path "${BB_REPL_KNOWN_HOSTS[$destination_id]}") || return "$BB_EXIT_CRITICAL"
    printf 'ssh -p %s -i %s -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s -o ConnectTimeout=15 -o ConnectionAttempts=1 -o ClearAllForwardings=yes -T\n' \
        "${BB_REPL_PORT[$destination_id]}" "$identity" "$known_hosts"
}

# Executa transferência ou dry-run com conjunto rsync fechado.
# Parâmetros: ID, `yes` para link-dest, `yes` para dry-run e arquivo de saída.
# Resultado: retorna exatamente o código rsync; dry-run válido também exige saída
# vazia, comprovando ausência de diferenças.
bb_rsync_repository() {
    local destination_id=$1 use_link_dest=$2 dry_run=$3 output_file=$4
    local source destination target transport rc
    local -a options=(
        --recursive
        --links
        --perms
        --times
        --hard-links
        --partial-dir=.rsync-partial
        --delay-updates
        --fsync
    )
    source=$(bb_system_path "${BB_REPLICATION_CONFIG[REPLICATION_SOURCE]}") || return "$BB_EXIT_CRITICAL"
    destination=${BB_REPL_DESTINATION[$destination_id]}
    target="${BB_REPL_USER[$destination_id]}@${BB_REPL_HOST[$destination_id]}:$destination/incoming-$BB_EXECUTION_ID/repo/"
    transport=$(bb_rsync_transport "$destination_id") || return "$BB_EXIT_CRITICAL"
    if [[ $use_link_dest == "yes" ]]; then
        options+=("--link-dest=$destination/current/repo")
    fi
    if [[ $dry_run == "yes" ]]; then
        options+=(--dry-run --itemize-changes)
    fi
    if rsync "${options[@]}" -e "$transport" "$source/" "$target" >"$output_file" 2>&1; then rc=0; else rc=$?; fi
    (( rc == 0 )) || return "$rc"
    if [[ $dry_run == "yes" && -s $output_file ]]; then
        return "$BB_EXIT_CRITICAL"
    fi
}

# Solicita cancelamento somente do incoming pertencente à execução corrente.
# Parâmetros: ID.
# Resultado: sempre 0 para não mascarar a causa primária.
bb_abort_replication_destination() {
    local destination_id=$1
    bb_receiver_command "$destination_id" "abort $BB_EXECUTION_ID" abort >/dev/null || true
}

# Persiste resultado individual não sensível após uma tentativa.
# Parâmetros: ID, estado, causa fechada e capacidade (`OK` ou `WARNING`).
# Resultado: 0 após promoção atômica do estado local.
bb_record_replication_state() {
    local destination_id=$1 status=$2 reason=$3 capacity=${4:-"UNKNOWN"} now generation="UNCHANGED"
    now=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    [[ $status == "OK" ]] && generation="current"
    bb_write_state "replication/$destination_id.state" \
        "REPLICATION_ID=$destination_id" \
        "RESULT=$status" \
        "REASON=$reason" \
        "CAPACITY=$capacity" \
        "EXECUTION_ID=$BB_EXECUTION_ID" \
        "GENERATION=$generation" \
        "TIMESTAMP_UTC=$now"
}

# Executa prepare, rsync, dry-run, validação, promoção e status de um destino.
# Parâmetros: ID habilitado e métricas locais.
# Resultado: 0 somente após current promovida; 2 e abort seguro em qualquer falha.
bb_replicate_one_destination() {
    local destination_id=$1 file_count=$2 file_bytes=$3 prepare_output current_flag status_output
    local transfer_output verify_output promote_output capacity="OK"
    prepare_output=$(bb_receiver_command "$destination_id" \
        "prepare $BB_EXECUTION_ID ${BB_BACKUP_CONFIG[ARCHIVE_PREFIX]} ${BB_REPLICATION_CONFIG[REPLICATION_MIN_FREE_MIB]}" prepare) || {
        bb_record_replication_state "$destination_id" FAILED PREPARE UNKNOWN || true
        return "$BB_EXIT_CRITICAL"
    }
    case $prepare_output in
        "READY CURRENT=yes") current_flag="yes" ;;
        "READY CURRENT=no") current_flag="no" ;;
        *)
            bb_abort_replication_destination "$destination_id"
            bb_record_replication_state "$destination_id" FAILED PROTOCOL UNKNOWN || true
            return "$BB_EXIT_CRITICAL"
            ;;
    esac

    transfer_output="$BB_EXECUTION_DIR/staging/replication-$destination_id-rsync.output"
    bb_rsync_repository "$destination_id" "$current_flag" no "$transfer_output" || {
        bb_abort_replication_destination "$destination_id"
        bb_record_replication_state "$destination_id" FAILED TRANSFER UNKNOWN || true
        return "$BB_EXIT_CRITICAL"
    }
    verify_output="$BB_EXECUTION_DIR/staging/replication-$destination_id-rsync-verify.output"
    bb_rsync_repository "$destination_id" "$current_flag" yes "$verify_output" || {
        bb_abort_replication_destination "$destination_id"
        bb_record_replication_state "$destination_id" FAILED DRY_RUN UNKNOWN || true
        return "$BB_EXIT_CRITICAL"
    }
    bb_receiver_command "$destination_id" "validate $BB_EXECUTION_ID $file_count $file_bytes" validate >/dev/null || {
        bb_abort_replication_destination "$destination_id"
        bb_record_replication_state "$destination_id" FAILED VALIDATE UNKNOWN || true
        return "$BB_EXIT_CRITICAL"
    }
    promote_output=$(bb_receiver_command "$destination_id" "promote $BB_EXECUTION_ID" promote) || {
        bb_record_replication_state "$destination_id" FAILED PROMOTE UNKNOWN || true
        return "$BB_EXIT_CRITICAL"
    }
    case $promote_output in
        "PROMOTED CAPACITY=OK") capacity="OK" ;;
        "PROMOTED CAPACITY=WARNING") capacity="WARNING" ;;
        *)
            bb_record_replication_state "$destination_id" FAILED PROTOCOL UNKNOWN || true
            return "$BB_EXIT_CRITICAL"
            ;;
    esac
    status_output=$(bb_receiver_command "$destination_id" status status) || {
        bb_record_replication_state "$destination_id" FAILED STATUS "$capacity" || true
        return "$BB_EXIT_CRITICAL"
    }
    [[ $status_output == CURRENT=yes* ]] || {
        bb_record_replication_state "$destination_id" FAILED STATUS "$capacity" || true
        return "$BB_EXIT_CRITICAL"
    }
    if [[ $capacity == "WARNING" ]]; then
        bb_record_replication_state "$destination_id" OK CAPACITY_WARNING WARNING || return "$BB_EXIT_CRITICAL"
        bb_log WARNING capacity destination-below-floor \
            "destino=$destination_id promovido; capacidade abaixo do piso" || return "$BB_EXIT_CRITICAL"
        return "$BB_EXIT_WARNING"
    fi
    bb_record_replication_state "$destination_id" OK NONE OK || return "$BB_EXIT_CRITICAL"
    bb_log INFO replication destination-ok "destino=$destination_id geração=current" || return "$BB_EXIT_CRITICAL"
}

# Serializa resultados do subprocesso protegido pelo lock Borg para o pai.
# Parâmetros: nenhum; usa mapas e resumo já consolidados.
# Resultado: arquivo literal atômico dentro do staging da execução.
bb_write_replication_result() {
    local destination_id
    BB_REPLICATION_RESULT_FILE="$BB_EXECUTION_DIR/staging/replication.result"
    {
        printf 'SUMMARY|%s\n' "$BB_REPLICATION_SUMMARY"
        printf 'CAPACITY|%s\n' "$BB_REPLICATION_CAPACITY"
        for destination_id in "${BB_REPLICATION_IDS[@]}"; do
            printf 'DESTINATION|%s|%s\n' "$destination_id" "${BB_REPLICATION_STATUS[$destination_id]}"
        done
    } | bb_atomic_write_from_stdin "$BB_REPLICATION_RESULT_FILE" 0600
}

# Processa todos os destinos sequencialmente dentro de `borg with-lock`.
# Parâmetros: nenhum; deve ser chamado somente no modo interno autenticado.
# Resultado: 0/1/2 conforme sucesso, falha opcional ou falha obrigatória.
bb_replicate_all_destinations_locked() {
    local repository file_count file_bytes destination_id destination_rc
    local optional_failed="no" required_failed="no" capacity_warning="no" enabled_count=0
    repository=$(bb_system_path "${BB_REPLICATION_CONFIG[REPLICATION_SOURCE]}") || return "$BB_EXIT_CRITICAL"
    bb_repository_metrics "$repository" file_count file_bytes || return "$BB_EXIT_CRITICAL"
    BB_REPLICATION_STATUS=()
    BB_REPLICATION_CAPACITY="OK"
    for destination_id in "${BB_REPLICATION_IDS[@]}"; do
        if [[ ${BB_REPL_ENABLED[$destination_id]} != "yes" ]]; then
            BB_REPLICATION_STATUS["$destination_id"]="DISABLED"
            bb_log INFO replication destination-disabled "destino=$destination_id" || true
            continue
        fi
        ((enabled_count += 1))
        if bb_replicate_one_destination "$destination_id" "$file_count" "$file_bytes"; then destination_rc=0; else destination_rc=$?; fi
        case $destination_rc in
            0)
                BB_REPLICATION_STATUS["$destination_id"]="OK"
                ;;
            1)
                BB_REPLICATION_STATUS["$destination_id"]="OK"
                capacity_warning="yes"
                ;;
            *)
                BB_REPLICATION_STATUS["$destination_id"]="FAILED"
                bb_log ERROR replication destination-failed "destino=$destination_id" || true
                if [[ ${BB_REPL_REQUIRED[$destination_id]} == "yes" ]]; then
                    required_failed="yes"
                else
                    optional_failed="yes"
                fi
                ;;
        esac
    done
    if [[ $required_failed == "yes" ]]; then
        BB_REPLICATION_SUMMARY="FAILED_REQUIRED"
    elif [[ $optional_failed == "yes" ]]; then
        BB_REPLICATION_SUMMARY="WARNING_OPTIONAL"
    elif (( enabled_count == 0 )); then
        BB_REPLICATION_SUMMARY="DISABLED"
    else
        BB_REPLICATION_SUMMARY="OK"
    fi
    [[ $capacity_warning == "no" ]] || BB_REPLICATION_CAPACITY="WARNING"
    bb_write_replication_result || return "$BB_EXIT_CRITICAL"
    case $BB_REPLICATION_SUMMARY in
        OK)
            [[ $BB_REPLICATION_CAPACITY == "OK" ]] && return "$BB_EXIT_OK"
            return "$BB_EXIT_WARNING"
            ;;
        DISABLED) return "$BB_EXIT_OK" ;;
        WARNING_OPTIONAL) return "$BB_EXIT_WARNING" ;;
        FAILED_REQUIRED) return "$BB_EXIT_CRITICAL" ;;
        *) return "$BB_EXIT_CRITICAL" ;;
    esac
}

# Lê resultado do subprocesso sem executar conteúdo e alimenta o relatório pai.
# Parâmetros: arquivo esperado.
# Resultado: 0 para sintaxe completa; 2 para ID/status ausente ou desconhecido.
bb_load_replication_result() {
    local file=$1 line kind id status summary_seen="no" capacity_seen="no"
    local -a fields=()
    local -A seen=()
    [[ -f $file && ! -L $file ]] || return "$BB_EXIT_CRITICAL"
    BB_REPLICATION_STATUS=()
    while IFS= read -r line || [[ -n $line ]]; do
        IFS='|' read -r -a fields <<<"$line"
        kind=${fields[0]:-}
        case $kind in
            SUMMARY)
                (( ${#fields[@]} == 2 )) || return "$BB_EXIT_CRITICAL"
                [[ $summary_seen == "no" ]] || return "$BB_EXIT_CRITICAL"
                BB_REPLICATION_SUMMARY=${fields[1]}
                [[ $BB_REPLICATION_SUMMARY == "OK" || $BB_REPLICATION_SUMMARY == "DISABLED" || $BB_REPLICATION_SUMMARY == "WARNING_OPTIONAL" || $BB_REPLICATION_SUMMARY == "FAILED_REQUIRED" ]] || return "$BB_EXIT_CRITICAL"
                summary_seen="yes"
                ;;
            CAPACITY)
                (( ${#fields[@]} == 2 )) || return "$BB_EXIT_CRITICAL"
                [[ $capacity_seen == "no" ]] || return "$BB_EXIT_CRITICAL"
                BB_REPLICATION_CAPACITY=${fields[1]}
                [[ $BB_REPLICATION_CAPACITY == "OK" || $BB_REPLICATION_CAPACITY == "WARNING" ]] || return "$BB_EXIT_CRITICAL"
                capacity_seen="yes"
                ;;
            DESTINATION)
                (( ${#fields[@]} == 3 )) || return "$BB_EXIT_CRITICAL"
                id=${fields[1]}; status=${fields[2]}
                bb_validate_id "$id" || return "$BB_EXIT_CRITICAL"
                bb_array_contains "$id" "${BB_REPLICATION_IDS[@]}" || return "$BB_EXIT_CRITICAL"
                [[ ! -v "seen[$id]" ]] || return "$BB_EXIT_CRITICAL"
                [[ $status == "OK" || $status == "FAILED" || $status == "DISABLED" ]] || return "$BB_EXIT_CRITICAL"
                seen["$id"]=1
                BB_REPLICATION_STATUS["$id"]=$status
                ;;
            *) return "$BB_EXIT_CRITICAL" ;;
        esac
    done <"$file"
    [[ $summary_seen == "yes" && $capacity_seen == "yes" ]] || return "$BB_EXIT_CRITICAL"
    for id in "${BB_REPLICATION_IDS[@]}"; do
        [[ -v "seen[$id]" ]] || return "$BB_EXIT_CRITICAL"
        bb_report_set "REPLICATION[$id]" "${BB_REPLICATION_STATUS[$id]}" || return "$BB_EXIT_CRITICAL"
        bb_log INFO replication destination-result "destino=$id resultado=${BB_REPLICATION_STATUS[$id]}" || return "$BB_EXIT_CRITICAL"
    done
    bb_report_set REPLICATION_SUMMARY "$BB_REPLICATION_SUMMARY"
    if [[ $BB_REPLICATION_CAPACITY == "WARNING" ]]; then
        BB_CAPACITY_WARNING="yes"
        bb_report_set CAPACITY "WARNING"
    fi
}

# Mantém o lock Borg enquanto o modo interno processa todos os destinos.
# Parâmetros: nenhum; BB_EXECUTION_DIR já existe e o flock global está no pai.
# Resultado: 0/1/2 após validar o resultado produzido pelo filho.
bb_run_replication_with_borg_lock() {
    local output_file result_file entrypoint rc expected_rc
    local -a internal_environment=()
    BB_PRIMARY_REPOSITORY_PATH=$(bb_system_path "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}") || return "$BB_EXIT_CRITICAL"
    entrypoint=$(bb_system_path "/usr/local/sbin/borg-backup") || return "$BB_EXIT_CRITICAL"
    output_file="$BB_EXECUTION_DIR/staging/borg-with-lock.output"
    result_file="$BB_EXECUTION_DIR/staging/replication.result"
    internal_environment=(
        "BB_INTERNAL_REPLICATION_TOKEN=replication-v1"
        "BB_INTERNAL_EXECUTION_ID=$BB_EXECUTION_ID"
        "BB_INTERNAL_EXECUTION_DIR=$BB_EXECUTION_DIR"
    )
    if [[ $BB_TEST_MODE == "yes" ]]; then
        internal_environment+=(
            "BORG_BACKUP_TEST_MODE=yes"
            "BORG_BACKUP_TEST_ROOT=$BB_TEST_ROOT"
            "BORG_BACKUP_TEST_BIN=$BB_BOOTSTRAP_TEST_BIN"
        )
    fi
    if bb_borg_command "$output_file" with-lock "$BB_PRIMARY_REPOSITORY_PATH" \
        /usr/bin/env "${internal_environment[@]}" "$entrypoint" __replicate-locked; then rc=0; else rc=$?; fi
    bb_load_replication_result "$result_file" || return "$BB_EXIT_CRITICAL"
    case $BB_REPLICATION_SUMMARY in
        OK)
            [[ $BB_REPLICATION_CAPACITY == "OK" ]] && expected_rc=0 || expected_rc=1
            ;;
        DISABLED) expected_rc=0 ;;
        WARNING_OPTIONAL) expected_rc=1 ;;
        FAILED_REQUIRED) expected_rc=2 ;;
        *) return "$BB_EXIT_CRITICAL" ;;
    esac
    (( rc == expected_rc )) || return "$BB_EXIT_CRITICAL"
    return "$rc"
}
