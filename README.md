# Distribuição do TSA

Este diretório define o contrato do repositório privado que distribuirá o TSA para macOS e Windows.

## Instalar no Mac

Rode no app Terminal:

```bash
curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | bash
```

Você não precisa de conta no GitHub nem do `gh`. O instalador faz duas coisas.

1. **Instala o app.** Ele baixa o TSA do release público, confere o SHA-256, copia o app para Aplicativos e remove a quarentena. O DNA da TSA já vem dentro do app.
2. **Prepara o Mac para o simulador ACE e para a leitura de mídia.** O simulador vai dentro do app e precisa de:
   - Python 3.10 ou mais (recomendado: 3.14);
   - Node;
   - PostgreSQL ligado, em que o seu usuário rode `psql -l` e `createdb` sem senha;
   - `ffmpeg`, para a leitura de mídia;
   - `agy`, o Antigravity CLI do Google, que lê vídeo.

   O instalador só instala o que falta, pelo Homebrew: `python@3.14`, `node`, `postgresql@16` e `ffmpeg`. Ele liga o PostgreSQL 16 com `brew services`. O `agy` vem do instalador oficial do Google (`curl -fsSL https://antigravity.google/cli/install.sh | bash`), e só depois de o endereço responder 200. O que já existe fica como está. O instalador não roda `brew upgrade` e não cria banco, usuário nem senha. O banco do simulador é criado pelo app na primeira simulação.

   **O login do Antigravity é seu.** O instalador nunca faz login, porque isso abre o navegador. Se o `agy` estiver instalado e sem login, o resumo final pede: rode o comando `agy`, escolha Google OAuth e entre com o e-mail da empresa (`@trafegosa.com.br` ou `@caduneiva.com`). Deixe a janela do terminal grande, senão o campo do código fica escondido.

Se o Mac não tem Homebrew, o instalador baixa o instalador oficial do Homebrew. **Nesse caso o Mac pode pedir a sua senha.** É a senha que você usa para entrar no Mac. O instalador do Homebrew também pede para apertar Enter antes de começar. Ele pode instalar as ferramentas de linha de comando da Apple, o que leva alguns minutos.

O instalador não instala um segundo PostgreSQL. Antes de instalar, ele procura o que já existe:

- se o `psql` existe mas o servidor está desligado, mostra o comando para ligar;
- se acha o app Postgres, outra versão do PostgreSQL no Homebrew ou a porta 5432 em uso, não instala nada e mostra como pôr o `psql` no PATH;
- se o `postgresql@16` já foi instalado antes e está fora do PATH, só acrescenta o caminho dele no PATH.

O `postgresql@16` instalado agora ganha `brew link --force`, para que `psql` e `createdb` fiquem no mesmo lugar dos outros programas do Homebrew. Se o link der conflito, o instalador usa o PATH. Uma alteração no `~/.zprofile` só acontece quando é necessária, e nunca se repete.

No fim aparece um resumo com o que ficou pronto e o que falta, com o comando para resolver cada item. Uma falha nessa preparação não desfaz o app.

Rodar o instalador de novo é seguro: o que já está pronto não é reinstalado nem atualizado.

### Controles

| Variável | Efeito |
|---|---|
| `TSA_SKIP_PREREQS=1` | Instala só o app e pula a preparação do simulador. |
| `TSA_ONLY_PREREQS=1` | Roda só a preparação do simulador, sem baixar nem instalar o app. Serve para conferir uma máquina que já tem o TSA. Sai com código 1 se faltar algo. |

```bash
curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | TSA_SKIP_PREREQS=1 bash
curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | TSA_ONLY_PREREQS=1 bash
```

O teste da preparação roda sem instalar nada, com binários falsos: `bash scripts/test-install-prereqs.sh`.

`scripts/install-tsa-macos.sh` é legado: exige `gh` autenticado e aponta para o release antigo. Use `docs/install.sh`.

O repositório de distribuição publica instaladores do aplicativo. Cada instalador já leva dentro do aplicativo o DNA aprovado, assinado e verificado na primeira execução. A Central fica como canal autenticado para atualizações futuras e contribuições.

## Estado atual

O contrato orienta o repositório instalador. Os artefatos e URLs de release são preenchidos pelo pipeline de build depois da verificação de cada arquivo.

O primeiro canal será macOS, com artefatos arm64, x64 e universal quando o runner e os testes permitirem. Windows permanece no mesmo contrato, com instalador x64 como primeiro alvo. Nenhum artefato é considerado publicado enquanto não houver hash, tamanho, assinatura do aplicativo e receipt de teste.

## Vínculo obrigatório com o DNA

Cada manifesto de distribuição deve conter `dna.source_repository`, `dna.approved_commit`, `dna.release_version`, `dna.manifest_url` e `dna.compatible_adapters`.

Para o release aprovado atual, os valores são:

- Repositório: `https://github.com/neivacadu/DNA-ACE-TSA`
- Commit aprovado: `6c3d56d6209d54e8145997780433351f06b3f41b`
- Release do DNA: `1.0.9-approved.20260915`
- Adaptadores: `tsa-codex-1`, `tsa-claude-1`
- Endpoint privado: `https://ace.acetsia.com/inteligencia/v1/dna/release`

O instalador não recebe token nem chave privada. O conteúdo assinado do DNA aprovado acompanha o aplicativo. O token da Central, quando necessário para atualizações, é criado e protegido pelo cofre do sistema durante a execução do TSA.

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

Ele baixa uma referência imutável do aplicativo TSA no repositório `aifocusdev/AceOrca`, na branch de integração do TSA, e gera os artefatos. O build inclui o envelope assinado do DNA aprovado dentro do aplicativo. Na primeira execução, o TSA valida a assinatura e instala o DNA localmente antes de tentar qualquer atualização pela Central.

O workflow `release.yml` roda só macOS, porque o Windows está fora por decisão do Cadu. Ele compila o app a partir de `aifocusdev/AceOrca` na branch `tsa/integracao` e chama `scripts/publicar-release.sh --sem-build`. Sem a opção `publish`, é só ensaio, e os artefatos ficam no upload do job.

**Ressalva:** hoje a branch `tsa/integracao` só existe nos clones locais. Enquanto ela não for enviada ao `aifocusdev/AceOrca`, o checkout do workflow falha. Até lá, publique pelo script local (seção abaixo).

O workflow exige o segredo `TSA_APP_REPO_TOKEN` para ler o repositório privado do aplicativo. Assinatura Apple, notarização e Authenticode são gates separados. Sem essas credenciais, os artefatos são ad-hoc e saem como pre-release, nunca como release estável.

O manifesto só deve ser publicado depois de haver instalador real, hash, tamanho e receipt de teste para cada artefato.

## Publicar uma versão

O script `scripts/publicar-release.sh` faz o release do macOS de ponta a ponta. Ele precisa de três coisas:

- o `gh` logado com escrita em `neivacadu/TSA-Installer`;
- um clone do AceOrca na branch `tsa/integracao`, com a árvore limpa;
- uma tag `tsa-installer-v<versão>-adhoc` que ainda não exista.

### 1. Ensaio (padrão)

Sem `--publicar`, o script não publica nada. Ele roda estes passos:

1. faz o build do app: `pnpm install --frozen-lockfile`, `verify:tsa-macos-release`, `TSA_ADHOC_SIGN=1 pnpm run build:mac` e `prepare:tsa-macos-release`;
2. escolhe os DMGs e os zips pelo `dist/latest-mac.yml` e confere o sha512 de cada um;
3. monta cada DMG e confere o `TSA.app`:
   - `codesign --verify --deep --strict`;
   - bundle id, versão e arquitetura do binário;
   - `Contents/Resources/tsa` com `simulador`, `gsd` e `dna-embedded-release.json`;
   - `ace-skills` e `ace-knowledge`, quando existirem;
   - DNA embutido igual ao de `config/release-policy.json`;
4. gera `checksums-sha256.txt` e o manifesto `tsa-release.json`, numa pasta temporária;
5. mostra a troca da `RELEASE_TAG` no `docs/install.sh`, o que publicaria e as notas da release.

```bash
scripts/publicar-release.sh 0.3.0 --app ../integracao
```

`--sem-build` reaproveita o `dist/` que já existe, sem rodar o build nem o `prepare`. Serve para testar o script. A lista de recursos exigidos fica no topo do script, em `RECURSOS_OBRIGATORIOS` e `RECURSOS_OPCIONAIS`.

O ensaio também lista o que ainda bloqueia a publicação: branch diferente de `main`, árvore suja, repositório privado ou Pages desligado.

### 2. Abrir o repositório

O `install.sh` e os downloads só funcionam com o repositório público. O script nunca muda a visibilidade sozinho.

```bash
gh repo edit neivacadu/TSA-Installer --visibility public --accept-visibility-change-consequences
# se o Pages estiver desligado (gh api repos/neivacadu/TSA-Installer/pages responde 404):
gh api -X POST repos/neivacadu/TSA-Installer/pages -f 'source[branch]=main' -f 'source[path]=/docs'
```

### 3. Publicar

Rode na branch `main` do instalador, com a árvore limpa:

```bash
scripts/publicar-release.sh 0.3.0 --app ../integracao --publicar
```

O script repete tudo o que o ensaio faz. Depois:

1. commita a nova `RELEASE_TAG` no `docs/install.sh`;
2. cria a pre-release com os dois DMGs, os dois zips, `checksums-sha256.txt` e `tsa-release.json`;
3. envia a `main`.

A release sai antes do push. Assim, o `install.sh` publicado nunca aponta para uma tag que ainda não existe.

### 4. Conferir

Com `--publicar`, o script espera o Pages servir o `install.sh` com a tag nova, por até 15 minutos (`TSA_PAGES_TIMEOUT`). Depois baixa o `checksums-sha256.txt` da release e compara com os DMGs locais. Para conferir à mão:

```bash
curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | grep RELEASE_TAG
curl -fsSL https://github.com/neivacadu/TSA-Installer/releases/download/tsa-installer-v0.3.0-adhoc/checksums-sha256.txt
curl -fsSL https://neivacadu.github.io/TSA-Installer/install.sh | TSA_ONLY_PREREQS=1 bash
```

### 5. Fechar o repositório

Depois que o time instalar:

```bash
gh repo edit neivacadu/TSA-Installer --visibility private --accept-visibility-change-consequences
```

Com o repositório privado, o `curl` do instalador volta a responder 404 e ninguém novo consegue instalar.
