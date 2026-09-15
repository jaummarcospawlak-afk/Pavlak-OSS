# Auditoria de prontidão pública

**Data:** 14 de setembro de 2026
**Escopo:** snapshot público auditado; o checkout original não foi alterado.

## Resultado

Esta cópia contém o pacote Swift principal, o executável `PavlakMCPBridge`, o projeto Xcode iOS, o pacote `PavlakUnifiedCore`, testes, documentação, templates de colaboração e licença MPL-2.0. Material privado, mídia, backups, relatórios locais, artefatos de build, estado de usuário do Xcode, credenciais e perfis de assinatura ficaram fora da cópia.

O candidato é tecnicamente reproduzível para build macOS e Simulator nesta máquina. A aceitação física em dispositivos, permissões e contas continuam fora desta auditoria.

## Inventário

| Área | Conteúdo |
| --- | --- |
| SwiftPM principal | `Sources/Pavlek`, `Sources/PavlakMCPBridge`, `Tests/PavlekTests` |
| iOS | `PavlakIOS.xcodeproj`, target `Pavlak Photo Search`, plist de uso |
| Núcleo separado | `PavlakUnifiedCore` e seus testes |
| Documentação | README, arquitetura, segurança, contribuição, roadmap, changelog |
| Colaboração | templates de issues/PR e CI em `.github/workflows/ci.yml` |
| Licença | MPL-2.0 e `NOTICE`; manter a cadeia de autoria e os direitos de redistribuição |

## Validação executada

```text
swift build --disable-sandbox                         -> passou
swift test --disable-sandbox                          -> 142 testes, 0 falhas
(cd PavlakUnifiedCore && swift test --disable-sandbox) -> 10 testes, 0 falhas
xcodebuild -list -project PavlakIOS.xcodeproj        -> exit 0, target e scheme enumerados
xcodebuild ... -sdk iphonesimulator ... build         -> BUILD SUCCEEDED, sem assinatura
./Scripts/build-app.sh                               -> app e arquivo zip assinados ad hoc
codesign --verify --deep --strict Build/Pavlek.app    -> válido
```

O build iOS foi feito para Simulator genérico e não prova instalação, abertura, permissões ou aceitação em iPhone. O build macOS e os testes não provam cota, cobrança, deployment ou credencial de OpenAI/Azure.

## Higiene e limites

Foi feita uma varredura final por padrões de chaves, tokens, chaves privadas, assignments de credenciais, bearer tokens, caminhos locais e identificadores pessoais. Não houve resultados nos arquivos publicados; fixtures de teste usam valores sintéticos. O snapshot público contém somente esta árvore auditada.

O cliente OpenAI macOS usa `store: true` e conversa persistente; Azure Responses, iOS Chat e o pacote separado usam `store: false` em seus requests atuais. Consulte `SECURITY.md` antes de habilitar modo remoto.

## Pendências concretas

1. manter a confirmação de autoria e direitos de redistribuição de todas as fontes e dependências;
2. executar aceitação manual de OCR, PhotoKit, Spotlight, pareamento e permissões;
3. manter futuras candidaturas e atualizações baseadas em fatos verificáveis, sem inventar adoção, estrelas, downloads ou métricas.
