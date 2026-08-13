#!/bin/bash
# Finalidade: fornecer primitivas compartilhadas de segurança, caminhos,
# validação, escrita atômica, temporários e bloqueio para a rotina Borg.
# Entradas: variáveis internas inicializadas pelo ponto de entrada e parâmetros
# explícitos de cada função; nenhuma configuração é executada neste módulo.
# Saídas: mensagens de diagnóstico em stderr e arquivos administrativos apenas
# quando uma função de escrita é chamada explicitamente.
# Efeitos colaterais: pode criar diretórios de uma execução, adquirir `flock`,
# promover arquivos temporários e remover somente a árvore temporária validada.
# Dependências: Bash, coreutils, findutils, util-linux e ferramentas Debian base.
# Privilégios: root em instalação real; usuário comum somente no modo controlado
# de teste, que é recusado quando EUID é zero.
# Códigos: funções retornam 0 em sucesso e 2 para falha administrativa; a
# interface converte uso inválido em 64.
# Sigilo: valores secretos jamais devem ser passados a funções de diagnóstico.

# Este módulo é carregado pelo ponto de entrada; a disciplina abaixo também o
# torna seguro para validação isolada por `bash -n`.
set -Eeuo pipefail
umask 077

declare -gr BB_EXIT_OK=0
declare -gr BB_EXIT_WARNING=1
declare -gr BB_EXIT_CRITICAL=2
declare -gr BB_EXIT_USAGE=64
declare -gr BB_VERSION="1.0.2"
declare -gr BB_STORAGE_PURPOSE="borg-backup"

declare -g BB_TEST_MODE="no"
declare -g BB_TEST_ROOT=""
declare -g BB_CONFIG_DIR=""
declare -g BB_STATE_DIR=""
declare -g BB_LOG_DIR=""
declare -g BB_TMP_ROOT=""
declare -g BB_RUN_DIR=""
declare -g BB_LOCK_FILE=""
declare -g BB_EXECUTION_DIR=""
declare -g BB_LOCK_HELD="no"
declare -g BB_ORPHANED_EXECUTION_DIRS_REMOVED=0
declare -g BB_ENFORCE_PRIMARY_CAPACITY_PRECHECK="yes"
declare -g BB_CAPACITY_WARNING="no"

# Emite diagnóstico inicial sem incluir valores de configuração ou ambiente.
# Parâmetros: mensagem administrativa já sanitizada.
# Resultado: sempre 0; escreve uma linha em stderr.
bb_stderr() {
    local message=${1:-"erro não especificado"}
    printf 'borg-backup: %s\n' "$message" >&2
}

# Confirma que um valor usa o identificador portátil definido pelo contrato.
# Parâmetros: identificador candidato.
# Resultado: 0 para letras minúsculas, números e hífen; 2 em caso contrário.
bb_validate_id() {
    local candidate=${1-}
    [[ $candidate =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || return "$BB_EXIT_CRITICAL"
}

# Confirma um valor booleano do conjunto fechado aceito pela configuração.
# Parâmetros: valor candidato.
# Resultado: 0 somente para `yes` ou `no`.
bb_validate_yes_no() {
    local candidate=${1-}
    [[ $candidate == "yes" || $candidate == "no" ]]
}

# Verifica inteiros decimais não negativos sem depender de coerção implícita.
# Parâmetros: valor candidato.
# Resultado: 0 para representação decimal canônica; 2 em caso contrário.
bb_validate_uint() {
    local candidate=${1-}
    [[ $candidate =~ ^(0|[1-9][0-9]*)$ ]]
}

# Verifica inteiros estritamente positivos.
# Parâmetros: valor candidato.
# Resultado: 0 quando decimal e maior que zero.
bb_validate_positive_uint() {
    local candidate=${1-}
    bb_validate_uint "$candidate" || return "$BB_EXIT_CRITICAL"
    (( 10#$candidate > 0 ))
}

# Obtém o espaço livre em MiB para um caminho já validado.
# Parâmetros: caminho físico e nome da variável de saída.
# Resultado: 0 com inteiro decimal; 2 se `df` falhar ou retornar dado ambíguo.
bb_available_mib() {
    local path=$1 output_name=$2 measured
    local -n output_ref=$output_name
    measured=$(df -m --output=avail "$path" | tail -n 1 | tr -d '[:space:]') || return "$BB_EXIT_CRITICAL"
    bb_validate_uint "$measured" || return "$BB_EXIT_CRITICAL"
    output_ref=$measured
}

# Valida a sentinela estruturada que identifica inequivocamente o filesystem.
# Parâmetros: arquivo físico, STORAGE_ID esperado, proprietário e grupo esperados.
# Resultado: 0 somente para modo 0640 e exatamente duas chaves literais únicas.
# Segurança: o arquivo é analisado como dados; comentários, shell e extras falham.
bb_validate_storage_sentinel() {
    local file=$1 expected_id=$2 expected_owner=$3 expected_group=$4
    local line key value line_count=0 owner group mode
    local -A seen=()

    bb_validate_id "$expected_id" || return "$BB_EXIT_CRITICAL"
    [[ -f $file && ! -L $file ]] || return "$BB_EXIT_CRITICAL"
    owner=$(stat -c '%U' -- "$file") || return "$BB_EXIT_CRITICAL"
    group=$(stat -c '%G' -- "$file") || return "$BB_EXIT_CRITICAL"
    mode=$(stat -c '%a' -- "$file") || return "$BB_EXIT_CRITICAL"
    [[ $owner == "$expected_owner" && $group == "$expected_group" && $mode == "640" ]] || return "$BB_EXIT_CRITICAL"

    while IFS= read -r line || [[ -n $line ]]; do
        ((line_count += 1))
        [[ ${line//[^=]/} == "=" && $line != "="* ]] || return "$BB_EXIT_CRITICAL"
        key=${line%%=*}
        value=${line#*=}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ && -n $value ]] || return "$BB_EXIT_CRITICAL"
        [[ ! -v "seen[$key]" ]] || return "$BB_EXIT_CRITICAL"
        seen["$key"]=1
        case $key in
            STORAGE_ID)
                bb_validate_id "$value" || return "$BB_EXIT_CRITICAL"
                [[ $value == "$expected_id" ]] || return "$BB_EXIT_CRITICAL"
                ;;
            PURPOSE)
                [[ $value == "$BB_STORAGE_PURPOSE" ]] || return "$BB_EXIT_CRITICAL"
                ;;
            *)
                return "$BB_EXIT_CRITICAL"
                ;;
        esac
    done <"$file"
    (( line_count == 2 )) || return "$BB_EXIT_CRITICAL"
    [[ -v 'seen[STORAGE_ID]' && -v 'seen[PURPOSE]' ]]
}

# Verifica caminho absoluto administrativo sem espaços ou componentes ambíguos.
# Parâmetros: caminho, `yes` quando a raiz for aceita e `yes` para espaço interno.
# Resultado: 0 para forma lexical segura; 2 para alvo vazio ou perigoso.
bb_validate_absolute_path() {
    local candidate=${1-}
    local allow_root=${2:-"no"}
    local allow_space=${3:-"no"}

    [[ -n $candidate && $candidate == /* ]] || return "$BB_EXIT_CRITICAL"
    [[ $candidate != *$'\n'* && $candidate != *$'\r'* && $candidate != *$'\t'* ]] || return "$BB_EXIT_CRITICAL"
    if [[ $allow_space != "yes" && $candidate == *' '* ]]; then
        return "$BB_EXIT_CRITICAL"
    fi
    [[ $candidate != *' ' ]] || return "$BB_EXIT_CRITICAL"
    [[ $candidate != *//* && $candidate != */./* && $candidate != */../* ]] || return "$BB_EXIT_CRITICAL"
    [[ $candidate != */. && $candidate != */.. ]] || return "$BB_EXIT_CRITICAL"
    if [[ $allow_root != "yes" && $candidate == "/" ]]; then
        return "$BB_EXIT_CRITICAL"
    fi
}

# Valida caminhos de repositório, réplica e credenciais com alfabeto fechado.
# Parâmetros: caminho absoluto sem espaços.
# Resultado: 0 quando também não contém metacaracteres desnecessários.
bb_validate_storage_path() {
    local candidate=${1-}
    bb_validate_absolute_path "$candidate" || return "$BB_EXIT_CRITICAL"
    [[ $candidate =~ ^/[A-Za-z0-9._@+/:,-]+$ ]]
}

# Procura correspondência literal em array sem avaliar o valor como subscript.
# Parâmetros: valor procurado e elementos restantes.
# Resultado: 0 quando encontrado; 1 quando ausente.
bb_array_contains() {
    local needle=$1
    shift
    local element
    for element in "$@"; do
        [[ $element == "$needle" ]] && return 0
    done
    return 1
}

# Informa se um caminho está contido em outro após normalização lexical.
# Parâmetros: diretório pai e caminho candidato.
# Resultado: 0 quando iguais ou quando o candidato está sob o pai.
# Efeitos: não segue nem cria links; usa `readlink -m` apenas para normalização.
bb_path_is_within() {
    local parent candidate normalized_parent normalized_candidate
    parent=$1
    candidate=$2
    normalized_parent=$(readlink -m -- "$parent") || return "$BB_EXIT_CRITICAL"
    normalized_candidate=$(readlink -m -- "$candidate") || return "$BB_EXIT_CRITICAL"
    [[ $normalized_candidate == "$normalized_parent" || $normalized_candidate == "$normalized_parent"/* ]]
}

# Traduz caminho operacional absoluto para a raiz sintética do harness público.
# Parâmetros: caminho lógico final, como `/etc/borg-backup`.
# Resultado: imprime o caminho físico; não cria arquivos.
# Segurança: modo de teste é recusado para root e a raiz não pode ser `/`.
bb_system_path() {
    local logical_path=$1
    bb_validate_absolute_path "$logical_path" "yes" "yes" || return "$BB_EXIT_CRITICAL"
    if [[ $BB_TEST_MODE == "yes" ]]; then
        printf '%s%s\n' "$BB_TEST_ROOT" "$logical_path"
    else
        printf '%s\n' "$logical_path"
    fi
}

# Inicializa todos os caminhos internos sem depender do diretório corrente.
# Parâmetros: nenhum; consome BB_BOOTSTRAP_TEST_MODE e BB_BOOTSTRAP_TEST_ROOT.
# Resultado: 0 e variáveis globais preenchidas, ou 2 antes de qualquer escrita.
bb_initialize_paths() {
    local requested_mode=${BB_BOOTSTRAP_TEST_MODE:-"no"}
    local requested_root=${BB_BOOTSTRAP_TEST_ROOT:-""}
    local canonical_root

    bb_validate_yes_no "$requested_mode" || {
        bb_stderr "modo controlado inválido"
        return "$BB_EXIT_CRITICAL"
    }

    if [[ $requested_mode == "yes" ]]; then
        if (( EUID == 0 )); then
            bb_stderr "modo controlado é recusado para EUID zero"
            return "$BB_EXIT_CRITICAL"
        fi
        bb_validate_absolute_path "$requested_root" || {
            bb_stderr "raiz controlada insegura"
            return "$BB_EXIT_CRITICAL"
        }
        [[ -d $requested_root && ! -L $requested_root && -r $requested_root && -w $requested_root && -x $requested_root ]] || {
            bb_stderr "raiz controlada ausente ou sem permissões"
            return "$BB_EXIT_CRITICAL"
        }
        canonical_root=$(readlink -e -- "$requested_root") || return "$BB_EXIT_CRITICAL"
        [[ $canonical_root == "$requested_root" ]] || {
            bb_stderr "raiz controlada deve usar caminho canônico"
            return "$BB_EXIT_CRITICAL"
        }
        BB_TEST_MODE="yes"
        BB_TEST_ROOT=$canonical_root
    else
        [[ -z $requested_root ]] || {
            bb_stderr "raiz controlada exige modo de teste explícito"
            return "$BB_EXIT_CRITICAL"
        }
        BB_TEST_MODE="no"
        BB_TEST_ROOT=""
    fi

    BB_CONFIG_DIR=$(bb_system_path "/etc/borg-backup")
    BB_STATE_DIR=$(bb_system_path "/var/lib/borg-backup/state")
    BB_LOG_DIR=$(bb_system_path "/var/log/borg-backup")
    BB_TMP_ROOT=$(bb_system_path "/var/tmp/borg-backup")
    BB_RUN_DIR=$(bb_system_path "/run/borg-backup")
    BB_LOCK_FILE="$BB_RUN_DIR/backup.lock"
}

# Exige root na instalação real e mantém a harness público executável sem elevação.
# Parâmetros: nenhum.
# Resultado: 0 para root real ou usuário não-root em modo controlado.
bb_require_administrative_context() {
    if [[ $BB_TEST_MODE == "yes" ]]; then
        (( EUID != 0 )) || return "$BB_EXIT_CRITICAL"
    else
        (( EUID == 0 )) || {
            bb_stderr "a operação administrativa exige root"
            return "$BB_EXIT_CRITICAL"
        }
    fi
}

# Exige uma dependência pelo nome, sem executar descoberta de infraestrutura.
# Parâmetros: nome fixo de comando previsto pelo contrato.
# Resultado: 0 se encontrado no PATH controlado; 2 em caso contrário.
bb_require_command() {
    local command_name=$1
    command -v -- "$command_name" >/dev/null 2>&1 || {
        bb_stderr "dependência obrigatória ausente: $command_name"
        return "$BB_EXIT_CRITICAL"
    }
}

# Verifica diretório administrativo preexistente e sem links simbólicos.
# Parâmetros: caminho físico e modo máximo opcional em notação octal.
# Resultado: 0 se seguro para a execução; 2 caso contrário.
bb_require_directory() {
    local directory=$1
    [[ -d $directory && ! -L $directory ]] || {
        bb_stderr "diretório administrativo ausente ou simbólico: $directory"
        return "$BB_EXIT_CRITICAL"
    }
}

# Confirma dono e modo exatos de um diretório administrativo preexistente.
# Parâmetros: caminho físico e modo octal esperado sem zero inicial.
# Resultado: 0 quando a árvore não é simbólica e respeita o contrato.
bb_validate_managed_directory() {
    local directory=$1 expected_mode=$2 owner group mode expected_owner expected_group
    bb_require_directory "$directory" || return "$BB_EXIT_CRITICAL"
    owner=$(stat -c '%U' -- "$directory") || return "$BB_EXIT_CRITICAL"
    group=$(stat -c '%G' -- "$directory") || return "$BB_EXIT_CRITICAL"
    mode=$(stat -c '%a' -- "$directory") || return "$BB_EXIT_CRITICAL"
    expected_owner="root"
    expected_group="root"
    if [[ $BB_TEST_MODE == "yes" ]]; then
        expected_owner=$(id -un)
        expected_group=$(id -gn)
    fi
    [[ $owner == "$expected_owner" && $group == "$expected_group" && $mode == "$expected_mode" ]] || {
        bb_stderr "dono ou modo inválido em diretório administrativo: $directory"
        return "$BB_EXIT_CRITICAL"
    }
}

# Valida os diretórios FHS que já devem existir antes da rotina diária.
# Parâmetros: nenhum; usa os caminhos globais inicializados.
# Resultado: 0 quando configuração, estado, log, temporário e runtime são seguros.
bb_validate_local_layout() {
    bb_validate_managed_directory "$BB_CONFIG_DIR" 750 || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$BB_STATE_DIR" 750 || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$BB_LOG_DIR" 750 || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$BB_TMP_ROOT" 700 || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$BB_RUN_DIR" 750 || return "$BB_EXIT_CRITICAL"
}

# Cria uma área privada e única para dumps e staging da execução atual.
# Parâmetros: identificador seguro da execução.
# Resultado: define BB_EXECUTION_DIR e cria subdiretórios modo 0700.
bb_create_execution_dir() {
    local execution_id=$1
    [[ $execution_id =~ ^[0-9]{8}T[0-9]{6}Z-[a-z0-9.-]+-[0-9]+$ ]] || {
        bb_stderr "identificador de execução inseguro"
        return "$BB_EXIT_CRITICAL"
    }
    bb_require_directory "$BB_TMP_ROOT" || return "$BB_EXIT_CRITICAL"
    BB_EXECUTION_DIR=$(mktemp -d -- "$BB_TMP_ROOT/${execution_id}.XXXXXX") || return "$BB_EXIT_CRITICAL"
    chmod 0700 -- "$BB_EXECUTION_DIR"
    mkdir -- "$BB_EXECUTION_DIR/dumps" "$BB_EXECUTION_DIR/staging"
    chmod 0700 -- "$BB_EXECUTION_DIR/dumps" "$BB_EXECUTION_DIR/staging"
}

# Remove somente a área temporária criada sob BB_TMP_ROOT.
# Parâmetros: nenhum; usa BB_EXECUTION_DIR.
# Resultado: 0 quando inexistente ou removida; 2 se a salvaguarda falhar.
# Segurança: `find -delete` não segue links e nunca recebe a raiz temporária.
bb_cleanup_execution_dir() {
    local canonical_tmp canonical_execution
    [[ -n $BB_EXECUTION_DIR ]] || return "$BB_EXIT_OK"
    canonical_tmp=$(readlink -m -- "$BB_TMP_ROOT") || return "$BB_EXIT_CRITICAL"
    canonical_execution=$(readlink -m -- "$BB_EXECUTION_DIR") || return "$BB_EXIT_CRITICAL"
    [[ $canonical_execution != "$canonical_tmp" && $canonical_execution == "$canonical_tmp"/* ]] || {
        bb_stderr "limpeza temporária recusada por salvaguarda de caminho"
        return "$BB_EXIT_CRITICAL"
    }
    if [[ -e $BB_EXECUTION_DIR || -L $BB_EXECUTION_DIR ]]; then
        find -P "$BB_EXECUTION_DIR" -depth -delete
    fi
    BB_EXECUTION_DIR=""
}

# Confirma que um filho imediato da raiz temporária possui a forma e os
# metadados exclusivos de uma área de execução criada por esta rotina.
# Parâmetros: caminho físico candidato.
# Resultado: 0 somente para diretório real, privado e com nome exato; 2 em erro.
bb_validate_execution_directory() {
    local candidate=$1 name
    [[ ${candidate%/*} == "$BB_TMP_ROOT" ]] || return "$BB_EXIT_CRITICAL"
    name=${candidate##*/}
    [[ $name =~ ^[0-9]{8}T[0-9]{6}Z-[a-z0-9.-]+-[0-9]+\.[A-Za-z0-9]{6}$ ]] || return "$BB_EXIT_CRITICAL"
    [[ -d $candidate && ! -L $candidate ]] || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$candidate" 700
}

# Remove áreas deixadas por término não tratável somente sob o lock global.
# Parâmetros: nenhum; preserva obrigatoriamente BB_EXECUTION_DIR.
# Resultado: 0 após validar todos os filhos e remover somente órfãos; 2 em desvio.
# Segurança: não usa idade; uma entrada inesperada recusa toda a reconciliação.
bb_reconcile_orphaned_execution_dirs() {
    local candidate current_seen="no" had_dotglob="no" had_nullglob="no"
    local -a children=() orphaned=()

    BB_ORPHANED_EXECUTION_DIRS_REMOVED=0
    [[ $BB_LOCK_HELD == "yes" ]] || {
        bb_stderr "reconciliação temporária exige o lock global"
        return "$BB_EXIT_CRITICAL"
    }
    bb_validate_managed_directory "$BB_TMP_ROOT" 700 || return "$BB_EXIT_CRITICAL"
    [[ -n $BB_EXECUTION_DIR ]] || return "$BB_EXIT_CRITICAL"
    bb_validate_execution_directory "$BB_EXECUTION_DIR" || {
        bb_stderr "área da execução corrente é inválida"
        return "$BB_EXIT_CRITICAL"
    }

    shopt -q dotglob && had_dotglob="yes"
    shopt -q nullglob && had_nullglob="yes"
    shopt -s dotglob nullglob
    children=("$BB_TMP_ROOT"/*)
    [[ $had_dotglob == "yes" ]] || shopt -u dotglob
    [[ $had_nullglob == "yes" ]] || shopt -u nullglob

    # A primeira passagem é deliberadamente não destrutiva: nenhum órfão válido
    # é removido se houver outro filho com nome, tipo ou metadados inesperados.
    for candidate in "${children[@]}"; do
        bb_validate_execution_directory "$candidate" || {
            bb_stderr "entrada inesperada impede a reconciliação temporária"
            return "$BB_EXIT_CRITICAL"
        }
        if [[ $candidate == "$BB_EXECUTION_DIR" ]]; then
            current_seen="yes"
        else
            orphaned+=("$candidate")
        fi
    done
    [[ $current_seen == "yes" ]] || return "$BB_EXIT_CRITICAL"

    for candidate in "${orphaned[@]}"; do
        [[ $candidate != "$BB_EXECUTION_DIR" ]] || return "$BB_EXIT_CRITICAL"
        bb_validate_execution_directory "$candidate" || return "$BB_EXIT_CRITICAL"
        if ! find -P "$candidate" -depth -delete 2>/dev/null; then
            bb_stderr "remoção de área temporária órfã falhou"
            return "$BB_EXIT_CRITICAL"
        fi
        ((BB_ORPHANED_EXECUTION_DIRS_REMOVED += 1))
    done
}

# Adquire o lock comum das operações mutáveis em descritor mantido pelo shell.
# Parâmetros: nenhum.
# Resultado: 0 com descritor 9 bloqueado; 2 se outra instância estiver ativa.
bb_acquire_global_lock() {
    bb_require_directory "$BB_RUN_DIR" || return "$BB_EXIT_CRITICAL"
    exec 9>"$BB_LOCK_FILE"
    if ! flock -n 9; then
        bb_stderr "outra operação incompatível mantém o lock global"
        exec 9>&-
        return "$BB_EXIT_CRITICAL"
    fi
    BB_LOCK_HELD="yes"
}

# Libera explicitamente o descritor do lock; o kernel também o libera na saída.
# Parâmetros: nenhum.
# Resultado: sempre 0.
bb_release_global_lock() {
    if [[ $BB_LOCK_HELD == "yes" ]]; then
        flock -u 9 || true
        exec 9>&-
        BB_LOCK_HELD="no"
    fi
}

# Grava stdin em arquivo temporário e o promove por rename no mesmo diretório.
# Parâmetros: caminho final e modo octal.
# Resultado: 0 após fsync do arquivo quando disponível e rename; 2 em falha.
# Efeitos: substitui atomicamente apenas o alvo exato fornecido pelo chamador.
bb_atomic_write_from_stdin() {
    local target=$1
    local mode=$2
    local target_directory temporary
    target_directory=$(dirname -- "$target")
    bb_require_directory "$target_directory" || return "$BB_EXIT_CRITICAL"
    temporary=$(mktemp -- "$target_directory/.tmp.$(basename -- "$target").XXXXXX") || return "$BB_EXIT_CRITICAL"
    if ! cat >"$temporary"; then
        find -P "$temporary" -delete 2>/dev/null || true
        return "$BB_EXIT_CRITICAL"
    fi
    chmod "$mode" -- "$temporary"
    if command -v sync >/dev/null 2>&1; then
        sync -f "$temporary" 2>/dev/null || true
    fi
    mv -fT -- "$temporary" "$target"
}

# Obtém nome local sanitizado para compor archive e identificador de execução.
# Parâmetros: nenhum.
# Resultado: imprime nome minúsculo seguro ou `host` como fallback.
bb_safe_hostname() {
    local raw safe
    raw=$(hostname -s 2>/dev/null || printf 'host')
    safe=${raw,,}
    safe=${safe//[^a-z0-9.-]/-}
    safe=${safe#-}
    safe=${safe%-}
    [[ -n $safe ]] || safe="host"
    printf '%s\n' "$safe"
}
