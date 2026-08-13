#!/bin/bash
# Finalidade: delegar listagem, check, retenção e compactação ao Borg nativo.
# Entradas: repositório, prefixo e retenção já validados.
# Saídas: listagem administrativa no stdout e eventos resumidos para operações.
# Efeitos colaterais: prune e compact modificam somente o repositório principal;
# check nunca usa `--repair` nesta versão.
# Dependências: BorgBackup 1.4.x e backup.sh.
# Privilégios: root em produção; repositório descartável em testes.
# Códigos: 0 somente para retorno Borg 0; qualquer outro retorno vira 2.
# Sigilo: saídas integrais ficam em staging/temporário e não incluem passphrase.

set -Eeuo pipefail
umask 077

# Cria arquivo privado para saída sob o staging da execução corrente.
# Parâmetros: nome seguro da operação.
# Resultado: imprime caminho capturado pela limpeza comum e pelo trap.
bb_maintenance_output_file() {
    local operation=$1
    [[ $operation =~ ^[a-z-]+$ ]] || return "$BB_EXIT_CRITICAL"
    [[ -d $BB_EXECUTION_DIR/staging ]] || return "$BB_EXIT_CRITICAL"
    mktemp -- "$BB_EXECUTION_DIR/staging/.borg-$operation.XXXXXX"
}

# Lista somente archives pertencentes ao prefixo deste host.
# Parâmetros: nenhum.
# Resultado: imprime nomes no stdout e retorna 0; falha Borg vira 2.
bb_borg_list_archives() {
    local output_file rc
    output_file=$(bb_maintenance_output_file list) || return "$BB_EXIT_CRITICAL"
    BB_PRIMARY_REPOSITORY_PATH=$(bb_system_path "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}") || return "$BB_EXIT_CRITICAL"
    if bb_borg_command "$output_file" list --format '{archive}{NL}' \
        --glob-archives "${BB_BACKUP_CONFIG[ARCHIVE_PREFIX]}-*" "$BB_PRIMARY_REPOSITORY_PATH"; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
        cat -- "$output_file"
    fi
    find -P "$output_file" -delete 2>/dev/null || true
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
}

# Executa check explícito sem reparo e sem fazer parte do ciclo diário.
# Parâmetros: nenhum.
# Resultado: 0 apenas para repositório íntegro segundo Borg.
bb_borg_check_repository() {
    local output_file rc
    output_file=$(bb_maintenance_output_file check) || return "$BB_EXIT_CRITICAL"
    BB_PRIMARY_REPOSITORY_PATH=$(bb_system_path "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}") || return "$BB_EXIT_CRITICAL"
    if bb_borg_command "$output_file" check "$BB_PRIMARY_REPOSITORY_PATH"; then rc=0; else rc=$?; fi
    find -P "$output_file" -delete 2>/dev/null || true
    bb_log INFO maintenance check-result "borg check concluiu rc=$rc" || return "$BB_EXIT_CRITICAL"
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
}

# Aplica exclusivamente a retenção 14/8/12 ao prefixo configurado.
# Parâmetros: nenhum.
# Resultado: 0 somente para retorno prune 0; compact não é chamado aqui.
bb_borg_prune_repository() {
    local output_file rc
    output_file=$(bb_maintenance_output_file prune) || return "$BB_EXIT_CRITICAL"
    BB_PRIMARY_REPOSITORY_PATH=$(bb_system_path "${BB_BACKUP_CONFIG[BORG_REPOSITORY]}") || return "$BB_EXIT_CRITICAL"
    if bb_borg_command "$output_file" prune \
        --glob-archives "${BB_BACKUP_CONFIG[ARCHIVE_PREFIX]}-*" \
        --keep-daily "${BB_BACKUP_CONFIG[KEEP_DAILY]}" \
        --keep-weekly "${BB_BACKUP_CONFIG[KEEP_WEEKLY]}" \
        --keep-monthly "${BB_BACKUP_CONFIG[KEEP_MONTHLY]}" \
        "$BB_PRIMARY_REPOSITORY_PATH"; then rc=0; else rc=$?; fi
    find -P "$output_file" -delete 2>/dev/null || true
    bb_log INFO maintenance prune-result "borg prune concluiu rc=$rc" || return "$BB_EXIT_CRITICAL"
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
}

# Compacta segmentos somente depois de prune integralmente bem-sucedido.
# Parâmetros: nenhum.
# Resultado: 0 somente para retorno Borg 0.
bb_borg_compact_repository() {
    local output_file rc
    output_file=$(bb_maintenance_output_file compact) || return "$BB_EXIT_CRITICAL"
    if bb_borg_command "$output_file" compact "$BB_PRIMARY_REPOSITORY_PATH"; then rc=0; else rc=$?; fi
    find -P "$output_file" -delete 2>/dev/null || true
    bb_log INFO maintenance compact-result "borg compact concluiu rc=$rc" || return "$BB_EXIT_CRITICAL"
    (( rc == 0 )) || return "$BB_EXIT_CRITICAL"
}

# Executa prune seguido de compact, sem algoritmo próprio de retenção.
# Parâmetros: nenhum.
# Resultado: 0 somente se ambas as operações Borg retornarem 0.
bb_run_maintenance() {
    bb_borg_prune_repository || return "$BB_EXIT_CRITICAL"
    bb_borg_compact_repository || return "$BB_EXIT_CRITICAL"
}
