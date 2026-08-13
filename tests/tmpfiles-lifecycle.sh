#!/bin/bash
# Finalidade: validar o lifecycle de /run/borg-backup definido por tmpfiles.d.
# Entradas: regra, unit e instalação sintética versionadas no workspace.
# Saídas: protocolo TAP-like com criação, idempotência e recusa de desvios.
# Efeitos colaterais: recria somente test-runtime/tmpfiles-lifecycle.
# Dependências: Bash, coreutils, systemd-tmpfiles e systemd-analyze.
# Privilégios: usuário comum; UID/GID numéricos são usados na raiz controlada.
# Códigos: 0 quando todos os contratos passam; 1 em regressão.
# Sigilo: a configuração usa exclusivamente marcadores sintéticos do harness.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT
ROOT="$PROJECT_ROOT/test-runtime/tmpfiles-lifecycle"

# Prepara a raiz sintética e remove somente o runtime que tmpfiles deve recriar.
# Parâmetros: nenhum.
# Resultado: configuração válida com /run/borg-backup inicialmente ausente.
prepare_case() {
    test_reset_root "$ROOT"
    test_stage_installation "$ROOT"
    test_write_valid_configuration "$ROOT"
    mkdir -p -- "$ROOT/etc/systemd/system"
    install -m 0644 -- "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.service" \
        "$ROOT/etc/systemd/system/borg-backup.service"
    install -m 0644 -- "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.timer" \
        "$ROOT/etc/systemd/system/borg-backup.timer"
    # A raiz alternativa não consulta os targets do host. Targets sintéticos
    # mínimos permitem resolver dependências sem alterar as units testadas.
    for target in sysinit.target basic.target timers.target network-online.target local-fs.target; do
        {
            printf '[Unit]\n'
            printf 'Description=Target sintético para verificação offline\n'
        } >"$ROOT/etc/systemd/system/$target"
        chmod 0644 -- "$ROOT/etc/systemd/system/$target"
    done
    find -P "$ROOT/run/borg-backup" -depth -delete
    # A raiz alternativa não possui banco de usuários; IDs numéricos permitem
    # provar criação e modos sem chown privilegiado nem alterar o host.
    sed "s/ root root / $(id -u) $(id -g) /" \
        "$PROJECT_ROOT/src/usr/local/lib/tmpfiles.d/borg-backup.conf" \
        >"$ROOT/usr/local/lib/tmpfiles.d/borg-backup.conf"
    chmod 0644 -- "$ROOT/usr/local/lib/tmpfiles.d/borg-backup.conf"
}

# Aplica somente a regra Borg na raiz controlada.
# Parâmetros: nenhum.
# Resultado: propaga o código do parser oficial de tmpfiles.
apply_tmpfiles() {
    systemd-tmpfiles --create --root="$ROOT" borg-backup.conf
}

prepare_case
[[ ! -e $ROOT/run/borg-backup && ! -L $ROOT/run/borg-backup ]] \
    && test_record ok "runtime está ausente antes de tmpfiles" \
    || test_record "not ok" "runtime está ausente antes de tmpfiles"
test_command_rc 0 "tmpfiles cria o runtime na raiz controlada" apply_tmpfiles
[[ -d $ROOT/run/borg-backup && ! -L $ROOT/run/borg-backup ]] \
    && test_record ok "runtime criado é diretório real" \
    || test_record "not ok" "runtime criado é diretório real"
test_equals "$(id -un):$(id -gn) 750" \
    "$(stat -c '%U:%G %a' -- "$ROOT/run/borg-backup")" \
    "owner, grupo e modo do runtime são exatos"

printf 'synthetic-marker\n' >"$ROOT/run/borg-backup/idempotence.marker"
test_command_rc 0 "segunda aplicação de tmpfiles é idempotente" apply_tmpfiles
[[ -f $ROOT/run/borg-backup/idempotence.marker ]] \
    && test_record ok "idempotência não remove estado volátil existente" \
    || test_record "not ok" "idempotência não remove estado volátil existente"

test_command_rc 0 "validate funciona depois da criação por tmpfiles" \
    test_run_entrypoint "$ROOT" validate

chmod 0755 -- "$ROOT/run/borg-backup"
test_command_rc 2 "validate recusa modo incorreto no runtime" \
    test_run_entrypoint "$ROOT" validate
chmod 0750 -- "$ROOT/run/borg-backup"

find -P "$ROOT/run/borg-backup" -depth -delete
mkdir -m 0700 -- "$ROOT/control-outside"
printf 'preserve\n' >"$ROOT/control-outside/sentinel"
ln -s -- "$ROOT/control-outside" "$ROOT/run/borg-backup"
test_command_rc 2 "validate recusa runtime simbólico" \
    test_run_entrypoint "$ROOT" validate
[[ -f $ROOT/control-outside/sentinel ]] \
    && test_record ok "alvo do symlink recusado permanece intacto" \
    || test_record "not ok" "alvo do symlink recusado permanece intacto"

test_command_rc 0 "systemd analisa service e timer distribuídos" \
    systemd-analyze verify --root="$ROOT" \
    /etc/systemd/system/borg-backup.service \
    /etc/systemd/system/borg-backup.timer

test_finish
