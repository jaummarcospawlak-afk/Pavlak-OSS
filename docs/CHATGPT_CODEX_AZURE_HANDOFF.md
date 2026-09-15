# ChatGPT → Codex Azure: protocolo de handoff

Este documento define a ponte operacional entre o planejamento feito no ChatGPT e a execução técnica pelo Codex configurado para usar Azure OpenAI.

## Objetivo

Permitir que uma ideia, função, correção ou implementação discutida no ChatGPT seja convertida em uma tarefa técnica reproduzível para o Codex Azure, sem compartilhar credenciais e sem depender da sessão autenticada do ChatGPT para executar o código.

## Separação de responsabilidades

### ChatGPT — planejamento e revisão

- entender a necessidade e reduzir ambiguidades;
- inspecionar o repositório autorizado quando necessário;
- transformar a necessidade em escopo implementável;
- definir arquivos prováveis, restrições, critérios de aceitação e testes;
- revisar diff, PR, testes e resultado devolvidos pelo executor;
- não declarar sucesso sem evidência de build/teste/validação.

### Codex Azure — execução

- operar no checkout local usando o provider Azure previamente configurado;
- ler `AGENTS.md` antes de alterar arquivos;
- trabalhar somente no escopo da tarefa recebida;
- preservar segredos, corpus pessoal, configurações locais e artefatos de assinatura;
- executar os testes definidos na tarefa e os testes mínimos aplicáveis do repositório;
- devolver resumo, arquivos alterados, comandos executados, resultados e pendências.

## Formato de tarefa

Toda tarefa preparada para execução deve conter:

1. **ID e título** — identificador curto e resultado esperado.
2. **Objetivo** — comportamento a ser obtido, sem prescrever solução desnecessariamente.
3. **Contexto confirmado** — somente fatos verificados no código/documentação.
4. **Escopo permitido** — arquivos/áreas que podem ser alterados.
5. **Fora de escopo** — itens que não devem ser modificados.
6. **Restrições** — privacidade, compatibilidade, custos e integrações que precisam ser preservados.
7. **Critérios de aceitação** — condições observáveis de conclusão.
8. **Validação** — comandos/testes que devem ser executados.
9. **Entrega do executor** — formato obrigatório do relatório final.

## Contrato de execução

Ao receber uma tarefa, o Codex Azure deve:

1. ler `AGENTS.md` e este documento;
2. inspecionar somente o necessário antes de editar;
3. informar qualquer conflito entre a tarefa e o estado real do repositório;
4. implementar a menor mudança suficiente para atender aos critérios de aceitação;
5. executar validação compatível com a mudança;
6. não criar recursos de nuvem, deployments ou custos novos sem autorização explícita;
7. não alterar configuração de Azure/OpenAI existente quando isso não fizer parte do escopo;
8. não fazer fallback silencioso para outro provider/modelo;
9. não publicar, compartilhar, abrir ou enviar dados pessoais;
10. encerrar com evidências objetivas.

## Formato do relatório do Codex Azure

```text
STATUS: concluído | parcial | bloqueado
TAREFA: <ID>
ARQUIVOS ALTERADOS:
- <arquivo>

VALIDAÇÃO EXECUTADA:
- <comando> → <resultado>

CRITÉRIOS DE ACEITAÇÃO:
- [x] ...
- [ ] ...

PENDÊNCIAS/RISCOS:
- ...

PRÓXIMO PASSO RECOMENDADO:
- ...
```

## Fluxo recomendado

`Ideia no ChatGPT → especificação estruturada → execução Codex Azure → diff/testes → revisão no ChatGPT → PR/merge somente após validação`

## Privacidade

O repositório pode ser público. Portanto, tarefas que revelem estratégia proprietária, dados pessoais, chaves, documentos, caminhos locais, identificadores sensíveis ou detalhes não destinados à publicação **não devem ser registradas em issues ou arquivos públicos**. Nesses casos, o handoff deve ocorrer diretamente na sessão local do Codex Azure.
