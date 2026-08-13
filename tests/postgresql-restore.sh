#!/bin/bash
# Finalidade: comprovar restauração PostgreSQL em cluster efêmero e isolado.
# Entradas: binários PostgreSQL locais e dados exclusivamente sintéticos.
# Saídas: protocolo TAP-like com validações de dump, restore e catálogo.
# Efeitos colaterais: cria e remove somente test-runtime/postgresql-restore;
# inicia temporariamente um postmaster sem TCP e com socket dentro do workspace.
# Dependências: Bash, pg_config e utilitários PostgreSQL da mesma instalação.
# Privilégios: usuário comum; initdb recusa root e nenhum sudo é utilizado.
# Códigos: 0 em sucesso ou dependência ausente; 1 diante de falha do teste.
# Sigilo: usa nomes e registros sintéticos, sem credenciais ou bancos reais.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT="$PROJECT_ROOT/test-runtime/postgresql-restore"
PG_STARTED=no
PG_BINDIR=""
PG_DATA=""
PG_SOCKET=""
PG_PORT=55439
PG_USER=$(id -un)
RESTORED_ROWS=""
RESTORED_TABLE=""
LISTEN_ADDRESSES="unset"

# Encerra o cluster, se necessário, e elimina somente a raiz validada do teste.
# Parâmetros: nenhum; usa os caminhos globais confinados ao workspace.
# Resultado: não deixa processo PostgreSQL nem área temporária deste harness.
cleanup_postgresql_restore() {
    if [[ $PG_STARTED == yes && -n $PG_BINDIR && -n $PG_DATA ]]; then
        "$PG_BINDIR/pg_ctl" -D "$PG_DATA" -m immediate -w stop >/dev/null 2>&1 || true
        PG_STARTED=no
    fi
    if [[ -e $ROOT || -L $ROOT ]]; then
        test_reset_root "$ROOT"
        find -P "$ROOT" -depth -delete
    fi
}

# Executa o ciclo completo usando somente socket Unix e duas bases sintéticas.
# Parâmetros: nenhum; os binários já foram validados pelo chamador.
# Resultado: 0 com dump restaurado e catálogo consultado; 1 em qualquer falha.
run_postgresql_restore_cycle() {
    local dump_file="$ROOT/synthetic.dump" table_count socket_setting
    PG_DATA="$ROOT/cluster"
    PG_SOCKET="$ROOT/socket"
    mkdir -p -- "$PG_SOCKET"

    "$PG_BINDIR/initdb" -D "$PG_DATA" --no-locale --encoding=UTF8 \
        --auth-local=trust --auth-host=reject >"$ROOT/initdb.log" 2>&1 || return 1
    "$PG_BINDIR/pg_ctl" -D "$PG_DATA" -w \
        -o "-c listen_addresses='' -c unix_socket_directories=$PG_SOCKET -c port=$PG_PORT" \
        -l "$ROOT/postgresql.log" start >"$ROOT/pg-ctl-start.log" 2>&1 || return 1
    PG_STARTED=yes

    LISTEN_ADDRESSES=$("$PG_BINDIR/psql" -XAt -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d postgres -c "SHOW listen_addresses;") || return 1
    socket_setting=$("$PG_BINDIR/psql" -XAt -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d postgres -c "SHOW unix_socket_directories;") || return 1
    [[ -z $LISTEN_ADDRESSES && $socket_setting == "$PG_SOCKET" ]] || return 1

    "$PG_BINDIR/createdb" -h "$PG_SOCKET" -p "$PG_PORT" -U "$PG_USER" synthetic_source || return 1
    "$PG_BINDIR/psql" -X -v ON_ERROR_STOP=1 -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d synthetic_source >"$ROOT/seed.log" 2>&1 <<'SQL' || return 1
CREATE SCHEMA app;
CREATE TABLE app.items (id integer PRIMARY KEY, label text NOT NULL);
INSERT INTO app.items (id, label) VALUES (1, 'alpha'), (2, 'beta');
SQL
    "$PG_BINDIR/pg_dump" -Fc -h "$PG_SOCKET" -p "$PG_PORT" -U "$PG_USER" \
        -f "$dump_file" synthetic_source || return 1
    [[ -s $dump_file ]] || return 1
    "$PG_BINDIR/pg_restore" --list "$dump_file" >"$ROOT/dump.list" || return 1

    "$PG_BINDIR/createdb" -h "$PG_SOCKET" -p "$PG_PORT" -U "$PG_USER" synthetic_restore || return 1
    "$PG_BINDIR/pg_restore" --exit-on-error --no-owner -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d synthetic_restore "$dump_file" >"$ROOT/restore.log" 2>&1 || return 1
    RESTORED_ROWS=$("$PG_BINDIR/psql" -XAt -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d synthetic_restore -c "SELECT count(*) FROM app.items;") || return 1
    RESTORED_TABLE=$("$PG_BINDIR/psql" -XAt -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d synthetic_restore -c "SELECT to_regclass('app.items');") || return 1
    table_count=$("$PG_BINDIR/psql" -XAt -h "$PG_SOCKET" -p "$PG_PORT" \
        -U "$PG_USER" -d synthetic_restore \
        -c "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname='app';") || return 1
    [[ $RESTORED_ROWS == 2 && $RESTORED_TABLE == app.items && $table_count == 1 ]] || return 1

    "$PG_BINDIR/pg_ctl" -D "$PG_DATA" -m fast -w stop >"$ROOT/pg-ctl-stop.log" 2>&1 || return 1
    PG_STARTED=no
}

trap cleanup_postgresql_restore EXIT

if ! command -v pg_config >/dev/null 2>&1; then
    printf '1..0 # SKIP pg_config ausente; teste PostgreSQL efêmero não executado\n'
    exit 0
fi
PG_BINDIR=$(pg_config --bindir)
for required in initdb pg_ctl createdb psql pg_dump pg_restore; do
    if [[ ! -x $PG_BINDIR/$required ]]; then
        printf '1..0 # SKIP %s ausente; teste PostgreSQL efêmero não executado\n' "$required"
        exit 0
    fi
done

test_reset_root "$ROOT"
test_command_rc 0 "cluster PostgreSQL efêmero restaura dump sintético" run_postgresql_restore_cycle
test_equals "" "$LISTEN_ADDRESSES" "cluster efêmero mantém TCP desabilitado"
test_equals 2 "$RESTORED_ROWS" "restore preserva as linhas sintéticas"
test_equals app.items "$RESTORED_TABLE" "restore recompõe schema e tabela esperados"
cleanup_postgresql_restore
[[ ! -e $ROOT ]] \
    && test_record ok "cluster e temporários PostgreSQL são removidos" \
    || test_record "not ok" "cluster e temporários PostgreSQL são removidos"
test_finish
