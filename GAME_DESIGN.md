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

### 3.3 Conexões Padrão, Juntas Estruturais e Pincel de Argamassa

-   **Conexões Padrão Fracas:** Blocos adjacentes posicionados na grade possuem conexões
    estruturais fracas por padrão, sem exigir argamassa em cada face. Essas conexões
    mantêm estruturas unidas sob cargas estáticas leves e gravidade, evitando colapsos
    em cadeia imediatos durante a colocação de novos blocos. Sob impactos ou cargas
    suficientes, essas conexões rompem-se facilmente.
-   **Pincel de Argamassa Baseado em Superfície:** O jogador aplica argamassa através de
    um fluxo intuitivo de pincel, mirando e pintando faces expostas (segurando a ação de
    argamassa/tecla `G` enquanto move a mira sobre a superfície).
-   **Reforço no Padrão `+` 2D:** A argamassa reforça as conexões entre os blocos
    vizinhos associados à superfície pintada no plano coplanar 2D (padrão em cruz `+`).
-   **Sem Conexões em Profundidade:** A aplicação de argamassa na superfície NÃO conecta
    blocos através da espessura da parede nem cria conexões ocultas com blocos atrás da
    superfície pintada.
-   **Consumo Racional de Recursos:** Apenas faces válidas e recém-revestidas consomem
    argamassa do inventário (1 unidade por face revestida). O jogador pode manter o botão
    pressionado sem consumo duplicado de recursos sobre faces já pintadas.
-   **Danos, Ruptura e Destroços Compostos:** A argamassa reforça as juntas (aumentando
    sua saúde/resistência), mas não torna a estrutura indestrutível. Fortes impactos
    ($E = 0.5 m v^2$) ou cargas repetidas causam desgaste e ruptura. Ao quebrar uma junta,
    a estabilidade é recalculada e os destroços mantêm suas juntas internas íntegras,
    dividindo-se em subgrupos fisicamente coerentes apenas quando suas juntas internas falham.

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

Os blocos possuem durabilidade/condição (`BlockData.durability`), que determina como seus
destroços podem ser reaproveitados.

**Regra implementada no Milestone 3:**
- **Mais de 50% de durabilidade (`durability / max_durability > 0.5`):** o bloco recuperado (via ação `R` / `recover_block`) volta a ser um bloco de construção utilizável no grid estático, preservando sua durabilidade atual e tipo de material.
- **50% ou menos (`durability / max_durability <= 0.5`):** o destroço é classificado e recuperado como matéria-prima (`raw_materials`), removido atomicamente do destroço físico e contabilizado no inventário de materiais brutos do jogador (exibido dinamicamente no HUD).
- O limiar de classificação é configurável via propriedade exportada (`recovery_durability_threshold = 0.5`).
- **Visual de Argamassa:** superfícies revestidas com o pincel de argamassa exibem uma fina camada sobreposta específica por face (`MortarOverlayRenderer`), com cor arenosa distinta, espessura mínima (0.03m), recuo sutil (0.96) e offset para evitar z-fighting, indicando com clareza quais faces foram pintadas sem tingir o bloco inteiro.
- **Escopo Futuro:** prensagem/fabricação de novos blocos a partir de matéria-prima bruta, reciclagem com perda de massa e reparo de blocos antes do colapso permanecem como etapas para marcos futuros.

Os destroços continuam existindo como corpos rígidos físicos (`DebrisIsland`) no mundo tempo suficiente para que o jogador possa recolhê-los ou arremessá-los. Não desaparecem apenas porque uma estrutura desmoronou.

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
-   Os destroços podem ser manipulados, arremessados e recuperados:
    - Destroços com durabilidade acima de 50% são elegíveis como blocos reutilizáveis para construção direta no grid.
    - Destroços com durabilidade igual ou inferior a 50% são classificados como matéria-prima.
    - Tentativas de posicionamento de destroços em regiões inválidas (vermelhas/bloqueadas) rejeitam o posicionamento sem consumir, converter, dropar ou modificar o bloco segurado.
    - Conversão para matéria-prima ocorre exclusivamente através de ação explícita de recuperação (`R`), impedindo conversão acidental durante posicionamento inválido.
-   Resolução padrão de exibição em 1920×1080 (modo janela redimensionável) com interface responsiva ancorada.
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

## 12. Loop de sobrevivência com física — Mineração Gradual e Fabricação em Pallet

> Mecânicas explicitamente definidas pelo usuário em outubro de 2026.
> Substituem a destruição instantânea de blocos para o terreno natural.

### 12.1 Mineração Gradual (LMB Segurado)

- Blocos naturais do terreno **não quebram instantaneamente**.
- Ao segurar o LMB mirando no terreno, um temporizador de dano acumula
  (`mine_duration_seconds`, padrão 1,2 s por bloco).
- Ao completar cada ciclo:
  1. `VoxelWorld.mine_voxel()` remove o voxel (TYPE + SDF, persiste o delta).
  2. Uma **subtração booleana de esfera SDF** (`VoxelTool.do_sphere`) é aplicada
     no ponto de impacto (raio configurável: `mine_sdf_radius = 0.6`).
  3. Um **fragmento físico** (`RigidBody3D`) é instanciado na posição do voxel
     e ejetado com impulso suave na direção da normal da superfície.
- Soltar o LMB cancela o progresso do ciclo atual.
- Trocar de alvo durante o hold reinicia o progresso para zero.
- Decal de rachadura em 4 estágios e barra de progresso no HUD atualizam
  em tempo real.

### 12.2 Fragmentos Físicos

- Cada fragmento é um `RigidBody3D` com `BoxMesh` procedural (0,25–0,45 m)
  colorido pelo tipo de material (pedra, terra, carvão, etc.).
- Fragmentos possuem metadados: `mined_fragment = true`, `fragment_type = <tipo>`.
- Uma cena personalizada (`mine_fragment_scene`) pode ser atribuída no
  `PlayerController` para substituir o fragmento procedural.
- Fragmentos se autodestróem após **30 segundos** para evitar acúmulo.

### 12.3 Coleta Ativa de Fragmentos

- O jogador **segura um botão de interação** para criar um campo de
  "vácuo" que atrai fragmentos próximos para o inventário.
- Fragmentos **não são coletados automaticamente** — impede roubo
  acidental por minions de IA.
- Escopo futuro: raio de coleta configurável, feedback sonoro/visual.

### 12.4 Processamento de Madeira

- Árvores derrubadas soltam **troncos físicos** (`RigidBody3D`).
- Troncos devem ser colocados em um **bloco de corte** (chopping block).
- A ação de cortar divide o tronco em **tábuas** (planks).

### 12.5 Pallet de Fabricação

- Estrutura baixa de tábuas construída e posicionada pelo jogador.
- O jogador **lança/dropa fragmentos** sobre o pallet.
- **Segurar RMB** sobre o pallet abre um **Radial Menu** com moldes
  disponíveis baseados nos materiais presentes no pallet.
- **Segurar Space** confirma e processa o lote.

### 12.6 Rendimento em Lote

- O pallet produz **lotes proporcionais** de blocos físicos acabados.
  Exemplo: um lote de fragmentos de pedra bruta → oito blocos 1×1
  empilhados fisicamente sobre o pallet.
- A receita de cada molde define tipo e quantidade de fragmentos
  necessários; valores finais definidos durante o balanceamento.

### 12.7 Regra de Coleta pelo Topo (Top-Down Pickup Rule)

- Tecla **E** → pegar bloco. Tecla **R** → colocar bloco.
- O jogador só pode pegar um bloco se ele for o **bloco mais acima**
  na pilha (nenhuma outra estrutura apoiada sobre ele).
- Blocos estruturais (com outros blocos apoiados) **devem ser minerados**,
  não simplesmente pegos.
- Objetivo: preservar a integridade estrutural durante a manipulação manual.

### 12.8 Notas de Implementação

- **Milestone atual:** Mineração gradual e spawn de fragmento implementados
  em `PlayerController.gd` (LMB hold-to-mine + `_process_lmb_mining` +
  `_spawn_voxel_fragment`).
- **Pendente:** Coleta ativa (campo de vácuo), troncos de árvore, bloco de
  corte, pallet, radial menu e regra de coleta pelo topo são marcos futuros.
