# Segurança e privacidade

Pavlak manipula documentos e fotos potencialmente sensíveis. O repositório público deve conter somente código, documentação e fixtures sintéticas.

## Regras obrigatórias

- nunca faça commit de chaves OpenAI/Azure, tokens, senhas, certificados, perfis de provisionamento ou códigos de pareamento;
- nunca inclua documentos, fotos, OCR, dumps de erro ou logs pessoais em issues, pull requests ou testes;
- mantenha credenciais no Keychain e use mocks nos testes;
- revise `.gitignore` e `git diff --cached` antes de qualquer push;
- trate nomes, caminhos, IDs de dispositivo, IDs de equipe e dados de localização como potencialmente privados;
- não envie conteúdo local para um provedor remoto sem autorização e sem explicar a finalidade.

## Modelo de ameaça resumido

O acesso a arquivos e fotos depende da autorização do sistema. O índice do Pavlak é dado derivado e deve ser purgado quando o escopo é revogado. A ligação macOS–iOS exige pareamento e autenticação, mas a segurança física de um dispositivo comprometido não é resolvida pelo aplicativo. O modelo remoto depende de credencial e infraestrutura do provedor; o Pavlak não é um cofre de chaves de API.

## Relato

Não publique um segredo ou dado pessoal para “demonstrar” o problema. Se encontrar exposição de credencial, interrompa o uso dessa credencial, preserve apenas evidência sanitizada e comunique o mantenedor por um canal privado previamente configurado. Até que um canal privado esteja documentado no repositório, não abra uma issue pública com detalhes exploráveis.

Relatos comuns de bugs podem usar o template público, desde que não contenham dados reais. Inclua versão, sistema, comando, fixture sintética e resultado observado.

## Dados em conversas remotas

O cliente OpenAI macOS usa conversas persistentes e `store: true`. Textos e saídas de ferramentas podem ser enviados e associados à conversa quando o usuário habilita IA remota. Azure Responses, iOS Chat e o pacote separado usam `store: false`; essa opção não é uma promessa de retenção zero do provedor. Para trabalhar somente no dispositivo, mantenha o Modo local ativo.
