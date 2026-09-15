# Pavlak Unified Core v0.3

Base unificada e preservável para o MVP macOS do Pavlak.

## O que esta versão resolve

- Uma única camada de autenticação OpenAI.
- Migração automática das credenciais salvas pelos códigos anteriores.
- Cabeçalho `Authorization: Bearer` aplicado por um único construtor de requisições.
- Validação por `GET /v1/models`, sem depender de `/v1/me`.
- Responses API, web search e function calling.
- Roteamento local para abrir Safari, pesquisar, abrir aplicativos e localizar arquivos.
- Funcionamento local dos comandos básicos mesmo sem OpenAI.
- Busca de arquivos pontuada e limitada, evitando retorno indiscriminado.
- Bloqueio explícito de ações destrutivas.
- Conversa SwiftUI limpa, sem painel técnico na tela principal.
- Registro cronológico local em `Application Support/Pavlak/Registros`.

## Validação concluída

- `swift test`: 10 testes aprovados, 0 falhas.
- Análise sintática de todos os arquivos Swift: aprovada.
- A execução com AppKit, Keychain e Sandbox ainda precisa ser validada no Xcode do Mac.

## Teste rápido no Xcode

Depois de integrar o pacote, use `PavlakChatView()` como tela principal e teste:

1. `Abra o Safari.`
2. `Pesquise OpenAI Responses API no Safari.`
3. `Localize meu contrato de locação no Finder.`
4. Um pedido mais complexo, para validar a interpretação pela OpenAI.

Leia, nesta ordem:

1. `Integracao_Xcode/INTEGRAR_NO_PROJETO.txt`
2. `Integracao_Xcode/CHECKLIST_VALIDACAO_MAC.txt`
3. `Integracao_Xcode/SUBSTITUICAO_CONTROLADA.txt`

## Proteção da chave

Esta integração direta é destinada ao protótipo pessoal e local. A chave é guardada no Keychain e nunca deve ser impressa em logs. Para distribuição pública, a chamada à OpenAI deve ser movida para um servidor controlado, sem incorporar uma chave de API no aplicativo.
