#!/bin/bash
# Finalidade: gerar e validar dumps lógicos PostgreSQL e SQLite declarados.
# Entradas: BB_DATABASE_ROWS e área privada da execução já preparada.
# Saídas: somente dumps finais validados em `<execução>/dumps/`.
# Efeitos colaterais: cria `.partial` e restaura SQLite somente em arquivo
# temporário; o ciclo uniforme de units pertence exclusivamente a services.sh.
# Dependências: runuser, pg_dump, pg_dumpall, pg_restore, sqlite3 e módulos.
# Privilégios: root em produção; doubles sintéticos nos testes.
# Códigos: 0 quando todos os dumps são válidos; 2 na primeira falha crítica.
# Sigilo: conteúdo e stderr dos SGBDs nunca são copiados para log ou relatório.

set -Eeuo pipefail
umask 077

declare -ga BB_DUMP_FILES=()

# Confirma existência dos sockets/dados locais sem abrir bancos ou gerar dumps.
# Parâmetros: nenhum; usa BB_DATABASE_ROWS.
# Resultado: 0 para caminhos locais explícitos e regulares; 2 em ausência.
bb_databases_validate_targets() {
    local row type logical physical
    local -a fields=()
    for row in "${BB_DATABASE_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}
        case $type in
            postgresql)
                logical=${fields[4]}
                physical=$(bb_system_path "$logical") || return "$BB_EXIT_CRITICAL"
                [[ -d $physical && ! -L $physical ]] || return "$BB_EXIT_CRITICAL"
                id -u "${fields[3]}" >/dev/null 2>&1 || return "$BB_EXIT_CRITICAL"
                ;;
            postgresql-globals)
                logical=${fields[3]}
                physical=$(bb_system_path "$logical") || return "$BB_EXIT_CRITICAL"
                [[ -d $physical && ! -L $physical ]] || return "$BB_EXIT_CRITICAL"
                id -u "${fields[2]}" >/dev/null 2>&1 || return "$BB_EXIT_CRITICAL"
                ;;
            sqlite)
                logical=${fields[2]}
                physical=$(bb_system_path "$logical") || return "$BB_EXIT_CRITICAL"
                [[ -f $physical && ! -L $physical ]] || return "$BB_EXIT_CRITICAL"
                ;;
        esac
    done
}

# Remove arquivo parcial exclusivamente dentro da área da execução.
# Parâmetros: caminho candidato.
# Resultado: 0 quando ausente/removido; 2 para caminho fora de dumps/staging.
bb_remove_temporary_database_file() {
    local path=$1
    if ! bb_path_is_within "$BB_EXECUTION_DIR" "$path" || [[ $path == "$BB_EXECUTION_DIR" ]]; then
        return "$BB_EXIT_CRITICAL"
    fi
    if [[ -e $path || -L $path ]]; then
        find -P "$path" -delete
    fi
}

# Gera dump custom PostgreSQL e confirma legibilidade por pg_restore --list.
# Parâmetros: ID, database, usuário, socket Unix e porta.
# Resultado: adiciona somente o arquivo final validado a BB_DUMP_FILES.
bb_dump_postgresql_database() {
    local id=$1 database=$2 user=$3 socket=$4 port=$5 partial final error_file rc size
    partial="$BB_EXECUTION_DIR/dumps/postgresql-$id.dump.partial"
    final="$BB_EXECUTION_DIR/dumps/postgresql-$id.dump"
    error_file="$BB_EXECUTION_DIR/staging/postgresql-$id.stderr"
    # A shell administrativa abre o arquivo privado; o cliente assume a
    # identidade local declarada para que autenticação PostgreSQL `peer`
    # funcione sem senha ou mapeamento implícito da conta root.
    if runuser -u "$user" -- pg_dump --no-password --format=custom --host="$socket" \
        --port="$port" --username="$user" --dbname="$database" >"$partial" 2>"$error_file"; then rc=0; else rc=$?; fi
    if (( rc != 0 )) || [[ ! -s $partial ]]; then
        bb_remove_temporary_database_file "$partial" || true
        return "$BB_EXIT_CRITICAL"
    fi
    if pg_restore --list "$partial" >/dev/null 2>"$error_file.validate"; then rc=0; else rc=$?; fi
    if (( rc != 0 )); then
        bb_remove_temporary_database_file "$partial" || true
        return "$BB_EXIT_CRITICAL"
    fi
    mv -fT -- "$partial" "$final"
    size=$(stat -c '%s' -- "$final")
    BB_DUMP_FILES+=("$final")
    bb_log INFO database dump-ok "dump PostgreSQL validado id=$id bytes=$size" || return "$BB_EXIT_CRITICAL"
}

# Exporta objetos globais PostgreSQL em SQL literal após retorno e tamanho.
# Parâmetros: ID do cluster, usuário, socket Unix e porta.
# Resultado: promove arquivo `.sql` completo e o registra para o archive.
bb_dump_postgresql_globals() {
    local id=$1 user=$2 socket=$3 port=$4 partial final error_file rc size
    partial="$BB_EXECUTION_DIR/dumps/postgresql-globals-$id.sql.partial"
    final="$BB_EXECUTION_DIR/dumps/postgresql-globals-$id.sql"
    error_file="$BB_EXECUTION_DIR/staging/postgresql-globals-$id.stderr"
    # Objetos globais seguem a mesma identidade local explícita do cluster.
    if runuser -u "$user" -- pg_dumpall --no-password --globals-only --host="$socket" \
        --port="$port" --username="$user" >"$partial" 2>"$error_file"; then rc=0; else rc=$?; fi
    if (( rc != 0 )) || [[ ! -s $partial ]]; then
        bb_remove_temporary_database_file "$partial" || true
        return "$BB_EXIT_CRITICAL"
    fi
    mv -fT -- "$partial" "$final"
    size=$(stat -c '%s' -- "$final")
    BB_DUMP_FILES+=("$final")
    bb_log INFO database globals-ok "objetos globais PostgreSQL validados id=$id bytes=$size" || return "$BB_EXIT_CRITICAL"
}

# Gera dump SQLite e valida restauração/integridade em cópia temporária.
# Parâmetros: ID e caminho lógico do banco vivo.
# Resultado: promove SQL final; não infere nem altera qualquer serviço.
bb_dump_sqlite_database() {
    local id=$1 logical_db=$2 physical_db partial final restored error_file integrity rc primary_rc=0 cleanup_rc=0 size
    physical_db=$(bb_system_path "$logical_db") || return "$BB_EXIT_CRITICAL"
    [[ -f $physical_db && ! -L $physical_db ]] || return "$BB_EXIT_CRITICAL"
    partial="$BB_EXECUTION_DIR/dumps/sqlite-$id.sql.partial"
    final="$BB_EXECUTION_DIR/dumps/sqlite-$id.sql"
    restored="$BB_EXECUTION_DIR/staging/sqlite-$id.restore.sqlite3"
    error_file="$BB_EXECUTION_DIR/staging/sqlite-$id.stderr"

    if sqlite3 "$physical_db" '.dump' >"$partial" 2>"$error_file"; then rc=0; else rc=$?; fi
    if (( rc != 0 )) || [[ ! -s $partial ]]; then
        primary_rc=$BB_EXIT_CRITICAL
    elif sqlite3 "$restored" <"$partial" 2>"$error_file.restore"; then
        if integrity=$(sqlite3 "$restored" 'PRAGMA integrity_check;' 2>"$error_file.integrity"); then
            [[ $integrity == "ok" ]] || primary_rc=$BB_EXIT_CRITICAL
        else
            primary_rc=$BB_EXIT_CRITICAL
        fi
    else
        primary_rc=$BB_EXIT_CRITICAL
    fi

    bb_remove_temporary_database_file "$restored" || cleanup_rc=$BB_EXIT_CRITICAL
    if (( primary_rc != 0 || cleanup_rc != 0 )); then
        bb_remove_temporary_database_file "$partial" || true
        return "$BB_EXIT_CRITICAL"
    fi
    mv -fT -- "$partial" "$final"
    size=$(stat -c '%s' -- "$final")
    BB_DUMP_FILES+=("$final")
    bb_log INFO database sqlite-ok "dump SQLite restaurado e íntegro id=$id bytes=$size" || return "$BB_EXIT_CRITICAL"
}

# Executa todos os dumps na ordem declarada e interrompe o fluxo dependente.
# Parâmetros: nenhum; usa somente tipos autorizados já validados.
# Resultado: 0 com BB_DUMP_FILES contendo apenas artefatos finais.
bb_dump_all_databases() {
    local row type
    local -a fields=()
    BB_DUMP_FILES=()
    for row in "${BB_DATABASE_ROWS[@]}"; do
        IFS='|' read -r -a fields <<<"$row"
        type=${fields[0]}
        case $type in
            postgresql)
                bb_dump_postgresql_database "${fields[1]}" "${fields[2]}" "${fields[3]}" "${fields[4]}" "${fields[5]}" || return "$BB_EXIT_CRITICAL"
                ;;
            postgresql-globals)
                bb_dump_postgresql_globals "${fields[1]}" "${fields[2]}" "${fields[3]}" "${fields[4]}" || return "$BB_EXIT_CRITICAL"
                ;;
            sqlite)
                bb_dump_sqlite_database "${fields[1]}" "${fields[2]}" || return "$BB_EXIT_CRITICAL"
                ;;
            *)
                return "$BB_EXIT_CRITICAL"
                ;;
        esac
    done
}
