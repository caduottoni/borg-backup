# Restauração e validação de recuperação

**Finalidade:** estabelecer testes isolados e critérios de recuperabilidade.

**Público-alvo:** administradores de backup, banco, aplicações e desastre.

**Compatibilidade:** Debian GNU/Linux 13; Bash 5.x; BorgBackup 1.4.x; especificação pública `PUB-SPEC-1`.

## Princípio

Backup só é comprovado por restauração. Todo teste ocorre em área isolada e
descartável, nunca sobre produção. Antes de extrair, registre archive/generation
selecionada, disponibilidade de chave e credencial, espaço, owner da área e
plano de limpeza.

## Repositório principal

1. Execute `borg-backup list` e selecione archive por nome/data documentados.
2. Use `borg info` para confirmar o archive.
3. Crie diretório privado fora das fontes e do repositório.
4. Extraia amostras de `/etc`, conteúdo de aplicação e dumps.
5. Compare presença, legibilidade, checksum quando adequado, owner, group, modo,
   hard links e destinos de links simbólicos em amostra representativa.
6. Registre `PASS` ou `FAIL`; remova a área somente após preservar evidência
   sanitizada.

Não é necessário percorrer milhões de arquivos se uma amostra definida e os
dumps cobrirem o critério aprovado.

## PostgreSQL

Extraia cada dump e use cluster efêmero criado por `initdb`, com diretório e
socket privados e `listen_addresses=''`. Crie roles/database temporários
necessários, execute `pg_restore`, confirme schemas/tabelas e consultas simples
de catálogo, pare o cluster e apague a área. Nunca use o cluster de produção.

## SQLite

Extraia o dump textual, restaure em arquivo novo e execute:

```bash
sqlite3 '<RESTORED_DATABASE>' 'PRAGMA integrity_check;'
```

O resultado deve ser `ok`. Não abra nem sobrescreva o banco vivo durante esse
teste.

## Aplicações

Valide que configurações, conteúdo persistente, certificados e dependências
declaradas foram extraídos. A subida completa de uma aplicação deve ocorrer em
ambiente isolado e sob plano próprio; não faça apontamento acidental para banco,
storage, DNS ou fila de produção.

## Réplicas

Confirme `current` pelo receptor e valide `generation.meta`. Depois copie
`current/repo` para storage independente, preservando metadados mas rompendo os
hard links com a generation viva. Remova apenas locks Borg copiados, se o
procedimento exigir, e execute `borg info`, listagem e extração na cópia.

Após existir segunda generation, repita com `previous`. Para testar fallback,
simule problema somente numa cópia de `current`, selecione `previous`, copie-a
independentemente e restaure. Nunca injete corrupção nas generations reais.

## Reparo e locks

`borg check --repair`, delete, prune, compact, recreate e qualquer comando
modificador são proibidos em `current`/`previous` vivas. Se uma investigação
exigir alteração, trabalhe numa terceira cópia, registre hash/estado de origem e
obtenha autorização específica.

## Critérios

`PASS` exige:

- repositório/archive ou generation identificados sem ambiguidade;
- Borg capaz de ler e extrair;
- arquivos de amostra e metadados válidos;
- restore PostgreSQL bem-sucedido quando aplicável;
- SQLite com `integrity_check=ok` quando aplicável;
- nenhuma escrita em produção;
- limpeza concluída e serviços de teste encerrados;
- relatório sanitizado e material de custódia novamente protegido.

Qualquer ausência de chave/credencial, corrupção, restore incompleto, metadado
incompatível, serviço de teste residual ou dúvida sobre o alvo produz `FAIL` e
escalonamento.

## Recuperação de desastre

Em alto nível: obter hardware/storage limpo, recuperar chave e credencial de
custódias independentes, copiar a fonte escolhida para área de trabalho,
validar Borg, restaurar configuração e dados, restaurar bancos isoladamente,
reconstruir permissões/serviços e só então planejar cutover. A documentação
as-built da instalação fornece valores locais; este guia não os inventa.
