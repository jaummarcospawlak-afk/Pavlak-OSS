# Exemplo de configuração

O caminho normal não usa arquivo `.env`. A configuração é feita na interface do Pavlak e as credenciais são guardadas no Keychain do sistema.

## Modo local

É o modo padrão para busca de arquivos e fotos autorizados. Não exige chave de API. O app deve continuar capaz de interpretar pedidos determinísticos sem rede.

## OpenAI direto

Na tela de conexões, informe uma credencial criada pelo próprio usuário e deixe o aplicativo validá-la. A credencial não deve ser copiada para este arquivo, para um plist, para uma issue ou para um log.

```text
provider: OpenAI
base URL: https://api.openai.com/v1/
model: <model-id-configurado-pelo-usuário>
credential: <somente no Keychain>
```

## Azure OpenAI / Microsoft Foundry

Informe o endpoint de inferência compatível, o nome literal do deployment já existente e a credencial do recurso. O Pavlak não cria deployment nem presume quota, crédito ou preço.

```text
provider: Azure OpenAI / Microsoft Foundry
base URL: https://<recurso-ou-projeto>/openai/v1/
deployment: <deployment-existente>
credential: <somente no Keychain>
```

## iOS e rede local

O target iOS solicita permissão de Fotos e rede local quando o fluxo correspondente é usado. O pareamento macOS–iOS deve ser realizado com um código novo, mantido fora do repositório e nunca reutilizado como exemplo real.

Antes de relatar uma validação, anote o sistema, a permissão concedida, o provider/deployment usado e se a chamada foi mockada ou real — sem registrar a credencial.

## Retenção

OpenAI no macOS usa `store: true` e conversas remotas. Azure Responses e iOS Chat usam `store: false` nos requests atuais. Revise `SECURITY.md` antes de habilitar o modo remoto. O build e os testes com fixtures não precisam de uma credencial real.
