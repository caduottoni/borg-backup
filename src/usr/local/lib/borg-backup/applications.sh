#!/bin/bash
# Finalidade: implementar somente os adaptadores autorizados Nextcloud e BIND.
# Entradas: registros validados de applications.conf.
# Saídas: eventos por ID técnico, sem saída integral de `occ` ou `rndc`.
# Efeitos colaterais: alterna manutenção Nextcloud quando necessário e executa
# `rndc sync` online; nunca para Apache, PHP-FPM, SSH ou DNS.
# Dependências: Bash, runuser, php, rndc e módulos comuns.
# Privilégios: root em produção; doubles controlados no harness público.
# Códigos: 0 após validação; 2 diante de estado ou comando inesperado.
# Sigilo: saídas de aplicações permanecem em staging e não são registradas.

set -Eeuo pipefail
umask 077

declare -gA BB_NEXTCLOUD_DIRECTORY=()
declare -gA BB_NEXTCLOUD_USER=()
declare -gA BB_NEXTCLOUD_ORIGINAL=()
declare -gA BB_NEXTCLOUD_CHANGED=()
declare -ga BB_NEXTCLOUD_ORDER=()
declare -gA BB_BIND_DIRECTORY=()
declare -gA BB_BIND_USER=()
declare -ga BB_BIND_ORDER=()

# Separa registros de aplicação por adaptador, preservando a ordem declarada.
# Parâmetros: nenhum; usa BB_APPLICATION_ROWS.
# Resultado: mapas internos prontos, sem alterar qualquer aplicação.
bb_applications_initialize() {
    local row type id directory user
    local -a fields=()
    BB_NEXTCLOUD_DIRECTORY=(); BB_NEXTCLOUD_USER=(); BB_NEXTCLOUD_ORIGINAL=(); BB_NEXTCLOUD_CHANGED=(); BB_NEXTCLOUD_ORDER=()
    BB_BIND_DIRECTORY=(); BB_BIND_USER=(); BB_BIND_ORDER=()
    for row in "${BB_APPLICATION_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}; id=${fields[1]}; directory=${fields[2]}; user=${fields[3]}
        case $type in
            nextcloud)
                BB_NEXTCLOUD_DIRECTORY["$id"]=$directory
                BB_NEXTCLOUD_USER["$id"]=$user
                BB_NEXTCLOUD_ORDER+=("$id")
                ;;
            bind)
                BB_BIND_DIRECTORY["$id"]=$directory
                BB_BIND_USER["$id"]=$user
                BB_BIND_ORDER+=("$id")
                ;;
            *)
                return "$BB_EXIT_CRITICAL"
                ;;
        esac
    done
}

# Valida caminhos, usuários e executáveis conhecidos sem mudar aplicações.
# Parâmetros: nenhum; usa mapas inicializados.
# Resultado: 0 para todos os alvos locais explícitos; 2 em qualquer ausência.
bb_applications_validate_targets() {
    local id directory user
    for id in "${BB_NEXTCLOUD_ORDER[@]}"; do
        directory=$(bb_system_path "${BB_NEXTCLOUD_DIRECTORY[$id]}") || return "$BB_EXIT_CRITICAL"
        user=${BB_NEXTCLOUD_USER[$id]}
        [[ -d $directory && -f $directory/occ && ! -L $directory/occ ]] || return "$BB_EXIT_CRITICAL"
        id -u "$user" >/dev/null 2>&1 || return "$BB_EXIT_CRITICAL"
    done
    for id in "${BB_BIND_ORDER[@]}"; do
        directory=$(bb_system_path "${BB_BIND_DIRECTORY[$id]}") || return "$BB_EXIT_CRITICAL"
        user=${BB_BIND_USER[$id]}
        [[ -d $directory && ! -L $directory ]] || return "$BB_EXIT_CRITICAL"
        id -u "$user" >/dev/null 2>&1 || return "$BB_EXIT_CRITICAL"
    done
}

# Consulta o modo de manutenção Nextcloud por interface conhecida do `occ`.
# Parâmetros: ID validado.
# Resultado: imprime `enabled` ou `disabled`; 2 para saída ambígua.
bb_nextcloud_state() {
    local id=$1 logical directory user occ output rc output_file
    logical=${BB_NEXTCLOUD_DIRECTORY[$id]}
    directory=$(bb_system_path "$logical") || return "$BB_EXIT_CRITICAL"
    user=${BB_NEXTCLOUD_USER[$id]}
    occ="$directory/occ"
    [[ -d $directory && -f $occ && ! -L $occ ]] || return "$BB_EXIT_CRITICAL"
    id -u "$user" >/dev/null 2>&1 || return "$BB_EXIT_CRITICAL"
    output_file="$BB_EXECUTION_DIR/staging/nextcloud-$id.state"
    if runuser -u "$user" -- php "$occ" maintenance:mode >"$output_file" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
    output=$(<"$output_file")
    case ${output,,} in
        *"currently enabled"*) printf 'enabled\n' ;;
        *"currently disabled"*) printf 'disabled\n' ;;
        *) return "$BB_EXIT_CRITICAL" ;;
    esac
}

# Habilita manutenção em cada Nextcloud que inicialmente a tinha desabilitada.
# Parâmetros: nenhum.
# Resultado: 0 com estados registrados; 2 e restauração posterior via trap.
bb_prepare_nextcloud_applications() {
    local id state directory user occ rc output_file
    for id in "${BB_NEXTCLOUD_ORDER[@]}"; do
        state=$(bb_nextcloud_state "$id") || return "$BB_EXIT_CRITICAL"
        BB_NEXTCLOUD_ORIGINAL["$id"]=$state
        BB_NEXTCLOUD_CHANGED["$id"]="no"
        if [[ $state == "disabled" ]]; then
            directory=$(bb_system_path "${BB_NEXTCLOUD_DIRECTORY[$id]}") || return "$BB_EXIT_CRITICAL"
            user=${BB_NEXTCLOUD_USER[$id]}
            occ="$directory/occ"
            output_file="$BB_EXECUTION_DIR/staging/nextcloud-$id.on"
            if runuser -u "$user" -- php "$occ" maintenance:mode --on >"$output_file" 2>&1; then rc=0; else rc=$?; fi
            (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
            # `occ --on` pode ter alterado a aplicação mesmo se a verificação
            # subsequente falhar; o trap deve conhecer a transição desde já.
            BB_NEXTCLOUD_CHANGED["$id"]="yes"
            [[ $(bb_nextcloud_state "$id") == "enabled" ]] || return "$BB_EXIT_CRITICAL"
            bb_log INFO application maintenance-on "id=$id adaptador Nextcloud habilitou manutenção" || return "$BB_EXIT_CRITICAL"
        else
            bb_log INFO application unchanged "id=$id Nextcloud já estava em manutenção" || return "$BB_EXIT_CRITICAL"
        fi
    done
}

# Sincroniza BIND online sem parar ou reiniciar a unidade DNS.
# Parâmetros: nenhum.
# Resultado: 0 quando cada `rndc sync` retorna 0; 2 na primeira falha.
bb_sync_bind_applications() {
    local id directory user output_file rc
    for id in "${BB_BIND_ORDER[@]}"; do
        directory=$(bb_system_path "${BB_BIND_DIRECTORY[$id]}") || return "$BB_EXIT_CRITICAL"
        user=${BB_BIND_USER[$id]}
        [[ -d $directory && ! -L $directory ]] || return "$BB_EXIT_CRITICAL"
        id -u "$user" >/dev/null 2>&1 || return "$BB_EXIT_CRITICAL"
        output_file="$BB_EXECUTION_DIR/staging/bind-$id.sync"
        if runuser -u "$user" -- rndc sync >"$output_file" 2>&1; then rc=0; else rc=$?; fi
        (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
        bb_log INFO application bind-sync "id=$id estado dinâmico BIND sincronizado online" || return "$BB_EXIT_CRITICAL"
    done
}

# Restaura um Nextcloud que a rotina retirou do estado inicial desabilitado.
# Parâmetros: ID validado.
# Resultado: 0 quando não alterado ou novamente desabilitado; 2 em falha.
bb_restore_one_nextcloud() {
    local id=$1 directory user occ output_file rc
    [[ ${BB_NEXTCLOUD_CHANGED[$id]:-"no"} == "yes" ]] || return "$BB_EXIT_OK"
    [[ ${BB_NEXTCLOUD_ORIGINAL[$id]:-""} == "disabled" ]] || return "$BB_EXIT_CRITICAL"
    directory=$(bb_system_path "${BB_NEXTCLOUD_DIRECTORY[$id]}") || return "$BB_EXIT_CRITICAL"
    user=${BB_NEXTCLOUD_USER[$id]}
    occ="$directory/occ"
    output_file="$BB_EXECUTION_DIR/staging/nextcloud-$id.off"
    if runuser -u "$user" -- php "$occ" maintenance:mode --off >"$output_file" 2>&1; then rc=0; else rc=$?; fi
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
    [[ $(bb_nextcloud_state "$id") == "disabled" ]] || return "$BB_EXIT_CRITICAL"
    BB_NEXTCLOUD_CHANGED["$id"]="no"
    bb_log INFO application maintenance-restored "id=$id Nextcloud retornou ao modo inicial" || return "$BB_EXIT_CRITICAL"
}

# Tenta restaurar todos os Nextclouds em ordem inversa.
# Parâmetros: nenhum.
# Resultado: 0 se todos restaurados; 2 após tentar todos os pendentes.
bb_restore_all_applications() {
    local index id aggregate=0
    for ((index=${#BB_NEXTCLOUD_ORDER[@]} - 1; index >= 0; index--)); do
        id=${BB_NEXTCLOUD_ORDER[$index]}
        if ! bb_restore_one_nextcloud "$id"; then
            aggregate=$BB_EXIT_CRITICAL
        fi
    done
    return "$aggregate"
}
