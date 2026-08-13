#!/bin/bash
# Finalidade: comprovar dump e restauração SQLite em arquivos sintéticos.
# Entradas: cliente sqlite3, quando já disponível no ambiente controlado.
# Saídas: protocolo TAP-like ou SKIP explícito por dependência ausente.
# Efeitos colaterais: cria e remove somente test-runtime/sqlite-restore.
# Dependências: Bash e sqlite3; nenhum pacote é instalado por este teste.
# Privilégios: usuário comum; não acessa serviços nem bancos operacionais.
# Códigos: 0 em sucesso ou dependência ausente; 1 diante de falha do teste.
# Sigilo: banco, schema e registros são integralmente sintéticos.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT="$PROJECT_ROOT/test-runtime/sqlite-restore"
RESTORED_ROWS=""
INTEGRITY_RESULT=""

# Elimina somente a raiz descartável previamente confinada ao workspace.
# Parâmetros: nenhum.
# Resultado: nenhum banco sintético permanece depois do teste.
cleanup_sqlite_restore() {
    if [[ -e $ROOT || -L $ROOT ]]; then
        test_reset_root "$ROOT"
        find -P "$ROOT" -depth -delete
    fi
}

# Gera dump textual, restaura em outro arquivo e valida integridade e conteúdo.
# Parâmetros: nenhum; usa apenas caminhos sintéticos sob ROOT.
# Resultado: 0 quando o banco restaurado é íntegro e contém duas linhas.
run_sqlite_restore_cycle() {
    local source_db="$ROOT/source.sqlite3" dump_file="$ROOT/source.sql"
    local restored_db="$ROOT/restored.sqlite3"
    sqlite3 "$source_db" \
        "CREATE TABLE items(id INTEGER PRIMARY KEY, label TEXT NOT NULL); INSERT INTO items VALUES(1,'alpha'),(2,'beta');" || return 1
    sqlite3 "$source_db" .dump >"$dump_file" || return 1
    [[ -s $dump_file ]] || return 1
    sqlite3 "$restored_db" <"$dump_file" || return 1
    RESTORED_ROWS=$(sqlite3 "$restored_db" 'SELECT count(*) FROM items;') || return 1
    INTEGRITY_RESULT=$(sqlite3 "$restored_db" 'PRAGMA integrity_check;') || return 1
    [[ $RESTORED_ROWS == 2 && $INTEGRITY_RESULT == ok ]] || return 1
}

trap cleanup_sqlite_restore EXIT

if ! command -v sqlite3 >/dev/null 2>&1; then
    printf '1..0 # SKIP sqlite3 ausente; teste SQLite real não executado\n'
    exit 0
fi

test_reset_root "$ROOT"
test_command_rc 0 "SQLite sintético é despejado e restaurado" run_sqlite_restore_cycle
test_equals 2 "$RESTORED_ROWS" "restore SQLite preserva as linhas sintéticas"
test_equals ok "$INTEGRITY_RESULT" "restore SQLite passa por PRAGMA integrity_check"
cleanup_sqlite_restore
[[ ! -e $ROOT ]] \
    && test_record ok "temporários SQLite são removidos" \
    || test_record "not ok" "temporários SQLite são removidos"
test_finish
