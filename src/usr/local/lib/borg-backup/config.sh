#!/bin/bash
# Finalidade: carregar e validar configuração declarativa como dados literais.
# Entradas: arquivos fixos sob /etc/borg-backup e replication.d/*.conf.
# Saídas: arrays Bash internos com valores validados; nada é exportado ou
# executado como comando.
# Efeitos colaterais: nenhum; validações usam somente consultas ao filesystem.
# Dependências: Bash, stat, findmnt, df, readlink e funções de common.sh.
# Privilégios: root na instalação; usuário comum no modo controlado.
# Códigos: 0 para configuração íntegra e 2 para qualquer desvio.
# Sigilo: secrets.conf é lido somente após validação de dono e modo e nunca é
# reproduzido em diagnóstico, log ou relatório.

set -Eeuo pipefail
umask 077

declare -gA BB_BACKUP_CONFIG=()
declare -gA BB_SECRET_CONFIG=()
declare -gA BB_REPLICATION_CONFIG=()
declare -ga BB_SOURCES=()
declare -ga BB_EXCLUDES=()
declare -ga BB_DATABASE_ROWS=()
declare -ga BB_APPLICATION_ROWS=()
declare -ga BB_SERVICE_ROWS=()
declare -ga BB_REPLICATION_FILES=()
declare -ga BB_REPLICATION_IDS=()
declare -gA BB_REPL_FILE=()
declare -gA BB_REPL_ENABLED=()
declare -gA BB_REPL_REQUIRED=()
declare -gA BB_REPL_HOST=()
declare -gA BB_REPL_USER=()
declare -gA BB_REPL_PORT=()
declare -gA BB_REPL_DESTINATION=()
declare -gA BB_REPL_IDENTITY=()
declare -gA BB_REPL_KNOWN_HOSTS=()
declare -gA BB_REPL_VERIFY=()

# Emite erro de configuração sem mostrar linha ou valor potencialmente secreto.
# Parâmetros: nome lógico do arquivo, número da linha e causa curta.
# Resultado: retorna 2.
bb_config_error() {
    local file_label=$1 line_number=$2 cause=$3
    bb_stderr "configuração inválida em $file_label:$line_number: $cause"
    return "$BB_EXIT_CRITICAL"
}

# Confirma dono e modo antes de ler um arquivo declarativo.
# Parâmetros: caminho, classe (`normal`, `secret`, `key` ou `known-hosts`).
# Resultado: 0 quando regular, não simbólico, dono esperado e modo restritivo.
bb_validate_config_file_security() {
    local file=$1 class=$2 owner group mode expected_owner expected_group
    [[ -f $file && ! -L $file ]] || {
        bb_stderr "arquivo de configuração ausente ou simbólico: $file"
        return "$BB_EXIT_CRITICAL"
    }
    owner=$(stat -c '%U' -- "$file") || return "$BB_EXIT_CRITICAL"
    group=$(stat -c '%G' -- "$file") || return "$BB_EXIT_CRITICAL"
    mode=$(stat -c '%a' -- "$file") || return "$BB_EXIT_CRITICAL"
    expected_owner="root"
    expected_group="root"
    if [[ $BB_TEST_MODE == "yes" ]]; then
        expected_owner=$(id -un)
        expected_group=$(id -gn)
    fi
    [[ $owner == "$expected_owner" && $group == "$expected_group" ]] || {
        bb_stderr "proprietário ou grupo inválido em arquivo administrativo"
        return "$BB_EXIT_CRITICAL"
    }
    case $class in
        secret|key)
            [[ $mode == "600" ]] || {
                bb_stderr "arquivo secreto não possui modo 0600"
                return "$BB_EXIT_CRITICAL"
            }
            ;;
        normal|known-hosts)
            [[ $mode == "640" ]] || {
                bb_stderr "arquivo administrativo não possui modo 0640"
                return "$BB_EXIT_CRITICAL"
            }
            ;;
        *)
            bb_stderr "classe interna de permissão desconhecida"
            return "$BB_EXIT_CRITICAL"
            ;;
    esac
}

# Verifica presença de uma chave numa lista interna delimitada por dois-pontos.
# Parâmetros: chave e lista sem valores vazios.
# Resultado: 0 quando a correspondência é exata.
bb_key_is_allowed() {
    local key=$1 allowed=$2
    [[ ":$allowed:" == *":$key:"* ]]
}

# Rejeita sintaxe que poderia ser confundida com shell ou comentário inline.
# Parâmetros: valor literal.
# Resultado: 0 para texto literal de uma linha sem expansão; 2 caso contrário.
bb_validate_literal_value() {
    local value=$1
    [[ $value != *$'\r'* && $value != *$'\n'* ]] || return "$BB_EXIT_CRITICAL"
    [[ $value != [[:space:]]* && $value != *[[:space:]] ]] || return "$BB_EXIT_CRITICAL"
    [[ $value != *'$'* && $value != *'`'* && $value != *'#'* ]] || return "$BB_EXIT_CRITICAL"
    [[ $value != *'()'* ]] || return "$BB_EXIT_CRITICAL"
}

# Analisa arquivo CHAVE=valor sem executar seu conteúdo.
# Parâmetros: arquivo, nome do array associativo, chaves aceitas e obrigatórias.
# Resultado: preenche somente o array indicado e retorna 2 no primeiro desvio.
bb_parse_assignment_file() {
    local file=$1 output_name=$2 allowed=$3 required=$4 class=${5:-"normal"}
    local -n output_ref=$output_name
    local line key value required_key line_number=0

    bb_validate_config_file_security "$file" "$class" || return "$BB_EXIT_CRITICAL"
    output_ref=()
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        [[ -z $line ]] && continue
        [[ $line == \#* ]] && continue
        [[ $line == *"="* ]] || bb_config_error "$(basename -- "$file")" "$line_number" "atribuição esperada" || return "$BB_EXIT_CRITICAL"
        key=${line%%=*}
        value=${line#*=}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || bb_config_error "$(basename -- "$file")" "$line_number" "chave malformada" || return "$BB_EXIT_CRITICAL"
        bb_key_is_allowed "$key" "$allowed" || bb_config_error "$(basename -- "$file")" "$line_number" "chave desconhecida" || return "$BB_EXIT_CRITICAL"
        [[ ! -v "output_ref[$key]" ]] || bb_config_error "$(basename -- "$file")" "$line_number" "chave duplicada" || return "$BB_EXIT_CRITICAL"
        [[ -n $value ]] || bb_config_error "$(basename -- "$file")" "$line_number" "valor vazio" || return "$BB_EXIT_CRITICAL"
        bb_validate_literal_value "$value" || bb_config_error "$(basename -- "$file")" "$line_number" "valor não literal" || return "$BB_EXIT_CRITICAL"
        output_ref["$key"]=$value
    done <"$file"

    IFS=':' read -r -a required_keys <<<"$required"
    for required_key in "${required_keys[@]}"; do
        [[ -n $required_key ]] || continue
        [[ -v "output_ref[$required_key]" ]] || {
            bb_config_error "$(basename -- "$file")" 0 "chave obrigatória ausente"
            return "$BB_EXIT_CRITICAL"
        }
    done
}

# Carrega lista literal, ignorando apenas linhas vazias e comentários completos.
# Parâmetros: arquivo, nome do array de saída e tipo (`source` ou `exclude`).
# Resultado: array ordenado como declarado, sem expansão de glob pelo shell.
bb_parse_list_file() {
    local file=$1 output_name=$2 kind=$3
    local -n output_ref=$output_name
    local line existing line_number=0 duplicate
    bb_validate_config_file_security "$file" normal || return "$BB_EXIT_CRITICAL"
    output_ref=()
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        [[ -z $line ]] && continue
        [[ $line == \#* ]] && continue
        bb_validate_literal_value "$line" || bb_config_error "$(basename -- "$file")" "$line_number" "linha não literal" || return "$BB_EXIT_CRITICAL"
        duplicate="no"
        for existing in "${output_ref[@]}"; do
            [[ $existing == "$line" ]] && duplicate="yes"
        done
        [[ $duplicate == "no" ]] || bb_config_error "$(basename -- "$file")" "$line_number" "linha duplicada" || return "$BB_EXIT_CRITICAL"
        if [[ $kind == "source" ]]; then
            bb_validate_absolute_path "$line" "no" "yes" || bb_config_error "$(basename -- "$file")" "$line_number" "fonte insegura" || return "$BB_EXIT_CRITICAL"
        fi
        output_ref+=("$line")
    done <"$file"
}

# Carrega tabela literal delimitada por `|` sem interpretar seus campos.
# Parâmetros: arquivo e nome do array de saída.
# Resultado: conserva uma linha por registro e rejeita campos vazios/hostis.
bb_parse_table_file() {
    local file=$1 output_name=$2
    local -n output_ref=$output_name
    local line field line_number=0
    local -a fields=()
    bb_validate_config_file_security "$file" normal || return "$BB_EXIT_CRITICAL"
    output_ref=()
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        [[ -z $line ]] && continue
        [[ $line == \#* ]] && continue
        bb_validate_literal_value "$line" || bb_config_error "$(basename -- "$file")" "$line_number" "linha não literal" || return "$BB_EXIT_CRITICAL"
        [[ $line == *"|"* && $line != "|"* && $line != *"|" ]] || bb_config_error "$(basename -- "$file")" "$line_number" "tabela malformada" || return "$BB_EXIT_CRITICAL"
        IFS='|' read -r -a fields <<<"$line"
        for field in "${fields[@]}"; do
            [[ -n $field && $field != [[:space:]]* && $field != *[[:space:]] ]] || bb_config_error "$(basename -- "$file")" "$line_number" "campo vazio ou com borda em branco" || return "$BB_EXIT_CRITICAL"
        done
        output_ref+=("$line")
    done <"$file"
}

# Confirma tipos, colunas e IDs dos adaptadores autorizados de banco.
# Parâmetros: usa BB_DATABASE_ROWS.
# Resultado: 0 para PostgreSQL/globais/SQLite válidos e IDs únicos.
bb_validate_database_rows() {
    local row type id database user socket port db_path key
    local -a fields=()
    local -A seen=()
    for row in "${BB_DATABASE_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}
        case $type in
            postgresql)
                (( ${#fields[@]} == 6 )) || return "$BB_EXIT_CRITICAL"
                id=${fields[1]}; database=${fields[2]}; user=${fields[3]}; socket=${fields[4]}; port=${fields[5]}
                bb_validate_id "$id" || return "$BB_EXIT_CRITICAL"
                [[ $database =~ ^[A-Za-z0-9_.-]+$ && $user =~ ^[A-Za-z0-9_.-]+$ ]] || return "$BB_EXIT_CRITICAL"
                bb_validate_absolute_path "$socket" "no" "yes" || return "$BB_EXIT_CRITICAL"
                bb_validate_positive_uint "$port" && (( 10#$port <= 65535 )) || return "$BB_EXIT_CRITICAL"
                ;;
            postgresql-globals)
                (( ${#fields[@]} == 5 )) || return "$BB_EXIT_CRITICAL"
                id=${fields[1]}; user=${fields[2]}; socket=${fields[3]}; port=${fields[4]}
                bb_validate_id "$id" || return "$BB_EXIT_CRITICAL"
                [[ $user =~ ^[A-Za-z0-9_.-]+$ ]] || return "$BB_EXIT_CRITICAL"
                bb_validate_absolute_path "$socket" "no" "yes" || return "$BB_EXIT_CRITICAL"
                bb_validate_positive_uint "$port" && (( 10#$port <= 65535 )) || return "$BB_EXIT_CRITICAL"
                ;;
            sqlite)
                (( ${#fields[@]} == 3 )) || return "$BB_EXIT_CRITICAL"
                id=${fields[1]}; db_path=${fields[2]}
                bb_validate_id "$id" || return "$BB_EXIT_CRITICAL"
                bb_validate_absolute_path "$db_path" "no" "yes" || return "$BB_EXIT_CRITICAL"
                ;;
            *)
                return "$BB_EXIT_CRITICAL"
                ;;
        esac
        key="$type:$id"
        [[ ! -v "seen[$key]" ]] || return "$BB_EXIT_CRITICAL"
        seen["$key"]=1
    done
}

# Confirma tipos e colunas dos adaptadores de aplicação previstos no contrato.
# Parâmetros: usa BB_APPLICATION_ROWS.
# Resultado: 0 somente para Nextcloud e BIND com IDs únicos.
bb_validate_application_rows() {
    local row type id directory user key
    local -a fields=()
    local -A seen=()
    for row in "${BB_APPLICATION_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        (( ${#fields[@]} == 4 )) || return "$BB_EXIT_CRITICAL"
        type=${fields[0]}; id=${fields[1]}; directory=${fields[2]}; user=${fields[3]}
        [[ $type == "nextcloud" || $type == "bind" ]] || return "$BB_EXIT_CRITICAL"
        bb_validate_id "$id" || return "$BB_EXIT_CRITICAL"
        bb_validate_absolute_path "$directory" "no" "yes" || return "$BB_EXIT_CRITICAL"
        [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || return "$BB_EXIT_CRITICAL"
        key="$type:$id"
        [[ ! -v "seen[$key]" ]] || return "$BB_EXIT_CRITICAL"
        seen["$key"]=1
    done
}

# Impede que configuração de serviço alcance infraestrutura protegida.
# Parâmetros: nome de unit systemd.
# Resultado: 0 apenas para unidade de aplicação sintaticamente segura.
bb_validate_application_unit() {
    local unit=$1 lowered=${1,,}
    [[ $unit =~ ^[A-Za-z0-9@_.:-]+\.service$ ]] || return "$BB_EXIT_CRITICAL"
    # Os padrões são deliberadamente conservadores: uma unit cujo nome a
    # associe a SSH, DNS, rede, firewall ou VPN não pode ser usada como serviço
    # de aplicação, inclusive quando a distribuição adota implementação nova.
    case $lowered in
        *ssh*.service|dropbear*.service|*bind*.service|*named*.service|*dns*.service|systemd-resolved.service|unbound*.service|knot*.service|kresd*.service|pdns*.service|nsd*.service|maradns*.service|*network*.service|ifup@*.service|dhcp*.service|connman*.service|wicked*.service|nft*.service|*firewall*.service|ufw*.service|iptables*.service|netfilter*.service|*vpn*.service|wg-quick*.service|wireguard*.service|strongswan*.service|ipsec*.service|tailscaled*.service|zerotier-one*.service|tinc*.service|openconnect*.service)
            return "$BB_EXIT_CRITICAL"
            ;;
    esac
}

# Valida a lista explícita de units sem associá-las a banco ou aplicação.
# Parâmetros: usa BB_SERVICE_ROWS já carregada como lista literal.
# Resultado: 0 somente para units de aplicação seguras; duplicatas já foram
# recusadas pelo parser de lista antes desta função.
bb_validate_service_rows() {
    local unit
    for unit in "${BB_SERVICE_ROWS[@]}"; do
        bb_validate_application_unit "$unit" || return "$BB_EXIT_CRITICAL"
    done
}

# Exige exclusão explícita do banco SQLite vivo e de seus auxiliares WAL/SHM.
# Parâmetros: usa BB_DATABASE_ROWS e BB_EXCLUDES.
# Resultado: 0 quando cada SQLite tem as três exclusões literais canônicas.
bb_validate_sqlite_exclusions() {
    local row type database required
    local -a fields=()
    for row in "${BB_DATABASE_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}
        [[ $type == "sqlite" ]] || continue
        database=${fields[2]}
        for required in "$database" "$database-wal" "$database-shm"; do
            bb_array_contains "$required" "${BB_EXCLUDES[@]}" || return "$BB_EXIT_CRITICAL"
        done
    done
}

# Confirma parâmetros globais, listas, mount, sentinela, espaço e recursão.
# Parâmetros: usa arrays de configuração já carregados.
# Resultado: 0 somente quando o repositório correto está montado e isolado.
bb_validate_primary_configuration() {
    local repository sentinel sentinel_root physical_repository physical_sentinel
    local mount_target mount_uuid mount_type expected_uuid minimum_free free_mib source physical_source
    local expected_owner expected_group expected_storage_id
    local exclusion required_exclusion

    repository=${BB_BACKUP_CONFIG[BORG_REPOSITORY]}
    sentinel=${BB_BACKUP_CONFIG[REPOSITORY_SENTINEL]}
    bb_validate_storage_path "$repository" || return "$BB_EXIT_CRITICAL"
    bb_validate_storage_path "$sentinel" || return "$BB_EXIT_CRITICAL"
    bb_validate_id "${BB_BACKUP_CONFIG[ARCHIVE_PREFIX]}" || return "$BB_EXIT_CRITICAL"
    [[ ${BB_BACKUP_CONFIG[BORG_COMPRESSION]} == "auto,zstd,3" ]] || return "$BB_EXIT_CRITICAL"
    [[ ${BB_BACKUP_CONFIG[KEEP_DAILY]} == "14" && ${BB_BACKUP_CONFIG[KEEP_WEEKLY]} == "8" && ${BB_BACKUP_CONFIG[KEEP_MONTHLY]} == "12" ]] || return "$BB_EXIT_CRITICAL"
    [[ ${BB_BACKUP_CONFIG[REPOSITORY_FILESYSTEM_TYPE]} == "ext4" ]] || return "$BB_EXIT_CRITICAL"
    expected_storage_id=${BB_BACKUP_CONFIG[REPOSITORY_STORAGE_ID]}
    bb_validate_id "$expected_storage_id" || return "$BB_EXIT_CRITICAL"
    bb_validate_positive_uint "${BB_BACKUP_CONFIG[REPOSITORY_MIN_FREE_MIB]}" || return "$BB_EXIT_CRITICAL"
    bb_validate_yes_no "${BB_BACKUP_CONFIG[FILE_LOG_ENABLED]}" || return "$BB_EXIT_CRITICAL"
    [[ ${BB_BACKUP_CONFIG[REPOSITORY_FILESYSTEM_UUID]} =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || return "$BB_EXIT_CRITICAL"

    case $repository in
        /etc|/etc/*|/usr/local|/usr/local/*|/var/lib/borg-backup|/var/lib/borg-backup/*|/var/tmp/borg-backup|/var/tmp/borg-backup/*)
            return "$BB_EXIT_CRITICAL"
            ;;
    esac

    physical_repository=$(bb_system_path "$repository") || return "$BB_EXIT_CRITICAL"
    physical_sentinel=$(bb_system_path "$sentinel") || return "$BB_EXIT_CRITICAL"
    sentinel_root=$(dirname -- "$physical_sentinel")
    [[ -d $physical_repository && ! -L $physical_repository ]] || return "$BB_EXIT_CRITICAL"
    expected_owner="root"
    expected_group="root"
    if [[ $BB_TEST_MODE == "yes" ]]; then
        expected_owner=$(id -un)
        expected_group=$(id -gn)
    fi
    bb_validate_storage_sentinel "$physical_sentinel" "$expected_storage_id" \
        "$expected_owner" "$expected_group" || return "$BB_EXIT_CRITICAL"

    read -r mount_target mount_uuid mount_type < <(findmnt --noheadings --output TARGET,UUID,FSTYPE --target "$physical_repository") || return "$BB_EXIT_CRITICAL"
    [[ $mount_target == "$sentinel_root" ]] || return "$BB_EXIT_CRITICAL"
    expected_uuid=${BB_BACKUP_CONFIG[REPOSITORY_FILESYSTEM_UUID],,}
    [[ ${mount_uuid,,} == "$expected_uuid" ]] || return "$BB_EXIT_CRITICAL"
    [[ $mount_type == "${BB_BACKUP_CONFIG[REPOSITORY_FILESYSTEM_TYPE]}" ]] || return "$BB_EXIT_CRITICAL"
    if [[ $BB_ENFORCE_PRIMARY_CAPACITY_PRECHECK == "yes" ]]; then
        bb_available_mib "$physical_repository" free_mib || return "$BB_EXIT_CRITICAL"
        minimum_free=${BB_BACKUP_CONFIG[REPOSITORY_MIN_FREE_MIB]}
        (( 10#$free_mib >= 10#$minimum_free )) || return "$BB_EXIT_CRITICAL"
    elif [[ $BB_ENFORCE_PRIMARY_CAPACITY_PRECHECK != "no" ]]; then
        return "$BB_EXIT_CRITICAL"
    fi

    (( ${#BB_SOURCES[@]} > 0 )) || return "$BB_EXIT_CRITICAL"
    for source in "${BB_SOURCES[@]}"; do
        physical_source=$(bb_system_path "$source") || return "$BB_EXIT_CRITICAL"
        [[ -e $physical_source && ! -L $physical_source ]] || return "$BB_EXIT_CRITICAL"
        if bb_path_is_within "$physical_source" "$physical_repository" || bb_path_is_within "$physical_repository" "$physical_source"; then
            return "$BB_EXIT_CRITICAL"
        fi
    done

    for required_exclusion in "$repository" "/var/tmp/borg-backup" "/etc/borg-backup/secrets.conf" "/etc/borg-backup/ssh/keys"; do
        bb_array_contains "$required_exclusion" "${BB_EXCLUDES[@]}" || return "$BB_EXIT_CRITICAL"
    done
}

# Valida configuração global e individual de todos os destinos antes de copiar.
# Parâmetros: usa BB_REPLICATION_CONFIG e arquivos em replication.d.
# Resultado: preenche mapas por ID; IDs/raízes duplicados abortam toda a etapa.
bb_load_and_validate_replication_destinations() {
    local enabled source verify minimum file id endpoint
    local -A item=() seen_id=() seen_endpoint=()
    local allowed required
    allowed="REPLICATION_ID:REPLICATION_ENABLED:REPLICATION_REQUIRED:REPLICATION_HOST:REPLICATION_USER:REPLICATION_SSH_PORT:REPLICATION_DESTINATION:REPLICATION_IDENTITY_FILE:REPLICATION_KNOWN_HOSTS_FILE:REPLICATION_VERIFY_MODE"
    required=$allowed

    enabled=${BB_REPLICATION_CONFIG[REPLICATION_ENABLED]}
    source=${BB_REPLICATION_CONFIG[REPLICATION_SOURCE]}
    verify=${BB_REPLICATION_CONFIG[REPLICATION_VERIFY_MODE]}
    minimum=${BB_REPLICATION_CONFIG[REPLICATION_MIN_FREE_MIB]}
    bb_validate_yes_no "$enabled" || return "$BB_EXIT_CRITICAL"
    [[ $source == "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}" ]] || return "$BB_EXIT_CRITICAL"
    [[ $verify == "basic" ]] || return "$BB_EXIT_CRITICAL"
    bb_validate_positive_uint "$minimum" || return "$BB_EXIT_CRITICAL"

    BB_REPLICATION_IDS=()
    for file in "${BB_REPLICATION_FILES[@]}"; do
        item=()
        bb_parse_assignment_file "$file" item "$allowed" "$required" normal || return "$BB_EXIT_CRITICAL"
        id=${item[REPLICATION_ID]}
        bb_validate_id "$id" || return "$BB_EXIT_CRITICAL"
        [[ ! -v "seen_id[$id]" ]] || return "$BB_EXIT_CRITICAL"
        seen_id["$id"]=1
        bb_validate_yes_no "${item[REPLICATION_ENABLED]}" || return "$BB_EXIT_CRITICAL"
        bb_validate_yes_no "${item[REPLICATION_REQUIRED]}" || return "$BB_EXIT_CRITICAL"
        [[ ${item[REPLICATION_HOST]} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return "$BB_EXIT_CRITICAL"
        [[ ${item[REPLICATION_USER]} =~ ^[a-z_][a-z0-9_-]*$ ]] || return "$BB_EXIT_CRITICAL"
        bb_validate_positive_uint "${item[REPLICATION_SSH_PORT]}" && (( 10#${item[REPLICATION_SSH_PORT]} <= 65535 )) || return "$BB_EXIT_CRITICAL"
        bb_validate_storage_path "${item[REPLICATION_DESTINATION]}" || return "$BB_EXIT_CRITICAL"
        bb_validate_storage_path "${item[REPLICATION_IDENTITY_FILE]}" || return "$BB_EXIT_CRITICAL"
        bb_validate_storage_path "${item[REPLICATION_KNOWN_HOSTS_FILE]}" || return "$BB_EXIT_CRITICAL"
        [[ ${item[REPLICATION_VERIFY_MODE]} == "basic" ]] || return "$BB_EXIT_CRITICAL"
        [[ ${item[REPLICATION_DESTINATION]} != "$source" ]] || return "$BB_EXIT_CRITICAL"
        endpoint="${item[REPLICATION_HOST]}:${item[REPLICATION_DESTINATION]}"
        [[ ! -v "seen_endpoint[$endpoint]" ]] || return "$BB_EXIT_CRITICAL"
        seen_endpoint["$endpoint"]=1

        if [[ ${item[REPLICATION_ENABLED]} == "yes" ]]; then
            bb_validate_config_file_security "$(bb_system_path "${item[REPLICATION_IDENTITY_FILE]}")" key || return "$BB_EXIT_CRITICAL"
            bb_validate_config_file_security "$(bb_system_path "${item[REPLICATION_KNOWN_HOSTS_FILE]}")" known-hosts || return "$BB_EXIT_CRITICAL"
        fi

        BB_REPLICATION_IDS+=("$id")
        BB_REPL_FILE["$id"]=$file
        BB_REPL_ENABLED["$id"]=${item[REPLICATION_ENABLED]}
        BB_REPL_REQUIRED["$id"]=${item[REPLICATION_REQUIRED]}
        BB_REPL_HOST["$id"]=${item[REPLICATION_HOST]}
        BB_REPL_USER["$id"]=${item[REPLICATION_USER]}
        BB_REPL_PORT["$id"]=${item[REPLICATION_SSH_PORT]}
        BB_REPL_DESTINATION["$id"]=${item[REPLICATION_DESTINATION]}
        BB_REPL_IDENTITY["$id"]=${item[REPLICATION_IDENTITY_FILE]}
        BB_REPL_KNOWN_HOSTS["$id"]=${item[REPLICATION_KNOWN_HOSTS_FILE]}
        BB_REPL_VERIFY["$id"]=${item[REPLICATION_VERIFY_MODE]}
    done

    if [[ $enabled == "yes" && ${#BB_REPLICATION_IDS[@]} -eq 0 ]]; then
        return "$BB_EXIT_CRITICAL"
    fi
}

# Carrega todos os arquivos fixos e executa validações independentes de backup.
# Parâmetros: nenhum; usa BB_CONFIG_DIR.
# Resultado: 0 com arrays globais completos ou 2 sem executar configurações.
bb_load_and_validate_configuration() {
    local backup_allowed backup_required replication_allowed replication_required
    local -a replication_candidates=()
    local candidate

    backup_allowed="BORG_REPOSITORY:ARCHIVE_PREFIX:BORG_COMPRESSION:KEEP_DAILY:KEEP_WEEKLY:KEEP_MONTHLY:REPOSITORY_FILESYSTEM_UUID:REPOSITORY_FILESYSTEM_TYPE:REPOSITORY_STORAGE_ID:REPOSITORY_MIN_FREE_MIB:REPOSITORY_SENTINEL:FILE_LOG_ENABLED"
    backup_required=$backup_allowed
    replication_allowed="REPLICATION_ENABLED:REPLICATION_SOURCE:REPLICATION_VERIFY_MODE:REPLICATION_MIN_FREE_MIB"
    replication_required=$replication_allowed

    bb_require_directory "$BB_CONFIG_DIR" || return "$BB_EXIT_CRITICAL"
    bb_parse_assignment_file "$BB_CONFIG_DIR/backup.conf" BB_BACKUP_CONFIG "$backup_allowed" "$backup_required" normal || return "$BB_EXIT_CRITICAL"
    bb_parse_assignment_file "$BB_CONFIG_DIR/secrets.conf" BB_SECRET_CONFIG "BORG_PASSPHRASE" "BORG_PASSPHRASE" secret || return "$BB_EXIT_CRITICAL"
    [[ ${BB_SECRET_CONFIG[BORG_PASSPHRASE]} != "SUBSTITUIR_POR_VALOR_SOB_CUSTODIA" ]] || return "$BB_EXIT_CRITICAL"
    bb_register_secret_for_redaction "${BB_SECRET_CONFIG[BORG_PASSPHRASE]}"
    bb_parse_assignment_file "$BB_CONFIG_DIR/replication.conf" BB_REPLICATION_CONFIG "$replication_allowed" "$replication_required" normal || return "$BB_EXIT_CRITICAL"
    bb_parse_list_file "$BB_CONFIG_DIR/sources.conf" BB_SOURCES source || return "$BB_EXIT_CRITICAL"
    bb_parse_list_file "$BB_CONFIG_DIR/excludes.conf" BB_EXCLUDES exclude || return "$BB_EXIT_CRITICAL"
    bb_parse_table_file "$BB_CONFIG_DIR/databases.conf" BB_DATABASE_ROWS || return "$BB_EXIT_CRITICAL"
    bb_parse_table_file "$BB_CONFIG_DIR/applications.conf" BB_APPLICATION_ROWS || return "$BB_EXIT_CRITICAL"
    bb_parse_list_file "$BB_CONFIG_DIR/services.conf" BB_SERVICE_ROWS service || return "$BB_EXIT_CRITICAL"

    bb_validate_managed_directory "$BB_CONFIG_DIR/replication.d" 750 || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$BB_CONFIG_DIR/ssh" 700 || return "$BB_EXIT_CRITICAL"
    bb_validate_managed_directory "$BB_CONFIG_DIR/ssh/keys" 700 || return "$BB_EXIT_CRITICAL"
    bb_validate_config_file_security "$BB_CONFIG_DIR/ssh/known_hosts" known-hosts || return "$BB_EXIT_CRITICAL"
    shopt -s nullglob
    replication_candidates=("$BB_CONFIG_DIR"/replication.d/*.conf)
    shopt -u nullglob
    BB_REPLICATION_FILES=()
    while IFS= read -r candidate; do
        [[ -n $candidate ]] && BB_REPLICATION_FILES+=("$candidate")
    done < <(printf '%s\n' "${replication_candidates[@]}" | LC_ALL=C sort)

    bb_validate_database_rows || return "$BB_EXIT_CRITICAL"
    bb_validate_application_rows || return "$BB_EXIT_CRITICAL"
    bb_validate_service_rows || return "$BB_EXIT_CRITICAL"
    bb_validate_sqlite_exclusions || return "$BB_EXIT_CRITICAL"
    bb_validate_primary_configuration || return "$BB_EXIT_CRITICAL"
    bb_load_and_validate_replication_destinations || return "$BB_EXIT_CRITICAL"
}
