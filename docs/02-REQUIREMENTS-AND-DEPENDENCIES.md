# Requisitos e dependências

**Finalidade:** definir o ambiente suportado e as pré-condições verificáveis.

**Público-alvo:** administradores de implantação e mantenedores.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Plataforma e ferramentas

| Componente | Uso | Obrigatoriedade |
|---|---|---|
| Debian GNU/Linux 13 | plataforma e layout administrativo | sempre |
| Bash 5.x | ponto de entrada e módulos | sempre |
| BorgBackup 1.4.x | archive, retenção, compactação e lock | sempre |
| util-linux (`flock`, `runuser`, `findmnt`) | lock, identidade local e validação de mount | conforme operação |
| coreutils e findutils | caminhos, hashes, modos, temporários e limpeza segura | sempre |
| rsync | réplica incremental integral | quando replicação estiver habilitada |
| OpenSSH client | transporte estrito do emissor | quando replicação estiver habilitada |
| OpenSSH server | comando forçado no receptor | no destino de réplica |
| PostgreSQL client | `pg_dump`, `pg_dumpall` e `pg_restore` | quando declarado |
| SQLite | dump, restauração temporária e `integrity_check` | quando declarado |
| PHP e `runuser` | execução do `occ` | quando Nextcloud estiver declarado |
| `rndc` e `runuser` | sincronização de estado dinâmico BIND | quando BIND estiver declarado |
| systemd | units de aplicação e agendamento | quando usados |
| logrotate | rotação do log em arquivo | quando logging em arquivo estiver ativo |
| cryptsetup | custódia LUKS2 offline | somente operação administrativa da mídia |

O runtime não instala, atualiza ou substitui pacotes. Uma dependência declarada
ausente encerra a operação com falha crítica antes de modificar aplicações.

## Verificação de versão e presença

Os comandos abaixo são consultas:

```bash
/bin/bash --version
borg --version
command -v flock findmnt runuser
command -v rsync ssh sshd
command -v pg_dump pg_dumpall pg_restore
command -v sqlite3 systemctl logrotate
```

`borg --version` deve retornar a série `1.4.x`. Ferramentas condicionais só são
exigidas quando o respectivo banco, aplicação, service ou réplica estiver
declarado.

## Privilégios

A operação instalada requer contexto administrativo para ler todas as fontes,
controlar units e preservar metadados. Código e configurações devem pertencer a
`root:root`. Contas receptoras de réplica não recebem `sudo`, senha interativa
ou grupos administrativos; elas escrevem apenas na raiz remota dedicada.

## Rede

O backup local não exige rede quando todos os bancos são locais e a replicação
está desabilitada. A replicação requer DNS ou endereço estável previamente
validado, porta SSH acessível, host key fixa, autenticação não interativa e
capacidade de manter a sessão durante toda a transferência. Rede, firewall,
SSH, DNS e VPN são serviços protegidos contra parada.

## Storage

O repositório principal e cada raiz receptora devem residir em ext4, com:

- mountpoint exato e dedicado;
- UUID registrado explicitamente;
- sentinela estruturada e protegida;
- renomeação atômica no mesmo filesystem;
- hard links e metadados POSIX;
- piso de espaço livre configurado;
- ausência de concorrência externa.

O valor inicial normativo do piso é `51200` MiB. Capacidade, desempenho, SMART e
mensagens de kernel devem ser acompanhados administrativamente.

## Relógio e timezone

O host deve manter relógio sincronizado. IDs, archive names e relatórios usam
UTC. `OnCalendar` é interpretado pelo systemd no timezone do host; por isso o
registro as-built deve documentar timezone e próxima ocorrência calculada.

## Dependências diárias e administrativas

`cryptsetup`, ferramentas de criação de filesystem, exportação da chave Borg e
testes completos de recuperação não participam do ciclo diário. São ferramentas
administrativas usadas sob autorização própria. Borg, Bash, utilitários básicos
e as ferramentas exigidas pelas declarações ativas pertencem ao runtime diário.
