#!/bin/bash
# Finalidade: comprovar replicação sequencial, políticas, gerações e receptor.
# Entradas: repositório/hosts/chaves totalmente sintéticos sob test-runtime.
# Saídas: protocolo TAP-like e árvores remotas descartáveis.
# Efeitos colaterais: rsync local para remotes/; nenhuma conexão de rede real.
# Dependências: Bash, rsync local, doubles SSH/Borg e receptor staged.
# Privilégios: usuário comum.
# Códigos: 0 com todos os asserts; 1 em regressão.
# Sigilo: chaves são apenas marcadores não criptográficos e nunca são impressas.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT=""

# Prepara raiz com repositório Borg estrutural sintético.
# Parâmetros: nome curto do caso.
# Resultado: ROOT isolada, configuração mínima e control/.
prepare_case() {
    local case_name=$1
    ROOT="$PROJECT_ROOT/test-runtime/checkpoint-03-$case_name"
    test_reset_root "$ROOT"
    test_stage_installation "$ROOT"
    test_write_valid_configuration "$ROOT"
    mkdir -p -- "$ROOT/control"
    test_make_synthetic_borg_repository "$ROOT"
}

# Retorna raiz física do destino sintético para inspeção de gerações.
# Parâmetros: host.
# Resultado: imprime caminho dedicado.
remote_root() {
    local host=$1 destination
    destination=$(<"$ROOT/control/remote-$host.destination")
    printf '%s\n' "$ROOT/remotes/$host$destination"
}

# Compara um campo do relatório atual.
# Parâmetros: chave, valor esperado e descrição.
# Resultado: registra assert.
assert_report() {
    local key=$1 expected=$2 description=$3
    test_equals "$expected" "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" "$key")" "$description"
}

prepare_case lexical
test_configure_replication_destination "$ROOT" 20-second.conf second backup-b.example.invalid yes yes replica-receiver-b
test_configure_replication_destination "$ROOT" 10-first.conf first backup-a.example.invalid no yes
test_configure_replication_destination "$ROOT" 30-disabled.conf disabled backup-c.example.invalid no no
test_command_rc 0 "dois destinos habilitados concluem sequencialmente" test_run_entrypoint "$ROOT" run
expected_order='ssh backup-a.example.invalid prepare rsync backup-a.example.invalid transfer rsync backup-a.example.invalid dry-run ssh backup-a.example.invalid validate ssh backup-a.example.invalid promote ssh backup-a.example.invalid status ssh backup-b.example.invalid prepare rsync backup-b.example.invalid transfer rsync backup-b.example.invalid dry-run ssh backup-b.example.invalid validate ssh backup-b.example.invalid promote ssh backup-b.example.invalid status'
actual_order=$(tr '\n' ' ' <"$ROOT/control/replication.commands" | sed 's/ $//')
test_equals "$expected_order" "$actual_order" "arquivos são processados em ordem lexical sem paralelismo"
assert_report 'REPLICATION[first]' OK "primeiro destino tem estado próprio"
assert_report 'REPLICATION[second]' OK "segundo destino tem estado próprio"
assert_report 'REPLICATION[disabled]' DISABLED "destino desabilitado é explícito"
assert_report REPLICATION_SUMMARY OK "resumo de duas réplicas válidas é OK"
if [[ -d $(remote_root backup-a.example.invalid)/current && -d $(remote_root backup-b.example.invalid)/current ]]; then
    test_record ok "cada host recebe current independente"
else
    test_record "not ok" "cada host recebe current independente"
fi
test_equals 1 "$(grep -c '^with-lock$' "$ROOT/control/borg.commands")" "um único borg with-lock cobre todos os destinos"

prepare_case optional-failure
test_configure_replication_destination "$ROOT" 10-optional.conf optional backup-a.example.invalid no yes
test_configure_replication_destination "$ROOT" 20-required.conf required backup-b.example.invalid yes yes
printf 'fail\n' >"$ROOT/control/rsync-fail-backup-a.example.invalid"
test_command_rc 1 "falha opcional retorna advertência" test_run_entrypoint "$ROOT" run
assert_report BACKUP OK "falha opcional não reescreve BACKUP=OK"
assert_report 'REPLICATION[optional]' FAILED "destino opcional falho é separado"
assert_report 'REPLICATION[required]' OK "destino seguinte ainda é tentado"
assert_report REPLICATION_SUMMARY WARNING_OPTIONAL "resumo opcional produz warning"
assert_report EXECUTION WARNING "execução distingue advertência"
[[ -d $(remote_root backup-b.example.invalid)/current ]] && test_record ok "segundo destino foi promovido após falha do primeiro" || test_record "not ok" "segundo destino foi promovido após falha do primeiro"

prepare_case required-failure
test_configure_replication_destination "$ROOT" 10-required.conf required backup-a.example.invalid yes yes
test_configure_replication_destination "$ROOT" 20-optional.conf optional backup-b.example.invalid no yes
printf 'fail\n' >"$ROOT/control/rsync-fail-backup-a.example.invalid"
test_command_rc 2 "falha obrigatória retorna falha global" test_run_entrypoint "$ROOT" run
assert_report BACKUP OK "backup principal continua semanticamente válido"
assert_report REPLICATION_SUMMARY FAILED_REQUIRED "resumo obrigatório é crítico"
assert_report EXECUTION FAILED "execução global falha sem perder backup"
[[ -d $(remote_root backup-b.example.invalid)/current ]] && test_record ok "destino posterior continua após falha obrigatória" || test_record "not ok" "destino posterior continua após falha obrigatória"
[[ -s $ROOT/var/log/borg-backup/last-success.report ]] && test_record ok "last-success é preservado para backup principal válido" || test_record "not ok" "last-success é preservado para backup principal válido"

prepare_case replication-capacity-warning
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
printf '8\n' >"$ROOT/control/df-post-remote-mib"
test_command_rc 1 "réplica promovida abaixo do piso produz warning" test_run_entrypoint "$ROOT" run
assert_report BACKUP OK "warning remoto preserva BACKUP=OK"
assert_report 'REPLICATION[primary]' OK "warning remoto preserva REPLICATION=OK"
assert_report CAPACITY WARNING "capacidade remota possui estado separado"
assert_report EXECUTION WARNING "capacidade remota produz execução warning"
grep -q '^RESULT=OK$' "$ROOT/var/lib/borg-backup/state/replication/primary.state" \
    && grep -q '^CAPACITY=WARNING$' "$ROOT/var/lib/borg-backup/state/replication/primary.state" \
    && test_record ok "estado do destino separa sucesso e capacidade" \
    || test_record "not ok" "estado do destino separa sucesso e capacidade"
test_command_rc 2 "réplica seguinte é bloqueada pelo piso pré-operacional" test_run_entrypoint "$ROOT" replicate

prepare_case generations
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
test_command_rc 0 "primeira sincronização cria current" test_run_entrypoint "$ROOT" run
generation_root=$(remote_root backup-a.example.invalid)
if [[ -d $generation_root/current && ! -e $generation_root/previous ]]; then
    test_record ok "primeira geração possui somente current válida"
else
    test_record "not ok" "primeira geração possui somente current válida"
fi
first_execution=$(awk -F= '$1=="EXECUTION_ID" {print $2}' "$generation_root/current/generation.meta")
first_inode=$(stat -c '%i' "$generation_root/current/repo/config")
test_command_rc 0 "replicate explícito cria segunda geração" test_run_entrypoint "$ROOT" replicate
second_execution=$(awk -F= '$1=="EXECUTION_ID" {print $2}' "$generation_root/current/generation.meta")
test_equals "$first_execution" "$(awk -F= '$1=="EXECUTION_ID" {print $2}' "$generation_root/previous/generation.meta")" "current anterior torna-se previous"
[[ $second_execution != "$first_execution" ]] && test_record ok "nova current possui execução distinta" || test_record "not ok" "nova current possui execução distinta"
test_equals "$first_inode" "$(stat -c '%i' "$generation_root/current/repo/config")" "link-dest reutiliza inode sem modificar geração válida"
test_equals "$first_inode" "$(stat -c '%i' "$generation_root/previous/repo/config")" "current e previous compartilham conteúdo imutável"
[[ ! -e $generation_root/current/repo/generation.meta ]] && test_record ok "generation.meta permanece fora do repositório" || test_record "not ok" "generation.meta permanece fora do repositório"
mkdir -p -- "$ROOT/restore-current"
cp -a -- "$generation_root/current/repo/." "$ROOT/restore-current/"
cmp "$ROOT/srv/borg-storage/repositories/lab/repo/config" "$ROOT/restore-current/config" && test_record ok "restauração controlada de current reproduz arquivo" || test_record "not ok" "restauração controlada de current reproduz arquivo"

prepare_case transfer-interruption
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
test_command_rc 0 "base válida existe antes da interrupção" test_run_entrypoint "$ROOT" run
generation_root=$(remote_root backup-a.example.invalid)
current_hash=$(sha256sum "$generation_root/current/generation.meta" | awk '{print $1}')
printf 'fail\n' >"$ROOT/control/rsync-fail-backup-a.example.invalid"
test_command_rc 2 "transferência interrompida falha sem promoção" test_run_entrypoint "$ROOT" replicate
test_equals "$current_hash" "$(sha256sum "$generation_root/current/generation.meta" | awk '{print $1}')" "current anterior permanece byte a byte"
if ! find "$generation_root" -maxdepth 1 -type d -name 'incoming-*' -print -quit | grep -q .; then
    test_record ok "incoming incompleto é abortado pelo ID exato"
else
    test_record "not ok" "incoming incompleto é abortado pelo ID exato"
fi

prepare_case dry-run-failure
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
test_command_rc 0 "base válida precede falha de dry-run" test_run_entrypoint "$ROOT" run
printf 'fail\n' >"$ROOT/control/rsync-dry-fail-backup-a.example.invalid"
test_command_rc 2 "dry-run divergente impede promoção" test_run_entrypoint "$ROOT" replicate
assert_report 'REPLICATION[primary]' FAILED "falha de verificação fica no destino"

prepare_case unknown-host-key
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
sed -i '/^backup-a\.example\.invalid /d' "$ROOT/etc/borg-backup/ssh/known_hosts"
test_command_rc 2 "host key ausente é recusada" test_run_entrypoint "$ROOT" run
assert_report 'REPLICATION[primary]' FAILED "recusa SSH não afeta semântica do backup"

prepare_case disabled-only
test_configure_replication_destination "$ROOT" 10-disabled.conf disabled backup-a.example.invalid no no
test_command_rc 0 "conjunto somente desabilitado é no-op válido" test_run_entrypoint "$ROOT" run
assert_report 'REPLICATION[disabled]' DISABLED "destino desabilitado não é acessado"
assert_report REPLICATION_SUMMARY DISABLED "resumo global desabilitado é explícito"
[[ ! -e $ROOT/control/replication.commands ]] && test_record ok "nenhum SSH/rsync ocorre para destino desabilitado" || test_record "not ok" "nenhum SSH/rsync ocorre para destino desabilitado"

prepare_case receiver-storage-validation
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
receiver_sentinel="$ROOT/remotes/backup-a.example.invalid/srv/borg-storage/.borg-storage"
test_command_rc 2 "receptor recusa STORAGE_ID esperado divergente" \
    test_receiver_command "$ROOT" backup-a.example.invalid status other-storage
test_command_rc 2 "receptor recusa UUID esperado divergente" \
    test_receiver_command "$ROOT" backup-a.example.invalid status lab-receiver 22222222-2222-2222-2222-222222222222
printf 'STORAGE_ID=lab-receiver\n' >"$receiver_sentinel"
test_command_rc 2 "receptor recusa sentinela sem PURPOSE" \
    test_receiver_command "$ROOT" backup-a.example.invalid status
printf 'STORAGE_ID=lab-receiver\nPURPOSE=borg-backup\nEXTRA=forbidden\n' >"$receiver_sentinel"
test_command_rc 2 "receptor recusa chave desconhecida na sentinela" \
    test_receiver_command "$ROOT" backup-a.example.invalid status
printf 'STORAGE_ID=lab-receiver\nPURPOSE=borg-backup\nSTORAGE_ID=lab-receiver\n' >"$receiver_sentinel"
test_command_rc 2 "receptor recusa chave duplicada na sentinela" \
    test_receiver_command "$ROOT" backup-a.example.invalid status
printf 'STORAGE_ID=lab-receiver\nPURPOSE=borg-backup\n' >"$receiver_sentinel"
chmod 0644 -- "$receiver_sentinel"
test_command_rc 2 "receptor exige modo 0640 na sentinela" \
    test_receiver_command "$ROOT" backup-a.example.invalid status
chmod 0640 -- "$receiver_sentinel"
printf 'yes\n' >"$ROOT/control/wrong-sentinel-owner"
test_command_rc 2 "receptor recusa proprietário divergente da sentinela" \
    test_receiver_command "$ROOT" backup-a.example.invalid status
find -P "$ROOT/control/wrong-sentinel-owner" -delete
printf '16\n' >"$ROOT/control/df-available-mib"
test_command_rc 0 "receptor aceita piso livre exatamente igual antes da réplica" \
    test_receiver_command "$ROOT" backup-a.example.invalid 'prepare 20260807T005000Z-lab-50 lab 16'
test_receiver_command "$ROOT" backup-a.example.invalid 'abort 20260807T005000Z-lab-50' >/dev/null
printf '15\n' >"$ROOT/control/df-available-mib"
test_command_rc 2 "receptor bloqueia espaço livre abaixo do piso" \
    test_receiver_command "$ROOT" backup-a.example.invalid 'prepare 20260807T005001Z-lab-51 lab 16'

prepare_case receiver-closed-interface
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
exec_one=20260807T010000Z-lab-100
test_command_rc 2 "receptor recusa origem divergente do comando forçado" test_receiver_command "$ROOT" backup-a.example.invalid "prepare $exec_one other-origin 16"
test_command_rc 2 "receptor recusa espaço mínimo divergente" test_receiver_command "$ROOT" backup-a.example.invalid "prepare $exec_one lab 32"
test_command_rc 0 "receptor aceita prepare conhecido" test_receiver_command "$ROOT" backup-a.example.invalid "prepare $exec_one lab 16"
test_command_rc 2 "token ativo recusa segunda preparação concorrente" test_receiver_command "$ROOT" backup-a.example.invalid "prepare 20260807T010001Z-lab-101 lab 16"
test_command_rc 2 "receptor recusa comando de shell" test_receiver_command "$ROOT" backup-a.example.invalid 'sh -c id'
receiver_root_path=$(remote_root backup-a.example.invalid)
server_command="rsync --server -lHtpre.iLsfxCIvu --partial-dir .rsync-partial --delay-updates --fsync . $receiver_root_path/incoming-$exec_one/repo/"
test_command_rc 0 "modo servidor rsync fechado aceita argv previsto" test_receiver_command "$ROOT" backup-a.example.invalid "$server_command"
dangerous_command="rsync --server -lHtpre.iLsfxCIvu --partial-dir .rsync-partial --delay-updates --fsync --inplace . $receiver_root_path/incoming-$exec_one/repo/"
test_command_rc 2 "modo servidor rejeita --inplace" test_receiver_command "$ROOT" backup-a.example.invalid "$dangerous_command"
test_command_rc 0 "abort remove somente incoming exato" test_receiver_command "$ROOT" backup-a.example.invalid "abort $exec_one"

prepare_case receiver-real-rsync-argv
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
exec_real=20260807T015000Z-lab-150
test_receiver_command "$ROOT" backup-a.example.invalid "prepare $exec_real lab 16" >/dev/null
receiver_root_path=$(remote_root backup-a.example.invalid)
captured_command="$ROOT/control/rsync-real-server.command"
if BB_RSYNC_CAPTURE_ROOT="$ROOT" BB_RSYNC_CAPTURE_FILE="$captured_command" \
    /usr/bin/rsync --recursive --links --perms --times --hard-links \
        --partial-dir=.rsync-partial --delay-updates --fsync \
        -e "$PROJECT_ROOT/tests/helpers/capture-rsync-rsh.sh" \
        "$ROOT/srv/borg-storage/repositories/lab/repo/" \
        "fixture-host:$receiver_root_path/incoming-$exec_real/repo/" \
        >/dev/null 2>&1; then
    capture_rc=0
else
    capture_rc=$?
fi
test_equals 12 "$capture_rc" "harness interrompe rsync real antes de transporte"
[[ -s $captured_command ]] && test_record ok "argv servidor do rsync real foi capturado" || test_record "not ok" "argv servidor do rsync real foi capturado"
test_command_rc 0 "receptor aceita argv emitido pelo rsync instalado" \
    test_receiver_command "$ROOT" backup-a.example.invalid "$(<"$captured_command")"
test_receiver_command "$ROOT" backup-a.example.invalid "abort $exec_real" >/dev/null

# Repete a captura com current válida para comprovar o `--link-dest` exato e o
# formato dry-run produzido pelo mesmo rsync, ainda sem abrir conexão.
test_create_receiver_generation "$ROOT" backup-a.example.invalid current 20260807T015001Z-lab-151
exec_link=20260807T015002Z-lab-152
test_receiver_command "$ROOT" backup-a.example.invalid "prepare $exec_link lab 16" >/dev/null
for capture_mode in transfer dry-run; do
    captured_command="$ROOT/control/rsync-real-link-$capture_mode.command"
    declare -a real_rsync_options=(
        --recursive --links --perms --times --hard-links
        --partial-dir=.rsync-partial --delay-updates --fsync
        "--link-dest=$receiver_root_path/current/repo"
    )
    if [[ $capture_mode == "dry-run" ]]; then
        real_rsync_options+=(--dry-run --itemize-changes)
    fi
    if BB_RSYNC_CAPTURE_ROOT="$ROOT" BB_RSYNC_CAPTURE_FILE="$captured_command" \
        /usr/bin/rsync "${real_rsync_options[@]}" \
            -e "$PROJECT_ROOT/tests/helpers/capture-rsync-rsh.sh" \
            "$ROOT/srv/borg-storage/repositories/lab/repo/" \
            "fixture-host:$receiver_root_path/incoming-$exec_link/repo/" \
            >/dev/null 2>&1; then
        capture_rc=0
    else
        capture_rc=$?
    fi
    test_equals 12 "$capture_rc" "captura rsync real com link-dest: $capture_mode"
    test_command_rc 0 "receptor aceita protocolo real com link-dest: $capture_mode" \
        test_receiver_command "$ROOT" backup-a.example.invalid "$(<"$captured_command")"
done
test_receiver_command "$ROOT" backup-a.example.invalid "abort $exec_link" >/dev/null

prepare_case receiver-lock
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
exec_lock=20260807T020000Z-lab-200
test_receiver_command "$ROOT" backup-a.example.invalid "prepare $exec_lock lab 16" >/dev/null
printf '2\n' >"$ROOT/control/receiver-rsync-delay"
receiver_root_path=$(remote_root backup-a.example.invalid)
server_command="rsync --server -lHtpre.iLsfxCIvu --partial-dir .rsync-partial --delay-updates --fsync . $receiver_root_path/incoming-$exec_lock/repo/"
destination=$(<"$ROOT/control/remote-backup-a.example.invalid.destination")
BB_BOOTSTRAP_TEST_ROOT="$ROOT" BB_RECEIVER_TEST_MODE=yes BB_RECEIVER_TEST_BIN="$ROOT/test-bin" \
SSH_ORIGINAL_COMMAND="$server_command" \
    "$ROOT/usr/local/lib/borg-backup/replica-receiver.sh" \
    --root "$ROOT/remotes/backup-a.example.invalid$destination" --origin lab \
    --sentinel "$ROOT/remotes/backup-a.example.invalid/srv/borg-storage/.borg-storage" \
    --storage-id lab-receiver \
    --filesystem-uuid 11111111-1111-1111-1111-111111111111 \
    --min-free-mib 16 &
receiver_pid=$!
sleep 0.2
test_command_rc 2 "flock remoto recusa operação simultânea" test_receiver_command "$ROOT" backup-a.example.invalid status
wait "$receiver_pid"
test_receiver_command "$ROOT" backup-a.example.invalid "abort $exec_lock" >/dev/null

prepare_case reconcile
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
test_create_receiver_generation "$ROOT" backup-a.example.invalid previous 20260807T030000Z-lab-300
reconcile_output=$(test_receiver_command "$ROOT" backup-a.example.invalid 'prepare 20260807T030001Z-lab-301 lab 16')
test_equals 'READY CURRENT=yes' "$reconcile_output" "previous válida é reconciliada para current ausente"
generation_root=$(remote_root backup-a.example.invalid)
[[ -d $generation_root/current && ! -e $generation_root/previous ]] && test_record ok "reconciliação usa rename no mesmo destino" || test_record "not ok" "reconciliação usa rename no mesmo destino"
test_receiver_command "$ROOT" backup-a.example.invalid 'abort 20260807T030001Z-lab-301' >/dev/null

prepare_case ambiguous
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
test_create_receiver_generation "$ROOT" backup-a.example.invalid current 20260807T040000Z-lab-400
generation_root=$(remote_root backup-a.example.invalid)
mkdir -p -- "$generation_root/incoming-20260807T040001Z-lab-401/repo"
test_command_rc 2 "incoming sem token torna estado ambíguo" test_receiver_command "$ROOT" backup-a.example.invalid 'prepare 20260807T040002Z-lab-402 lab 16'
[[ -d $generation_root/current && -d $generation_root/incoming-20260807T040001Z-lab-401 ]] && test_record ok "estado ambíguo é preservado sem remoções" || test_record "not ok" "estado ambíguo é preservado sem remoções"

# Cada ponto de falha da promoção é criado diretamente com gerações válidas para
# demonstrar que ao menos current ou previous permanece recuperável.
for failpoint in after-remove-previous after-current-to-previous after-incoming-to-current; do
    prepare_case "promotion-$failpoint"
    test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
    test_create_receiver_generation "$ROOT" backup-a.example.invalid previous 20260807T050000Z-lab-500
    test_create_receiver_generation "$ROOT" backup-a.example.invalid current 20260807T050001Z-lab-501
    incoming_exec=20260807T050002Z-lab-502
    test_create_receiver_generation "$ROOT" backup-a.example.invalid "incoming-$incoming_exec" "$incoming_exec"
    test_write_receiver_active_validated "$ROOT" backup-a.example.invalid "$incoming_exec"
    printf '%s\n' "$failpoint" >"$ROOT/control/receiver-failpoint"
    test_command_rc 2 "falha injetada é observada: $failpoint" test_receiver_command "$ROOT" backup-a.example.invalid "promote $incoming_exec"
    status_output=$(test_receiver_command "$ROOT" backup-a.example.invalid status)
    case $failpoint in
        after-remove-previous) expected_status='CURRENT=yes PREVIOUS=no ACTIVE=yes' ;;
        after-current-to-previous) expected_status='CURRENT=no PREVIOUS=yes ACTIVE=yes' ;;
        after-incoming-to-current) expected_status='CURRENT=yes PREVIOUS=yes ACTIVE=yes' ;;
    esac
    test_equals "$expected_status" "$status_output" "ponto de promoção mantém geração recuperável: $failpoint"
done

prepare_case previous-recovery
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
test_create_receiver_generation "$ROOT" backup-a.example.invalid previous 20260807T060000Z-lab-600
test_create_receiver_generation "$ROOT" backup-a.example.invalid current 20260807T060001Z-lab-601
generation_root=$(remote_root backup-a.example.invalid)
sed -i 's/^STATUS=VALID$/STATUS=CORRUPT/' "$generation_root/current/generation.meta"
test_equals 'CURRENT=no PREVIOUS=yes ACTIVE=no' "$(test_receiver_command "$ROOT" backup-a.example.invalid status)" "corrupção de current mantém previous identificável"
mkdir -p -- "$ROOT/restore-previous"
cp -a -- "$generation_root/previous/repo/." "$ROOT/restore-previous/"
cmp "$ROOT/srv/borg-storage/repositories/lab/repo/config" "$ROOT/restore-previous/config" && test_record ok "previous pode ser recuperada em área independente" || test_record "not ok" "previous pode ser recuperada em área independente"
test_command_rc 2 "current corrompida bloqueia promoção automática" test_receiver_command "$ROOT" backup-a.example.invalid 'prepare 20260807T060002Z-lab-602 lab 16'
[[ -d $generation_root/current && -d $generation_root/previous ]] && test_record ok "receptor não apaga gerações diante de corrupção" || test_record "not ok" "receptor não apaga gerações diante de corrupção"

prepare_case command-lock
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
"$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 2 &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e $ROOT/lock-ready ]] && break; sleep 0.1; done
test_command_rc 2 "replicate respeita o lock global" test_run_entrypoint "$ROOT" replicate
wait "$holder_pid"

# Integra Borg 1.4 real com o modo interno; somente SSH/rsync permanecem doubles
# para evitar qualquer conexão externa. A ausência ou versão incompatível pula
# apenas este bloco, salvo quando o gate de release o declara obrigatório.
real_borg=""
real_borg_version=""
if [[ ${BORG_BACKUP_TEST_FORCE_NO_REAL_BORG:-no} != yes ]] \
    && real_borg=$(command -v borg 2>/dev/null) \
    && real_borg_version=$("$real_borg" --version 2>/dev/null) \
    && [[ $real_borg_version =~ ^borg[[:space:]]1\.4\.[0-9]+$ ]]; then
prepare_case real-borg-with-lock
test_configure_replication_destination "$ROOT" 10-primary.conf primary backup-a.example.invalid yes yes
repository="$ROOT/srv/borg-storage/repositories/lab/repo"
find -P "$repository" -mindepth 1 -delete
find -P "$ROOT/test-bin/borg" -delete
mkdir -p -- "$ROOT/var/cache/borg" "$ROOT/var/lib/borg-backup/borg-security" "$ROOT/var/lib/borg-backup/borg-keys"
env -i PATH="$PATH" LC_ALL=C LANG=C \
    BORG_PASSPHRASE=test-only-synthetic-passphrase \
    BORG_CACHE_DIR="$ROOT/var/cache/borg" \
    BORG_SECURITY_DIR="$ROOT/var/lib/borg-backup/borg-security" \
    BORG_KEYS_DIR="$ROOT/var/lib/borg-backup/borg-keys" \
    "$real_borg" init --encryption=repokey-blake2 "$repository" \
    >"$ROOT/control/borg-init.output" 2>&1
test_command_rc 0 "Borg real mantém lock nativo durante réplica controlada" test_run_entrypoint "$ROOT" run
[[ -f $(remote_root backup-a.example.invalid)/current/repo/config ]] && test_record ok "réplica de repositório Borg real é promovida" || test_record "not ok" "réplica de repositório Borg real é promovida"
assert_report REPLICATION_SUMMARY OK "resultado real com with-lock permanece rastreável"
test_command_rc 0 "segunda réplica real cria geração previous" test_run_entrypoint "$ROOT" replicate
real_remote_root=$(remote_root backup-a.example.invalid)
[[ -d $real_remote_root/current/repo && -d $real_remote_root/previous/repo ]] \
    && test_record ok "repositório real possui current e previous" \
    || test_record "not ok" "repositório real possui current e previous"

# Corrompe somente o marcador de current e recupera previous em cópia sem hard
# links com a réplica, conforme o runbook; o repositório fonte não é alterado.
sed -i 's/^STATUS=VALID$/STATUS=CORRUPT/' "$real_remote_root/current/generation.meta"
mkdir -p -- "$ROOT/restore-from-previous/repo" "$ROOT/restore-from-previous/output" \
    "$ROOT/restore-from-previous/cache" "$ROOT/restore-from-previous/security" \
    "$ROOT/restore-from-previous/keys"
cp -a -- "$real_remote_root/previous/repo/." "$ROOT/restore-from-previous/repo/"
source_inode=$(stat -c '%i' -- "$real_remote_root/previous/repo/config")
copy_inode=$(stat -c '%i' -- "$ROOT/restore-from-previous/repo/config")
[[ $source_inode != "$copy_inode" ]] \
    && test_record ok "cópia de recuperação rompe hard links da geração" \
    || test_record "not ok" "cópia de recuperação rompe hard links da geração"
real_archive=$(awk -F= '$1=="ARCHIVE" {print $2}' "$ROOT/var/lib/borg-backup/state/last-success.state")
declare -a replica_borg_environment=(
    env -i PATH="$PATH" LC_ALL=C LANG=C
    BORG_PASSPHRASE=test-only-synthetic-passphrase
    BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
    BORG_CACHE_DIR="$ROOT/restore-from-previous/cache"
    BORG_SECURITY_DIR="$ROOT/restore-from-previous/security"
    BORG_KEYS_DIR="$ROOT/restore-from-previous/keys"
)
test_command_rc 0 "lock Borg copiado é removido somente na cópia independente" \
    "${replica_borg_environment[@]}" "$real_borg" break-lock "$ROOT/restore-from-previous/repo"
test_command_rc 0 "previous copiada lista o archive esperado" \
    "${replica_borg_environment[@]}" "$real_borg" info "$ROOT/restore-from-previous/repo::$real_archive"
(
    cd "$ROOT/restore-from-previous/output"
    "${replica_borg_environment[@]}" "$real_borg" extract "$ROOT/restore-from-previous/repo::$real_archive"
)
restored_member="$ROOT/restore-from-previous/output/${ROOT#/}/etc/borg-backup/sources.conf"
cmp "$ROOT/etc/borg-backup/sources.conf" "$restored_member" \
    && test_record ok "arquivo é restaurado da previous após current simuladamente corrompida" \
    || test_record "not ok" "arquivo é restaurado da previous após current simuladamente corrompida"
else
    if [[ ${BORG_BACKUP_REQUIRE_REAL_BORG:-no} == yes ]]; then
        test_record "not ok" "BorgBackup 1.4.x real é obrigatório para o gate de release"
    else
        ((TEST_COUNT += 1))
        printf 'ok %d - integração com Borg real # SKIP BorgBackup 1.4.x ausente ou incompatível\n' "$TEST_COUNT"
    fi
fi

if ! grep -R -F 'test-only-synthetic-passphrase' "$PROJECT_ROOT/test-runtime"/checkpoint-03-*/var/log/borg-backup "$PROJECT_ROOT/test-runtime"/checkpoint-03-*/var/lib/borg-backup/state >/dev/null 2>&1; then
    test_record ok "logs, relatórios e estados de replicação não contêm passphrase"
else
    test_record "not ok" "logs, relatórios e estados de replicação não contêm passphrase"
fi

test_finish
