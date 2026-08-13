#!/bin/bash
# Finalidade: validar reconciliação segura de temporários sob o lock global.
# Entradas: common.sh staged e árvores exclusivamente sintéticas.
# Saídas: protocolo TAP-like e diagnósticos administrativos sem dados reais.
# Efeitos colaterais: somente subárvores descartáveis em test-runtime/.
# Dependências: Bash, coreutils, findutils e util-linux.
# Privilégios: usuário comum; o modo controlado é recusado para root.
# Códigos: 0 quando todos os contratos passam; 1 em regressão.
# Sigilo: nomes e conteúdos são marcadores sintéticos.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT=""

# Prepara uma instalação sintética independente para um cenário.
# Parâmetros: nome seguro do cenário.
# Resultado: redefine ROOT e cria somente a árvore descartável correspondente.
prepare_case() {
    local case_name=$1
    ROOT="$PROJECT_ROOT/test-runtime/runtime-lifecycle-$case_name"
    test_reset_root "$ROOT"
    test_stage_installation "$ROOT"
    mkdir -p -- "$ROOT/control"
}

# Cria uma área antiga que respeita exatamente o contrato do mktemp operacional.
# Parâmetros: sufixo alfanumérico de seis caracteres.
# Resultado: imprime o caminho do órfão sintético criado.
make_valid_orphan() {
    local suffix=$1 path
    path="$ROOT/var/tmp/borg-backup/20260801T010203Z-test-host-123.$suffix"
    mkdir -m 0700 -- "$path"
    mkdir -m 0700 -- "$path/dumps" "$path/staging"
    printf 'synthetic\n' >"$path/dumps/database.dump"
    printf '%s\n' "$path"
}

# Executa a função real em subshell, com lock opcional para o caso negativo.
# Parâmetros: raiz sintética e `yes`/`no` para aquisição do lock.
# Resultado: propaga a reconciliação e registra evidências não sensíveis.
run_reconciliation() {
    local root=$1 acquire_lock=${2:-yes}
    (
        BB_BOOTSTRAP_TEST_MODE=yes
        BB_BOOTSTRAP_TEST_ROOT=$root
        source "$root/usr/local/lib/borg-backup/common.sh"
        bb_initialize_paths
        if [[ $acquire_lock == "yes" ]]; then
            if ! bb_acquire_global_lock; then
                exit "$BB_EXIT_CRITICAL"
            fi
        fi
        bb_create_execution_dir "20260812T120000Z-test-host-$$"
        printf 'synthetic-current\n' >"$BB_EXECUTION_DIR/staging/current.marker"
        printf '%s\n' "$BB_EXECUTION_DIR" >"$root/control/current-path"
        local rc
        if bb_reconcile_orphaned_execution_dirs; then rc=0; else rc=$?; fi
        printf '%s\n' "$BB_ORPHANED_EXECUTION_DIRS_REMOVED" >"$root/control/removed-count"
        if [[ -f $BB_EXECUTION_DIR/staging/current.marker ]]; then
            printf 'yes\n' >"$root/control/current-preserved"
        else
            printf 'no\n' >"$root/control/current-preserved"
        fi
        bb_release_global_lock
        exit "$rc"
    )
}

# Registra se um alvo sintético continua presente sem seguir symlinks.
# Parâmetros: path e descrição do assert.
# Resultado: acrescenta um resultado à suíte.
assert_exists() {
    local path=$1 description=$2
    [[ -e $path || -L $path ]] && test_record ok "$description" || test_record "not ok" "$description"
}

prepare_case empty
test_command_rc 0 "raiz sem órfãos é aceita sob lock" run_reconciliation "$ROOT"
test_equals 0 "$(<"$ROOT/control/removed-count")" "raiz sem órfãos remove zero áreas"
test_equals yes "$(<"$ROOT/control/current-preserved")" "execução corrente é preservada"

prepare_case valid
orphan_a=$(make_valid_orphan AAAAAA)
orphan_b=$(make_valid_orphan BBBBBB)
test_command_rc 0 "órfãos válidos são reconciliados sob lock" run_reconciliation "$ROOT"
test_equals 2 "$(<"$ROOT/control/removed-count")" "todos os órfãos válidos são contabilizados"
[[ ! -e $orphan_a && ! -e $orphan_b ]] \
    && test_record ok "árvores órfãs validadas são removidas" \
    || test_record "not ok" "árvores órfãs validadas são removidas"
test_equals yes "$(<"$ROOT/control/current-preserved")" "corrente não é confundida com órfão"

prepare_case no-lock
orphan=$(make_valid_orphan CCCCCC)
test_command_rc 2 "reconciliação sem lock é recusada" run_reconciliation "$ROOT" no
assert_exists "$orphan" "órfão permanece quando o lock não foi adquirido"

prepare_case competing-lock
orphan=$(make_valid_orphan DDDDDD)
"$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 10 &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e $ROOT/lock-ready ]] && break
    sleep 0.1
done
test_command_rc 2 "lock concorrente impede a reconciliação" run_reconciliation "$ROOT"
assert_exists "$orphan" "órfão permanece enquanto outra operação mantém o lock"
kill -TERM "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

prepare_case invalid-name
valid=$(make_valid_orphan EEEEEE)
mkdir -m 0700 -- "$ROOT/var/tmp/borg-backup/unexpected-name"
test_command_rc 2 "nome inesperado recusa toda a reconciliação" run_reconciliation "$ROOT"
assert_exists "$valid" "falha de nome não remove órfão válido"

prepare_case invalid-type
valid=$(make_valid_orphan FFFFFF)
printf 'synthetic\n' >"$ROOT/var/tmp/borg-backup/20260801T010203Z-test-host-123.GGGGGG"
test_command_rc 2 "tipo que não é diretório recusa toda a reconciliação" run_reconciliation "$ROOT"
assert_exists "$valid" "falha de tipo não remove órfão válido"

prepare_case invalid-symlink
valid=$(make_valid_orphan HHHHHH)
mkdir -m 0700 -- "$ROOT/outside-target"
printf 'keep\n' >"$ROOT/outside-target/sentinel"
ln -s -- "$ROOT/outside-target" \
    "$ROOT/var/tmp/borg-backup/20260801T010203Z-test-host-123.IIIIII"
test_command_rc 2 "symlink com nome plausível é recusado" run_reconciliation "$ROOT"
assert_exists "$valid" "falha de symlink não remove órfão válido"
assert_exists "$ROOT/outside-target/sentinel" "alvo externo do symlink permanece intacto"

prepare_case invalid-mode
valid=$(make_valid_orphan JJJJJJ)
invalid_mode=$(make_valid_orphan KKKKKK)
chmod 0750 -- "$invalid_mode"
test_command_rc 2 "modo inesperado recusa toda a reconciliação" run_reconciliation "$ROOT"
assert_exists "$valid" "falha de metadados não remove órfão válido"
assert_exists "$invalid_mode" "diretório com modo inesperado não é removido"

prepare_case invalid-group
valid=$(make_valid_orphan LLLLLL)
users_group_available="no"
for candidate_group in $(id -Gn); do
    if [[ $candidate_group == "users" ]]; then
        users_group_available="yes"
        break
    fi
done
if [[ $users_group_available == "yes" ]]; then
    chgrp -- users "$valid"
    test_command_rc 2 "grupo inesperado recusa toda a reconciliação" run_reconciliation "$ROOT"
    assert_exists "$valid" "órfão com grupo inesperado é preservado"
else
    test_record ok "grupo users inesperado não testado: SKIP executor não pertence a users"
    test_record ok "preservação por grupo não testada: SKIP executor não pertence a users"
fi

prepare_case removal-failure
unremovable=$(make_valid_orphan MMMMMM)
blocked="$unremovable/dumps/blocked"
secret_marker="SYNTHETIC_SECRET_CONTENT_MUST_NOT_APPEAR"
mkdir -m 0700 -- "$blocked"
printf '%s\n' "$secret_marker" >"$blocked/protected.dump"
chmod 0000 -- "$blocked"
if run_reconciliation "$ROOT" \
    >"$ROOT/control/reconciliation.stdout" \
    2>"$ROOT/control/reconciliation.stderr"; then
    removal_rc=0
else
    removal_rc=$?
fi
test_equals 2 "$removal_rc" "falha real de remoção retorna código crítico"
assert_exists "$unremovable" "área não removível permanece para diagnóstico"
test_equals yes "$(<"$ROOT/control/current-preserved")" "falha de remoção preserva a execução corrente"
[[ -s $ROOT/control/reconciliation.stderr ]] \
    && test_record ok "falha real de remoção produz diagnóstico administrativo" \
    || test_record "not ok" "falha real de remoção produz diagnóstico administrativo"
if ! grep -Fq -- "$secret_marker" \
    "$ROOT/control/reconciliation.stdout" "$ROOT/control/reconciliation.stderr"; then
    test_record ok "diagnósticos não expõem conteúdo do dump órfão"
else
    test_record "not ok" "diagnósticos não expõem conteúdo do dump órfão"
fi
chmod 0700 -- "$blocked"
assert_exists "$blocked/protected.dump" "conteúdo inacessível é preservado após falha de remoção"

prepare_case precheck-failure
test_write_valid_configuration "$ROOT"
printf 'UNKNOWN_KEY=synthetic\n' >>"$ROOT/etc/borg-backup/backup.conf"
precheck_orphan=$(make_valid_orphan NNNNNN)
if test_run_entrypoint "$ROOT" run \
    >"$ROOT/control/precheck.stdout" \
    2>"$ROOT/control/precheck.stderr"; then
    precheck_rc=0
else
    precheck_rc=$?
fi
test_equals 2 "$precheck_rc" "configuração inválida ainda falha após a reconciliação"
[[ ! -e $precheck_orphan ]] \
    && test_record ok "órfão é removido antes da validação de configuração" \
    || test_record "not ok" "órfão é removido antes da validação de configuração"
grep -Fq 'borg-backup: áreas temporárias órfãs removidas quantidade=1' \
    "$ROOT/control/precheck.stderr" \
    && test_record ok "remoção anterior ao logger permanece observável em stderr" \
    || test_record "not ok" "remoção anterior ao logger permanece observável em stderr"
[[ ! -f $ROOT/control/borg.commands ]] \
    && test_record ok "falha de configuração posterior não alcança Borg" \
    || test_record "not ok" "falha de configuração posterior não alcança Borg"

prepare_case logged-removal
test_write_valid_configuration "$ROOT"
logged_orphan=$(make_valid_orphan OOOOOO)
if test_run_entrypoint "$ROOT" run \
    >"$ROOT/control/run.stdout" \
    2>"$ROOT/control/run.stderr"; then
    logged_run_rc=0
else
    logged_run_rc=$?
fi
test_equals 0 "$logged_run_rc" "ciclo prossegue após reconciliar órfão válido"
[[ ! -e $logged_orphan ]] \
    && test_record ok "órfão é removido antes do preparo completo" \
    || test_record "not ok" "órfão é removido antes do preparo completo"
grep -Fq 'borg-backup: áreas temporárias órfãs removidas quantidade=1' "$ROOT/control/run.stderr" \
    && test_record ok "quantidade removida é registrada imediatamente em stderr" \
    || test_record "not ok" "quantidade removida é registrada imediatamente em stderr"
grep -Fq ' execution cleanup áreas temporárias órfãs removidas quantidade=1' \
    "$ROOT/var/log/borg-backup/backup.log" \
    && test_record ok "quantidade removida é registrada pelo logger persistente" \
    || test_record "not ok" "quantidade removida é registrada pelo logger persistente"

prepare_case before-stop
test_write_valid_configuration "$ROOT"
test_configure_sqlite "$ROOT" active
mkdir -m 0700 -- "$ROOT/var/tmp/borg-backup/unexpected-name"
test_command_rc 2 "falha de reconciliação bloqueia o ciclo diário" test_run_entrypoint "$ROOT" run
if [[ ! -f $ROOT/control/systemctl.commands ]] \
    || ! grep -Eq '^(stop|start) ' "$ROOT/control/systemctl.commands"; then
    test_record ok "reconciliação ocorre antes de parar recursos"
else
    test_record "not ok" "reconciliação ocorre antes de parar recursos"
fi
if [[ ! -f $ROOT/control/borg.commands ]]; then
    test_record ok "reconciliação recusada antecede validações Borg"
else
    test_record "not ok" "reconciliação recusada antecede validações Borg"
fi
assert_exists "$ROOT/var/tmp/borg-backup/unexpected-name" "entrada recusada permanece para diagnóstico seguro"

test_finish
