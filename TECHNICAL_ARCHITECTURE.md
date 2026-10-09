# GAME DESIGN SCOPE --- Projeto 3D inspirado em Castle Story

> Documento vivo de design. Decisões confirmadas devem ser tratadas como requisitos;
> detalhes ainda não definidos devem permanecer em aberto, sem serem inventados
> pelo agente de desenvolvimento.

## 1. Visão do jogo

Criar um jogo 3D de construção, sobrevivência e gerenciamento inspirado
principalmente em **Castle Story**, com elementos de construção em
blocos de **Minecraft**. O foco é tornar a construção prazerosa,
permitir estruturas fisicamente convincentes e evitar que danos ou
ataques obriguem o jogador a refazer tudo manualmente.

A identidade do jogo deve ser própria. As referências orientam as
mecânicas, não uma reprodução literal de outros jogos.

A experiência principal será em **primeira pessoa**, combinada com uma
habilidade chamada provisoriamente **Projeção Espiritual**: o jogador pode
desprender a câmera do corpo e controlá-la livremente para construir,
inspecionar estruturas e gerenciar a base em grande escala.

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
-   **Presença e visão ampla:** explorar o mundo em primeira pessoa e usar
    a Projeção Espiritual para facilitar construção e gerenciamento em escala.

## 3. Câmera, personagem e Projeção Espiritual

### 3.1 Modo corporal — primeira pessoa

- A primeira pessoa é a experiência padrão para explorar e interagir com o mundo.
- O personagem físico terá movimento, gravidade e colisões com o ambiente.
- A mira central/raycast será usada para interagir com blocos e objetos.
- O personagem e os sistemas de construção devem ser separados para permitir
  mudanças de modo sem duplicar a lógica de construção.

### 3.2 Projeção Espiritual — câmera livre de construção

O jogador pode projetar sua consciência para fora do corpo. A câmera se
separa do personagem e ganha movimento livre em 3D, permitindo observar
construções de qualquer ângulo e trabalhar em locais distantes sem precisar
subir fisicamente em cada parede.

- O corpo permanece parado no local onde a projeção foi iniciada.
- Na projeção, o jogador pode colocar e remover blocos, inspecionar danos
  e gerenciar construções, usando os mesmos sistemas de grade, sustentação,
  física e materiais do modo corporal.
- Ao encerrar a projeção, a câmera retorna à perspectiva do personagem.
- A Projeção Espiritual complementa os ajudantes; não substitui transporte,
  coleta, fabricação ou reconstrução automatizada.
- A câmera livre atual do protótipo pode continuar disponível como ferramenta
  de depuração/desenvolvimento, separada da habilidade usada no jogo final.
- Não definir ainda custo de energia, alcance máximo, invulnerabilidade do
  corpo ou penalidades durante a projeção. Essas regras precisam ser avaliadas
  após testar a experiência básica.

Os dois modos devem usar uma única fonte de verdade para o estado do mundo.
Não criar sistemas paralelos de construção ou física para cada câmera.

## 4. Construção em blocos e física híbrida

### 4.1 Construções estáveis

-   Construções utilizam blocos alinhados a uma grade, com encaixe
    previsível.
-   O jogo calcula sustentação, conexões e estabilidade estrutural.
-   Blocos que fazem parte de uma construção estável não precisam ser
    corpos físicos independentes em simulação contínua.
-   O jogador deve conseguir salvar/registrar estruturas como projetos
    para reconstrução posterior.

### 4.2 Desmoronamento

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

## 5. Núcleo e reconstrução automática

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

### 5.1 Projetos de construção salvos

Um projeto salvo deve registrar a disposição dos blocos e seus tipos. O
sistema de reconstrução usa esse projeto como referência, mas deve
preservar alterações manuais posteriores quando o jogador atualizar ou
substituir o registro.

Ainda precisam ser definidos: limites da área de manutenção, custo de
materiais, quantidade de ajudantes, alcance do núcleo e comportamento
quando o terreno ou o acesso mudar.

## 6. Durabilidade e recuperação de destroços

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

## 7. Mineração e fabricação de blocos

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

## 8. Direção visual: blocos e voxels

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

## 9. Tecnologia e desenvolvimento

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

## 10. Critérios de qualidade

-   Construir e remover blocos é intuitivo.
-   O modo corporal funciona em primeira pessoa com movimento e colisões.
-   A Projeção Espiritual permite construção e inspeção em câmera livre e retorna
    corretamente ao corpo, sem duplicar ou perder estado do mundo.
-   Alternar entre os modos não corrompe alvos, blocos, destroços ou estado físico.
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

## 11. Decisões confirmadas e questões em aberto

### Decisões confirmadas

- Jogo 3D para PC, desenvolvido no Godot Standard com GDScript.
- Inspiração principal em Castle Story, com construção em blocos alinhados à
  grade, visual cúbico e identidade própria.
- Primeira pessoa como modo corporal padrão.
- Projeção Espiritual como modo de câmera livre para construção, inspeção e
  gerenciamento; o corpo fica parado e a câmera retorna a ele ao encerrar.
- Os dois modos compartilham os mesmos sistemas de construção, estabilidade,
  física e recursos.
- Abordagem híbrida: blocos inteiros para construção e fragmentação física/voxel
  para destruição quando apropriado; não é necessário simular cada bloco estável
  como um corpo rígido independente.
- A reconstrução automática depende de um núcleo funcional, projetos salvos,
  ajudantes e materiais. Danos ao núcleo suspendem o sistema, mas não apagam
  projetos salvos.
- Destroços com mais de 50% de durabilidade podem voltar a ser blocos utilizáveis;
  destroços com 50% ou menos tornam-se matéria-prima, com rendimento a balancear.
- Areia, cascalho e outros materiais extraídos podem precisar ser prensados ou
  compactados antes de se tornarem blocos de construção.
- Single-player nesta fase; não implementar multiplayer sem uma decisão posterior.
- A câmera livre existente no protótipo pode ser mantida como ferramenta de debug.

### Questões ainda em aberto

Não inventar respostas definitivas sem discutir com o usuário:

- Combate, inimigos e fontes de dano além das ações básicas do jogador.
- Quantidade, funções, personalidade e comportamento detalhado dos ajudantes.
- Geração do mundo e quanto do terreno poderá ser escavado/modificado.
- Progressão, desbloqueios, receitas e balanceamento de materiais.
- Tipos finais de blocos, resistências, durabilidade e rendimento de reciclagem.
- Alcance, custo ou outras limitações da Projeção Espiritual, se necessárias.
- Se o corpo pode ser atacado ou sofrer consequências enquanto a projeção está ativa.
- Direção artística final, interface, áudio e controles definitivos.
- Escala típica das construções e metas finais de desempenho.

## 12. Orientação para o agente de IA

Antes de implementar: 1. Ler este documento e inspecionar a estrutura do
projeto. 2. Identificar decisões ainda não especificadas, sem inventar
mecânicas definitivas. 3. Propor uma arquitetura técnica modular para
aprovação. 4. Implementar em etapas pequenas e jogáveis, validando cada
sistema no Godot. 5. Executar testes, verificar erros e corrigir
regressões. 6. Atualizar este documento quando requisitos forem
explicitamente definidos ou alterados.

## 13. Histórico de Marcos e Confiabilidade Técnica

### 13.1 Milestone 1 — Fundação de Construção e Desmoronamento
- **GridSystem:** Armazenamento esparso autoritativo para blocos estáveis (`Dictionary[Vector3i, BlockData]`).
- **StabilitySystem:** Propagação de suporte baseada em BFS a partir de âncoras de fundação (`y <= ground_anchor_y` e âncoras customizadas).
- **CollapseOrchestrator:** Agrupamento de células sem suporte em componentes conectados via `IslandBuilder` e instanciação de `DebrisIsland` (`RigidBody3D`) com geometria de colisão composta exata.
- **GridRenderer:** Renderização visual e colisão estática (`StaticBody3D`) com tags de metadados em cada forma de colisão.
- **BuildCamera:** Câmera livre de desenvolvimento com posicionamento e remoção por raycast.

### 13.2 Milestone 1.1 — Confiabilidade de Física e Interação (Implementado e Validado)
- **Interação com Destroços:**
  - Remoção alvejada de blocos individuais em corpos dinâmicos (`DebrisIsland.remove_block(cell)`).
  - Resolução robusta de forma e célula através de `shape_find_owner` e `shape_owner_get_owner` com metadados `cell_coord`, eliminando problemas de indexação incorreta no PhysicsServer3D.
  - Atualização imediata de geometria de colisão (`CollisionShape3D`), malha visual (`MeshInstance3D`), massa (`BlockTypeCatalog.get_mass`) e preservação integral de metadados e tipo de bloco (`BlockData`).
  - Desconexão e divisão dinâmica (`DebrisIsland.split_into_islands` / `CollapseOrchestrator.split_debris_island`): quando a remoção de um bloco intermediário quebra a conectividade 6-vizinhança da ilha, a mesma é particionada deterministicamente em corpos rígidos independentes, preservando transformações e cinemática rígida (velocidade linear e momento angular).
  - Remoção completa do corpo rígido quando o último bloco constituinte é retirado.
- **Regras de Posicionamento Seguro e Exclusão Mútua:**
  - Rejeição de construção sobre destroços em movimento (`is_moving() = true` quando não acomodado ou com velocidade > limiar).
  - Verificação de ocupação espacial mútua (`CollapseOrchestrator.is_cell_blocked_by_debris`): rejeição de novos blocos que colidiriam com destroços existentes (ativos ou acomodados).
  - Posse estritamente mutuamente exclusiva: blocos pertencem exclusivamente ao `GridSystem` ou a um `DebrisIsland`, nunca a ambos simultaneamente.
  - Transições atômicas e determinísticas: deduplicação de células antes da remoção em lote, garantindo zero blocos duplicados, zero referências obsoletas e zero blocos fantasmas.
- **Confiabilidade Estrutural e Reavaliação Regional:**
  - Suporte à conexão do sinal `block_placed` no `StabilitySystem` para atualização imediata de células apoiadas.
  - Avaliação de impacto regional (`evaluate_affected_region`) com fallback garantido para BFS completo (`evaluate_stability`).
  - Bloqueio estrito de reentrância (`_is_evaluating`) para evitar cascatas recursivas durante o despacho do sinal de desmoronamento.
  - Isolamento de estruturas: alteração em uma estrutura não interfere na estabilidade de construções não relacionadas nem corrompe destroços preexistentes.
- **Resolução de Conflitos de Entrada:**
  - Resolução do conflito entre a movimentação lateral da câmera (`A`) e o preset de arco: preset reatribuído para `H` (`KEY_H`).
  - Interface do usuário (`BuildHUD.tscn`) e dicas visuais atualizadas para refletir exatamente os atalhos vigentes e a capacidade de remoção de blocos em destroços.
- **Validação e Testes Executados:**
  - Suíte M1 (`tests/test_m1.gd`): 11/11 testes aprovados com sucesso.
  - Suíte M1.1 (`tests/test_m1_1.gd`): 11/11 testes de regressão aprovados com sucesso.
  - Teste de Integração em Tempo Real (`tests/test_scene_runtime.gd`): aprovado com sucesso (criação de torre, corte de base, geração de destroços, remoção de bloco de destroço em tempo real, presets de ponte e arco, limpeza do mundo).
  - Execução no Godot 4.7.2 Forward+ D3D12 Standard (GPU AMD Radeon RX 6700 XT): inicialização e renderização validadas com código de saída 0.

### 13.3 Milestone 2 — Controlador em Primeira Pessoa & Projeção Espiritual (Implementado e Validado)
- **Controlador Físico em Primeira Pessoa (`Player.tscn` / `PlayerController.gd`):**
  - Implementado como `CharacterBody3D` reutilizável com `CollisionShape3D` (cápsula: raio 0.4m, altura 1.8m) na camada de colisão 2 e máscara 1 (ambiente estático).
  - Suporte completo a locomoção física: WASD, gravidade (`gravity = 14.0`), pulo (`jump_velocity = 4.8`), corrida com multiplicador configurável (`walk_speed = 6.0`, `sprint_speed_multiplier = 1.75`), detecção de chão via `is_on_floor()` e rotação de câmera com sensibilidade configurável (`mouse_sensitivity = 0.003`).
  - Prevenção de bloqueio e penetração no terreno e estruturas estáticas através de `move_and_slide()`.
- **Máquina de Estados de Projeção Espiritual (`State` Enum):**
  - **`BODY_CONTROL`:** O jogador controla o corpo físico em primeira pessoa com a câmera acoplada à cabeça (`Head/BodyCamera`).
  - **`SOUL_PROJECTION`:** Ao pressionar `soul_projection` (teclas `V` ou `P`), a consciência se desprende para uma câmera livre `ProjectionCamera` (`top_level = true`). O corpo físico é mantido estritamente estacionário no mundo (`velocity = Vector3.ZERO`), sem sofrer deslocamentos por movimentação.
  - O voo na projeção suporta movimentação 3D livre (WASD + Espaço para subir + Ctrl/C para descer + Shift para acelerar) com velocidade configurável (`projection_speed = 12.0`, `projection_fast_multiplier = 2.5`).
  - Ao alternar novamente a ação `soul_projection`, a visualização retorna imediatamente ao corpo físico, restaurando a perspectiva de primeira pessoa, física e gravidade, comprovando que o corpo não se deslocou durante o uso da habilidade.
  - Zero mecânicas restritivas inventadas: sem custos de energia arbitrários, sem limites artificiais de alcance e sem tempos de recarga inexistentes no `GAME_DESIGN.md`.
- **Interação Unificada de Construção e Remoção:**
  - Raycast centralizado gerado a partir da câmera ativa em cada modo (`get_active_camera()`).
  - Posicionamento (LMB) e remoção (RMB) consistentes tanto no corpo quanto na projeção.
  - Proteção contra sobreposição na cápsula do jogador (`is_cell_overlapping_player`): impede o jogador de posicionar blocos que colidiriam com o próprio corpo em qualquer dos modos.
  - Preservação integral das regras de posicionamento seguro e remoção em destroços do marco M1.1.
  - Seleção de materiais (1: Pedra, 2: Madeira, 3: Tijolo, 4: Ouro, ou roda do mouse) e atalhos de presets (T: Torre, B: Ponte, H: Arco, C: Limpar mundo).
- **Câmera de Desenvolvimento / Depuração Separada (`DEBUG_FLIGHT`):**
  - Câmera livre de desenvolvimento (`BuildCamera.gd`) preservada e acionável via `F1` (`debug_camera`), desvinculada da mecânica canônica de Projeção Espiritual.
  - O modo padrão de jogo ao iniciar é o personagem físico em primeira pessoa.
- **Gerenciador de Entradas Autoload (`InputManager.gd`):**
  - Registro dinâmico e idempotente de ações no `InputMap` do Godot: `move_forward`, `move_backward`, `move_left`, `move_right`, `jump`, `sprint`, `fly_up`, `fly_down`, `soul_projection`, `debug_camera`, `place_block`, `remove_block`, `toggle_mouse_capture`.
  - Interface do usuário (`BuildHUD.tscn` / `BuildHUD.gd`) atualizada com indicador de modo ativo (Corpo / Projeção / Câmera Livre) e painel completo de instruções.
- **Validação e Testes Executados:**
  - Suíte M1 (`tests/test_m1.gd`): 11/11 testes aprovados.
  - Suíte M1.1 (`tests/test_m1_1.gd`): 11/11 testes aprovados.
  - Suíte M2 (`tests/test_m2.gd`): 7/7 testes aprovados (`test_player_scene_instantiation_and_nodes`, `test_first_person_movement_and_gravity`, `test_soul_projection_state_machine`, `test_capsule_overlap_placement_prevention`, `test_shared_building_in_both_modes`, `test_debug_camera_separate_from_soul_projection`, `test_input_actions_exist_and_no_conflicts`).
  - Total de testes automatizados: **29/29 aprovados (0 falhas)**.
  - Teste de Integração em Tempo Real (`tests/test_scene_runtime.gd`): aprovado com sucesso.
  - Renderização no Godot 4.7.2 Forward+ D3D12 Standard (GPU AMD Radeon RX 6700 XT): inicialização do mundo com o jogador em primeira pessoa validada sem erros.

### 13.4 Limitações Restantes e Próximos Passos
- Ajudantes (workers), projetos salvos (blueprints), sistema de durabilidade detalhada, reciclagem com prensa, mineração e inventário permanecem em aberto para os marcos futuros (M3+).


