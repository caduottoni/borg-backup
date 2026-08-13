#!/bin/bash
# Finalidade: fornecer asserts e preparação repetível ao harness do harness público.
# Entradas: caminho do projeto e nomes de casos definidos pelos testes.
# Saídas: linhas TAP-like simples e contadores globais de sucesso/falha.
# Efeitos colaterais: cria ou remove somente raízes descartáveis validadas sob
# `test-runtime/`; nunca toca caminhos operacionais reais.
# Dependências: Bash e ferramentas básicas disponíveis no Debian 13.
# Privilégios: usuário comum; execução como root é recusada pelos scripts alvo.
# Códigos: os testes consumidores encerram com 0 quando todos os asserts passam.
# Sigilo: fixtures usam apenas marcadores sintéticos e nunca credenciais reais.

set -Eeuo pipefail
umask 077

declare -g TEST_COUNT=0
declare -g TEST_FAILURES=0
declare -g TEST_PROJECT_ROOT=""

# Registra resultado individual sem interromper os casos seguintes.
# Parâmetros: `ok`/`not ok` e descrição humana.
# Resultado: atualiza contadores e escreve uma linha.
test_record() {
    local result=$1 description=$2
    ((TEST_COUNT += 1))
    if [[ $result == "ok" ]]; then
        printf 'ok %d - %s\n' "$TEST_COUNT" "$description"
    else
        ((TEST_FAILURES += 1))
        printf 'not ok %d - %s\n' "$TEST_COUNT" "$description"
    fi
}

# Compara valor observado e esperado sem exibir conteúdo sensível.
# Parâmetros: esperado, observado e descrição.
# Resultado: registra o assert e sempre retorna 0 para continuar a suíte.
test_equals() {
    local expected=$1 actual=$2 description=$3
    if [[ $actual == "$expected" ]]; then
        test_record ok "$description"
    else
        test_record "not ok" "$description (esperado=$expected observado=$actual)"
    fi
}

# Executa comando e compara somente seu código de saída.
# Parâmetros: código esperado, descrição e comando/argumentos restantes.
# Resultado: registra o assert, preservando stdout/stderr no arquivo indicado
# pelo próprio chamador quando necessário.
test_command_rc() {
    local expected=$1 description=$2
    shift 2
    local actual
    if "$@"; then
        actual=0
    else
        actual=$?
    fi
    test_equals "$expected" "$actual" "$description"
}

# Remove uma raiz de caso somente depois de confirmar seu limite canônico.
# Parâmetros: caminho absoluto sob test-runtime.
# Resultado: raiz ausente ao final; recusa qualquer caminho amplo.
test_reset_root() {
    local root=$1 runtime_parent
    runtime_parent=$(readlink -m -- "$TEST_PROJECT_ROOT/test-runtime")
    [[ $(readlink -m -- "$root") == "$runtime_parent"/* ]] || {
        printf 'raiz de teste insegura: %s\n' "$root" >&2
        return 2
    }
    if [[ -e $root || -L $root ]]; then
        find -P "$root" -depth -delete
    fi
    mkdir -p -- "$root"
    chmod 0700 -- "$root"
}

# Instala uma cópia descartável dos artefatos sob uma raiz sintética.
# Parâmetros: raiz do caso.
# Resultado: árvore FHS simulada e diretórios de runtime privados.
test_stage_installation() {
    local root=$1 config example
    mkdir -p -- "$root/etc" "$root/usr/local" "$root/var/lib/borg-backup/state" \
        "$root/var/log/borg-backup" "$root/var/tmp/borg-backup" \
        "$root/run/borg-backup" "$root/srv/borg-storage/repositories/lab/repo" \
        "$root/test-bin" "$root/etc/borg-backup/replication.d" \
        "$root/etc/borg-backup/ssh/keys"
    for config in applications backup databases excludes replication services sources; do
        example="$TEST_PROJECT_ROOT/examples/etc/borg-backup/$config.conf.example"
        install -m 0640 -- "$example" "$root/etc/borg-backup/$config.conf"
    done
    install -m 0600 -- \
        "$TEST_PROJECT_ROOT/examples/etc/borg-backup/secrets.conf.example" \
        "$root/etc/borg-backup/secrets.conf"
    install -m 0640 -- \
        "$TEST_PROJECT_ROOT/examples/etc/borg-backup/ssh/known_hosts.example" \
        "$root/etc/borg-backup/ssh/known_hosts"
    cp -a -- "$TEST_PROJECT_ROOT/src/usr/local/sbin" "$root/usr/local/"
    cp -a -- "$TEST_PROJECT_ROOT/src/usr/local/lib" "$root/usr/local/"
    cp -a -- "$TEST_PROJECT_ROOT/fixtures/bin/." "$root/test-bin/"
    chmod 0750 -- "$root/etc/borg-backup" "$root/etc/borg-backup/replication.d"
    chmod 0700 -- "$root/etc/borg-backup/ssh" "$root/etc/borg-backup/ssh/keys"
    chmod 0750 -- "$root/var/lib/borg-backup" "$root/var/lib/borg-backup/state" \
        "$root/var/log/borg-backup" "$root/run/borg-backup"
    chmod 0700 -- "$root/var/tmp/borg-backup"
    chmod 0755 -- "$root/usr/local/sbin/borg-backup" "$root/test-bin"/*
}

# Escreve a menor configuração válida do laboratório, toda ela comentada.
# Parâmetros: raiz do caso.
# Resultado: arquivos declarativos sintéticos com modos compatíveis.
test_write_valid_configuration() {
    local root=$1 config="$1/etc/borg-backup"
    cat >"$config/backup.conf" <<'EOF'
# Repositório sintético restrito à raiz controlada.
BORG_REPOSITORY=/srv/borg-storage/repositories/lab/repo
# Prefixo sintético e portátil.
ARCHIVE_PREFIX=lab
# Compressão normativa.
BORG_COMPRESSION=auto,zstd,3
# Retenção diária normativa.
KEEP_DAILY=14
# Retenção semanal normativa.
KEEP_WEEKLY=8
# Retenção mensal normativa.
KEEP_MONTHLY=12
# UUID fornecido pelo double de findmnt.
REPOSITORY_FILESYSTEM_UUID=11111111-1111-1111-1111-111111111111
# Filesystem permitido.
REPOSITORY_FILESYSTEM_TYPE=ext4
# Identificador esperado na sentinela sintética.
REPOSITORY_STORAGE_ID=lab
# Espaço mínimo reduzido somente para laboratório.
REPOSITORY_MIN_FREE_MIB=16
# Sentinela sintética na raiz do mount representado.
REPOSITORY_SENTINEL=/srv/borg-storage/.borg-storage
# Log em arquivo permite validar observabilidade controlada.
FILE_LOG_ENABLED=yes
EOF
    cat >"$config/sources.conf" <<'EOF'
# Fonte sintética existente dentro da raiz controlada.
/etc
EOF
    cat >"$config/excludes.conf" <<'EOF'
# Exclui o repositório sintético.
/srv/borg-storage/repositories/lab/repo
# Exclui temporários da rotina.
/var/tmp/borg-backup
# Exclui a passphrase.
/etc/borg-backup/secrets.conf
# Exclui chaves privadas de replicação.
/etc/borg-backup/ssh/keys
EOF
    cat >"$config/databases.conf" <<'EOF'
# Nenhum banco é necessário ao caso básico de configuração.
EOF
    cat >"$config/applications.conf" <<'EOF'
# Nenhuma aplicação é necessária ao caso básico de configuração.
EOF
    cat >"$config/services.conf" <<'EOF'
# Nenhum serviço é necessário ao caso básico de configuração.
EOF
    cat >"$config/replication.conf" <<'EOF'
# A replicação básica permanece desabilitada neste checkpoint.
REPLICATION_ENABLED=no
# A origem deve coincidir com o repositório principal.
REPLICATION_SOURCE=/srv/borg-storage/repositories/lab/repo
# Único modo autorizado.
REPLICATION_VERIFY_MODE=basic
# Espaço remoto mínimo sintético em MiB.
REPLICATION_MIN_FREE_MIB=16
EOF
    cat >"$config/secrets.conf" <<'EOF'
# Marcador sintético sem qualquer credencial real.
BORG_PASSPHRASE=test-only-synthetic-passphrase
EOF
    {
        printf 'STORAGE_ID=lab\n'
        printf 'PURPOSE=borg-backup\n'
    } >"$root/srv/borg-storage/.borg-storage"
    chmod 0640 -- "$config/backup.conf" "$config/sources.conf" \
        "$config/excludes.conf" "$config/databases.conf" \
        "$config/applications.conf" "$config/services.conf" \
        "$config/replication.conf"
    chmod 0600 -- "$config/secrets.conf"
    chmod 0640 -- "$root/srv/borg-storage/.borg-storage"
}

# Acrescenta um destino sintético totalmente declarado para testes de parser.
# Parâmetros: raiz, nome do arquivo, ID, habilitação e obrigatoriedade.
# Resultado: arquivo modo 0640; nenhum endpoint é acessado neste checkpoint.
test_write_destination_configuration() {
    local root=$1 filename=$2 id=$3 enabled=$4 required=$5
    local host=${6:-"backup.example.invalid"}
    local destination=${7:-"/srv/borg-storage/replicas/$filename"}
    local remote_user=${8:-"replica-receiver-a"}
    local config="$root/etc/borg-backup/replication.d/$filename"
    cat >"$config" <<EOF
# Identificador sintético deste destino.
REPLICATION_ID=$id
# Habilitação individual controlada pelo caso.
REPLICATION_ENABLED=$enabled
# Severidade individual controlada pelo caso.
REPLICATION_REQUIRED=$required
# Host reservado exclusivamente à documentação/teste.
REPLICATION_HOST=$host
# Conta técnica sintética; representa a direção origem A para destino B.
REPLICATION_USER=$remote_user
# Porta SSH convencional.
REPLICATION_SSH_PORT=22
# Raiz remota sintética dedicada.
REPLICATION_DESTINATION=$destination
# Chave sintética que só seria exigida se o destino estivesse habilitado.
REPLICATION_IDENTITY_FILE=/etc/borg-backup/ssh/keys/$id
# Base sintética de host keys.
REPLICATION_KNOWN_HOSTS_FILE=/etc/borg-backup/ssh/known_hosts
# Modo fechado autorizado.
REPLICATION_VERIFY_MODE=basic
EOF
    chmod 0640 -- "$config"
}

# Cria estrutura mínima de repositório Borg para testes rápidos de replicação.
# Parâmetros: raiz do caso.
# Resultado: config, data e index sintéticos sob o repositório declarado.
test_make_synthetic_borg_repository() {
    local root=$1 repository="$1/srv/borg-storage/repositories/lab/repo"
    mkdir -p -- "$repository/data/0"
    printf 'repository-format-synthetic\n' >"$repository/config"
    printf 'index-synthetic\n' >"$repository/index.1"
    printf 'segment-synthetic\n' >"$repository/data/0/1"
    chmod 0600 -- "$repository/config" "$repository/index.1" "$repository/data/0/1"
}

# Declara e provisiona somente um destino remoto sintético do harness público.
# Parâmetros: raiz, arquivo, ID, host, obrigatoriedade, habilitação e conta
# remota opcional.
# Resultado: configuração, chave/host key marcadoras e raiz remota controlada.
test_configure_replication_destination() {
    local root=$1 filename=$2 id=$3 host=$4 required=$5 enabled=$6
    local remote_user=${7:-"replica-receiver-a"}
    local config="$root/etc/borg-backup" destination="/srv/borg-storage/replicas/lab"
    sed -i 's|REPLICATION_ENABLED=no|REPLICATION_ENABLED=yes|' "$config/replication.conf"
    test_write_destination_configuration "$root" "$filename" "$id" "$enabled" "$required" "$host" "$destination" "$remote_user"
    printf '%s\n' '# Synthetic private-key marker; not a cryptographic key.' >"$config/ssh/keys/$id"
    chmod 0600 -- "$config/ssh/keys/$id"
    {
        printf '# Synthetic host key fixture for %s.\n' "$id"
        printf '%s ssh-ed25519 AAAAC3NzaSyntheticOnly%s\n' "$host" "$id"
    } >>"$config/ssh/known_hosts"
    chmod 0640 -- "$config/ssh/known_hosts"
    mkdir -p -- "$root/remotes/$host/srv/borg-storage/replicas/lab"
    chmod 0750 -- "$root/remotes/$host/srv/borg-storage/replicas/lab"
    {
        printf 'STORAGE_ID=lab-receiver\n'
        printf 'PURPOSE=borg-backup\n'
    } >"$root/remotes/$host/srv/borg-storage/.borg-storage"
    chmod 0640 -- "$root/remotes/$host/srv/borg-storage/.borg-storage"
    printf '%s\n' "$destination" >"$root/control/remote-$host.destination"
}

# Invoca o receptor staged como se fosse um comando forçado SSH.
# Parâmetros: raiz do caso, host configurado e comando remoto literal.
# Resultado: propaga stdout/código do receptor, sempre no modo controlado.
test_receiver_command() {
    local root=$1 host=$2 remote_command=$3
    local storage_id=${4:-"lab-receiver"}
    local filesystem_uuid=${5:-"11111111-1111-1111-1111-111111111111"}
    local destination receiver_root sentinel
    destination=$(<"$root/control/remote-$host.destination")
    receiver_root="$root/remotes/$host$destination"
    sentinel="$root/remotes/$host/srv/borg-storage/.borg-storage"
    BB_BOOTSTRAP_TEST_ROOT="$root" \
    BB_RECEIVER_TEST_MODE=yes \
    BB_RECEIVER_TEST_BIN="$root/test-bin" \
    SSH_ORIGINAL_COMMAND="$remote_command" \
        "$root/usr/local/lib/borg-backup/replica-receiver.sh" \
        --root "$receiver_root" \
        --origin lab \
        --sentinel "$sentinel" \
        --storage-id "$storage_id" \
        --filesystem-uuid "$filesystem_uuid" \
        --min-free-mib 16
}

# Cria uma geração marcada válida exclusivamente para testes do receptor.
# Parâmetros: raiz, host, nome de geração e ID de execução seguro.
# Resultado: cópia sintética de repo e generation.meta consistente.
test_create_receiver_generation() {
    local root=$1 host=$2 generation_name=$3 execution=$4 destination receiver_root generation count bytes
    destination=$(<"$root/control/remote-$host.destination")
    receiver_root="$root/remotes/$host$destination"
    generation="$receiver_root/$generation_name"
    mkdir -p -- "$generation/repo"
    cp -a -- "$root/srv/borg-storage/repositories/lab/repo/." "$generation/repo/"
    count=$(find -P "$generation/repo" -type f | wc -l)
    bytes=$(find -P "$generation/repo" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
    cat >"$generation/generation.meta" <<EOF
FORMAT=BORG-REPLICA-GENERATION-V1
ORIGIN=lab
EXECUTION_ID=$execution
STATUS=VALID
FILE_COUNT=$count
FILE_BYTES=$bytes
TIMESTAMP_UTC=2026-08-07T00:00:00Z
EOF
    chmod 0750 -- "$generation"
    chmod 0640 -- "$generation/generation.meta"
}

# Registra token VALIDATED necessário para testar somente a promoção.
# Parâmetros: raiz, host e execução do incoming.
# Resultado: active.state literal sob a raiz dedicada.
test_write_receiver_active_validated() {
    local root=$1 host=$2 execution=$3 destination receiver_root
    destination=$(<"$root/control/remote-$host.destination")
    receiver_root="$root/remotes/$host$destination"
    mkdir -p -- "$receiver_root/state"
    cat >"$receiver_root/state/active.state" <<EOF
FORMAT=RECEIVER-ACTIVE-V1
ORIGIN=lab
EXECUTION_ID=$execution
STATUS=VALIDATED
EOF
    chmod 0640 -- "$receiver_root/state/active.state"
}

# Declara PostgreSQL sintético local e cria somente o diretório de socket fixture.
# Parâmetros: raiz do caso.
# Resultado: databases.conf com banco e globais, integralmente comentado.
test_configure_postgresql() {
    local root=$1 config="$1/etc/borg-backup" database_user
    database_user=$(id -un)
    mkdir -p -- "$root/var/run/postgresql"
    cat >"$config/databases.conf" <<EOF
# Banco PostgreSQL local sintético.
postgresql|pg-app|appdb|$database_user|/var/run/postgresql|5432
# Objetos globais do cluster sintético.
postgresql-globals|pg-cluster|$database_user|/var/run/postgresql|5432
EOF
    chmod 0640 -- "$config/databases.conf"
}

# Declara SQLite sintético, unit independente e exclusões obrigatórias.
# Parâmetros: raiz e estado inicial (`active` ou `inactive`).
# Resultado: banco fixture, configuração comentada e estado systemd controlado.
test_configure_sqlite() {
    local root=$1 initial_state=$2 config="$1/etc/borg-backup"
    [[ $initial_state == "active" || $initial_state == "inactive" ]] || return 2
    mkdir -p -- "$root/srv/sqlite-app" "$root/control/services"
    printf 'SQLITE-LIVE-SYNTHETIC\n' >"$root/srv/sqlite-app/database.sqlite3"
    cat >"$config/databases.conf" <<'EOF'
# Banco SQLite vivo sintético; somente o dump lógico entra no archive.
sqlite|sqlite-app|/srv/sqlite-app/database.sqlite3
EOF
    cat >"$config/services.conf" <<'EOF'
# A unit sintética permanece parada por toda a janela crítica do archive.
sqlite-app.service
EOF
    cat >>"$config/excludes.conf" <<'EOF'
# Exclui o banco SQLite vivo.
/srv/sqlite-app/database.sqlite3
# Exclui o WAL SQLite vivo.
/srv/sqlite-app/database.sqlite3-wal
# Exclui a memória compartilhada SQLite viva.
/srv/sqlite-app/database.sqlite3-shm
EOF
    printf '%s\n' "$initial_state" >"$root/control/services/sqlite-app.service.state"
    chmod 0640 -- "$config/databases.conf" "$config/services.conf" "$config/excludes.conf"
}

# Declara Nextcloud e BIND sintéticos com usuário local explícito.
# Parâmetros: raiz e usuário existente no host de teste.
# Resultado: diretórios/occ fixtures e applications.conf comentado.
test_configure_applications() {
    local root=$1 application_user=$2 config="$1/etc/borg-backup"
    mkdir -p -- "$root/srv/cloud-app" "$root/var/lib/bind-synthetic" "$root/control"
    printf '%s\n' '<?php // Synthetic occ fixture; never executed directly.' >"$root/srv/cloud-app/occ"
    cat >"$config/applications.conf" <<EOF
# Nextcloud sintético controlado pelo double runuser.
nextcloud|cloud-app|/srv/cloud-app|$application_user
# BIND sintético sincronizado online pelo mesmo double.
bind|bind-app|/var/lib/bind-synthetic|$application_user
EOF
    chmod 0640 -- "$config/applications.conf"
    printf 'disabled\n' >"$root/control/nextcloud.state"
}

# Extrai valor de um relatório pontilhado sem executar seu conteúdo.
# Parâmetros: arquivo e chave exata.
# Resultado: imprime o último campo textual da linha correspondente.
test_report_value() {
    local report=$1 key=$2
    awk -v wanted="$key" '{ label=$1; sub(/\.+$/, "", label); if (label == wanted) { print $2; found=1 } } END { if (!found) exit 1 }' "$report"
}

# Executa o ponto de entrada com ambiente controlado e raiz explícita.
# Parâmetros: raiz, operação e argumentos adicionais opcionais.
# Resultado: propaga exatamente o código da interface administrativa.
test_run_entrypoint() {
    local root=$1
    shift
    env -i \
        HOME="$HOME" \
        BORG_BACKUP_TEST_MODE=yes \
        BORG_BACKUP_TEST_ROOT="$root" \
        BORG_BACKUP_TEST_BIN="$root/test-bin" \
        "$root/usr/local/sbin/borg-backup" "$@"
}

# Finaliza a suíte com resumo e código convencional de teste.
# Parâmetros: nenhum.
# Resultado: 0 sem falhas; 1 caso algum assert tenha falhado.
test_finish() {
    printf '1..%d\n' "$TEST_COUNT"
    if (( TEST_FAILURES > 0 )); then
        printf '# falhas: %d\n' "$TEST_FAILURES"
        return 1
    fi
    printf '# todos os %d testes passaram\n' "$TEST_COUNT"
}
