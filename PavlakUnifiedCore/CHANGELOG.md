# Histórico do Pavlak Unified Core

## v0.3 — 19 de agosto de 2026

- Unificação dos clientes OpenAI e dos slots de Keychain.
- Migração não destrutiva de três identificadores antigos de credencial.
- Autenticação Bearer centralizada em todas as requisições.
- Validação da credencial por `GET /v1/models`.
- Integração com Responses API, function calling e web search.
- Roteamento local resiliente para Safari, aplicativos, arquivos e histórico.
- Busca de arquivos limitada à pasta autorizada, com pontuação e limite de resultados.
- Bloqueio de ações destrutivas e registro cronológico local.
- Interface SwiftUI operacional e configurações de conexão/permissões.
- 10 testes automatizados aprovados no Swift Package.
