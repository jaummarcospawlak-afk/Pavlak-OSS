# Demonstração reproduzível com dados sintéticos

Esta demonstração não usa a Fototeca, documentos pessoais, rede, chave de API ou credencial.

## Busca autorizada em arquivos

O teste cria temporariamente três arquivos de texto fictícios (`digitalizacao.txt`, `contrato.txt` e `ingresso.txt`) dentro de uma pasta temporária autorizada. Em seguida, indexa a pasta, consulta três pedidos e verifica que o primeiro candidato tem nome e origem esperados:

```sh
swift test --disable-sandbox \
  --filter PavlakDocumentFlowTests.testABCRealFilesAndContextualResidence
```

O teste também verifica que a seleção não abre nem altera o arquivo e que a resposta distingue a fonte consultada de uma inferência.

## Política local

Para conferir que uma busca especializada não dispara OpenAI quando o modo local está ativo:

```sh
swift test --disable-sandbox \
  --filter PavlakWorkspaceStateTests.testDocumentKindSearchRunsOnlyLocallyBeforeOpenAI
```

## Ponte MCP somente leitura

Depois de compilar o produto, a ponte aceita JSON-RPC em stdin e só expõe `pavlak_status`:

```sh
swift build --disable-sandbox --product PavlakMCPBridge
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  | swift run --skip-build PavlakMCPBridge
```

O comando consulta o snapshot operacional local, sem uma operação de escrita. Um estado `nao_iniciado` é válido quando o aplicativo ainda não publicou seu snapshot.
