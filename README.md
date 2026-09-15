# Distribuição do TSA

Este diretório define o contrato do repositório privado que distribuirá o TSA para macOS e Windows.

O repositório de distribuição publica instaladores do aplicativo. Ele não copia o DNA para uma pasta pública e não substitui o canal autenticado da Central. O aplicativo deve buscar o DNA pelo endpoint privado, validar a assinatura Ed25519 e conferir os hashes antes de aplicar qualquer pacote.

## Estado atual

`DRAFT`. O contrato está pronto para orientar o repositório instalador. Os artefatos e URLs de release só podem ser preenchidos depois que o pipeline de build gerar e verificar cada arquivo.

O primeiro canal será macOS, com artefatos arm64, x64 e universal quando o runner e os testes permitirem. Windows permanece no mesmo contrato, com instalador x64 como primeiro alvo. Nenhum artefato é considerado publicado enquanto não houver hash, tamanho, assinatura do aplicativo e receipt de teste.

## Vínculo obrigatório com o DNA

Cada manifesto de distribuição deve conter `dna.source_repository`, `dna.approved_commit`, `dna.release_version`, `dna.manifest_url` e `dna.compatible_adapters`.

Para o release aprovado atual, os valores são:

- Repositório: `https://github.com/neivacadu/DNA-ACE-TSA`
- Commit aprovado: `6c3d56d6209d54e8145997780433351f06b3f41b`
- Release do DNA: `1.0.9-approved.20260915`
- Adaptadores: `tsa-codex-1`, `tsa-claude-1`
- Endpoint privado: `https://ace.acetsia.com/inteligencia/v1/dna/release`

O instalador não recebe token, chave privada ou conteúdo do envelope do DNA. A instalação registra apenas a configuração pública necessária para o primeiro contato autenticado; o token de instalação é criado e protegido pelo cofre do sistema durante a execução do TSA.

## Contrato

- `contracts/tsa-distribution-manifest-v1.schema.json` define o formato do manifesto.
- `contracts/tsa-dna-binding-v1.schema.json` define o vínculo mínimo entre aplicativo, DNA e Central.
- `manifests/` deve conter somente manifestos versionados sem segredo. Um manifesto incompleto deve declarar `state: DRAFT`.

## Gates antes de publicar

1. Gerar o TSA a partir de um commit imutável.
2. Conferir identidade do produto `com.trafegosa.orca-tsa` e versão efetiva do pacote.
3. Verificar o instalador no sistema operacional e arquitetura declarados.
4. Verificar atualização, interrupção, retomada e preservação da versão anterior.
5. Conferir o vínculo do DNA e a rejeição de pacote candidato, adulterado ou incompatível.
6. Gerar SHA-512, tamanho e receipt para cada artefato.
7. Publicar o release privado somente após o manifesto mudar de `DRAFT` para `PUBLISHED`.

O pipeline não pode ativar campanhas, registrar credenciais em logs, publicar o DNA em release público ou apontar para o repositório do Orca.


## Repositório de instalação

Este diretório é o conteúdo do repositório privado `neivacadu/TSA-Installer`.

Ele baixa uma referência imutável do aplicativo TSA no repositório `aifocusdev/AceOrca`, na branch de integração do TSA, e gera os artefatos. O DNA não é copiado para o instalador. O aplicativo recebe somente a configuração pública do endpoint e das chaves confiáveis, depois autentica e verifica o pacote durante a execução.

O workflow `release.yml` tem três etapas:

1. compilar macOS arm64 e x64;
2. compilar Windows x64;
3. gerar e validar o manifesto, com publicação sempre como rascunho.

A publicação exige o segredo `TSA_APP_REPO_TOKEN` para ler o repositório privado do aplicativo. Assinatura Apple, notarização e Authenticode são gates separados. Sem essas credenciais, o workflow pode gerar artefato adhoc, mas não pode marcar um release como estável.

O manifesto inicial permanece em `DRAFT` até haver instalador real, hash, tamanho e receipt de teste para cada artefato.
