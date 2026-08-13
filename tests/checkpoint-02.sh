#!/bin/bash
# Finalidade: comprovar consistência local, dumps, Borg, manutenção e gates CP2.
# Entradas: código em src/, fixtures sintéticas e um Borg descartável opcional.
# Saídas: protocolo TAP-like e árvores descartáveis sob test-runtime.
# Efeitos colaterais: somente repositórios/dados sintéticos dentro do workspace.
# Dependências: Bash e coreutils/timeout; Borg 1.4 real apenas no caso de
# integração descartável.
# Privilégios: usuário comum, sem sudo, systemctl real ou rede.
# Códigos: 0 quando todos os casos passam; 1 em regressão.
# Sigilo: usa exclusivamente passphrase sintética que não é impressa.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT="$PROJECT_ROOT/test-runtime/checkpoint-02"

# Prepara um caso isolado com a configuração mínima válida.
# Parâmetros: sufixo do caso.
# Resultado: redefine ROOT para a nova instalação sintética.
prepare_case() {
    local case_name=$1
    ROOT="$PROJECT_ROOT/test-runtime/checkpoint-02-$case_name"
    test_reset_root "$ROOT"
    test_stage_installation "$ROOT"
    test_write_valid_configuration "$ROOT"
    mkdir -p -- "$ROOT/control"
}

# Compara a sequência de nomes registrada pelo double Borg.
# Parâmetros: sequência esperada separada por espaços e descrição.
# Resultado: registra assert literal.
assert_borg_order() {
    local expected=$1 description=$2 actual=""
    if [[ -f $ROOT/control/borg.commands ]]; then
        actual=$(tr '\n' ' ' <"$ROOT/control/borg.commands")
        actual=${actual% }
    fi
    test_equals "$expected" "$actual" "$description"
}

# Confirma que a área temporária da rotina ficou vazia após a operação.
# Parâmetros: descrição.
# Resultado: registra sucesso quando nenhum filho permanece.
assert_no_execution_temporary() {
    local description=$1
    if ! find "$ROOT/var/tmp/borg-backup" -mindepth 1 -print -quit | grep -q .; then
        test_record ok "$description"
    else
        test_record "not ok" "$description"
    fi
}

prepare_case basic-success
test_command_rc 0 "run sintético local conclui" test_run_entrypoint "$ROOT" run
assert_borg_order "info create info prune compact" "gate create-info-prune-compact mantém ordem"
test_equals OK "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" BACKUP)" "relatório marca backup principal OK"
test_equals OK "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" MAINTENANCE)" "relatório marca manutenção OK"
test_equals DISABLED "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" REPLICATION_SUMMARY)" "replicação desabilitada permanece separada"
[[ -s $ROOT/var/lib/borg-backup/state/last-success.state ]] && test_record ok "estado mínimo da última geração é persistido" || test_record "not ok" "estado mínimo da última geração é persistido"
assert_no_execution_temporary "temporários são limpos após sucesso"
grep -q ' execution cleanup temporários da execução removidos$' "$ROOT/var/log/borg-backup/backup.log" \
    && test_record ok "limpeza normal é observável" \
    || test_record "not ok" "limpeza normal é observável"

prepare_case create-warning
cat >"$ROOT/var/lib/borg-backup/state/last-success.state" <<'EOF'
EXECUTION_ID=prior-synthetic
ARCHIVE=prior-valid
RESULT=OK
TIMESTAMP_UTC=2026-08-01T00:00:00Z
EOF
chmod 0640 -- "$ROOT/var/lib/borg-backup/state/last-success.state"
printf '1\n' >"$ROOT/control/borg-create.rc"
test_command_rc 2 "Borg create rc=1 não é aceito como válido" test_run_entrypoint "$ROOT" run
assert_borg_order "info create" "rc=1 bloqueia info, prune e compact"
test_equals prior-valid "$(awk -F= '$1=="ARCHIVE" {print $2}' "$ROOT/var/lib/borg-backup/state/last-success.state")" "última geração válida anterior é preservada"
test_equals FAILED_CREATE "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" BACKUP)" "relatório distingue falha de create"
assert_no_execution_temporary "temporários são limpos após warning Borg"

prepare_case archive-info-failure
printf '2\n' >"$ROOT/control/borg-info-archive.rc"
test_command_rc 2 "archive sem borg info válido é recusado" test_run_entrypoint "$ROOT" run
assert_borg_order "info create info" "falha de confirmação bloqueia manutenção"

prepare_case prune-failure
printf '2\n' >"$ROOT/control/borg-prune.rc"
test_command_rc 2 "falha de prune é crítica após backup válido" test_run_entrypoint "$ROOT" run
assert_borg_order "info create info prune" "falha de prune bloqueia compact"
test_equals OK "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" BACKUP)" "backup permanece OK apesar da manutenção falha"
test_equals FAILED "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" MAINTENANCE)" "manutenção falha permanece separada"
[[ -s $ROOT/var/lib/borg-backup/state/last-success.state ]] && test_record ok "archive válido é preservado após prune falhar" || test_record "not ok" "archive válido é preservado após prune falhar"

prepare_case compact-failure
printf '2\n' >"$ROOT/control/borg-compact.rc"
test_command_rc 2 "falha de compact bloqueia fluxo dependente" test_run_entrypoint "$ROOT" run
assert_borg_order "info create info prune compact" "compact só ocorre depois de prune válido"

prepare_case post-capacity-warning
printf '8\n' >"$ROOT/control/df-post-local-mib"
test_command_rc 1 "queda de capacidade após backup válido produz warning" test_run_entrypoint "$ROOT" run
test_equals OK "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" BACKUP)" "warning de capacidade preserva BACKUP=OK"
test_equals WARNING "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" CAPACITY)" "capacidade pós-operação possui estado separado"
test_equals WARNING "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" EXECUTION)" "warning de capacidade produz EXECUTION=WARNING"
[[ -s $ROOT/var/lib/borg-backup/state/last-success.state ]] && test_record ok "backup válido abaixo do piso atualiza last-success" || test_record "not ok" "backup válido abaixo do piso atualiza last-success"
borg_count_before=$(grep -c '^create$' "$ROOT/control/borg.commands")
test_command_rc 2 "execução seguinte é bloqueada enquanto capacidade permanece baixa" test_run_entrypoint "$ROOT" run
borg_count_after=$(grep -c '^create$' "$ROOT/control/borg.commands")
test_equals "$borg_count_before" "$borg_count_after" "precheck baixo bloqueia novo borg create"

prepare_case postgresql-success
test_configure_postgresql "$ROOT"
test_command_rc 0 "dumps PostgreSQL e globais válidos integram o run" test_run_entrypoint "$ROOT" run
test_equals "pg_dump pg_restore-list pg_dumpall" "$(tr '\n' ' ' <"$ROOT/control/database.commands" | sed 's/ $//')" "PostgreSQL custom é validado antes dos globais"
database_user=$(id -un)
test_equals "$database_user pg_dump $database_user pg_dumpall" "$(tr '\n' ' ' <"$ROOT/control/database-users.commands" | sed 's/ $//')" "clientes PostgreSQL usam identidade local explícita para peer"
assert_borg_order "info create info prune compact" "Borg só inicia depois dos dumps PostgreSQL"

prepare_case postgresql-failure
test_configure_postgresql "$ROOT"
printf 'fail\n' >"$ROOT/control/pg-dump-fail"
test_command_rc 2 "falha de pg_dump impede archive" test_run_entrypoint "$ROOT" run
assert_borg_order "info" "falha de dump impede borg create e manutenção"
assert_no_execution_temporary "parciais PostgreSQL são removidos após falha"

prepare_case postgresql-validation-failure
test_configure_postgresql "$ROOT"
printf 'fail\n' >"$ROOT/control/pg-restore-fail"
test_command_rc 2 "falha de pg_restore --list invalida o dump" test_run_entrypoint "$ROOT" run
assert_borg_order "info" "dump PostgreSQL ilegível bloqueia borg create"

prepare_case sqlite-success
test_configure_sqlite "$ROOT" active
printf 'sqlite-app.service\n' >"$ROOT/control/expect-services-inactive"
test_command_rc 0 "SQLite é despejado com unit controlada" test_run_entrypoint "$ROOT" run
test_equals active "$(<"$ROOT/control/services/sqlite-app.service.state")" "unit SQLite retorna ao estado ativo"
test_equals "sqlite-dump sqlite-restore sqlite-integrity" "$(tr '\n' ' ' <"$ROOT/control/database.commands" | sed 's/ $//')" "dump SQLite é restaurado e verificado"
if grep -q '^stop sqlite-app.service$' "$ROOT/control/systemctl.commands" && grep -q '^start sqlite-app.service$' "$ROOT/control/systemctl.commands"; then
    test_record ok "unit SQLite é parada e retomada explicitamente"
else
    test_record "not ok" "unit SQLite é parada e retomada explicitamente"
fi
grep -q ' service restored unidade=sqlite-app.service retornou ao estado ativo$' "$ROOT/var/log/borg-backup/backup.log" \
    && test_record ok "log identifica a unit restaurada" \
    || test_record "not ok" "log identifica a unit restaurada"
stop_line=$(grep -n '^systemctl stop sqlite-app.service$' "$ROOT/control/timeline" | cut -d: -f1)
create_line=$(grep -n '^borg create$' "$ROOT/control/timeline" | cut -d: -f1)
archive_info_line=$(grep -n '^borg info$' "$ROOT/control/timeline" | tail -n 1 | cut -d: -f1)
start_line=$(grep -n '^systemctl start sqlite-app.service$' "$ROOT/control/timeline" | cut -d: -f1)
if (( stop_line < create_line && create_line < archive_info_line && archive_info_line < start_line )); then
    test_record ok "unit permanece parada até borg info confirmar o archive"
else
    test_record "not ok" "unit permanece parada até borg info confirmar o archive"
fi

prepare_case sqlite-failure
test_configure_sqlite "$ROOT" active
printf 'fail\n' >"$ROOT/control/sqlite-dump-fail"
test_command_rc 2 "falha de SQLite impede archive" test_run_entrypoint "$ROOT" run
test_equals active "$(<"$ROOT/control/services/sqlite-app.service.state")" "unit SQLite é restaurada após erro"
assert_borg_order "info" "falha SQLite bloqueia borg create"

prepare_case sqlite-post-stop-validation-failure
test_configure_sqlite "$ROOT" active
printf 'fail\n' >"$ROOT/control/systemctl-is-active-fail-when-inactive"
test_command_rc 2 "falha ao validar parada mantém restauração armada" test_run_entrypoint "$ROOT" run
test_equals active "$(<"$ROOT/control/services/sqlite-app.service.state")" "unit retorna ao estado inicial após consulta pós-parada falhar"
assert_borg_order "info" "falha pós-parada bloqueia borg create"

prepare_case sqlite-integrity-failure
test_configure_sqlite "$ROOT" active
printf 'fail\n' >"$ROOT/control/sqlite-integrity-fail"
test_command_rc 2 "integrity_check divergente invalida dump SQLite" test_run_entrypoint "$ROOT" run
test_equals active "$(<"$ROOT/control/services/sqlite-app.service.state")" "unit é restaurada após integridade SQLite falhar"
assert_borg_order "info" "SQLite não íntegro bloqueia borg create"

prepare_case sqlite-service-restore-failure
test_configure_sqlite "$ROOT" active
printf 'fail\n' >"$ROOT/control/systemctl-start-fail"
test_command_rc 2 "falha ao retomar unit invalida o ciclo" test_run_entrypoint "$ROOT" run
test_equals FAILED_RESTORE "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" BACKUP)" "erro primário e restauração permanecem distinguíveis"
test_equals FAILED "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" RESTORE)" "falha de restauração possui campo próprio"
assert_borg_order "info create info" "retomada ocorre somente após confirmação do archive"

prepare_case sqlite-inactive
test_configure_sqlite "$ROOT" inactive
test_command_rc 0 "SQLite respeita unit inicialmente inativa" test_run_entrypoint "$ROOT" run
test_equals inactive "$(<"$ROOT/control/services/sqlite-app.service.state")" "unit inicialmente inativa não é iniciada"
if ! grep -Eq '^(stop|start) sqlite-app.service$' "$ROOT/control/systemctl.commands"; then
    test_record ok "nenhuma transição ocorre para unit inicialmente inativa"
else
    test_record "not ok" "nenhuma transição ocorre para unit inicialmente inativa"
fi

prepare_case multiple-services
cat >"$ROOT/etc/borg-backup/services.conf" <<'EOF'
# Primeira unit sintética inicialmente ativa.
apache2.service
# Segunda unit sintética inicialmente inativa.
app-secondary.service
EOF
mkdir -p -- "$ROOT/control/services"
printf 'active\n' >"$ROOT/control/services/apache2.service.state"
printf 'inactive\n' >"$ROOT/control/services/app-secondary.service.state"
printf 'apache2.service\napp-secondary.service\n' >"$ROOT/control/expect-services-inactive"
chmod 0640 -- "$ROOT/etc/borg-backup/services.conf"
test_command_rc 0 "múltiplas units compartilham uma única janela crítica" test_run_entrypoint "$ROOT" run
test_equals active "$(<"$ROOT/control/services/apache2.service.state")" "unit ativa retorna ao estado ativo"
test_equals inactive "$(<"$ROOT/control/services/app-secondary.service.state")" "unit inativa permanece inativa"
if grep -q '^stop apache2.service$' "$ROOT/control/systemctl.commands" \
    && grep -q '^start apache2.service$' "$ROOT/control/systemctl.commands" \
    && ! grep -Eq '^(stop|start) app-secondary.service$' "$ROOT/control/systemctl.commands"; then
    test_record ok "somente units originalmente ativas sofrem transição"
else
    test_record "not ok" "somente units originalmente ativas sofrem transição"
fi

prepare_case applications-success
test_configure_applications "$ROOT" "$(id -un)"
test_command_rc 0 "Nextcloud e BIND técnicos concluem sem parar rede" test_run_entrypoint "$ROOT" run
test_equals disabled "$(<"$ROOT/control/nextcloud.state")" "Nextcloud retorna ao estado inicial"
if grep -q '^bind sync$' "$ROOT/control/application.commands" && [[ ! -e $ROOT/control/systemctl.commands ]]; then
    test_record ok "BIND sincroniza online sem systemctl"
else
    test_record "not ok" "BIND sincroniza online sem systemctl"
fi
if grep -q ' application maintenance-on id=cloud-app ' "$ROOT/var/log/borg-backup/backup.log" \
    && grep -q ' application bind-sync id=bind-app ' "$ROOT/var/log/borg-backup/backup.log"; then
    test_record ok "logs identificam os adaptadores declarados"
else
    test_record "not ok" "logs identificam os adaptadores declarados"
fi

prepare_case application-restore-failure-path
test_configure_applications "$ROOT" "$(id -un)"
printf '2\n' >"$ROOT/control/borg-create.rc"
test_command_rc 2 "falha Borg restaura manutenção Nextcloud" test_run_entrypoint "$ROOT" run
test_equals disabled "$(<"$ROOT/control/nextcloud.state")" "Nextcloud é restaurado na falha crítica"
assert_borg_order "info create" "falha de create não executa manutenção"

prepare_case application-post-enable-validation-failure
test_configure_applications "$ROOT" "$(id -un)"
printf 'fail\n' >"$ROOT/control/nextcloud-status-fail-when-enabled"
test_command_rc 2 "falha ao validar manutenção mantém restauração armada" test_run_entrypoint "$ROOT" run
test_equals disabled "$(<"$ROOT/control/nextcloud.state")" "Nextcloud retorna ao estado inicial após consulta pós-alteração falhar"
assert_borg_order "info" "falha pós-alteração bloqueia borg create"

prepare_case bind-failure
test_configure_applications "$ROOT" "$(id -un)"
printf 'fail\n' >"$ROOT/control/rndc-fail"
test_command_rc 2 "falha de rndc sync bloqueia archive" test_run_entrypoint "$ROOT" run
test_equals disabled "$(<"$ROOT/control/nextcloud.state")" "Nextcloud é restaurado quando BIND falha"
assert_borg_order "info" "falha BIND ocorre antes de borg create"

prepare_case nextcloud-restore-failure
test_configure_applications "$ROOT" "$(id -un)"
printf 'fail\n' >"$ROOT/control/nextcloud-off-fail"
test_command_rc 2 "falha ao sair da manutenção invalida o ciclo" test_run_entrypoint "$ROOT" run
test_equals FAILED_RESTORE "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" BACKUP)" "falha de restauração Nextcloud é explícita"
assert_borg_order "info create info" "falha de restauração bloqueia prune"

prepare_case application-initially-enabled
test_configure_applications "$ROOT" "$(id -un)"
printf 'enabled\n' >"$ROOT/control/nextcloud.state"
test_command_rc 0 "Nextcloud inicialmente em manutenção é preservado" test_run_entrypoint "$ROOT" run
test_equals enabled "$(<"$ROOT/control/nextcloud.state")" "estado inicial enabled permanece enabled"
if ! grep -Eq '^nextcloud (--on|--off)$' "$ROOT/control/application.commands"; then
    test_record ok "adaptador não alterna manutenção já habilitada"
else
    test_record "not ok" "adaptador não alterna manutenção já habilitada"
fi

prepare_case admin-commands
test_command_rc 0 "list respeita configuração e lock" test_run_entrypoint "$ROOT" list
test_command_rc 0 "check explícito conclui" test_run_entrypoint "$ROOT" check
test_command_rc 0 "prune administrativo inclui compact" test_run_entrypoint "$ROOT" prune
assert_borg_order "info list info check info prune compact" "operações administrativas delegam ao Borg nativo"

prepare_case command-lock
"$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 2 &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e $ROOT/lock-ready ]] && break
    sleep 0.1
done
test_command_rc 2 "check recusa concorrência" test_run_entrypoint "$ROOT" check
test_command_rc 2 "prune recusa concorrência" test_run_entrypoint "$ROOT" prune
test_command_rc 2 "validate recusa diagnóstico concorrente" test_run_entrypoint "$ROOT" validate
wait "$holder_pid"

for signal_name in HUP INT TERM; do
    prepare_case "signal-${signal_name,,}"
    test_configure_sqlite "$ROOT" active
    printf '10\n' >"$ROOT/control/sqlite-dump-delay"
    # `timeout` mantém o comando testado em primeiro plano. Isso é essencial
    # para SIGINT: shells não interativos podem iniciar jobs assíncronos com
    # SIGINT ignorado, o que testaria a semântica do shell pai em vez do trap
    # instalado pelo ponto de entrada. `--preserve-status` expõe o rc=2 real.
    signal_rc=0
    timeout --preserve-status --kill-after=3s --signal="$signal_name" 2s \
        env -i \
            HOME="$HOME" \
            BORG_BACKUP_TEST_MODE=yes \
            BORG_BACKUP_TEST_ROOT="$ROOT" \
            BORG_BACKUP_TEST_BIN="$ROOT/test-bin" \
            "$ROOT/usr/local/sbin/borg-backup" run \
            >"$ROOT/control/signal.stdout" 2>"$ROOT/control/signal.stderr" \
        || signal_rc=$?
    test_equals 2 "$signal_rc" "sinal $signal_name é convertido em falha crítica"
    test_equals active "$(<"$ROOT/control/services/sqlite-app.service.state")" "trap restaura unit após $signal_name"
    assert_no_execution_temporary "trap remove temporários após $signal_name"
done

# O caso final usa Borg real somente em repositório descartável dentro do
# workspace; caches e security dir também permanecem na raiz controlada. A
# ausência ou versão incompatível pula apenas esta integração; o gate de release
# pode torná-la obrigatória sem alterar o contrato normal da suíte.
real_borg=""
real_borg_version=""
if [[ ${BORG_BACKUP_TEST_FORCE_NO_REAL_BORG:-no} != yes ]] \
    && real_borg=$(command -v borg 2>/dev/null) \
    && real_borg_version=$("$real_borg" --version 2>/dev/null) \
    && [[ $real_borg_version =~ ^borg[[:space:]]1\.4\.[0-9]+$ ]]; then
prepare_case real-borg
find -P "$ROOT/test-bin/borg" -delete
mkdir -p -- "$ROOT/data" "$ROOT/var/cache/borg" \
    "$ROOT/var/lib/borg-backup/borg-security" "$ROOT/var/lib/borg-backup/borg-keys"
printf 'conteudo sintetico\n' >"$ROOT/data/file.txt"
# Combina os dois tipos normativos para que seus dumps sejam extraídos e
# validados a partir do archive real, sem acessar SGBD externo.
test_configure_sqlite "$ROOT" active
mkdir -p -- "$ROOT/var/run/postgresql"
database_user=$(id -un)
cat >>"$ROOT/etc/borg-backup/databases.conf" <<EOF
# Banco PostgreSQL local sintético incluído no teste de restauração.
postgresql|pg-app|appdb|$database_user|/var/run/postgresql|5432
# Objetos globais sintéticos incluídos no mesmo archive.
postgresql-globals|pg-cluster|$database_user|/var/run/postgresql|5432
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/databases.conf"
cat >"$ROOT/etc/borg-backup/sources.conf" <<'EOF'
# Fonte mínima para integração Borg real.
/data
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/sources.conf"
env -i PATH="$PATH" LC_ALL=C LANG=C \
    BORG_PASSPHRASE=test-only-synthetic-passphrase \
    BORG_CACHE_DIR="$ROOT/var/cache/borg" \
    BORG_SECURITY_DIR="$ROOT/var/lib/borg-backup/borg-security" \
    BORG_KEYS_DIR="$ROOT/var/lib/borg-backup/borg-keys" \
    "$real_borg" init --encryption=repokey-blake2 "$ROOT/srv/borg-storage/repositories/lab/repo"
test_command_rc 0 "Borg 1.4 real cria, confirma, retém e compacta archive descartável" \
    test_run_entrypoint "$ROOT" run
real_archive_count=$(env -i PATH="$PATH" LC_ALL=C LANG=C \
    BORG_PASSPHRASE=test-only-synthetic-passphrase \
    BORG_CACHE_DIR="$ROOT/var/cache/borg" \
    BORG_SECURITY_DIR="$ROOT/var/lib/borg-backup/borg-security" \
    BORG_KEYS_DIR="$ROOT/var/lib/borg-backup/borg-keys" \
    "$real_borg" list --format '{archive}{NL}' "$ROOT/srv/borg-storage/repositories/lab/repo" | wc -l)
test_equals 1 "$real_archive_count" "repositório descartável contém um archive válido"

real_archive=$(awk -F= '$1=="ARCHIVE" {print $2}' "$ROOT/var/lib/borg-backup/state/last-success.state")
mkdir -p -- "$ROOT/restore-primary"
(
    cd "$ROOT/restore-primary"
    env -i PATH="$PATH" LC_ALL=C LANG=C \
        BORG_PASSPHRASE=test-only-synthetic-passphrase \
        BORG_CACHE_DIR="$ROOT/var/cache/borg" \
        BORG_SECURITY_DIR="$ROOT/var/lib/borg-backup/borg-security" \
        BORG_KEYS_DIR="$ROOT/var/lib/borg-backup/borg-keys" \
        "$real_borg" extract "$ROOT/srv/borg-storage/repositories/lab/repo::$real_archive"
)
restored_prefix="$ROOT/restore-primary/${ROOT#/}"
cmp "$ROOT/data/file.txt" "$restored_prefix/data/file.txt" \
    && test_record ok "arquivo é restaurado do repositório principal" \
    || test_record "not ok" "arquivo é restaurado do repositório principal"
restored_pg=$(find "$restored_prefix/var/tmp/borg-backup" -type f -name 'postgresql-pg-app.dump' -print -quit)
test_command_rc 0 "dump PostgreSQL extraído continua legível" \
    env BB_BOOTSTRAP_TEST_ROOT="$ROOT" "$ROOT/test-bin/pg_restore" --list "$restored_pg"
restored_sqlite=$(find "$restored_prefix/var/tmp/borg-backup" -type f -name 'sqlite-sqlite-app.sql' -print -quit)
restored_sqlite_db="$ROOT/restore-primary/sqlite-restored.sqlite3"
test_command_rc 0 "dump SQLite extraído recria banco controlado" \
    env BB_BOOTSTRAP_TEST_ROOT="$ROOT" "$ROOT/test-bin/sqlite3" "$restored_sqlite_db" <"$restored_sqlite"
test_equals ok "$(env BB_BOOTSTRAP_TEST_ROOT="$ROOT" "$ROOT/test-bin/sqlite3" "$restored_sqlite_db" 'PRAGMA integrity_check;')" \
    "banco SQLite restaurado passa por integrity_check"
if ! find "$restored_prefix/var/tmp/borg-backup" -type f -path '*/staging/*' -print -quit | grep -q .; then
    test_record ok "staging permanece excluído apesar da inclusão restrita de dumps"
else
    test_record "not ok" "staging permanece excluído apesar da inclusão restrita de dumps"
fi
else
    if [[ ${BORG_BACKUP_REQUIRE_REAL_BORG:-no} == yes ]]; then
        test_record "not ok" "BorgBackup 1.4.x real é obrigatório para o gate de release"
    else
        ((TEST_COUNT += 1))
        printf 'ok %d - integração com Borg real # SKIP BorgBackup 1.4.x ausente ou incompatível\n' "$TEST_COUNT"
    fi
fi

test_finish
