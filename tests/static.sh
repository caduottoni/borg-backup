#!/bin/bash
# Finalidade: verificar sintaxe, disciplina Bash e superfície pública básica.
# Entradas: código, testes, fixtures, exemplos e tooling deste repositório.
# Saídas: protocolo TAP-like com uma asserção por contrato estático.
# Efeitos colaterais: nenhum; todos os comandos são de leitura.
# Dependências: Bash, find, awk, grep, stat e coreutils do Debian 13.
# Privilégios: usuário comum; nenhuma consulta exige acesso administrativo.
# Códigos: 0 sem violações; 1 quando um requisito estático falha.
# Sigilo: procura padrões proibidos sem imprimir valores encontrados.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT=$(readlink -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
source "$PROJECT_ROOT/tests/lib/testlib.sh"
TEST_PROJECT_ROOT=$PROJECT_ROOT

mapfile -d '' scripts < <(
    find "$PROJECT_ROOT/src/usr/local" "$PROJECT_ROOT/tests" \
        "$PROJECT_ROOT/fixtures/bin" "$PROJECT_ROOT/packaging" \
        -path "$PROJECT_ROOT/packaging/work" -prune -o \
        -type f \( -name '*.sh' -o -path '*/sbin/borg-backup' \
        -o -path '*/fixtures/bin/*' \) -print0 | sort -z
)

syntax_ok=yes
headers_ok=yes
functions_ok=yes
for script in "${scripts[@]}"; do
    bash -n "$script" || syntax_ok=no
    [[ $(head -n 1 -- "$script") == '#!/bin/bash' ]] || headers_ok=no
    for header in Finalidade Entradas Saídas 'Efeitos colaterais' Dependências Privilégios Códigos Sigilo; do
        grep -q "^# $header:" "$script" || headers_ok=no
    done
    if ! awk '
        /^[[:space:]]*#/ { previous_comment=1; next }
        /^[[:space:]]*$/ { next }
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
            if (!previous_comment) exit 1
        }
        { previous_comment=0 }
    ' "$script"; then
        functions_ok=no
    fi
done
[[ $syntax_ok == yes ]] && test_record ok "todos os scripts passam por bash -n" || test_record "not ok" "todos os scripts passam por bash -n"
[[ $headers_ok == yes ]] && test_record ok "todos os scripts documentam o contrato obrigatório" || test_record "not ok" "todos os scripts documentam o contrato obrigatório"
[[ $functions_ok == yes ]] && test_record ok "todas as funções possuem comentário imediatamente anterior" || test_record "not ok" "todas as funções possuem comentário imediatamente anterior"

if awk '
    /^[[:space:]]*#/ { next }
    /(^|[[:space:]])eval([[:space:]]|$)/ { exit 1 }
' "${scripts[@]}"; then
    test_record ok "nenhuma linha ativa usa eval"
else
    test_record "not ok" "nenhuma linha ativa usa eval"
fi

if awk '
    /^[[:space:]]*#/ { next }
    /(source|\.)[[:space:]].*\.conf([[:space:]"\047]|$)/ { exit 1 }
' "${scripts[@]}"; then
    test_record ok "configurações nunca são carregadas como shell"
else
    test_record "not ok" "configurações nunca são carregadas como shell"
fi

if grep -R -E -- '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----' \
    "$PROJECT_ROOT/src" "$PROJECT_ROOT/examples" "$PROJECT_ROOT/fixtures" \
    "$PROJECT_ROOT/tests" >/dev/null 2>&1; then
    test_record "not ok" "nenhuma chave privada integra o repositório"
else
    test_record ok "nenhuma chave privada integra o repositório"
fi

forbidden_names=$(find "$PROJECT_ROOT" \
    \( -path "$PROJECT_ROOT/packaging/work" -o -path "$PROJECT_ROOT/test-runtime" \) \
    -prune -o -type f \
    \( -name secrets.conf -o -name known_hosts -o -name '*.key' -o -name '.env' \) \
    -print -quit)
[[ -z $forbidden_names ]] \
    && test_record ok "nenhum arquivo de credencial ativa está presente" \
    || test_record "not ok" "nenhum arquivo de credencial ativa está presente"

examples_ok=yes
for config in applications backup databases excludes replication services sources secrets; do
    [[ -f $PROJECT_ROOT/examples/etc/borg-backup/$config.conf.example ]] || examples_ok=no
done
[[ -f $PROJECT_ROOT/examples/etc/borg-backup/ssh/known_hosts.example ]] || examples_ok=no
[[ -f $PROJECT_ROOT/examples/etc/borg-backup/replication.d/10-destination.conf.example ]] || examples_ok=no
[[ $examples_ok == yes ]] \
    && test_record ok "todos os modelos públicos usam extensão .example" \
    || test_record "not ok" "todos os modelos públicos usam extensão .example"

comments_ok=yes
while IFS= read -r -d '' config; do
    if ! awk '
        /^[[:space:]]*#/ { previous_comment=1; next }
        /^[[:space:]]*$/ { next }
        { if (!previous_comment) exit 1; previous_comment=0 }
    ' "$config"; then
        comments_ok=no
    fi
done < <(find "$PROJECT_ROOT/examples/etc/borg-backup" -type f -name '*.example' -print0 | sort -z)
[[ $comments_ok == yes ]] \
    && test_record ok "toda declaração modelo possui comentário administrativo" \
    || test_record "not ok" "toda declaração modelo possui comentário administrativo"

version=$(tr -d '\n' <"$PROJECT_ROOT/VERSION")
runtime_version=$(sed -n 's/^declare -gr BB_VERSION="\([^"]*\)"$/\1/p' \
    "$PROJECT_ROOT/src/usr/local/lib/borg-backup/common.sh")
[[ $version == 1.0.2 && $runtime_version == "$version" ]] \
    && test_record ok "VERSION e runtime declaram 1.0.2" \
    || test_record "not ok" "VERSION e runtime declaram 1.0.2"

types_ok=yes
while IFS= read -r -d '' entry; do
    [[ -f $entry || -d $entry ]] || types_ok=no
done < <(find "$PROJECT_ROOT" -not -path "$PROJECT_ROOT/test-runtime*" -print0)
[[ $types_ok == yes ]] \
    && test_record ok "a árvore pública contém somente arquivos e diretórios" \
    || test_record "not ok" "a árvore pública contém somente arquivos e diretórios"

test_finish
