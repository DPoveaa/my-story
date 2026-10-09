# TECHNICAL ARCHITECTURE — MyStory

> **Engine**: Godot 4.7.2 Standard · **Language**: GDScript · **Physics**: Jolt Physics · **Renderer**: Forward Plus (D3D12)
>
> This document records technical decisions, system design, implementation roadmap,
> and acceptance tests. It does **not** repeat GAME_DESIGN.md. Read that document
> first for vision and requirements.
>
> Last updated: 2026-10-09

---

## 1. Project State Snapshot

| Item | Status |
|---|---|
| Engine | Godot 4.7 (config_version = 5) |
| Physics backend | Jolt Physics (3d/physics_engine) |
| Renderer | Forward Plus, D3D12 on Windows |
| Scenes/Scripts | **None — blank slate** |
| Assets | Default icon only |

Everything must be built from scratch. This is an advantage: no legacy debt.

---

## 2. Architecture Overview

The game is split into **nine loosely-coupled autoload singletons and scene-local
managers**. Each owns a clearly defined slice of data and exposes a signal-based
interface. No system calls another system's internals directly.

```
┌───────────────────────────────────────────────────────────┐
│                      GameWorld (scene root)               │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │  GridMap /   │  │  PhysicsWorld│  │  DebrisTracker │  │
│  │  ChunkManager│  │  (Jolt RBs)  │  │                │  │
│  └──────┬───────┘  └──────┬───────┘  └───────┬────────┘  │
│         │                 │                  │            │
│  ┌──────▼───────────────────────────────────▼────────┐   │
│  │               StabilitySystem (autoload)           │   │
│  └──────────────────────────┬─────────────────────────┘   │
│                             │ signals collapse events      │
│  ┌──────────────────────────▼─────────────────────────┐   │
│  │              CollapseOrchestrator                  │   │
│  │  (decides which chunks become rigid bodies)        │   │
│  └─────────────────────────────────────────────────── ┘   │
│                                                           │
│  ┌─────────────┐  ┌────────────────┐  ┌──────────────┐   │
│  │ CoreManager │  │ WorkerAI       │  │BlueprintStore│   │
│  │ (autoload)  │  │ (NavigationAI) │  │ (autoload)   │   │
│  └─────────────┘  └────────────────┘  └──────────────┘   │
│                                                           │
│  ┌──────────────────┐  ┌───────────────────────────────┐  │
│  │ InventorySystem  │  │ CraftingSystem                │  │
│  │ (autoload)       │  │ (autoload)                    │  │
│  └──────────────────┘  └───────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

---

## 3. System Definitions

### 3.1 GridSystem (autoload: `GridSystem`)

**Responsibility**: owns the canonical grid state — the definitive record of which
block type occupies every cell.

| Item | Decision |
|---|---|
| Storage | `Dictionary[Vector3i, BlockData]` (sparse; only occupied cells stored) |
| Cell size | 1 m³ default — configurable via a project constant `CELL_SIZE` |
| Chunk size | 16 × 16 × 16 cells per chunk |
| Coordinate | `Vector3i` (integer grid coords); world position = `cell * CELL_SIZE` |
| Serialization | `Dictionary` → JSON / Godot binary resource for save/load |

**Key signals**:
- `block_placed(cell: Vector3i, block_type: StringName)`
- `block_removed(cell: Vector3i, previous_type: StringName)`

**No physics**. GridSystem is purely data. It does not own any Node3D.

---

### 3.2 StabilitySystem (autoload: `StabilitySystem`)

**Responsibility**: determines which grid cells are structurally supported and
which are floating after every placement/removal event.

**Algorithm — flood-fill connectivity**:
1. Maintain a `supported_set: Dictionary[Vector3i, bool]`.
2. On every `block_placed` or `block_removed` signal, re-evaluate affected cells
   using a **breadth-first flood from ground anchors** (y == 0, or any block
   tagged `GROUND_ANCHOR`).
3. Any occupied cell not reachable from an anchor is **unsupported**.
4. Batch evaluation: run the BFS at the end of the frame (via `call_deferred` or
   a dirty-flag queue) so rapid multi-block changes produce one BFS pass.

**Performance ceiling**: BFS on a 64 × 64 × 64 grid = 262 144 cells max.
Pure GDScript BFS at ~1M lookups/s → less than 0.3 ms for typical castle-sized builds.
If profiling shows bottlenecks, move BFS to a C# extension or a thread.

**Key signals**:
- `stability_changed(unsupported_cells: Array[Vector3i])`

**Does not move blocks**. It only identifies them.

---

### 3.3 CollapseOrchestrator (`CollapseOrchestrator.gd`, scene-local node)

**Responsibility**: translates `stability_changed` events into physics events.
This is the **critical bridge between the static grid and dynamic Jolt physics**.

**Transition strategy — Island grouping**:

1. Receive the `unsupported_cells` array from `StabilitySystem`.
2. **Group adjacent unsupported cells into islands** using a second BFS pass.
   Each island becomes one `RigidBody3D`, not one body per block.
3. Build island mesh: create a single `MeshInstance3D` + `CollisionShape3D`
   (compound trimesh or per-block box shapes) for the island body.
4. Remove the falling cells from `GridSystem`.
5. Add the island `RigidBody3D` to the scene tree → Jolt simulates it.
6. On `body_sleeping_state_changed(true)`: the island has settled → hand off to
   `DebrisTracker`.

**Why island grouping?**
- A 50-block wall that detaches becomes 1 rigid body, not 50.
- Compound box colliders are very fast in Jolt.
- Each settling body can be immediately optimised by Jolt's sleeping mechanism.

**Chain reactions**: when a falling island collides with a supported structure,
emit an impulse check. If impact force > block durability threshold, flag those
cells dirty → re-run StabilitySystem → repeat. Cap chain-reaction depth per frame
to avoid spiral cost.

---

### 3.4 DebrisTracker (scene-local node or autoload)

**Responsibility**: manages settled rigid-body debris — keeps them alive for
collection, prevents them from accumulating forever, tracks their durability.

| Concern | Decision |
|---|---|
| Durability encoding | Each island body stores a `Dictionary[local_cell, float]` of durability values inherited from the grid |
| Settled detection | Jolt sleep signal → mark body as "settled debris" |
| Despawn policy | Never despawn automatically; only worker pickup or explicit player action removes debris |
| Performance | Sleeping bodies cost near-zero CPU in Jolt; leave them until collected |
| Debris limit | Configurable cap (e.g. 200 active debris bodies). Oldest settled bodies freeze-merge into a StaticBody3D if cap exceeded |

**Recovery rule** (from GAME_DESIGN §5):
- Durability > 50% → debris becomes a reusable block item on pickup.
- Durability ≤ 50% → converts to raw materials proportional to durability.

---

### 3.5 ChunkRenderer (scene-local, one per chunk)

**Responsibility**: visual representation of the stable grid. Generates meshes on
demand; does not drive gameplay logic.

| Item | Decision |
|---|---|
| Method | `SurfaceTool` or `ArrayMesh` built per chunk; faces against empty cells only (greedy meshing v1, can upgrade) |
| Collision | Static trimesh or per-chunk `StaticBody3D` with box shapes |
| Rebuild trigger | `GridSystem.block_placed/removed` → dirty-flag → rebuild at end of frame |
| LOD | Simple distance-based: rebuild at normal detail inside 80 m, skip rebuilds beyond view distance |
| Threading | Mesh generation can be offloaded to a `Thread` since `ArrayMesh` creation is thread-safe in Godot 4 |

**First milestone**: no greedy meshing — one box mesh per block. Optimize later.

---

### 3.6 BlueprintStore (autoload: `BlueprintStore`)

**Responsibility**: save, load, and manage named construction blueprints.

```
Blueprint {
  name: String,
  origin_cell: Vector3i,         # pivot for relative offsets
  blocks: Dictionary[Vector3i, StringName],  # relative cell → block type
  saved_at: int,                 # Unix timestamp
}
```

- Blueprints are stored as Godot `Resource` files (`.tres` / `.res`) in
  `user://blueprints/`.
- A blueprint is **never deleted** when the CoreManager is destroyed (satisfying
  GAME_DESIGN §4 non-punitive constraint).
- `BlueprintStore` compares a saved blueprint against the live grid to produce a
  `BuildTask` list: `{cell: Vector3i, block_type: StringName, action: PLACE|REMOVE}`.

---

### 3.7 CoreManager (autoload: `CoreManager`)

**Responsibility**: tracks the construction core object's state and gates automatic
reconstruction.

```
enum CoreState { OPERATIONAL, DAMAGED, DESTROYED }
```

| State | Reconstruction | Worker task dispatch |
|---|---|---|
| OPERATIONAL | Enabled | Enabled |
| DAMAGED | Suspended | Suspended (core repair priority) |
| DESTROYED | Suspended | Suspended |

**Signals**:
- `core_state_changed(new_state: CoreState)`
- `reconstruction_enabled()`
- `reconstruction_disabled(reason: String)`

`CoreManager` does not perform reconstruction itself. It gates `WorkerDispatcher`.

---

### 3.8 WorkerSystem (nodes: `WorkerDispatcher`, `WorkerAgent`)

**Responsibility**: execute `BuildTask` lists generated by `BlueprintStore`.

`WorkerDispatcher` (scene-level singleton-pattern node):
- Listens to `CoreManager.reconstruction_enabled/disabled`.
- Polls pending `BuildTask` queues from `BlueprintStore`.
- Assigns tasks to idle `WorkerAgent` nodes.
- Broadcasts status to UI: no materials, path blocked, core offline.

`WorkerAgent` (one node per worker character):
- Uses `NavigationAgent3D` for pathfinding to task cell.
- On arrival: calls `GridSystem.place_block()` / `remove_block()` → consumes
  materials from `InventorySystem`.
- Reports failure reasons back to `WorkerDispatcher`.

**Open items** (per GAME_DESIGN §10): worker count, speed, and animation
depend on art direction decisions not yet made.

---

### 3.9 InventorySystem (autoload: `InventorySystem`)

**Responsibility**: owns all material and item counts. Single source of truth.

- Signals: `item_added(type, qty)`, `item_removed(type, qty)`,
  `stock_insufficient(type, needed, available)`.
- No gameplay logic. Pure data + signals.

### 3.10 CraftingSystem (autoload: `CraftingSystem`)

**Responsibility**: manages crafting station states and block fabrication recipes.

- Recipes are `Resource` files (`CraftingRecipe.gd`) — data-driven, no hardcoded
  values (balancing deferred per GAME_DESIGN §6).
- Listens for "press/compact" commands; deducts materials from `InventorySystem`,
  produces block items.

---

## 4. Data Ownership Map

| Data | Owner | Consumers |
|---|---|---|
| Grid cell state | `GridSystem` | StabilitySystem, CollapseOrchestrator, ChunkRenderer, BlueprintStore |
| Structural support set | `StabilitySystem` | CollapseOrchestrator |
| Active debris bodies | `DebrisTracker` | WorkerAgent (pickup), Player (pickup) |
| Blueprints | `BlueprintStore` | WorkerDispatcher, UI |
| Core state | `CoreManager` | WorkerDispatcher, UI |
| Materials/items | `InventorySystem` | WorkerAgent, CraftingSystem, UI |
| Worker task queue | `WorkerDispatcher` | WorkerAgent nodes |

---

## 5. Signal Flow (happy path: support removed → collapse → recovery)

```
Player removes block
  → GridSystem.remove_block(cell)
    → signal: block_removed(cell)
      → StabilitySystem (BFS, deferred)
        → signal: stability_changed([cell_A, cell_B, ...])
          → CollapseOrchestrator
            → groups islands, builds RigidBody3D
            → removes cells from GridSystem
            → ChunkRenderer rebuilds affected chunks
            → Jolt simulates fall
              → body_sleeping_state_changed(true)
                → DebrisTracker.register_debris(body)
                  → WorkerDispatcher notified (debris available)
                    → WorkerAgent navigates → picks up debris
                      → InventorySystem.add_item(block | raw_material)
```

---

## 6. Technical Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| BFS too slow on very large builds | Medium | Dirty-cell incremental BFS; defer to thread if > 5 ms |
| Too many RigidBody3D during collapse | High | Island grouping (§3.3); debris cap with freeze-merge |
| Chain reactions causing frame spikes | High | Cap chain depth per frame; process overflow next frame |
| ChunkRenderer stalls main thread | Medium | Thread-based mesh generation; frame budget limiting |
| NavigationAgent3D failing in 3D terrain | Medium | NavMesh rebake only on structural change; bake asynchronously |
| Blueprint diff diverging from live grid | Low | Diff computed lazily on demand, not stored as state |
| Jolt sleeping not triggering correctly | Low | Set `max_contacts_reported` and tune sleep thresholds; fallback timer |
| Save corruption losing blueprints | Low | Blueprints saved as separate files; never overwrite, only append |

---

## 7. Implementation Roadmap

Each milestone is **small, testable, and builds on the previous one**. Do not
start a milestone until its predecessor passes acceptance tests.

---

### M1 — Construction Grid & Physics Collapse (First Playable)

**Goal**: place and remove blocks on a 3D grid; removing a support causes a
convincing collapse.

**Scope**:
- `GridSystem` autoload: `place_block`, `remove_block`, `get_block`.
- `StabilitySystem` autoload: BFS from y=0 ground anchors.
- `CollapseOrchestrator` node: island grouping → one `RigidBody3D` per island.
- `ChunkRenderer` (single chunk, no LOD): one box mesh per block.
- Minimal test scene: flat ground, player can left-click to place/right-click
  to remove blocks; camera flies freely.
- **No workers, no inventory, no core yet.**

**Acceptance tests**:
1. Placing a block adjacent to the ground marks it supported.
2. A floating block (no ground connection) is immediately flagged unsupported.
3. Removing the base of a 5-block tower collapses the tower into one
   RigidBody3D that falls and settles.
4. A 10x10x10 cube (1000 blocks): remove one base corner block → only
   the visually unsupported section collapses, not the whole structure.
5. Adding and removing 500 blocks with no pauses: no frame drop below 30 fps.
6. Stability BFS with a 32x32x32 filled grid takes < 5 ms (profiled).
7. After collapse, a `StaticBody3D` still represents the remaining stable
   structure correctly.

**Failure cases to verify**:
- Removing a non-structural block (mid-wall) causes no collapse.
- Removing the last ground block under a floating island doesn't leave ghost
  collision shapes.
- Rapid placement/removal (spam clicks) does not produce duplicate bodies or
  orphaned cells.

---

### M2 — Durability, Debris & Pickup

**Goal**: collapsed blocks carry durability; player can pick them up and receive
items or raw materials.

**Scope**:
- `BlockData` resource: `block_type`, `durability` (0.0–1.0).
- `DebrisTracker`: register bodies on sleep, expose pickup interface.
- `InventorySystem`: counts of block items and raw materials.
- Player pickup: ray-cast to debris body → call `DebrisTracker.pickup(body)`.
- Simple HUD: item counts.

**Acceptance tests**:
1. A block with > 50% durability on pickup adds a block item to inventory.
2. A block with ≤ 50% durability on pickup adds raw materials.
3. Debris bodies persist after collapse until picked up or cap exceeded.
4. 200 sleeping debris bodies maintain > 30 fps (Jolt sleep is near-free).
5. Inventory totals match the blocks placed minus blocks removed minus durability
   losses (mass conservation check).

---

### M3 — Blueprint Save & Diff

**Goal**: player can save a structure as a blueprint; system can identify missing
blocks.

**Scope**:
- `BlueprintStore`: save/load to `user://blueprints/`.
- Blueprint diff function: compare live grid to blueprint → list `BuildTask`.
- Blueprint viewer UI (simple list of missing blocks).

**Acceptance tests**:
1. Save a structure → destroy half → diff lists exactly the destroyed blocks.
2. Blueprint file persists after simulated core-destroyed scenario.
3. After manual additions post-save, diff does not flag additions as "missing".
4. Load blueprint from disk after game restart → diff still correct.

---

### M4 — Construction Core & Worker Reconstruction

**Goal**: a core object gates reconstruction; workers rebuild from blueprints.

**Scope**:
- `CoreManager`: placed core block with state machine.
- `WorkerAgent` (1 worker): `NavigationAgent3D`, picks up task, places block.
- `WorkerDispatcher`: queue-based task assignment.
- NavMesh: `NavigationRegion3D` covering the play area; rebake on structure change.

**Acceptance tests**:
1. Core operational → workers start rebuilding missing blocks.
2. Core destroyed mid-rebuild → workers pause; blueprint not deleted.
3. Core repaired → workers resume from where they stopped.
4. Worker cannot place block if `InventorySystem` has insufficient materials →
   broadcasts `stock_insufficient` signal; UI shows reason.
5. Worker path blocked by debris → worker waits or picks alternate route;
   does not soft-lock.

---

### M5 — Crafting & Material Processing

**Goal**: raw materials can be converted to blocks at a crafting station.

**Scope**:
- `CraftingSystem` + `CraftingRecipe` resources.
- Crafting station scene: player or worker deposits materials → produces blocks.
- Data-driven recipes (no hardcoded values).

**Acceptance tests**:
1. Depositing X raw materials into station with valid recipe produces Y blocks.
2. Missing recipe → station rejects input with clear feedback.
3. Recipes can be modified via resource files without code changes.

---

### M6 — Performance & Scale Validation

**Goal**: confirm the architecture holds at Castle Story-ish scale before any
content expansion.

**Target**: 4000 blocks placed, 25% collapse, 200 debris, 4 workers active,
30+ fps on a mid-range PC.

**Scope**:
- Greedy face-merging for ChunkRenderer.
- Thread-based mesh generation.
- Incremental (dirty-cell) BFS in StabilitySystem.
- Debris freeze-merge on cap.
- NavMesh async rebake.

**Acceptance tests**:
1. 4000-block structure: < 2 ms/frame for stability BFS (incremental).
2. Chunk mesh rebuild < 4 ms per chunk (threaded).
3. 200 sleeping debris bodies: 0 fps impact from physics.
4. NavMesh rebake asynchronous: no frame hitch > 16 ms during rebake.
5. Total frame time < 33 ms under the above load at 1080p.

---

## 8. File / Directory Structure (target)

```
res://
├── autoloads/
│   ├── GridSystem.gd
│   ├── StabilitySystem.gd
│   ├── BlueprintStore.gd
│   ├── CoreManager.gd
│   ├── InventorySystem.gd
│   └── CraftingSystem.gd
├── systems/
│   ├── collapse/
│   │   ├── CollapseOrchestrator.gd
│   │   └── IslandBuilder.gd        # helper: groups cells into islands
│   ├── debris/
│   │   └── DebrisTracker.gd
│   ├── workers/
│   │   ├── WorkerDispatcher.gd
│   │   └── WorkerAgent.gd
│   └── rendering/
│       └── ChunkRenderer.gd
├── data/
│   ├── block_types/                 # BlockTypeResource.gd instances (.tres)
│   └── recipes/                    # CraftingRecipe.gd instances (.tres)
├── scenes/
│   ├── world/
│   │   └── GameWorld.tscn
│   ├── entities/
│   │   ├── Core.tscn
│   │   └── Worker.tscn
│   └── ui/
│       └── HUD.tscn
├── tests/
│   └── m1_grid_collapse_test.tscn  # one test scene per milestone
└── TECHNICAL_ARCHITECTURE.md
```

---

## 9. Decisions Requiring Your Input

These are **genuinely under-specified** in GAME_DESIGN.md. I will not invent
answers for them.

| # | Question | Why it matters architecturally |
|---|---|---|
| 1 | **Terrain**: is it a static mesh, a voxel grid, or a heightmap? | Determines whether the NavMesh must handle destructible terrain and whether ChunkRenderer needs a separate terrain pass |
| 2 | **Grid cell size**: 1 m³ seems correct for Castle Story scale — confirm or adjust | Affects physics body sizes, greedy meshing strategy, and readable construction scale |
| 3 | **Structural support model**: pure vertical (gravity only) or also lateral (arches, bridges)? | Determines BFS anchor rules. Lateral support requires diagonal/horizontal connectivity checks |
| 4 | **Worker count and character representation**: placeholder capsule vs. full character? | Determines when to invest in NavMesh complexity and animation systems |
| 5 | **Combat / damage source**: does damage come from enemies, the environment, or the player? | CollapseOrchestrator needs an `apply_damage(cell, amount)` entry point now; the caller is unknown |
| 6 | **Save format preference**: JSON (human-readable, debuggable) or Godot binary resource (faster, smaller)? | One format should be chosen for `GridSystem` and `BlueprintStore` from the start |
| 7 | **Multiplayer**: single-player only, or is co-op a future consideration? | Would fundamentally change `GridSystem` ownership and network authority from day one |

---

## 10. Non-Decisions (Resolved by Engineering Judgment)

The following were resolved without requiring input, consistent with constraints:

- **Island grouping over per-block RigidBody3D** — required for performance; not a design choice.
- **Sparse Dictionary grid** — correct for a block game with mostly empty space.
- **Deferred BFS** — avoids redundant recalculations during rapid edits; standard technique.
- **Jolt sleep for debris** — Jolt's explicit sleep API makes this trivial and reliable.
- **Blueprints as separate files** — directly satisfies the non-punitive constraint in GAME_DESIGN §4.
- **Autoloads for data-owning systems** — prevents scene instancing issues with cross-system data.
- **No physics on stable blocks** — explicitly required by GAME_DESIGN §3.1; island RB only on collapse.
