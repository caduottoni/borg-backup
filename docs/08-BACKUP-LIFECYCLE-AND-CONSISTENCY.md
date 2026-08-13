# Lifecycle de backup e consistência

**Finalidade:** descrever a sequência exata, a janela crítica e a falha segura.

**Público-alvo:** operadores, administradores de aplicações e revisores.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Sequência normativa

Antes da primeira parada, a rotina valida todas as units, aplicações, bancos,
fontes, exclusões, dependências, storage e repositório. Depois:

```text
capturar estados iniciais de todas as units e aplicações
→ parar units declaradas originalmente ativas
→ confirmar cada parada
→ habilitar manutenção Nextcloud quando inicialmente desabilitada
→ gerar e validar dumps lógicos
→ sincronizar BIND online por rndc
→ borg create
→ borg info do archive exato
→ restaurar units e aplicações em ordem segura
→ borg prune
→ borg compact
→ medir capacidade local
→ borg with-lock + destinos remotos sequenciais
→ persistir relatório/estado e limpar temporários
```

A janela crítica vai da primeira mudança de estado até a confirmação do archive
e restauração completa. Units inicialmente inativas permanecem inativas. Uma
unit originalmente ativa permanece parada até `borg info` retornar zero. Sinais
HUP, INT e TERM acionam tentativa de restauração e encerramento crítico.

## Aplicações

Nextcloud usa `occ` sob o usuário declarado. Seu estado inicial de manutenção é
registrado e preservado. BIND executa `rndc sync` online; DNS nunca é parado.
Units genéricas só são interrompidas quando aparecem em `services.conf`, e
infraestrutura protegida é rejeitada pelo parser.

## Dumps e archive

Cada dump nasce como parcial numa área privada, é validado e só então recebe o
nome final incluído no archive. `borg create` e `borg info` exigem retorno zero;
o retorno Borg 1 não é aceito como backup válido. Staging e dumps de outras
execuções permanecem excluídos.

## Manutenção e replicação

Somente depois da restauração dos estados, `prune` aplica 14 diários, 8 semanais
e 12 mensais ao prefixo. `compact` depende do sucesso de `prune`. A replicação
depende de archive, restauração e manutenção válidos. Uma falha em destino não
impede os destinos seguintes, mas a obrigatoriedade determina o código global.

## Capacidade

Antes de iniciar, espaço livre abaixo do piso bloqueia a operação. Depois de um
backup ou promoção remota válidos, nova medição abaixo do piso produz:

```text
BACKUP ou REPLICATION[id]=OK
CAPACITY=WARNING
EXECUTION=WARNING
exit=1
```

Nada é apagado por algoritmo próprio. A próxima execução será bloqueada pelo
precheck enquanto o espaço permanecer insuficiente.

## Cenários de falha

| Cenário | Resultado seguro |
|---|---|
| service ativo | para, permanece parado até info e retorna a ativo |
| service inativo | não sofre transição nem é iniciado ao final |
| dump falho | estados restaurados; create/manutenção/réplica não executam |
| create retorna não zero | archive inválido; info e etapas seguintes bloqueadas |
| info retorna não zero | archive não confirmado; manutenção e réplica bloqueadas |
| restauração de estado falha | falha crítica; manutenção e réplica bloqueadas |
| prune falha | backup confirmado continua `OK`; compact/réplica bloqueados |
| compact falha | backup confirmado continua `OK`; réplica bloqueada |
| réplica opcional falha | demais destinos tentados; execução `WARNING`, código 1 |
| réplica obrigatória falha | demais destinos tentados; execução `FAILED`, código 2 |
| sinal | trap tenta restaurar estados, limpar temporários e liberar lock |
| capacidade baixa antes | nenhuma operação Borg/remota é iniciada |
| capacidade baixa depois | operação válida preservada; advertência e gate futuro |

## Estado válido anterior

`last-success.state` e `last-success.report` só são atualizados após backup
principal confirmado. Falhas de nova execução não apagam a referência ao último
archive válido. Do mesmo modo, uma réplica só substitui `current` após a nova
`incoming` passar por validação e promoção atômica.
