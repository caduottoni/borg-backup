# Política de segurança

## Versões suportadas

| Versão | Suporte de segurança |
|---|---|
| 1.0.2 | Sim, em regime de melhor esforço |
| Anteriores a 1.0.2 | Não suportadas publicamente |

Somente releases publicados neste repositório são abrangidos. Branches de
desenvolvimento e forks não constituem releases suportados.

## Como relatar uma vulnerabilidade

Não abra issue, discussion ou pull request com detalhes de uma vulnerabilidade
não corrigida.

Use **Security → Report a vulnerability** neste repositório. Esse fluxo utiliza
o Private Vulnerability Reporting do GitHub e permite discussão privada com os
mantenedores.

Inclua, quando possível:

- versão ou commit afetado;
- componente e pré-condições;
- impacto e cenário de ameaça;
- reprodução mínima com dados sintéticos;
- mitigação ou correção sugerida;
- informação sobre divulgação prévia.

Não anexe segredos, dumps, arquivos de configuração reais, chaves, tokens ou
dados pessoais. O Private Vulnerability Reporting é o único canal aceito para
vulnerabilidades. Se o botão privado estiver indisponível, não divulgue o relato
por outro canal e aguarde sua reativação.

## Tratamento

Os relatos serão tratados em regime de **melhor esforço**, sem SLA de resposta
ou correção. Quando o relato for confirmado, os mantenedores procurarão:

1. preservar a confidencialidade durante a análise;
2. identificar versões afetadas e mitigações;
3. preparar correção e testes de regressão;
4. coordenar release e advisory;
5. creditar o relator quando solicitado e apropriado.

Não há programa de recompensa ou promessa de compensação.

## Escopo

Estão no escopo vulnerabilidades reproduzíveis no código genérico, parser,
controle de serviços, manipulação de temporários, empacotamento, restauração,
transporte SSH/rsync e receptor remoto deste repositório.

Não estão no escopo:

- BorgBackup, OpenSSH, rsync, systemd, PostgreSQL, SQLite ou outras dependências
  sem uma falha específica causada pela integração deste projeto;
- configuração incorreta de terceiros;
- engenharia social, negação de serviço ou varredura indiscriminada;
- qualquer infraestrutura, host, VPN, storage, repositório ou conta real.

Esta política não concede autorização para testar sistemas de terceiros ou
infraestrutura dos mantenedores. Toda reprodução deve ocorrer em ambiente
próprio, isolado e com dados sintéticos.

## Divulgação coordenada

Solicitamos que detalhes permaneçam privados até que uma correção ou mitigação
esteja disponível e que a data de divulgação seja coordenada com os mantenedores.
