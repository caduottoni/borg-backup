#!/bin/bash
# Finalidade: executar sequencialmente toda a suíte controlada do harness público.
# Entradas: scripts de teste versionáveis e fixtures sintéticas do workspace.
# Saídas: cabeçalho por suíte, seus asserts TAP-like e resumo final simples.
# Efeitos colaterais: recria somente subárvores descartáveis em test-runtime/.
# Dependências: Bash e as dependências normativas disponíveis, sem instalação.
# Privilégios: usuário comum; a execução como root é recusada pelo código alvo.
# Códigos: 0 quando todas as suítes passam e 1 se ao menos uma falhar.
# Sigilo: os casos usam apenas valores sintéticos e não abrem conexões externas.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export LANG=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
declare -a suites=(
    static.sh
    checkpoint-01.sh
    tmpfiles-lifecycle.sh
    runtime-lifecycle.sh
    checkpoint-02.sh
    checkpoint-03.sh
    postgresql-restore.sh
    sqlite-restore.sh
    artifacts.sh
)
aggregate=0

for suite in "${suites[@]}"; do
    printf '# suite: %s\n' "$suite"
    if "$PROJECT_ROOT/tests/$suite"; then
        printf '# resultado: %s OK\n' "$suite"
    else
        printf '# resultado: %s FAILED\n' "$suite"
        aggregate=1
    fi
done

if (( aggregate == 0 )); then
    printf '# suíte completa: OK\n'
else
    printf '# suíte completa: FAILED\n'
fi
exit "$aggregate"
