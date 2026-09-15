# Rascunhos de candidatura OpenAI

Este arquivo separa os dois programas oficiais que podem parecer semelhantes. O estado de envio e de aprovação é externo a este snapshot; as respostas abaixo devem permanecer factuais e atualizadas.

## Codex for Open Source

Formulário: <https://openai.com/form/codex-for-oss/>
Termos: <https://learn.chatgpt.com/docs/codex-for-oss-terms>

O programa é voltado a mantenedores de projetos open source ativos. A página informa avaliação de uso relevante, importância para o ecossistema e manutenção ativa. Benefícios possíveis, segundo a página e os termos, são seis meses de ChatGPT Pro com Codex, créditos de API para fluxos de manutenção e acesso condicional ao Codex Security. A seleção, o conjunto de benefícios, duração e escopo ficam a critério da OpenAI; a candidatura não garante aprovação.

### Respostas preparadas

- **Projeto:** Pavlak
- **Repositório:** `https://github.com/jaummarcospawlak-afk/Pavlak-OSS`
- **Papel:** mantenedor primário do projeto
- **Por que qualifica:** Pavlak é um projeto local-first para recuperação autorizada de documentos e fotos em macOS/iOS. O código combina busca limitada por autorização, evidência explicável, OCR/PhotoKit, persistência revogável, ligação autenticada entre dispositivos e ponte MCP somente leitura. A cópia pública tem build/testes reproduzíveis, CI, segurança documentada e fixtures sintéticas. É um protótipo em consolidação; não alegar métricas de adoção não medidas.
- **Interesse:** API credits for my project; Codex Security somente se a revisão condicional considerar apropriado.
- **Uso dos créditos (até 500 caracteres):** Usaria créditos em testes reproduzíveis com fixtures sintéticas: comparar parser local e respostas remotas, exercitar limites de quota/timeout/modelo, validar fluxos OpenAI em revisão/automação do repositório e testar voz contextual somente com consentimento. Os créditos não seriam usados para enviar documentos pessoais, alterar originais ou substituir a aceitação manual em dispositivos.
- **Observação (até 500 caracteres):** O modo local é o padrão. O cliente OpenAI macOS usa conversa persistente (`store: true`); Azure/iOS usam `store: false` nos requests atuais. Não há chaves, dados pessoais, logs ou material confidencial na candidatura. Build/testes estão documentados; PhotoKit, permissões, pareamento e dispositivo físico ainda exigem validação manual.

## Codex Open Source Fund

Formulário: <https://openai.com/form/codex-open-source-fund/>

Esta iniciativa é diferente: a página anuncia uma iniciativa de US$1 milhão para apoiar projetos open source que usem Codex CLI e modelos OpenAI, com grants de até US$25.000 em créditos de API, analisados continuamente.

### Respostas preparadas

- **Projeto:** Pavlak
- **Descrição breve:** Protótipo Swift macOS/iOS de recuperação local-first de documentos e fotos. Busca somente fontes autorizadas, mantém evidência explicável e oferece integrações opcionais de OCR, PhotoKit, ligação autenticada, MCP e OpenAI/Azure sem tratar inferência como prova.
- **GitHub:** `https://github.com/jaummarcospawlak-afk/Pavlak-OSS`
- **Como usaria os créditos:** Em fixtures sintéticas e fluxos públicos de desenvolvimento: revisão de pull requests, automação de manutenção, testes de requests e falhas de quota, e experimentos de voz/continuidade com consentimento. Sem dados pessoais ou credenciais no repositório.
- **Nota adicional:** O projeto é real e reproduzível, mas ainda está em consolidação e não deve ser apresentado com métricas de adoção ou aprovação prévias.

## Decisão recomendada

O formulário `Codex for Open Source` é o encaixe mais direto para a necessidade de benefícios de manutenção, pois explicita Pro, API credits e possível Codex Security. O `Open Source Fund` é uma candidatura complementar se a intenção principal for crédito de API para o projeto. Ambos exigem conta, dados exatos e revisão dos termos na hora do envio.
