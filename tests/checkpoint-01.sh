#!/bin/bash
# Finalidade: comprovar fundação, parser literal, validações e lock do CP1.
# Entradas: artefatos em src/ e fixtures sintéticas deste repositório.
# Saídas: protocolo TAP-like no stdout e logs descartáveis em test-runtime.
# Efeitos colaterais: recria somente test-runtime/checkpoint-01.
# Dependências: Bash e ferramentas Debian já presentes; não usa rede.
# Privilégios: usuário comum.
# Códigos: 0 quando todos os casos passam; 1 em qualquer regressão.
# Sigilo: utiliza exclusivamente a passphrase sintética declarada no testlib.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT="$PROJECT_ROOT/test-runtime/checkpoint-01"

test_reset_root "$ROOT"
test_stage_installation "$ROOT"
test_write_valid_configuration "$ROOT"

test_command_rc 0 "configuração literal válida" \
    test_run_entrypoint "$ROOT" validate
if grep -q '^EXECUTION\.\+ OK$' "$ROOT/var/log/borg-backup/last-run.report"; then
    test_record ok "validate produz last-run atômico com resultado separado"
else
    test_record "not ok" "validate produz last-run atômico com resultado separado"
fi
if [[ ! -e $ROOT/var/log/borg-backup/last-success.report ]]; then
    test_record ok "validate não altera last-success sem backup válido"
else
    test_record "not ok" "validate não altera last-success sem backup válido"
fi
if ! grep -R -F 'test-only-synthetic-passphrase' \
    "$ROOT/var/log/borg-backup" "$ROOT/var/lib/borg-backup/state" >/dev/null 2>&1; then
    test_record ok "segredo sintético não aparece em log, relatório ou estado"
else
    test_record "not ok" "segredo sintético não aparece em log, relatório ou estado"
fi
test_command_rc 64 "operação desconhecida retorna uso inválido" \
    test_run_entrypoint "$ROOT" unknown-operation
test_command_rc 2 "modo controlado é recusado no binário não staged" \
    env -i HOME="$HOME" BORG_BACKUP_TEST_MODE=yes \
        BORG_BACKUP_TEST_ROOT="$ROOT" BORG_BACKUP_TEST_BIN="$ROOT/test-bin" \
        "$PROJECT_ROOT/src/usr/local/sbin/borg-backup" validate

# Cada mutação abaixo é refeita a partir da fixture válida para isolar a causa.
test_write_valid_configuration "$ROOT"
printf '%s\n' 'UNKNOWN_KEY=value' >>"$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "chave desconhecida é rejeitada" \
    test_run_entrypoint "$ROOT" validate
test_equals FAILED "$(test_report_value "$ROOT/var/log/borg-backup/last-run.report" EXECUTION)" \
    "falha de preparação ainda atualiza last-run"

test_write_valid_configuration "$ROOT"
printf '%s\n' 'KEEP_DAILY=14' >>"$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "chave duplicada é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i "s|ARCHIVE_PREFIX=lab|ARCHIVE_PREFIX=\$(touch $ROOT/command-substitution-ran)|" \
    "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "substituição de comando é rejeitada sem execução" \
    test_run_entrypoint "$ROOT" validate
[[ ! -e $ROOT/command-substitution-ran ]] && \
    test_record ok "conteúdo rejeitado não produziu efeito colateral" || \
    test_record "not ok" "conteúdo rejeitado não produziu efeito colateral"

test_write_valid_configuration "$ROOT"
sed -i 's|ARCHIVE_PREFIX=lab|ARCHIVE_PREFIX=${HOME}|' "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "expansão de variável é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i 's|ARCHIVE_PREFIX=lab|ARCHIVE_PREFIX=lab # comentário|' "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "comentário inline é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
printf '%s\n' 'malicious() { true; }' >>"$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "declaração de função é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i '/^KEEP_MONTHLY=/d' "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "chave obrigatória ausente é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i 's|BORG_REPOSITORY=/srv/borg-storage/repositories/lab/repo|BORG_REPOSITORY=/|' \
    "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "repositório raiz é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i 's|REPOSITORY_FILESYSTEM_UUID=11111111-1111-1111-1111-111111111111|REPOSITORY_FILESYSTEM_UUID=22222222-2222-2222-2222-222222222222|' \
    "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "UUID divergente é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
printf '%s\n' 'SENTINELA-INCORRETA' >"$ROOT/srv/borg-storage/.borg-storage"
test_command_rc 2 "conteúdo de sentinela divergente é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
printf 'STORAGE_ID=lab\n' >"$ROOT/srv/borg-storage/.borg-storage"
test_command_rc 2 "sentinela sem PURPOSE é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
cat >>"$ROOT/srv/borg-storage/.borg-storage" <<'EOF'
EXTRA=forbidden
EOF
test_command_rc 2 "sentinela com chave desconhecida é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
cat >>"$ROOT/srv/borg-storage/.borg-storage" <<'EOF'
STORAGE_ID=lab
EOF
test_command_rc 2 "sentinela com chave duplicada é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i 's|REPOSITORY_STORAGE_ID=lab|REPOSITORY_STORAGE_ID=other-storage|' \
    "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "STORAGE_ID divergente é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
chmod 0644 -- "$ROOT/srv/borg-storage/.borg-storage"
test_command_rc 2 "sentinela exige modo exato 0640" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
printf 'yes\n' >"$ROOT/control/wrong-sentinel-owner"
test_command_rc 2 "proprietário divergente da sentinela é rejeitado" \
    test_run_entrypoint "$ROOT" validate
find -P "$ROOT/control/wrong-sentinel-owner" -delete

test_write_valid_configuration "$ROOT"
sed -i 's|REPOSITORY_MIN_FREE_MIB=16|REPOSITORY_MIN_FREE_MIB=999999|' \
    "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "espaço livre abaixo do mínimo é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
printf '16\n' >"$ROOT/control/df-available-mib"
test_command_rc 0 "espaço livre exatamente igual ao piso é aceito" \
    test_run_entrypoint "$ROOT" validate
printf '17\n' >"$ROOT/control/df-available-mib"
test_command_rc 0 "espaço livre acima do piso é aceito" \
    test_run_entrypoint "$ROOT" validate
printf '15\n' >"$ROOT/control/df-available-mib"
test_command_rc 2 "espaço livre um MiB abaixo do piso é bloqueado" \
    test_run_entrypoint "$ROOT" validate
find -P "$ROOT/control/df-available-mib" -delete

test_write_valid_configuration "$ROOT"
cp -- "$PROJECT_ROOT/fixtures/bin/findmnt-fail" "$ROOT/test-bin/findmnt"
chmod 0755 -- "$ROOT/test-bin/findmnt"
test_command_rc 2 "mountpoint ausente é rejeitado" \
    test_run_entrypoint "$ROOT" validate
cp -- "$PROJECT_ROOT/fixtures/bin/findmnt" "$ROOT/test-bin/findmnt"
chmod 0755 -- "$ROOT/test-bin/findmnt"

test_write_valid_configuration "$ROOT"
chmod 0640 -- "$ROOT/etc/borg-backup/secrets.conf"
test_command_rc 2 "segredo sem modo 0600 é rejeitado antes da leitura" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
chmod 0644 -- "$ROOT/etc/borg-backup/backup.conf"
test_command_rc 2 "configuração normal exige modo exato 0640" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
chmod 0755 -- "$ROOT/etc/borg-backup/replication.d"
test_command_rc 2 "diretório replication.d exige modo 0750" \
    test_run_entrypoint "$ROOT" validate
chmod 0750 -- "$ROOT/etc/borg-backup/replication.d"

test_write_valid_configuration "$ROOT"
chmod 0750 -- "$ROOT/etc/borg-backup/ssh"
test_command_rc 2 "diretório SSH administrativo exige modo 0700" \
    test_run_entrypoint "$ROOT" validate
chmod 0700 -- "$ROOT/etc/borg-backup/ssh"

test_write_valid_configuration "$ROOT"
cat >"$ROOT/etc/borg-backup/databases.conf" <<'EOF'
# Banco SQLite sintético associado a serviço protegido para testar rejeição.
sqlite|lab-sqlite|/srv/app/database.sqlite3
EOF
cat >"$ROOT/etc/borg-backup/services.conf" <<'EOF'
# SSH é infraestrutura e jamais pode ser parado.
ssh.service
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/databases.conf" "$ROOT/etc/borg-backup/services.conf"
test_command_rc 2 "serviço SSH protegido é rejeitado" \
    test_run_entrypoint "$ROOT" validate

for protected_unit in bind9.service systemd-resolved.service unbound.service coredns.service nsd.service networking.service NetworkManager-wait-online.service nftables.service netfilter-persistent.service openvpn-client@lab.service wireguard.service tailscaled.service dropbear.service; do
    test_write_valid_configuration "$ROOT"
    cat >"$ROOT/etc/borg-backup/databases.conf" <<'EOF'
# SQLite sintético usado apenas para validar a política de unidades protegidas.
sqlite|lab-sqlite|/srv/app/database.sqlite3
EOF
    cat >"$ROOT/etc/borg-backup/services.conf" <<EOF
# Esta unidade de infraestrutura deve ser recusada.
$protected_unit
EOF
    chmod 0640 -- "$ROOT/etc/borg-backup/databases.conf" "$ROOT/etc/borg-backup/services.conf"
    test_command_rc 2 "infraestrutura protegida é rejeitada: $protected_unit" \
        test_run_entrypoint "$ROOT" validate
done

test_write_valid_configuration "$ROOT"
cat >"$ROOT/etc/borg-backup/services.conf" <<'EOF'
# Uma unit declarada uma única vez é suficiente.
apache2.service
# A repetição literal deve falhar antes de consultar systemd.
apache2.service
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/services.conf"
test_command_rc 2 "unit duplicada em services.conf é rejeitada" \
    test_run_entrypoint "$ROOT" validate

# Compõe o formato legado em runtime para provar sua rejeição sem mantê-lo
# como exemplo copiável na documentação ou no código ativo.
legacy_service_stage=backup
legacy_service_binding=web
for invalid_service_line in \
    "$legacy_service_stage:$legacy_service_binding|apache2.service" \
    'apache2.service --now' \
    'apache2.service;true' \
    'apache2.service # comentário'; do
    test_write_valid_configuration "$ROOT"
    {
        printf '# Sintaxe adicional deve ser recusada como dado inválido.\n'
        printf '%s\n' "$invalid_service_line"
    } >"$ROOT/etc/borg-backup/services.conf"
    chmod 0640 -- "$ROOT/etc/borg-backup/services.conf"
    test_command_rc 2 "services.conf rejeita sintaxe extra: $invalid_service_line" \
        test_run_entrypoint "$ROOT" validate
done

test_write_valid_configuration "$ROOT"
cat >"$ROOT/etc/borg-backup/sources.conf" <<'EOF'
# Fonte que contém o repositório deve disparar a salvaguarda de recursão.
/srv/borg-storage
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/sources.conf"
test_command_rc 2 "relação recursiva entre fonte e repositório é rejeitada" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
mkdir -p -- "$ROOT/srv/borg-storage/repositories/lab/repo/data"
cat >"$ROOT/etc/borg-backup/sources.conf" <<'EOF'
# Fonte contida no repositório também constitui recursão insegura.
/srv/borg-storage/repositories/lab/repo/data
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/sources.conf"
test_command_rc 2 "repositório que contém fonte também é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
mkdir -p -- "$ROOT/srv/source with space"
cat >"$ROOT/etc/borg-backup/sources.conf" <<'EOF'
# Espaço interno é permitido em fonte literal porque não há expansão shell.
/srv/source with space
EOF
chmod 0640 -- "$ROOT/etc/borg-backup/sources.conf"
test_command_rc 0 "fonte literal com espaço interno é tratada como dado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
sed -i 's|REPLICATION_ENABLED=no|REPLICATION_ENABLED=yes|' "$ROOT/etc/borg-backup/replication.conf"
test_write_destination_configuration "$ROOT" 10-first.conf duplicate-id no no
test_write_destination_configuration "$ROOT" 20-second.conf duplicate-id no yes
test_command_rc 2 "IDs de replicação duplicados abortam antes de transferir" \
    test_run_entrypoint "$ROOT" validate
[[ ! -e $ROOT/control/replication.commands ]] \
    && test_record ok "duplicidade é recusada antes de SSH ou rsync" \
    || test_record "not ok" "duplicidade é recusada antes de SSH ou rsync"

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
sed -i 's|REPLICATION_ENABLED=no|REPLICATION_ENABLED=yes|' "$ROOT/etc/borg-backup/replication.conf"
test_write_destination_configuration "$ROOT" 10-root.conf root-destination no no backup.example.invalid /
test_command_rc 2 "destino remoto raiz é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
sed -i 's|REPLICATION_ENABLED=no|REPLICATION_ENABLED=yes|' "$ROOT/etc/borg-backup/replication.conf"
test_write_destination_configuration "$ROOT" 10-empty.conf empty-destination no no backup.example.invalid ''
sed -i 's|^REPLICATION_DESTINATION=.*|REPLICATION_DESTINATION=|' \
    "$ROOT/etc/borg-backup/replication.d/10-empty.conf"
test_command_rc 2 "destino remoto vazio é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
sed -i 's|REPLICATION_ENABLED=no|REPLICATION_ENABLED=yes|' "$ROOT/etc/borg-backup/replication.conf"
test_write_destination_configuration "$ROOT" 10-first.conf first-id no no backup.example.invalid /srv/borg-storage/replicas/shared
test_write_destination_configuration "$ROOT" 20-second.conf second-id no no backup.example.invalid /srv/borg-storage/replicas/shared
test_command_rc 2 "diretório remoto compartilhado é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
sed -i 's|REPLICATION_ENABLED=no|REPLICATION_ENABLED=yes|' "$ROOT/etc/borg-backup/replication.conf"
test_write_destination_configuration "$ROOT" 10-invalid.conf INVALID_ID no no
test_command_rc 2 "ID fora do alfabeto permitido é rejeitado" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
test_configure_replication_destination "$ROOT" 10-key.conf key-mode backup.example.invalid yes yes
chmod 0644 -- "$ROOT/etc/borg-backup/ssh/keys/key-mode"
test_command_rc 2 "chave privada de replicação exige modo 0600" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
test_configure_replication_destination "$ROOT" 10-hosts.conf hosts-mode backup.example.invalid yes yes
chmod 0644 -- "$ROOT/etc/borg-backup/ssh/known_hosts"
test_command_rc 2 "known_hosts dedicado exige modo 0640" \
    test_run_entrypoint "$ROOT" validate
chmod 0640 -- "$ROOT/etc/borg-backup/ssh/known_hosts"

test_write_valid_configuration "$ROOT"
find -P "$ROOT/etc/borg-backup/replication.d" -type f -name '*.conf' -delete
test_configure_sqlite "$ROOT" active
sed -i '/database\.sqlite3-wal/d' "$ROOT/etc/borg-backup/excludes.conf"
test_command_rc 2 "SQLite vivo exige exclusões de banco, WAL e SHM" \
    test_run_entrypoint "$ROOT" validate

test_write_valid_configuration "$ROOT"
"$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 2 &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e $ROOT/lock-ready ]] && break
    sleep 0.1
done
test_command_rc 2 "segunda instância é recusada pelo flock" \
    "$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 0
wait "$holder_pid"
test_command_rc 0 "lock é liberado após saída normal" \
    "$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 0

find -P "$ROOT" -name lock-ready -delete
"$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 10 &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e $ROOT/lock-ready ]] && break
    sleep 0.1
done
kill -TERM "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
test_command_rc 0 "lock é liberado após sinal" \
    "$PROJECT_ROOT/tests/helpers/lock-probe.sh" "$ROOT" 0

test_finish
