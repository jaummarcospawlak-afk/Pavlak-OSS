# Contribuindo

Obrigado por ajudar no Pavlak. O projeto prioriza busca autorizada, fonte verificável e privacidade local. Uma mudança que torna a interface mais bonita, mas enfraquece essas garantias, não é uma melhoria aceitável sem uma decisão explícita.

## Antes de começar

- macOS 14 ou posterior;
- Swift 6 e Xcode compatível com os SDKs usados pelo projeto;
- uma cópia de trabalho sem documentos pessoais, fotos, backups ou credenciais;
- conhecimento de que o checkout atual não contém um histórico Git remoto configurado.

Leia [AGENTS.md](AGENTS.md), [ARCHITECTURE.md](ARCHITECTURE.md) e [SECURITY.md](SECURITY.md). Para uma mudança de comportamento, abra uma issue antes ou explique o problema e o critério de aceitação no pull request.

## Fluxo local

```sh
swift build
swift test --disable-sandbox
(cd PavlakUnifiedCore && swift test --disable-sandbox)
```

Para o alvo iOS, abra `PavlakIOS.xcodeproj` no Xcode. A equipe de assinatura deve ser escolhida localmente; ela não deve ser gravada no projeto compartilhado.

## Regras para mudanças

- preserve a distinção entre `Implementado`, `Em desenvolvimento` e `Planejado`;
- não adicione chaves, tokens, provisioning profiles, IDs de equipe, caminhos pessoais ou fixtures reais;
- não transforme OCR, nome de arquivo ou ranking em uma afirmação de titularidade ou de fato;
- mudanças de permissão devem ter um teste de autorização negada/revogada;
- mudanças de persistência devem cobrir migração, corrupção, revogação e recuperação;
- mudanças de transporte devem cobrir autenticação, replay, cancelamento e limites;
- prefira testes determinísticos com dados sintéticos;
- registre falhas ambientais separadamente de regressões de produto.

## Pull requests

Inclua:

- resumo do problema e da solução;
- arquivos ou módulos afetados;
- testes executados, com comando e resultado;
- validação manual, se houver, indicando dispositivo, permissão e fixture sintética;
- riscos, limitações e trabalho restante;
- confirmação de que não foram incluídos dados privados ou segredos.

Não declare que um build, um teste ou uma integração foi validado além do que o comando realmente observou.
