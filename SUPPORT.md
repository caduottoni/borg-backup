# Suporte

Este projeto é mantido pela comunidade em regime de melhor esforço. Não há
SLA, plantão, suporte emergencial ou garantia de resposta.

## Antes de pedir ajuda

1. Consulte [`README.md`](README.md) e [`docs/README.md`](docs/README.md).
2. Leia o [runbook](docs/15-OPERATIONS-RUNBOOK.md) e o
   [troubleshooting](docs/16-TROUBLESHOOTING.md).
3. Confirme Debian, Bash, BorgBackup e dependências suportadas.
4. Execute `borg-backup validate` e a regressão pertinente em ambiente seguro.
5. Remova ou substitua toda informação sensível antes de compartilhar saídas.

## Onde solicitar suporte

Use os formulários de issue para:

- defeito reproduzível no produto;
- proposta de funcionalidade;
- correção da documentação.

Informe versão, plataforma, comportamento observado e reprodução mínima. Não
publique configurações reais, logs integrais, passphrases, chaves, tokens, IPs,
FQDNs, UUIDs, repository IDs ou dados de usuários.

Vulnerabilidades devem seguir exclusivamente [`SECURITY.md`](SECURITY.md).

## Limites

Os mantenedores não podem operar, diagnosticar ou recuperar infraestrutura
privada por meio de uma issue. Implantação, dimensionamento, RPO/RTO, custódia,
topologia, retenção e resposta a incidentes continuam sendo responsabilidades
do administrador da instalação.

Se houver risco de perda de dados, preserve logs e estado, interrompa mudanças
destrutivas e siga o plano local de recuperação. Uma issue pública não substitui
um procedimento de incidente.
