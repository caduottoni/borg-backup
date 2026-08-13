#!/bin/bash
# Finalidade: controlar a janela crítica das units de aplicação declaradas.
# Entradas: uma lista literal de units já validada a partir de services.conf.
# Saídas: eventos sem conteúdo de aplicação e estado interno para restauração.
# Efeitos colaterais: pode parar e reiniciar exclusivamente units autorizadas.
# Dependências: Bash, systemctl e funções de common.sh/logging.sh.
# Privilégios: root em produção; doubles locais no modo controlado.
# Códigos: 0 quando a transição e validação concluem; 2 em falha crítica.
# Sigilo: saída integral do systemctl não é registrada.

set -Eeuo pipefail
umask 077

declare -ga BB_SERVICE_UNITS=()
declare -gA BB_SERVICE_ORIGINAL_STATE=()
declare -gA BB_SERVICE_CHANGED=()
declare -ga BB_SERVICE_CHANGE_ORDER=()

# Copia a lista declarada preservando sua ordem administrativa.
# Parâmetros: nenhum; usa BB_SERVICE_ROWS.
# Resultado: array de units sem inferir aplicação, banco ou etapa.
bb_services_initialize() {
    BB_SERVICE_UNITS=("${BB_SERVICE_ROWS[@]}")
    BB_SERVICE_ORIGINAL_STATE=()
    BB_SERVICE_CHANGED=()
    BB_SERVICE_CHANGE_ORDER=()
}

# Confirma previamente existência e estado inequívoco das units declaradas.
# Parâmetros: nenhum; usa a lista criada por bb_services_initialize.
# Resultado: 0 sem alterar serviços; 2 para unit ausente/failed/ambígua.
bb_services_validate_targets() {
    local unit
    for unit in "${BB_SERVICE_UNITS[@]}"; do
        bb_service_exists "$unit" || return "$BB_EXIT_CRITICAL"
        bb_service_state "$unit" >/dev/null || return "$BB_EXIT_CRITICAL"
    done
}

# Confirma que a unit declarada existe e foi carregada pelo systemd.
# Parâmetros: nome validado da unit.
# Resultado: 0 somente para LoadState=loaded.
bb_service_exists() {
    local unit=$1 load_state rc
    if load_state=$(systemctl show --property=LoadState --value -- "$unit" 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi
    (( rc == 0 )) && [[ $load_state == "loaded" ]]
}

# Obtém estado operacional limitado a active/inactive.
# Parâmetros: nome da unit.
# Resultado: imprime o estado e retorna 0; estados ambíguos retornam 2.
bb_service_state() {
    local unit=$1 state rc
    if state=$(systemctl is-active -- "$unit" 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi
    case $state:$rc in
        active:0)
            printf 'active\n'
            ;;
        inactive:3)
            printf 'inactive\n'
            ;;
        *)
            return "$BB_EXIT_CRITICAL"
            ;;
    esac
}

# Registra todos os estados antes de parar a primeira unit e abre a janela crítica.
# Parâmetros: nenhum; usa somente units explicitamente declaradas.
# Resultado: 0 com todas as units originalmente ativas confirmadas como inativas.
# Efeitos: units já inativas não são alteradas; falha mantém dados para o trap.
bb_stop_declared_services() {
    local unit original current rc

    # A primeira passagem evita uma parada parcial causada por unit posterior
    # ausente ou em estado ambíguo e fixa o estado que deverá ser restaurado.
    for unit in "${BB_SERVICE_UNITS[@]}"; do
        bb_validate_application_unit "$unit" || return "$BB_EXIT_CRITICAL"
        bb_service_exists "$unit" || return "$BB_EXIT_CRITICAL"
        original=$(bb_service_state "$unit") || return "$BB_EXIT_CRITICAL"
        BB_SERVICE_ORIGINAL_STATE["$unit"]=$original
        BB_SERVICE_CHANGED["$unit"]="no"
    done

    for unit in "${BB_SERVICE_UNITS[@]}"; do
        original=${BB_SERVICE_ORIGINAL_STATE[$unit]}
        if [[ $original == "active" ]]; then
            if systemctl stop -- "$unit" >/dev/null 2>&1; then
                rc=0
            else
                rc=$?
            fi
            (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
            # O stop pode ter surtido efeito mesmo se a consulta seguinte falhar;
            # a marca imediata garante tentativa de restauração pelo trap.
            BB_SERVICE_CHANGED["$unit"]="yes"
            BB_SERVICE_CHANGE_ORDER+=("$unit")
            current=$(bb_service_state "$unit") || return "$BB_EXIT_CRITICAL"
            [[ $current == "inactive" ]] || return "$BB_EXIT_CRITICAL"
            bb_log INFO service stopped "unidade=$unit foi parada para a janela crítica" || return "$BB_EXIT_CRITICAL"
        else
            bb_log INFO service unchanged "unidade=$unit já estava inativa" || return "$BB_EXIT_CRITICAL"
        fi
    done
}

# Restaura uma unit ativa antes da etapa e valida seu estado final.
# Parâmetros: nome da unit previamente registrada.
# Resultado: 0 quando não alterada ou novamente ativa; 2 em falha de retomada.
bb_restore_one_service() {
    local unit=$1 state rc
    [[ ${BB_SERVICE_CHANGED[$unit]:-"no"} == "yes" ]] || return "$BB_EXIT_OK"
    [[ ${BB_SERVICE_ORIGINAL_STATE[$unit]:-""} == "active" ]] || return "$BB_EXIT_CRITICAL"
    if systemctl start -- "$unit" >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
    state=$(bb_service_state "$unit") || return "$BB_EXIT_CRITICAL"
    [[ $state == "active" ]] || return "$BB_EXIT_CRITICAL"
    BB_SERVICE_CHANGED["$unit"]="no"
    bb_log INFO service restored "unidade=$unit retornou ao estado ativo" || return "$BB_EXIT_CRITICAL"
}

# Tenta restaurar todas as units alteradas em ordem inversa.
# Parâmetros: nenhum.
# Resultado: 0 se todas voltaram; 2 sem mascarar tentativas subsequentes.
bb_restore_all_services() {
    local index unit aggregate=0
    for ((index=${#BB_SERVICE_CHANGE_ORDER[@]} - 1; index >= 0; index--)); do
        unit=${BB_SERVICE_CHANGE_ORDER[$index]}
        if ! bb_restore_one_service "$unit"; then
            aggregate=$BB_EXIT_CRITICAL
        fi
    done
    return "$aggregate"
}
