# Como contribuir

Obrigado pelo interesse em melhorar o Borg Backup para Debian 13. O projeto
aceita correções, testes e documentação que preservem seu desenho declarativo,
auditável e de falha segura.

## Antes de começar

- Para dúvidas de uso, consulte [`SUPPORT.md`](SUPPORT.md).
- Para vulnerabilidades, não abra issue ou pull request; siga
  [`SECURITY.md`](SECURITY.md).
- Para mudanças maiores, abra primeiro uma solicitação de funcionalidade e
  descreva objetivo, riscos operacionais e alternativas.
- Leia e observe o [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Escopo das contribuições

Uma contribuição não deve:

- adicionar autodiscovery, execução arbitrária de configuração ou bypass dos
  gates de segurança sem discussão e aprovação de arquitetura;
- incluir dados de hosts reais, IPs, FQDNs, UUIDs, repository IDs, seriais,
  fingerprints, logs, dumps, tokens, passphrases, chaves ou `.env`;
- acessar infraestrutura real, VPN, storage, repositório Borg ou serviço
  externo durante os testes;
- reduzir validações, permissões, isolamento de processos ou garantias de
  restauração sem justificativa explícita.

Use somente fixtures evidentemente sintéticas e domínios reservados, como
`example.invalid`.

## Ambiente de desenvolvimento

O alvo suportado é Debian GNU/Linux 13, Bash 5.x e BorgBackup 1.4.x. Consulte
[`docs/02-REQUIREMENTS-AND-DEPENDENCIES.md`](docs/02-REQUIREMENTS-AND-DEPENDENCIES.md)
para a relação completa.

Execute, no mínimo:

```bash
bash -n src/usr/local/sbin/borg-backup
find src tests fixtures/bin -type f -name '*.sh' -exec bash -n {} +
./tests/run-tests.sh
```

Quando disponível, execute também `shellcheck` nos scripts alterados. Mudanças
de empacotamento devem provar dois builds independentes e byte a byte idênticos.

## Estilo e testes

- Preserve `set -Eeuo pipefail`, `umask` restritiva e ambiente controlado onde
  esses contratos já existirem.
- Prefira dados literais, paths validados e operações fail-closed.
- Não introduza dependência implícita de shell interativo.
- Documente finalidade, entradas, saídas, efeitos colaterais, dependências,
  privilégios, códigos de saída e sigilo.
- Inclua testes positivos, negativos e de restauração proporcionais ao risco.
- Atualize documentação e `CHANGELOG.md` quando houver mudança observável.

## Pull requests

Mantenha cada pull request pequeno e com uma finalidade. Descreva:

- problema e resultado esperado;
- ameaças ou riscos operacionais afetados;
- testes executados e dependências indisponíveis;
- efeitos sobre compatibilidade, configuração, restore e rollback;
- confirmação de que nenhum dado real ou segredo foi incluído.

Pull requests passam por revisão de mantenedor e pelos checks obrigatórios. A
aprovação de código não autoriza release ou implantação.

## DCO 1.1 e sign-off

O projeto usa o [Developer Certificate of Origin 1.1](DCO) e não exige CLA.
Cada commit deve declarar `Signed-off-by` com um nome e e-mail que o autor esteja
autorizado a tornar públicos:

```bash
git commit -s
```

Exemplo:

```text
Signed-off-by: Nome da Pessoa <email@example.invalid>
```

O sign-off certifica os termos do DCO; não é apenas uma assinatura decorativa.
Não assine em nome de outra pessoa sem autorização.
