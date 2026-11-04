# AuResgate (aplicativo iOS)

Aplicativo iOS do protótipo de busca colaborativa de animais perdidos com
beacons Bluetooth Low Energy, desenvolvido como trabalho de conclusão de curso
em Ciência da Computação na UNISINOS.

O servidor correspondente está em https://github.com/hedojunior/auresgate-backend

## Configuração

A chave compartilhada com o servidor não é versionada. Antes de executar,
defina a variável de ambiente `AURESGATE_API_KEY` com o mesmo valor da
variável de mesmo nome configurada no servidor:

1. No Xcode, abra `Product > Scheme > Edit Scheme`.
2. Em `Run > Arguments > Environment Variables`, adicione `AURESGATE_API_KEY`.

Sem essa variável, o aplicativo é compilado e executado normalmente, mas as
requisições ao servidor são recusadas com erro de chave de API.

## Requisitos

- iOS 17 ou superior
- Permissão de localização `Sempre`, necessária para o monitoramento de
  regiões e para a detecção com o aplicativo encerrado
