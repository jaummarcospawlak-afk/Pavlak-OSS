# Instruções do repositório

Estas regras valem para mantenedores, automações e agentes que trabalham neste checkout.

## Invariantes

- não inventar funcionalidade, métrica, adoção, crédito, integração ou resultado;
- tratar busca como autorizada e local por padrão;
- manter a distinção entre implementação no código, teste automatizado, observação manual e aceitação física;
- preservar originais e nunca incluir corpus pessoal no repositório público;
- não ler, imprimir ou persistir segredos;
- não gravar identidade de equipe, caminho absoluto local, provisioning profile ou artefato de assinatura no projeto compartilhado;
- qualquer ação de abertura, compartilhamento, cópia ou envio deve exigir a ação explícita correspondente.

## Áreas importantes

- `Sources/Pavlek/`: aplicativo macOS/iOS compartilhado por condicionais de plataforma;
- `Sources/PavlakMCPBridge/`: executável MCP somente leitura;
- `Tests/PavlekTests/`: testes do pacote principal;
- `PavlakUnifiedCore/`: pacote separado ainda não consolidado;
- `PavlakIOS.xcodeproj/`: target iOS e configurações de build;
- `Support/`: Info.plist e exemplos de configuração;
- `docs/`: documentação pública curada.

## Validação mínima

Execute `swift build`, `swift test --disable-sandbox` e os testes de `PavlakUnifiedCore` quando a mudança afetar SwiftPM. Para mudanças iOS, use também `xcodebuild -list` e registre se o build/device foi realmente executado. Não transforme uma falha de ambiente em falha de produto nem o contrário.

## Higiene antes de publicar

Rode uma busca por chaves, tokens, caminhos absolutos, IDs pessoais, logs e binários. Confira `git status`, `git diff` e `git diff --cached`. A ausência de `.git` neste checkout deve ser resolvida antes de qualquer commit ou push, com destino remoto confirmado pelo mantenedor.
