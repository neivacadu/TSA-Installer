# Manual de arquitetura e evolução do TSA

**Destinatário:** Paulo, desenvolvimento  
**Produto:** TSA Orca / ACE-TSIA  
**DNA:** DNA ACE TSA  
**Data:** 15/09/2026  
**Estado:** manual operacional para orientar novas alterações

## 1. Objetivo

Este manual explica como o TSA está dividido, onde cada tipo de mudança deve ser feito e como publicar uma evolução sem misturar responsabilidades.

A regra central é:

```text
TSA Orca       = onde o sistema roda
Sistema ACE    = como os agentes trabalham
DNA ACE TSA    = o que os agentes sabem e como decidem
Central        = como o DNA evolui e é distribuído
Instalador     = como a versão chega ao computador
```

Uma mudança deve entrar na menor camada que resolve o problema. Quando atravessar mais de uma camada, o trabalho precisa declarar a dependência entre elas.

## 2. Arquitetura completa

```text
                         ┌──────────────────────────┐
                         │       Cadu / usuário     │
                         └────────────┬─────────────┘
                                      │ pedido
                                      v
┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│ TSA Orca             │──>│ Sistema agêntico ACE │──>│ DNA ACE TSA          │
│ aplicativo e runtime │   │ coordenação e ação   │   │ inteligência e método│
└──────────┬───────────┘   └──────────┬───────────┘   └──────────┬───────────┘
           │                          │                          │
           │ sessões e ferramentas   │ agentes, gates e receipts │ regras e conhecimento
           └──────────────────────────┴──────────────────────────┘
                                      │
                                      v
                         ┌──────────────────────────┐
                         │ Resultado verificável   │
                         └────────────┬─────────────┘
                                      │ aprendizado filtrado
                                      v
                         ┌──────────────────────────┐
                         │ Central de Inteligência │
                         │ avaliação e publicação  │
                         └────────────┬─────────────┘
                                      │ release assinado
                                      v
                         ┌──────────────────────────┐
                         │ Instalador TSA           │
                         │ Mac e Windows            │
                         └──────────────────────────┘
```

### Dependências

- O Orca pode existir sem o DNA TSA, mas não entrega a inteligência específica da TSA.
- O sistema agêntico depende do runtime do Orca para abrir sessões, usar ferramentas e apresentar resultados.
- O sistema agêntico depende do DNA para aplicar métodos, papéis, limites e critérios.
- O DNA não executa sozinho. Ele fornece instruções, contratos e conhecimento para um ambiente de execução.
- A Central recebe e organiza candidatos. Ela não aprova automaticamente, não executa conteúdo recebido e não substitui o Cadu.
- O instalador distribui a versão. Ele não deve conter credenciais privadas.

## 3. Onde cada componente vive

| Componente | Repositório ou área | Responsabilidade | Não deve receber |
|---|---|---|---|
| TSA Orca | `repos/tsa-app` | aplicação desktop, sessões, projetos, terminais, bridges, packaging e runtime | regras de negócio do DNA espalhadas em telas |
| DNA ACE TSA | `repos/dna` | constituição, agentes, métodos, pipelines, receitas, contratos, testes e manuais | segredos, tokens, memória privada de clientes |
| Central | `central-inteligencia-tsa` | cadastro, recebimento autenticado, armazenamento e recibos de contribuições | aprovação automática, execução de conteúdo ou assinatura sem gate |
| Instalador | `installer` | manifestos, políticas, checksums, releases e scripts de instalação | chave privada, convite ou token persistente |
| Projeto local | perfil do TSA | contexto, memória isolada, sessões e estado de execução | conteúdo de outro cliente |

## 4. Regra para decidir onde alterar

Antes de editar, responda estas três perguntas:

1. A mudança altera a interface ou o ambiente de execução?
2. A mudança altera o modo como uma tarefa é coordenada e executada?
3. A mudança altera conhecimento, método, regra ou decisão dos agentes?

| Resposta principal | Camada de destino |
|---|---|
| Interface, abas, sessões, terminal, projeto, runtime ou packaging | TSA Orca |
| Inicialização, roteamento, delegação, paralelismo, retry, lock, checkpoint ou sincronização | Sistema agêntico |
| Regra, método, papel, pipeline, receita, conhecimento, critério ou modelo por etapa | DNA ACE TSA |
| Cadastro, recebimento, fila remota, auditoria ou distribuição central | Central |
| DMG, ZIP, checksum, script, release ou instalação | Instalador |

### Regra de fronteira

Não copie uma regra do DNA para o código do Orca apenas para resolver uma tarefa rápida. Não coloque controle de sessão no DNA apenas porque o Master participa da sessão. A camada deve refletir a natureza da responsabilidade.

## 5. TSA Orca

### Função

O TSA Orca é o aplicativo que o usuário abre. Ele fornece a superfície e o runtime para:

- criar e retomar projetos;
- abrir abas e sessões;
- executar terminais e ferramentas;
- conectar bridges de agentes;
- mostrar estado e resultado;
- guardar configuração local do projeto;
- empacotar o aplicativo para Mac e Windows.

### Quando atualizar

Atualize o TSA Orca quando a solicitação pedir:

- nova tela ou fluxo de interface;
- nova aba ou tipo de projeto;
- mudança na sessão ou no terminal;
- novo bridge ou integração nativa;
- mudança no armazenamento local;
- suporte de plataforma;
- correção de build, assinatura ou empacotamento.

### Exemplo

**Pedido:** criar a opção de retomar um projeto sem abrir abas duplicadas.

**Alterar:** código de projetos, sessões e persistência no `repos/tsa-app`.

**Não alterar primeiro:** o DNA. O DNA pode documentar a regra de retomada, mas a prevenção da duplicação é comportamento do aplicativo.

### Critérios de aceite

- O projeto abre e retoma sem duplicação.
- A configuração persiste depois de fechar o app.
- O estado visual corresponde ao estado real.
- O build da plataforma afetada passa.
- A assinatura do app e das bibliotecas é válida.

## 6. Sistema agêntico ACE

### Função

O sistema agêntico é o mecanismo operacional que transforma um pedido em trabalho coordenado. Ele define o ciclo:

```text
receber -> entender -> planejar -> rotear -> delegar -> executar
-> testar -> revisar -> corrigir -> integrar -> registrar -> entregar
```

Ele controla:

- ACE Master;
- Joker e especialistas;
- escolha do ambiente Codex ou Claude;
- ordem de execução;
- dependências e paralelismo;
- ownership de cada frente;
- checkpoint e retomada;
- lock para impedir trabalho duplicado;
- retry seguro;
- revisão e integração;
- receipt de agente, modelo, harness, artefatos e testes.

### Quando atualizar

Atualize o sistema agêntico quando mudar:

- como uma tarefa é quebrada;
- como um agente é escolhido;
- como agentes trabalham em paralelo;
- como o Master retoma ou cancela;
- como uma tarefa adquire lock;
- como um worker recebe e conclui uma ordem;
- como o sistema sincroniza Mac, servidor e fila;
- como evidências são capturadas.

### Exemplo

**Pedido:** permitir que o Master distribua cinco ordens independentes e espere duas ordens de dependência antes de integrar.

**Alterar:** orquestração, DAG, scheduler, receipt, lock e integração do sistema agêntico.

**Também atualizar:** o DNA, se a nova forma de trabalhar virar regra geral ou método normativo.

## 7. DNA ACE TSA

### Função

O DNA é a inteligência distribuível da TSA. Ele define o conteúdo que orienta o sistema agêntico:

- identidade e constituição;
- precedência de regras;
- papéis e limites dos agentes;
- métodos de planejamento e execução;
- pipelines reutilizáveis;
- receitas operacionais;
- conhecimento e memória;
- contratos de dados e APIs;
- critérios de aceite;
- segurança e permissões;
- observabilidade e custos;
- modelos por etapa;
- filtro e avaliação de aprendizado;
- manuais e glossário.

### Quando atualizar

Atualize o DNA quando mudar:

- o que um agente sabe;
- como um agente deve pensar ou decidir;
- uma regra de operação;
- um pipeline;
- uma receita;
- um papel ou sua responsabilidade;
- um critério de aprovação;
- uma regra de segurança;
- uma integração conceitual ou contrato;
- um método reutilizável descoberto na operação.

### Exemplo

**Pedido:** ensinar o Gestor de Tráfego a seguir um novo método de diagnóstico de campanha.

**Alterar:** agente, pipeline, receita, critérios e testes no DNA.

**Não alterar primeiro:** a interface do Orca, se nenhuma tela ou execução nova for necessária.

### DNA embutido e DNA atualizado

- A instalação recebe uma cópia aprovada e assinada do DNA.
- O primeiro uso aplica o pacote localmente, sem depender da Central.
- A Central pode publicar uma versão posterior.
- O cliente verifica assinatura, hashes e compatibilidade antes de aplicar.
- Se a Central estiver indisponível, o DNA local aprovado continua válido.

## 8. Central de Inteligência

### Função

A Central é o canal controlado para cadastro de instalações e recebimento de contribuições autenticadas. Ela não é o lugar onde se coloca toda a lógica do agente.

Fluxo:

```text
experiência local
-> candidato
-> filtro
-> sanitização
-> fila protegida
-> envio autenticado
-> avaliação do Cadu
-> validação técnica
-> release aprovado
```

### Quando atualizar

Atualize a Central quando mudar:

- contrato HTTP;
- cadastro e revogação de instalações;
- armazenamento e auditoria de contribuições;
- quotas e retry remoto;
- autenticação do receptor;
- backup e recuperação;
- observabilidade do serviço.

### Não confundir

- A Central recebe candidatos. Ela não decide sozinha o que entra no DNA.
- O token da instalação não aprova conteúdo.
- Um candidato recebido não é um release.
- A aprovação humana e a validação técnica são gates distintos.
- O receptor não deve executar instruções recebidas.

## 9. Instalador TSA

### Função

O instalador transforma uma versão aprovada em algo que o usuário consegue instalar.

Ele cuida de:

- seleção da plataforma;
- download de artefato;
- checksum;
- instalação limpa;
- assinatura do aplicativo;
- inclusão do DNA aprovado;
- publicação de release;
- instruções de atualização.

### Quando atualizar

Atualize o instalador quando mudar:

- formato de DMG, ZIP ou instalador Windows;
- nome ou destino do aplicativo;
- checksum ou manifesto;
- versão do app distribuída;
- política de release;
- rotina de instalação e rollback.

### Não colocar no instalador

- tokens da Central;
- convites;
- chaves privadas;
- credenciais de cliente;
- conteúdo de memória privada.

## 10. Matriz de exemplos

| Mudança desejada | Camada primária | Camadas que podem acompanhar | Teste mínimo |
|---|---|---|---|
| novo botão de projeto | Orca | docs de uso | UI, persistência e retomada |
| Master cria tarefas paralelas | sistema agêntico | DNA se virar método geral | DAG, lock, retry e receipt |
| novo método de copy | DNA | agente de conteúdo | casos de uso e critério de aceite |
| novo agente de CRM | sistema agêntico + DNA | Orca se houver nova tela | descoberta, permissão, execução e entrega |
| fila remota de contribuição | Central + sistema agêntico | DNA de aprendizado | autenticação, idempotência e auditoria |
| nova versão do DNA | DNA + instalador | Central para distribuição | assinatura, hashes e compatibilidade |
| Mac e VPS compartilhando tarefas | Orca + sistema agêntico + dados | Central para presença | lock, checkpoint, reconexão e conflito |
| novo DMG macOS | instalador | Orca se mudar packaging | assinatura, abertura e smoke test |

## 11. Fluxo de desenvolvimento

### Antes de editar

1. Descrever a mudança em uma frase.
2. Classificar a camada primária.
3. Verificar o que já existe no repositório.
4. Declarar dependências com outras camadas.
5. Definir teste e critério de pronto.

### Durante a alteração

1. Manter contratos compartilhados com um escritor responsável.
2. Não copiar regra para outra camada sem registrar a decisão.
3. Manter versão de DNA e versão do sistema compatíveis.
4. Registrar agente, ambiente, versão efetiva e evidência.
5. Atualizar documentação quando a responsabilidade mudar.

### Depois da alteração

1. Rodar teste proporcional à camada alterada.
2. Revisar o diff por segurança e regressão.
3. Validar integração entre camadas.
4. Gerar receipt com artefatos e comandos executados.
5. Publicar somente depois dos gates.

## 12. Fluxos de release

### Mudança somente no Orca

```text
editar app -> testar app -> build -> assinar -> publicar instalador
```

### Mudança somente no sistema agêntico

```text
editar orquestração -> testar execução -> revisar receipt
-> integrar no TSA -> publicar versão compatível
```

### Mudança somente no DNA

```text
editar DNA -> validar documentos e casos -> aprovar Cadu
-> gerar envelope -> assinar -> publicar release do DNA
-> TSA verifica -> aplica localmente
```

### Mudança cruzada

```text
contrato da mudança
-> alterar sistema agêntico e DNA
-> atualizar testes de integração
-> gerar matriz de compatibilidade
-> build do app
-> release do DNA
-> atualizar instalador
```

## 13. Versionamento e compatibilidade

Cada release deve registrar:

- versão do TSA Orca;
- versão do sistema agêntico;
- versão do DNA;
- versão do manifesto;
- plataformas suportadas;
- hashes dos arquivos;
- chave de assinatura usada;
- testes executados;
- limitações conhecidas.

Uma mudança do DNA não pode alterar silenciosamente uma execução em andamento. A tarefa fixa a versão do DNA no início e só usa a nova versão em uma execução posterior, salvo decisão explícita de migração.

## 14. Segurança e privacidade

- Segredos ficam no cofre do sistema ou no ambiente autorizado.
- O DNA distribuível não contém tokens ou chaves privadas.
- Dados de clientes ficam fora da distribuição central.
- O filtro envia a menor descrição útil.
- A Central não executa conteúdo recebido.
- Um release adulterado ou incompatível deve ser rejeitado.
- Falha de atualização não pode apagar o DNA local aprovado.

## 15. Checklist para o Paulo

Antes de abrir um pull request, responda:

- [ ] Classifiquei a mudança na camada correta.
- [ ] Listei as camadas dependentes.
- [ ] Separei código operacional de regra do DNA.
- [ ] Defini o critério de pronto.
- [ ] Rodei o teste da camada afetada.
- [ ] Testei a integração se a mudança atravessa camadas.
- [ ] Não incluí segredo, token ou memória privada.
- [ ] Atualizei o manual ou contrato que mudou.
- [ ] Registrei versão, agente, ambiente e evidência.
- [ ] Confirmei que o instalador continua apontando para artefato verificável.

## 16. Resumo para decisão rápida

```text
Mudou a tela ou o runtime?
    -> TSA Orca

Mudou como os agentes trabalham?
    -> Sistema agêntico

Mudou o que os agentes sabem ou devem decidir?
    -> DNA ACE TSA

Mudou o recebimento, a auditoria ou o cadastro central?
    -> Central de Inteligência

Mudou como o app chega ao usuário?
    -> Instalador

Mudou mais de uma resposta?
    -> mudança coordenada com compatibilidade e teste de integração
```

O objetivo dessa separação é permitir evolução rápida sem transformar cada mudança em uma alteração no sistema inteiro. Cada camada tem uma função, um responsável, um teste e uma forma própria de release.
