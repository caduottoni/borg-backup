#!/bin/bash
# Finalidade: validar integração, documentação, portabilidade e superfície pública.
# Entradas: artefatos versionáveis exclusivamente dentro deste repositório.
# Saídas: protocolo TAP-like com uma asserção por contrato inspecionado.
# Efeitos colaterais: nenhum; não instala, publica, ativa timer ou usa rede.
# Dependências: Bash, awk, grep, find, stat e a biblioteca local de testes.
# Privilégios: usuário comum; nenhuma consulta exige acesso administrativo.
# Códigos: 0 quando todos os contratos passam; 1 diante de divergência.
# Sigilo: verifica padrões proibidos sem imprimir conteúdo potencialmente sensível.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT

# Retorna somente diretivas ativas, preservando seções e ordem normativa.
# Parâmetros: arquivo de configuração textual.
# Resultado: stdout normalizado, sem comentários ou linhas vazias.
active_configuration() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }
    ' "$1"
}

service_expected=$'[Unit]\nDescription=Rotina diária de backup Borg\nWants=network-online.target\nAfter=network-online.target local-fs.target\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/borg-backup run\nTimeoutStartSec=infinity\nSuccessExitStatus=0 1'
timer_expected=$'[Unit]\nDescription=Agendamento diário da rotina Borg Backup\n[Timer]\nOnCalendar=daily\nPersistent=true\nRandomizedDelaySec=30m\n[Install]\nWantedBy=timers.target'
logrotate_expected=$'/var/log/borg-backup/backup.log {\nweekly\nrotate 12\ncompress\ndelaycompress\nmissingok\nnotifempty\ncreate 0640 root root\n}'

test_equals "$service_expected" "$(active_configuration "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.service")" \
    "service oneshot contém somente integração normativa"
test_equals "$timer_expected" "$(active_configuration "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.timer")" \
    "timer diário persistente aplica jitter de trinta minutos"
test_equals "$logrotate_expected" "$(active_configuration "$PROJECT_ROOT/src/etc/logrotate.d/borg-backup")" \
    "logrotate reproduz política semanal de doze rotações"
test_equals 'd /run/borg-backup 0750 root root -' \
    "$(active_configuration "$PROJECT_ROOT/src/usr/local/lib/tmpfiles.d/borg-backup.conf")" \
    "tmpfiles recria o runtime volátil com owner e modo normativos"

integration_checkout_modes=yes
for artifact in \
    "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.service" \
    "$PROJECT_ROOT/src/etc/systemd/system/borg-backup.timer" \
    "$PROJECT_ROOT/src/etc/logrotate.d/borg-backup" \
    "$PROJECT_ROOT/src/usr/local/lib/tmpfiles.d/borg-backup.conf"; do
    [[ -f $artifact && ! -L $artifact ]] || integration_checkout_modes=no
    mode=$(stat -c '%a' -- "$artifact")
    (( (8#$mode & 0133) == 0 )) || integration_checkout_modes=no
done
if [[ $integration_checkout_modes == yes ]]; then
    test_record ok "artefatos de integração são regulares e não executáveis no checkout"
else
    test_record "not ok" "artefatos de integração são regulares e não executáveis no checkout"
fi

build_tools=(
    "$PROJECT_ROOT/packaging/build-package.sh"
    "$PROJECT_ROOT/packaging/compare-builds.sh"
    "$PROJECT_ROOT/packaging/validate-package.sh"
)
relocatable_tools=yes
for tool in "${build_tools[@]}"; do
    [[ -x $tool ]] || relocatable_tools=no
    grep -Fq '${BASH_SOURCE[0]}' "$tool" || relocatable_tools=no
done
[[ $relocatable_tools == yes ]] \
    && test_record ok "tooling deriva a raiz de BASH_SOURCE" \
    || test_record "not ok" "tooling deriva a raiz de BASH_SOURCE"

version=$(tr -d '\n' <"$PROJECT_ROOT/VERSION")
runtime_version=$(sed -n 's/^declare -gr BB_VERSION="\([^"]*\)"$/\1/p' \
    "$PROJECT_ROOT/src/usr/local/lib/borg-backup/common.sh")
metadata_version=$(awk -F '\t' '$1 == "PACKAGE_VERSION" { print $2 }' \
    "$PROJECT_ROOT/packaging/templates/PACKAGE-METADATA.tsv.in")
metadata_license=$(awk -F '\t' '$1 == "LICENSE" { print $2 }' \
    "$PROJECT_ROOT/packaging/templates/PACKAGE-METADATA.tsv.in")
[[ $version == 1.0.2 && $runtime_version == "$version" \
    && $metadata_version == '@PACKAGE_VERSION@' && $metadata_license == GPL-3.0-or-later ]] \
    && test_record ok "produto e pacote declaram uma única versão 1.0.2" \
    || test_record "not ok" "produto e pacote declaram uma única versão 1.0.2"

grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$PROJECT_ROOT/LICENSE" \
    && grep -Fq 'Version 3, 29 June 2007' "$PROJECT_ROOT/LICENSE" \
    && grep -Fq 'GPL-3.0-or-later' "$PROJECT_ROOT/NOTICE" \
    && grep -Fq 'GPL-3.0-or-later' "$PROJECT_ROOT/README.md" \
    && test_record ok "licença pública GPL-3.0-or-later está declarada" \
    || test_record "not ok" "licença pública GPL-3.0-or-later está declarada"

documentation_ok=yes
for document in \
    01-OVERVIEW-AND-ARCHITECTURE.md 02-REQUIREMENTS-AND-DEPENDENCIES.md \
    03-FILESYSTEM-LAYOUT-AND-PERMISSIONS.md 04-PACKAGE-LAYOUT-CONTRACT.md \
    05-INSTALLATION.md 06-CONFIGURATION-REFERENCE.md 07-COMMAND-REFERENCE.md \
    08-BACKUP-LIFECYCLE-AND-CONSISTENCY.md 09-DATABASES.md \
    10-SYSTEMD-SCHEDULING-AND-LOGROTATE.md 11-REPLICATION-AND-REMOTE-RECEIVER.md \
    12-SECURITY-AND-SECRET-CUSTODY.md 13-LOGGING-REPORTS-STATE-AND-EXIT-CODES.md \
    14-RESTORE-AND-RECOVERY-VALIDATION.md 15-OPERATIONS-RUNBOOK.md \
    16-TROUBLESHOOTING.md 17-UPGRADE-ROLLBACK-AND-UNINSTALL.md \
    18-POST-DEPLOY-VALIDATION-CHECKLIST.md DOCUMENTATION-MANIFEST.tsv GLOSSARY.md \
    README.md SOURCE-TO-DOCUMENT-MATRIX.md reference/SPECIFICATION.md; do
    [[ -s $PROJECT_ROOT/docs/$document ]] || documentation_ok=no
done
[[ $documentation_ok == yes ]] \
    && test_record ok "documentação pública canônica está presente" \
    || test_record "not ok" "documentação pública canônica está presente"

specification=$PROJECT_ROOT/docs/reference/SPECIFICATION.md
pub_requirements=$(grep -Eo 'PUB-REQ-[0-9]{3}' "$specification" | sort -u | wc -l)
[[ $pub_requirements -ge 20 ]] \
    && test_record ok "especificação pública possui requisitos identificáveis" \
    || test_record "not ok" "especificação pública possui requisitos identificáveis"

installation_document=$PROJECT_ROOT/docs/05-INSTALLATION.md
init_line=$(grep -nF 'Depois de `borg init`' "$installation_document" | cut -d: -f1)
validate_line=$(grep -nF '/usr/local/sbin/borg-backup validate' "$installation_document" | cut -d: -f1)
[[ $init_line =~ ^[0-9]+$ && $validate_line =~ ^[0-9]+$ && $init_line -lt $validate_line ]] \
    && test_record ok "runbook exige borg init antes de validate" \
    || test_record "not ok" "runbook exige borg init antes de validate"

security_document=$PROJECT_ROOT/docs/11-REPLICATION-AND-REMOTE-RECEIVER.md
grep -Fq 'restrict,command="/usr/local/lib/borg-backup/replica-receiver.sh' "$security_document" \
    && grep -Fq '`restrict` desabilita PTY, agent forwarding, port forwarding e X11 forwarding.' "$security_document" \
    && test_record ok "modelo de chave restringe comando e forwardings" \
    || test_record "not ok" "modelo de chave restringe comando e forwardings"

restore_document=$PROJECT_ROOT/docs/14-RESTORE-AND-RECOVERY-VALIDATION.md
grep -Fq 'storage independente' "$restore_document" \
    && grep -Fq '`previous`' "$restore_document" \
    && grep -Fq 'hard links' "$restore_document" \
    && test_record ok "runbook exige recuperação em cópia independente" \
    || test_record "not ok" "runbook exige recuperação em cópia independente"

grep -Fq -- '-o StrictHostKeyChecking=yes' "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replication.sh" \
    && grep -Fq -- '-o BatchMode=yes' "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replication.sh" \
    && grep -Fq -- '-o ClearAllForwardings=yes' "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replication.sh" \
    && test_record ok "transporte SSH usa política estrita e não interativa" \
    || test_record "not ok" "transporte SSH usa política estrita e não interativa"

if ! awk '!/^[[:space:]]*#/' "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replication.sh" | grep -F -- '--inplace' >/dev/null \
    && ! grep -R -F -- 'StrictHostKeyChecking=no' "$PROJECT_ROOT/src/usr/local" >/dev/null; then
    test_record ok "emissor não usa inplace nem desabilita host key"
else
    test_record "not ok" "emissor não usa inplace nem desabilita host key"
fi

grep -Fq -- '-lHtpre.iLsfxCIvu' "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replica-receiver.sh" \
    && grep -Fq -- '-nlHtpre.iLsfxCIvu' "$PROJECT_ROOT/src/usr/local/lib/borg-backup/replica-receiver.sh" \
    && test_record ok "receptor aceita somente os argv rsync necessários" \
    || test_record "not ok" "receptor aceita somente os argv rsync necessários"

if grep -R -E -- '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}' \
    "$PROJECT_ROOT/src" "$PROJECT_ROOT/examples" "$PROJECT_ROOT/fixtures" \
    "$PROJECT_ROOT/docs" >/dev/null 2>&1; then
    test_record "not ok" "superfície pública não contém chave privada ou token"
else
    test_record ok "superfície pública não contém chave privada ou token"
fi

grep -Fq 'REPOSITORY_STORAGE_ID=host-example' "$PROJECT_ROOT/examples/etc/borg-backup/backup.conf.example" \
    && grep -Fq 'REPOSITORY_FILESYSTEM_UUID=00000000-0000-0000-0000-000000000000' "$PROJECT_ROOT/examples/etc/borg-backup/backup.conf.example" \
    && grep -Fq 'REPLICATION_HOST=server-b.example.invalid' "$PROJECT_ROOT/examples/etc/borg-backup/replication.d/10-destination.conf.example" \
    && test_record ok "modelos usam identificadores reservados e inválidos" \
    || test_record "not ok" "modelos usam identificadores reservados e inválidos"

if ! active_configuration "$PROJECT_ROOT/examples/etc/borg-backup/services.conf.example" | grep -Eq '[|;[:space:]]' \
    && grep -Fq 'uma unit systemd por linha' "$PROJECT_ROOT/examples/etc/borg-backup/services.conf.example"; then
    test_record ok "modelo de services contém somente units literais"
else
    test_record "not ok" "modelo de services contém somente units literais"
fi

forbidden_path_count=$(find "$PROJECT_ROOT" -mindepth 1 \
    \( -path "$PROJECT_ROOT/deployment" -o -path "$PROJECT_ROOT/archive" \
    -o -path "$PROJECT_ROOT/dist" -o -path "$PROJECT_ROOT/docs/installations" \
    -o -name host-specific-documentation.sh \) -printf '.' | wc -c)
[[ $forbidden_path_count -eq 0 ]] \
    && test_record ok "nenhuma árvore privada integra a superfície pública" \
    || test_record "not ok" "nenhuma árvore privada integra a superfície pública"

non_public_pattern='/home/[[:alnum:]_.-]+|[[:alnum:].-]+\.(lan|local|internal|net\.br)([^[:alnum:].-]|$)|(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)'
if grep -R -IqiE --exclude-dir=work "$non_public_pattern" \
    "$PROJECT_ROOT/src" "$PROJECT_ROOT/examples" "$PROJECT_ROOT/fixtures" \
    "$PROJECT_ROOT/docs" "$PROJECT_ROOT/packaging"; then
    test_record "not ok" "produto público não contém marcadores privados ou históricos"
else
    test_record ok "produto público não contém marcadores privados ou históricos"
fi

community_ok=yes
for file in README.md LICENSE NOTICE CHANGELOG.md CONTRIBUTING.md SECURITY.md SUPPORT.md \
    CODE_OF_CONDUCT.md DCO VERSION .gitignore .gitattributes; do
    [[ -s $PROJECT_ROOT/$file ]] || community_ok=no
done
[[ $community_ok == yes ]] \
    && test_record ok "arquivos públicos de comunidade e governança estão presentes" \
    || test_record "not ok" "arquivos públicos de comunidade e governança estão presentes"

workflow_ok=yes
if grep -R -E 'pull_request_target|self-hosted' "$PROJECT_ROOT/.github/workflows" >/dev/null; then
    workflow_ok=no
fi
grep -Rq '^permissions:' "$PROJECT_ROOT/.github/workflows" || workflow_ok=no
grep -Rq 'pull_request:' "$PROJECT_ROOT/.github/workflows" || workflow_ok=no
[[ $workflow_ok == yes ]] \
    && test_record ok "workflows públicos usam eventos e runners seguros" \
    || test_record "not ok" "workflows públicos usam eventos e runners seguros"

if ! grep -Fq 'host-specific-documentation.sh' "$PROJECT_ROOT/tests/run-tests.sh"; then
    test_record ok "suíte pública não depende de documentação de host"
else
    test_record "not ok" "suíte pública não depende de documentação de host"
fi

test_finish
