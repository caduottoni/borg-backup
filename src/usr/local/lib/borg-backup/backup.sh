#!/bin/bash
# Finalidade: validar dependências/repositório e criar/confirmar archives Borg.
# Entradas: configuração validada, fontes explícitas e dumps finais da execução.
# Saídas: nome do archive confirmado e diagnósticos resumidos.
# Efeitos colaterais: `borg create` modifica somente o repositório configurado;
# demais funções deste módulo são consultas.
# Dependências: BorgBackup 1.4.x e módulos internos.
# Privilégios: root em produção; repositório descartável no modo controlado.
# Códigos: preserva retorno Borg para o chamador tratar 1 como não válido.
# Sigilo: passphrase é fornecida somente no ambiente do subprocesso Borg e sua
# saída integral fica em staging privado, nunca no log persistente.

set -Eeuo pipefail
umask 077

declare -g BB_ARCHIVE_NAME=""
declare -g BB_PRIMARY_REPOSITORY_PATH=""

# Monta o ambiente mínimo de um único subprocesso Borg.
# Parâmetros: nome do array de saída.
# Resultado: array `env` com passphrase e caches controlados quando em teste.
bb_build_borg_environment() {
    local output_name=$1
    local -n output_ref=$output_name
    output_ref=("BORG_PASSPHRASE=${BB_SECRET_CONFIG[BORG_PASSPHRASE]}")
    if [[ $BB_TEST_MODE == "yes" ]]; then
        mkdir -p -- "$BB_TEST_ROOT/var/cache/borg" "$BB_TEST_ROOT/var/lib/borg-backup/borg-security" "$BB_TEST_ROOT/var/lib/borg-backup/borg-keys"
        chmod 0700 -- "$BB_TEST_ROOT/var/cache/borg" "$BB_TEST_ROOT/var/lib/borg-backup/borg-security" "$BB_TEST_ROOT/var/lib/borg-backup/borg-keys"
        output_ref+=("BORG_CACHE_DIR=$BB_TEST_ROOT/var/cache/borg")
        output_ref+=("BORG_SECURITY_DIR=$BB_TEST_ROOT/var/lib/borg-backup/borg-security")
        output_ref+=("BORG_KEYS_DIR=$BB_TEST_ROOT/var/lib/borg-backup/borg-keys")
        # O marcador não é usado pela solução real; permite que doubles locais
        # mantenham todo o estado de teste dentro da raiz descartável.
        output_ref+=("BB_BORG_TEST_ROOT=$BB_TEST_ROOT")
    fi
}

# Executa Borg com ambiente mínimo e captura sua saída em staging privado.
# Parâmetros: arquivo de saída e argumentos Borg restantes.
# Resultado: retorna exatamente o código Borg para tratamento explícito.
bb_borg_command() {
    local output_file=$1
    shift
    local -a borg_environment=()
    local rc
    bb_build_borg_environment borg_environment || return "$BB_EXIT_CRITICAL"
    if env -i PATH="$PATH" LC_ALL=C LANG=C "${borg_environment[@]}" borg "$@" >"$output_file" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    unset borg_environment
    return "$rc"
}

# Confirma que a versão disponível pertence à série normativa 1.4.x.
# Parâmetros: nenhum.
# Resultado: 0 para `borg 1.4.N`; 2 para versão ausente ou divergente.
bb_validate_borg_version() {
    local version
    bb_require_command borg || return "$BB_EXIT_CRITICAL"
    version=$(borg --version 2>/dev/null) || return "$BB_EXIT_CRITICAL"
    [[ $version =~ ^borg[[:space:]]1\.4\.[0-9]+$ ]]
}

# Valida somente dependências necessárias aos registros declarados.
# Parâmetros: nenhum; usa bancos, aplicações e serviços já carregados.
# Resultado: 0 quando o perfil pode ser executado sem instalar pacotes.
bb_validate_declared_dependencies() {
    local row type
    local -a fields=()
    bb_validate_borg_version || return "$BB_EXIT_CRITICAL"
    bb_require_command flock || return "$BB_EXIT_CRITICAL"
    for row in "${BB_DATABASE_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}
        case $type in
            postgresql)
                bb_require_command runuser || return "$BB_EXIT_CRITICAL"
                bb_require_command pg_dump || return "$BB_EXIT_CRITICAL"
                bb_require_command pg_restore || return "$BB_EXIT_CRITICAL"
                ;;
            postgresql-globals)
                bb_require_command runuser || return "$BB_EXIT_CRITICAL"
                bb_require_command pg_dumpall || return "$BB_EXIT_CRITICAL"
                ;;
            sqlite)
                bb_require_command sqlite3 || return "$BB_EXIT_CRITICAL"
                ;;
        esac
    done
    if (( ${#BB_SERVICE_ROWS[@]} > 0 )); then
        bb_require_command systemctl || return "$BB_EXIT_CRITICAL"
    fi
    for row in "${BB_APPLICATION_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}
        case $type in
            nextcloud)
                bb_require_command runuser || return "$BB_EXIT_CRITICAL"
                bb_require_command php || return "$BB_EXIT_CRITICAL"
                ;;
            bind)
                bb_require_command runuser || return "$BB_EXIT_CRITICAL"
                bb_require_command rndc || return "$BB_EXIT_CRITICAL"
                ;;
        esac
    done
    if [[ ${BB_REPLICATION_CONFIG[REPLICATION_ENABLED]} == "yes" ]]; then
        bb_require_command rsync || return "$BB_EXIT_CRITICAL"
        bb_require_command ssh || return "$BB_EXIT_CRITICAL"
    fi
}

# Confirma acesso ao repositório Borg já provisionado sem modificá-lo.
# Parâmetros: nenhum.
# Resultado: 0 somente quando `borg info` retorna 0.
bb_validate_borg_repository() {
    local output_file rc
    BB_PRIMARY_REPOSITORY_PATH=$(bb_system_path "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}") || return "$BB_EXIT_CRITICAL"
    [[ -d $BB_EXECUTION_DIR/staging ]] || return "$BB_EXIT_CRITICAL"
    output_file="$BB_EXECUTION_DIR/staging/borg-info-repository.output"
    if bb_borg_command "$output_file" info "$BB_PRIMARY_REPOSITORY_PATH"; then rc=0; else rc=$?; fi
    find -P "$output_file" -delete 2>/dev/null || true
    (( rc == 0 ))
}

# Reavalia capacidade depois do ciclo local sem invalidar um archive confirmado.
# Parâmetros: nenhum; usa repositório e piso declarados em backup.conf.
# Resultado: 0 para medição válida, inclusive abaixo do piso; 2 se não puder
# medir. Quando abaixo, preserva BACKUP e marca CAPACITY/execução como warning.
bb_check_primary_capacity_after_operation() {
    local available minimum
    [[ -n $BB_PRIMARY_REPOSITORY_PATH ]] || return "$BB_EXIT_CRITICAL"
    bb_available_mib "$BB_PRIMARY_REPOSITORY_PATH" available || return "$BB_EXIT_CRITICAL"
    minimum=${BB_BACKUP_CONFIG[REPOSITORY_MIN_FREE_MIB]}
    if (( 10#$available < 10#$minimum )); then
        BB_CAPACITY_WARNING="yes"
        bb_report_set CAPACITY "WARNING" || return "$BB_EXIT_CRITICAL"
        bb_log WARNING capacity below-floor \
            "repositório principal abaixo do piso após operação; livre-mib=$available mínimo-mib=$minimum" || return "$BB_EXIT_CRITICAL"
    else
        bb_log INFO capacity sufficient \
            "repositório principal acima do piso após operação; livre-mib=$available mínimo-mib=$minimum" || return "$BB_EXIT_CRITICAL"
    fi
}

# Constrói arquivo de exclusão físico para a raiz sintética sem alterar modelos.
# Parâmetros: caminho final em staging.
# Resultado: um padrão por linha, prefixando absolutos somente em modo de teste.
bb_build_effective_excludes() {
    local target=$1 exclusion
    {
        for exclusion in "${BB_EXCLUDES[@]}"; do
            if [[ $BB_TEST_MODE == "yes" && $exclusion == /* ]]; then
                printf '%s%s\n' "$BB_TEST_ROOT" "$exclusion"
            else
                printf '%s\n' "$exclusion"
            fi
        done
    } | bb_atomic_write_from_stdin "$target" 0600
}

# Cria archive com fontes explícitas e diretório de dumps já validado.
# Parâmetros: nenhum; define BB_ARCHIVE_NAME.
# Resultado: retorna exatamente 0/1/2+ do Borg, sem converter warning em sucesso.
bb_create_archive() {
    local timestamp output_file excludes_file source physical_source rc
    local -a effective_sources=() dump_include=()
    timestamp=${BB_EXECUTION_ID%%-*}
    BB_ARCHIVE_NAME="${BB_BACKUP_CONFIG[ARCHIVE_PREFIX]}-$timestamp"
    BB_PRIMARY_REPOSITORY_PATH=$(bb_system_path "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}") || return "$BB_EXIT_CRITICAL"
    output_file="$BB_EXECUTION_DIR/staging/borg-create.output"
    excludes_file="$BB_EXECUTION_DIR/staging/excludes.effective"
    bb_build_effective_excludes "$excludes_file" || return "$BB_EXIT_CRITICAL"
    for source in "${BB_SOURCES[@]}"; do
        physical_source=$(bb_system_path "$source") || return "$BB_EXIT_CRITICAL"
        effective_sources+=("$physical_source")
    done
    if (( ${#BB_DUMP_FILES[@]} > 0 )); then
        effective_sources+=("$BB_EXECUTION_DIR/dumps")
        # O contrato exige excluir a raiz transitória inteira, mas também exige
        # incluir os dumps validados desta execução. O include prefixado é
        # avaliado pelo Borg antes do arquivo de exclusões e abre somente a
        # subárvore `dumps` já controlada; staging e outras execuções continuam
        # excluídos. Não há padrão livre vindo da configuração neste argumento.
        dump_include=(--pattern "+ pp:$BB_EXECUTION_DIR/dumps")
    fi
    if bb_borg_command "$output_file" create --compression "${BB_BACKUP_CONFIG[BORG_COMPRESSION]}" \
        "${dump_include[@]}" --exclude-from "$excludes_file" "$BB_PRIMARY_REPOSITORY_PATH::$BB_ARCHIVE_NAME" \
        "${effective_sources[@]}"; then rc=0; else rc=$?; fi
    bb_log INFO backup create-result "borg create concluiu rc=$rc archive=$BB_ARCHIVE_NAME" || return "$BB_EXIT_CRITICAL"
    return "$rc"
}

# Localiza o archive recém-criado por nome exato usando `borg info`.
# Parâmetros: nenhum; exige BB_ARCHIVE_NAME.
# Resultado: retorna exatamente o código Borg.
bb_confirm_archive() {
    local output_file rc
    [[ -n $BB_ARCHIVE_NAME ]] || return "$BB_EXIT_CRITICAL"
    output_file="$BB_EXECUTION_DIR/staging/borg-info-archive.output"
    if bb_borg_command "$output_file" info "$BB_PRIMARY_REPOSITORY_PATH::$BB_ARCHIVE_NAME"; then rc=0; else rc=$?; fi
    bb_log INFO backup info-result "borg info concluiu rc=$rc archive=$BB_ARCHIVE_NAME" || return "$BB_EXIT_CRITICAL"
    return "$rc"
}
