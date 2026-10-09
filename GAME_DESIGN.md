# GAME DESIGN SCOPE --- Projeto 3D inspirado em Castle Story

> Documento de escopo inicial. O jogo ainda está em fase de concepção;
> requisitos não definidos devem permanecer em aberto, sem serem
> inventados pelo agente de desenvolvimento.

## 1. Visão do jogo

Criar um jogo 3D de construção, sobrevivência e gerenciamento inspirado
principalmente em **Castle Story**, com elementos de construção em
blocos de **Minecraft**. O foco é tornar a construção prazerosa,
permitir estruturas fisicamente convincentes e evitar que danos ou
ataques obriguem o jogador a refazer tudo manualmente.

A identidade do jogo deve ser própria. As referências orientam as
mecânicas, não uma reprodução literal de outros jogos.

## 2. Pilares de design

-   **Construção satisfatória:** posicionar, remover e organizar blocos
    deve ser intuitivo e previsível.
-   **Física híbrida:** construções estáveis não precisam simular todos
    os blocos como corpos físicos o tempo todo; partes que perdem
    sustentação podem se soltar e desmoronar com física real.
-   **Recuperação não punitiva:** estruturas registradas podem ser
    reconstruídas por ajudantes, desde que haja núcleo funcional e
    materiais.
-   **Recursos recuperáveis:** destroços não devem ser automaticamente
    lixo; sua condição determina como podem ser reutilizados.
-   **Automação compreensível:** o jogador deve conseguir entender por
    que os ajudantes estão ou não construindo, reparando ou coletando.
-   **Desempenho escalável:** suportar construções grandes sem manter
    física completa ativa em cada bloco permanentemente.

## 3. Construção em blocos e física híbrida

### 3.1 Construções estáveis

-   Construções utilizam blocos alinhados a uma grade, com encaixe
    previsível.
-   O jogo calcula sustentação, conexões e estabilidade estrutural.
-   Blocos que fazem parte de uma construção estável não precisam ser
    corpos físicos independentes em simulação contínua.
-   O jogador deve conseguir salvar/registrar estruturas como projetos
    para reconstrução posterior.

### 3.2 Desmoronamento

Quando blocos de sustentação são removidos ou destruídos: 1. O sistema
identifica as partes que perderam apoio. 2. Os blocos afetados são
liberados da estrutura estável. 3. Eles passam a usar física dinâmica,
incluindo gravidade, colisões, rotação e impactos. 4. Colisões podem
afetar outras partes e provocar desmoronamentos em cadeia, respeitando
limites de desempenho. 5. Quando os destroços ficam estáveis, o jogo
pode reduzir o custo da simulação, sem eliminar automaticamente seu
valor como material.

A física deve ser convincente, mas não precisa ser uma simulação
perfeita de engenharia. Priorizar jogabilidade, previsibilidade e
desempenho.

## 4. Núcleo e reconstrução automática

A base possui um **núcleo de construção**, responsável por habilitar o
sistema de manutenção e reconstrução da área.

-   **Núcleo intacto e operacional:** ajudantes podem reparar estruturas
    registradas dentro da área atendida.
-   **Estruturas danificadas:** o sistema compara a construção existente
    com o projeto salvo e identifica os blocos ausentes ou danificados.
-   **Núcleo danificado:** suspender a reconstrução automática até que o
    núcleo seja reparado.
-   **Núcleo destruído:** desativar temporariamente a reconstrução
    automática, mas preservar os projetos salvos e evitar apagar
    construções registradas.
-   **Materiais insuficientes:** os ajudantes devem informar ou indicar
    a falta de recursos, em vez de falhar silenciosamente.
-   **Prioridades:** permitir priorizar núcleo, estruturas essenciais e,
    depois, estruturas secundárias/decorativas.
-   **Acesso e logística:** ajudantes precisam de acesso viável ao local
    e aos materiais para trabalhar.

O objetivo é permitir que o jogador repare o que for essencial e deixe
os ajudantes reconstruírem o restante, sem exigir que a casa inteira
seja refeita manualmente.

### 4.1 Projetos de construção salvos

Um projeto salvo deve registrar a disposição dos blocos e seus tipos. O
sistema de reconstrução usa esse projeto como referência, mas deve
preservar alterações manuais posteriores quando o jogador atualizar ou
substituir o registro.

Ainda precisam ser definidos: limites da área de manutenção, custo de
materiais, quantidade de ajudantes, alcance do núcleo e comportamento
quando o terreno ou o acesso mudar.

## 5. Durabilidade e recuperação de destroços

Os blocos possuem durabilidade/condição, que determina como seus
destroços podem ser reaproveitados.

Regra inicial proposta: - **Mais de 50% de durabilidade:** o bloco
recuperado pode voltar a ser um bloco de construção utilizável, caso
seja possível recolhê-lo e transportá-lo. - **50% ou menos:** o destroço
é convertido em matéria-prima recuperável para fabricar novos blocos. -
O limite exato, a perda de material e a possibilidade de reparar blocos
parcialmente danificados poderão ser balanceados durante os testes.

Os destroços devem continuar existindo como objetos ou materiais do
mundo tempo suficiente para que o jogador e os ajudantes possam
recolhê-los. Não devem desaparecer apenas porque uma estrutura
desmoronou.

## 6. Mineração e fabricação de blocos

A mineração produz materiais brutos, como areia, cascalho e outros
recursos a definir.

Em vez de transformar automaticamente uma quantidade de fragmentos em um
bloco pronto, o processo pode exigir uma etapa de
**prensagem/compactação**:

1.  O jogador ou os ajudantes extraem o material.
2.  O material é coletado e transportado.
3.  Uma prensa ou estação de fabricação compacta uma quantidade definida
    de matéria-prima.
4.  O resultado é um bloco de construção utilizável.

A receita de cada bloco deve definir o tipo e a quantidade de material
exigidos. Por exemplo, uma quantidade `X` de areia ou cascalho pode
produzir um bloco compactado, desde que a receita correspondente esteja
desbloqueada e a estação esteja funcionando.

Não fixar valores de receitas antes do balanceamento. A prensa, as
receitas, o transporte e a automação devem ser sistemas modulares.

## 7. Direção visual: blocos e voxels

### Recomendação inicial: abordagem híbrida

Usar **blocos alinhados à grade como formato principal de construção**,
com estética de voxel/block game, e reservar a fragmentação voxel ou
efeitos de pequenos fragmentos para mineração, quebra e desmoronamentos.

Isso oferece: - Construção clara e fácil de controlar, no estilo de
blocos de Minecraft/Castle Story. - Silhuetas e encaixes previsíveis
para estruturas. - Destruição visualmente satisfatória, com fragmentos e
destroços. - Possibilidade de recuperar materiais de acordo com a
durabilidade. - Menos complexidade do que fazer todo o terreno e todas
as construções se comportarem como uma massa voxel totalmente
deformável.

**Distinção importante:** "voxel" pode descrever a aparência cúbica ou
uma representação volumétrica interna. O jogo não precisa usar voxels
destrutíveis em tudo só para ter estética de blocos. Uma grade de blocos
para construção pode coexistir com efeitos de fragmentação na
destruição.

### Decisão técnica a validar

-   Se o terreno for principalmente estático e a construção acontecer
    com peças encaixadas, começar com grade de blocos e chunks para
    renderização/colisão é uma opção mais simples.
-   Se escavar livremente qualquer parte do terreno e modificar seu
    volume for uma mecânica central, avaliar uma representação voxel
    para o terreno separada do sistema de construção.
-   Evitar criar um corpo rígido completo para cada bloco enquanto a
    estrutura estiver estável. Ativar física dinâmica apenas para partes
    liberadas e otimizar ou agrupar destroços parados.

## 8. Tecnologia e desenvolvimento

-   Engine: Godot Engine Standard.
-   Linguagem preferida: GDScript.
-   Dimensão: 3D.
-   Agente de desenvolvimento: Google Antigravity, com acesso à pasta do
    projeto.
-   O agente deve editar os arquivos do projeto, executar o jogo pelo
    Godot quando possível, verificar logs/erros e corrigir problemas
    encontrados.
-   Separar os sistemas de construção, estabilidade, física de
    destroços, durabilidade, recursos, fabricação, ajudantes, núcleo e
    interface.
-   Testar o desempenho com muitas peças antes de aumentar a escala.

## 9. Critérios de qualidade

-   Construir e remover blocos é intuitivo.
-   Uma construção estável não desmorona sem motivo.
-   Remover uma sustentação produz um desmoronamento coerente.
-   Os destroços podem ser recuperados e convertidos em materiais
    conforme sua condição.
-   O núcleo controla corretamente a disponibilidade da reconstrução
    automática.
-   Os ajudantes conseguem reconstruir projetos salvos com materiais
    disponíveis.
-   Falta de recursos, acesso bloqueado e núcleo danificado são
    comunicados claramente.
-   O jogo não apaga projetos de construção quando o núcleo é destruído.
-   O sistema continua utilizável em construções grandes, com
    estratégias de otimização para física e renderização.

## 10. Questões em aberto

Não inventar respostas para estas decisões sem discutir o conceito com o
usuário: - Combate, inimigos e causas de dano. - Controles exatos de
construção e demolição. - Quantidade, funções e comportamento dos
ajudantes. - Geração do mundo e liberdade para escavar terreno. -
Progressão, desbloqueios e receitas. - Materiais, tipos de blocos e
resistências. - Escala típica de construções e desempenho-alvo. -
Direção artística final, câmera, interface e áudio.

## 11. Orientação para o agente de IA

Antes de implementar: 1. Ler este documento e inspecionar a estrutura do
projeto. 2. Identificar decisões ainda não especificadas, sem inventar
mecânicas definitivas. 3. Propor uma arquitetura técnica modular para
aprovação. 4. Implementar em etapas pequenas e jogáveis, validando cada
sistema no Godot. 5. Executar testes, verificar erros e corrigir
regressões. 6. Atualizar este documento quando requisitos forem
explicitamente definidos ou alterados.
