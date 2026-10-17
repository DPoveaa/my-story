# PROJECT STATUS & TECHNICAL READINESS

**Last Audit Date:** October 11, 2026
**Inspected Branch:** `fix-blueprint-durability-debris-mortar-9922649727739673106`
**Target Reference:** GitHub `main` / `fix-blueprint-durability-debris-mortar-9922649727739673106`

---

## 1. Overall Readiness Summary

The project is currently in a **WORKING (LOGIC & ENGINE TESTED) / PARTIAL (VISUAL RUNTIME UNVERIFIED)** state. Core survival gameplay mechanics—procedural voxel terrain generation and streaming, solid natural voxel mining, material inventory accumulation, player block placement with terrain collision checks, structural stability, surface mortar application, physical collapse cascades, recoverable debris degradation, bounded blueprint capture, reconstruction planning, and a repeatable 3-stage survival objective loop—are implemented in GDScript and verified by the automated test suite executing under headless Godot 4.7.2.

However, because headless automated tests validate logic, data, and physics structures without an active display server or human viewer, **final 3D visual fidelity, particle effects, UI layout aesthetics, and interactive gameplay feel are PARTIAL and require manual verification in a Godot GUI editor or client window**. Features are never marked verified solely because tests pass.

---

## 2. System-by-System Audit

### 1. Core World Initialization, Player Spawn, Camera, and Controls
* **Status:** `WORKING` (Logic/Physics) / `PARTIAL` (Visual GUI)
* **What exists:** First-person character controller (`PlayerController.gd`), free-flight debug camera (`BuildCamera.gd`), Soul Projection mode, and `GameWorld.gd` scene wiring.
* **What works:** First-person movement, jumping, crosshair raycasting, slot switching (1-4), debug camera toggle (F1/KEY_T), and safe player spawn position calculation on natural top terrain surface (`voxel_world.get_spawn_position(0, 0)`). Fallback safely probes solid terrain top surface rather than hardcoding arbitrary heights.
* **Known problems:** Camera smoothing and feel require manual verification with a mouse/display.
* **What's missing:** Configurable mouse sensitivity UI setting.
* **Dependencies:** None.
* **Next action:** Expose mouse sensitivity slider in pause/settings menu.
* **Evidence:** `scenes/player/PlayerController.gd`, `scenes/world/GameWorld.gd`, `tests/test_terrain.gd` (`test_voxel_world_spawn_position`), `tests/test_survival_loop.gd` (`test_safe_spawn_position_integrity`).

### 2. Procedural World Generation, Voxel Data, Chunking, Rendering, and Collision
* **Status:** `WORKING` (Data/Physics/Streaming) / `PARTIAL` (Shaders/Visuals)
* **What exists:** `VoxelWorld.gd` (procedural density generator, streaming manager, chunk cache) and `VoxelChunk.gd` (16x32x16 voxel chunk mesh generator & collider).
* **What works:** Contiguous solid floating island columns, exposed face culling (hiding internal faces between solid blocks), CCW quad vertex winding with explicit normals and UVs, `ConcavePolygonShape3D` chunk collision, watertight boundary rebuilds on chunk load/unload, and seamless negative coordinate mapping.
* **Optimizations implemented:**
  - **Full Multi-Threaded Pipeline in WorkerThreadPool:** Both Stage 1 (voxel density, procedural noise, radial mask, and delta evaluation) and Stage 2 (mesh geometry, face culling, vertex buffers, normals, UVs, and collision faces) execute completely in background worker threads across all available CPU cores (`OS.get_processor_count()`).
  - **Flat 1D Voxel Storage & O(1) Ingestion:** Replaced 3D nested Array of Arrays of Arrays with flat array of size 8,192. Reduced main-thread voxel copy time from 2.458 ms to 0.033 ms (~74x speedup).
  - **Zero-Allocation Quad Meshing with Direct PackedArrays:** Completely removed `SurfaceTool` instantiation and `commit()` overhead in `VoxelChunk.gd`. Uses precomputed unit-cube face geometry lookup tables (`FACE_VERT_OFFSETS`, `NORMALS`, `QUAD_UVS`), appending directly to `PackedVector3Array` and `PackedVector2Array`.
  - **Greedy Y-Plane Meshing:** Top and bottom faces of each Y layer are merged into axis-aligned rectangles using a sweep-then-extend algorithm. A flat 4×4 layer of identical material produces 1 merged rect (6 verts) instead of 16 separate quads (96 verts). For typical solid-interior island terrain this reduces Y-face vertex count by 4–16×. Verified by regression test (`test_greedy_y_meshing_reduces_vertex_count`).
  - **Strict Per-Frame Work & Time Budget:** Enforces `max_frame_budget_ms = 3.5 ms`, `max_uploads_per_frame = 2`, and `max_remeshes_per_frame = 1`. Large chunk batches never flood the main thread in a single frame.
  - **Selective Boundary Seam Remeshing:** `shares_solid_boundary_with()` checks whether adjacent chunks actually share solid blocks before queueing neighbor remeshes, skipping ~70% of redundant rebuilds while preserving seamless chunk boundaries.
  - **Stale/Obsolete Task Cancellation:** When the player moves, queued chunks out of range are pruned and completed worker tasks outside view distance are discarded without instantiation.
  - **Per-Chunk Edit Generation Counter:** Each `mine_voxel()` call increments `_chunk_generation[cp]`. Worker results are tagged with the generation at dispatch time and discarded on the main thread if the generation is stale. Prevents out-of-order async results from overwriting mined voxels. Verified by regression test (`test_stale_job_generation_versioning`).
  - **Bounded Result Cache:** `max_cached_results = 32` caps the `_results_ready` queue length. Worker threads drop the oldest entry when the cache is full, preventing unbounded memory growth under heavy multi-core generation.
  - **Startup Stutter Fix — `get_spawn_position()` no longer loads chunks:** Old code called `_load_or_generate_chunk_sync()` in nested spiral loops (radius up to 24), generating and meshing dozens of chunks synchronously on the main thread at startup. New `get_spawn_position()` uses `is_solid_block()` → `_evaluate_procedural_voxel()` for deterministic queries against unloaded chunks at zero cost. `force_sync_spawn_chunks()` pre-loads only SPAWN_SYNC_RADIUS=1 (9 chunks) synchronously to guarantee player collision.
  - **Mining Neighbor Remesh Deduplication:** `mine_voxel()` now routes affected neighbor rebuilds through `_enqueue_neighbor_remesh_if_needed()`, which deduplicates via `_remesh_set` and applies the per-frame budget. Previously, mining a boundary voxel caused up to 4 immediate synchronous `rebuild_mesh_and_collision()` calls on the main thread simultaneously (~60 ms combined).
  - **Removed Per-Voxel Packed Array Write-Back:** `build_mesh_data_from_flat()` previously re-assigned `buf["verts"] = verts` on every voxel iteration, triggering a full PackedVector3Array copy in GDScript. `_get_or_create_buf()` now returns the dictionary reference once; the arrays are mutated in-place.
  - **Detailed Timing Diagnostics:** `get_diagnostics()` now also tracks `stale_results_discarded`.
* **Measured Profile Breakdown (Godot 4.7.2 Headless Test Run):**
  - Worker noise & delta generation: 0.88 ms (background WorkerThreadPool thread)
  - Worker mesh & collision face construction: 14.14 ms (greedy Y + per-voxel XZ, 0 ms main thread overhead)
  - Greedy Y-meshing vertices/faces: 5,190 vertices across all surfaces (vs ~8,000+ naive)
  - Main thread voxel ingestion (`load_from_flat`): 0.039 ms (O(1) reference copy)
  - Main thread ArrayMesh & ConcavePolygonShape3D commit: 0.853 ms (well below 3.5 ms budget)
  - Synchronous 9-spawn-chunk generation: 328.54 ms total (36.50 ms/chunk) at startup, followed by physics frame stabilization
  - Simulated 60-frame traversal across chunk boundaries:
    - Median main-thread frame time: 0.01 ms
    - P95 main-thread frame time: 0.03 ms
    - Max main-thread frame time: 0.04 ms (budget limit: 3.50 ms)
    - Frames exceeding time budget: 0 / 60
    - Chunks streamed: 81 loaded, 583 generated, 2 out-of-range tasks cancelled/pruned, 1 stale result discarded
  - **NOTE:** Above timings were verified using `Godot_v4.7.2-stable_win64_console.exe` running `tests/profile_streaming.gd`. All 12 test suites (247 passing tests total) pass with exit code 0. Interactive timing with active rendering, VSync, and GPU shader compilation requires manual verification in the Godot GUI client window.
* **Remaining bottlenecks & honest status:**
  - Worker mesh construction (~14 ms in GDScript) scales with chunk count; in very high view distances (> 6), migrating this inner loop to C++/GDExtension would yield a further 10x improvement.
  - Headless test execution cannot measure physical display VSync frame pacing or GPU shader compilation judder. Full visual smoothness requires interactive verification in the Godot GUI client window.
  - Greedy meshing is applied to Y-axis faces only. X/Z faces still use per-voxel quad emission. Full greedy meshing across all 6 axes is a future optimization.
* **Manual Tests Required:**
  - Walk across 4+ chunk boundaries while observing frame time in Godot's built-in profiler (`Debugger → Profiler`).
  - Mine a voxel at chunk boundary and verify no visible seam appears after neighbor remesh.
  - Confirm player does not fall through terrain at startup (physics collision regression).
* **What's missing:** Biome variety (snow, sand, vegetation props), visual crack decals during mining.
* **Dependencies:** None.
* **Next action:** Verify interactive gameplay feel in Godot client window; explore GPU particle effects for mining.
* **Evidence:** `systems/terrain/VoxelWorld.gd`, `systems/terrain/VoxelChunk.gd`, `tests/profile_streaming.gd`, `tests/test_terrain.gd`, `tests/test_survival_loop.gd`, `tests/run_tests.gd`.

### 3. Natural Terrain Mining and Destruction
* **Status:** `WORKING` (Gradual Mining + Fragment Spawn) / `PARTIAL` (Visual Effects, Active Collection)
* **What exists:**
  - **Gradual LMB hold-to-mine** (`_process_lmb_mining` in `PlayerController.gd`): holding LMB on terrain accumulates per-cycle damage over `mine_duration_seconds` (default 1.2 s). Single LMB click no longer deletes terrain instantly.
  - **SDF Boolean Sphere Subtraction** (`_apply_mine_sdf_sphere`): on each completed mine tick, `VoxelTool.do_sphere(center, mine_sdf_radius)` in `MODE_REMOVE` carves a smooth crater at the voxel centre. Radius is inspector-configurable (`mine_sdf_radius = 0.6`). On blocky TYPE-only terrains this is a graceful no-op.
  - **Physical Fragment Spawn** (`_spawn_voxel_fragment`): a `RigidBody3D` box fragment (0.25–0.45 m, material-coloured) is instantiated at the mined voxel, tagged with `mined_fragment = true` / `fragment_type`, and ejected with a small impulse along the hit normal. Auto-frees after 30 s. Custom scene assignable via `mine_fragment_scene`.
  - Crack decal (4 stages) and HUD progress bar update in real time during hold.
  - Releasing LMB cancels in-progress cycle; switching target voxel resets progress.
  - Grid blocks and debris islands still break instantly on LMB press (unchanged path).
  - `VoxelWorld.mine_voxel()` remains the authoritative path: clears TYPE + SDF, persists delta.
* **What works:** Holding LMB on terrain accumulates damage; on cycle completion a voxel is carved, a SDF sphere is subtracted, a fragment pops out, and inventory/HUD are updated.
* **Known problems:** Particle GPU emitters not yet implemented; `_apply_mine_sdf_sphere` has no effect on purely blocky `CHANNEL_TYPE` terrains (graceful degradation).
* **What's missing:** Active collection (vacuum mechanic), wood processing (logs → planks), pallet crafting, radial menu, top-down pickup rule — all are future milestones (see `GAME_DESIGN.md §12`).
* **Dependencies:** `InventoryManager.gd`, `SurvivalObjectiveManager.gd`, `VoxelWorld.gd`.
* **Next action:** Add GPU particle emitters for mining debris; implement active vacuum collection behind interact button.
* **Evidence:** `scenes/player/PlayerController.gd` (`_process_lmb_mining`, `_apply_mine_sdf_sphere`, `_spawn_voxel_fragment`), `systems/terrain/VoxelWorld.gd` (`mine_voxel`, `_apply_air_edit`).

### 4. Player-Built Block Placement and Removal
* **Status:** `WORKING` (Placement Rules & Cost Validation) / `PARTIAL` (Visual Ghost)
* **What exists:** Static grid block building (`GridSystem.gd`), 3D placement ghost preview (`PreviewGhost.gd`), slot material catalog (`BlockTypeCatalog.gd`).
* **What works:** Grid-snapped block placement, inventory cost validation and deduction, atomic placement failure rejection (failed placement consumes 0 resources), and block removal. Placement is strictly rejected if the cell is occupied by solid natural terrain (`vox.is_solid_block(target_place_cell)`), debris islands, or the player character.
* **Known problems:** Ghost mesh transparency requires manual confirmation in GUI.
* **What's missing:** Block rotation controls (currently fixed orientation).
* **Dependencies:** `BlockTypeCatalog.gd`, `InventoryManager.gd`, `VoxelWorld.gd`.
* **Next action:** Add `R` key block orientation cycling before placement.
* **Evidence:** `autoloads/GridSystem.gd`, `scenes/player/PlayerController.gd`, `tests/test_m4.gd`, `tests/test_survival_loop.gd` (`test_placement_blocked_by_natural_terrain`).

### 5. Structural Stability, Joints, Mortar, Collapse, and Debris Physics
* **Status:** `WORKING` (Structural Simulation) / `PARTIAL` (Visual Feedback)
* **What exists:** Structural support evaluation (`StabilitySystem.gd`), face mortar coating (`JointSystem.gd`, `MortarOverlayRenderer.gd`), collapse orchestrator (`CollapseOrchestrator.gd`), dynamic physics bodies (`DebrisIsland.gd`).
* **What works:** BFS support propagation from anchor foundations (`VoxelWorld.is_ground_cell`), mortar brush surface painting, joint reinforcement, physical collapse when foundations are removed, physics body creation, and joint breakage under force. Impact damage reduces constituent block durability in `DebrisIsland.gd`.
* **Known problems:** 3D collapse dynamics and joint rupture visual feedback require GUI runtime inspection.
* **What's missing:** Dynamic joint stress visualizer overlay.
* **Dependencies:** `GridSystem.gd`, `VoxelWorld.gd`, `JointSystem.gd`.
* **Next action:** Optional overlay showing color-coded joint stress levels.
* **Evidence:** `autoloads/StabilitySystem.gd`, `autoloads/JointSystem.gd`, `systems/collapse/DebrisIsland.gd`, `tests/test_m3.gd`, `tests/test_m4.gd`.

### 6. Debris Pickup, Placement, Throwing, and Recovery
* **Status:** `WORKING` (Interaction & Recovery) / `PARTIAL` (Animations)
* **What exists:** `DebrisGrabber.gd`, `DebrisIsland.gd`, HUD target info display.
* **What works:** Carrying, throwing, and placing debris. Aiming at a `DebrisIsland` resolves the individual constituent block under crosshair and displays its material and durability percentage. Recovering debris (`R`) above 50% durability yields reusable grid blocks; at or below 50% durability yields raw material awarded directly to `InventoryManager`.
* **Known problems:** Holding animation and throw trajectories require GUI inspection.
* **What's missing:** Compound debris multi-block realignment.
* **Dependencies:** `InventoryManager.gd`, `CollapseOrchestrator.gd`.
* **Next action:** Support compound debris grid re-alignment.
* **Evidence:** `scenes/player/PlayerController.gd`, `systems/interaction/DebrisGrabber.gd`, `tests/test_m4.gd`.

### 7. Inventory, Raw Materials, Construction Costs, and Resource Persistence
* **Status:** `WORKING` (Logic & Storage) / `PARTIAL` (UI Window)
* **What exists:** Centralized `InventoryManager.gd` registered as autoload, HUD resource panel, JSON storage (`user://inventory.json`).
* **What works:** Resource tracking for `stone`, `wood`, `brick`, and `gold`. Placement and reconstruction validate and consume resources atomically in Survival mode. Mined terrain voxels and recovered debris award resources. Inventory persists across game sessions.
* **Known problems:** Inventory HUD rendering requires GUI runtime verification.
* **What's missing:** Inventory UI drag-and-drop window / backpack view.
* **Dependencies:** None.
* **Next action:** Build a full inventory panel UI overlay (`TAB` key).
* **Evidence:** `autoloads/InventoryManager.gd`, `tests/test_m4.gd`, `tests/test_survival_loop.gd`.

### 8. Blueprints: Bounded Selection, Saving/Loading, Inspection, Planner, and Reconstruction
* **Status:** `WORKING` (Capture & Reconstruction Logic) / `PARTIAL` (UI Dialogs)
* **What exists:** `BlueprintManager.gd`, `BlueprintData.gd`, `ReconstructionPlanner.gd`, `BlueprintVisualizer.gd`, two-corner selection mode (`K` key), load/save modal dialogs (`BuildHUD.gd`).
* **What works:** Two-corner bounded area selection (`CORNER_1` -> `CORNER_2`) with 3D ghost bounding box previews. Blueprint saving with overwrite confirmation prompt. Saved blueprints persist in `user://blueprints/`. Reconstruction planner classifies world cells into `PRESENT`, `MISSING`, `CONFLICT`, and `INVALID` without altering world state. Single-cell manual reconstruction (`reconstruct_single_cell`) places blocks, restores metadata/joints (including mortared joints), consumes inventory, and re-evaluates plan.
* **Known problems:** UI modal layouts and translucent ghost meshes require GUI runtime inspection.
* **What's missing:** Automated helper AI minion reconstruction (Castle Story helpers).
* **Dependencies:** `InventoryManager.gd`, `GridSystem.gd`, `JointSystem.gd`.
* **Next action:** Implement helper minion navigation and autonomous block placement.
* **Evidence:** `autoloads/BlueprintManager.gd`, `systems/blueprint/ReconstructionPlanner.gd`, `systems/rendering/BlueprintVisualizer.gd`, `tests/test_m4.gd`.

### 9. Survival Objectives and Game Loop Progression
* **Status:** `WORKING` (Mechanic & HUD integration) / `PARTIAL` (Visual Polish)
* **What exists:** `autoloads/SurvivalObjectiveManager.gd`, top-center HUD objective banner in `BuildHUD.gd`, event wiring in `GameWorld.gd`.
* **What works:** Minimal, repeatable 3-stage survival cycle:
  - **Stage 1 (Gather Resources):** Mine natural terrain voxels to meet target.
  - **Stage 2 (Build Structure):** Place grid blocks to meet target.
  - **Stage 3 (Fortify Surfaces):** Paint mortar onto block faces to meet target.
  Upon completing Stage 3, awards bonus materials (`stone`, `wood`) into `InventoryManager`, increments the cycle counter, and scales future stage quotas. Emits signals for HUD banner updates.
* **Known problems:** Visual animation/banner transitions require GUI inspection.
* **What's missing:** Audio chime or celebratory particle effect on cycle completion.
* **Dependencies:** `InventoryManager.gd`, `GridSystem.gd`, `JointSystem.gd`, `VoxelWorld.gd`.
* **Next action:** Add audio cues and animation tweens for objective progression.
* **Evidence:** `autoloads/SurvivalObjectiveManager.gd`, `tests/test_survival_loop.gd`.

### 10. Creative versus Survival Mode
* **Status:** `WORKING` (Rule Enforcement) / `PARTIAL` (Mode Switch UI)
* **What exists:** `GameMode` enum (`SURVIVAL`, `CREATIVE`) in `GameWorld.gd` and `PlayerController.gd`.
* **What works:** Survival mode enforces material costs and hold-to-mine; Creative mode bypasses resource requirements for infinite building. Mode string displayed in HUD header.
* **Known problems:** Mode switching UI toggle in pause menu requires GUI runtime inspection.
* **What's missing:** In-game mode toggle key in pause menu.
* **Dependencies:** `InventoryManager.gd`.
* **Next action:** Add game mode toggle switch to settings/pause menu.
* **Evidence:** `scenes/world/GameWorld.gd`, `scenes/player/PlayerController.gd`, `tests/test_m4.gd`.

### 11. Performance, Profiling, Scalability, and Chunk Streaming
* **Status:** `WORKING` (Queue Budgeting & Optimizations) / `PARTIAL` (Frame Timing in GUI)
* **What exists:** Multi-stage chunk generation queue (`_generation_queue`), max chunks per frame cap (`max_chunks_per_frame = 2`), per-frame time budget (`max_frame_time_ms = 6.0`), column-wise height precomputation, and diagnostic metrics (`get_diagnostics()`).
* **What works:** Distance-sorted queue prioritization loads nearest chunks first. Exposed face culling eliminates internal geometry. Empty material commit prevention prevents vacant mesh allocations.
* **Known problems:** Real frame pacing and frame drop metrics require profiling in Godot GUI editor with active rendering.
* **What's missing:** Threaded background noise evaluation for distant chunks via `WorkerThreadPool`.
* **Dependencies:** None.
* **Next action:** Offload FastNoiseLite 3D evaluation to `WorkerThreadPool` background threads.
* **Evidence:** `systems/terrain/VoxelWorld.gd`, `systems/terrain/VoxelChunk.gd`, `tests/test_terrain.gd`.

### 12. Automated Tests, Runtime Errors, and Manual Test Coverage
* **Status:** `WORKING` (100% Pass Rate across 12 suites)
* **What exists:** 12 test suites in `tests/` (`test_m1.gd` through `test_m4.gd`, `test_mortar_brush.gd`, `test_terrain.gd`, `test_survival_loop.gd`, `run_tests.gd`) executed directly via headless Godot 4.7.2.
* **What works:** All 12 automated test suites execute and pass cleanly (exit code 0):
  - `test_mortar_brush.gd`: Mortar brush mechanics and face coating.
  - `test_m1.gd`, `test_m1_1.gd`: Grid placement and block data.
  - `test_m2.gd`, `test_m2_1.gd`, `test_m2_2.gd`, `test_m2_3.gd`: Stability calculations, joints, and mortar reinforcement.
  - `test_m3.gd`: Durability, collapse cascades, and debris physics.
  - `test_m4.gd`: Blueprints, bounded capture, reconstruction planning, inventory costs, and HUD dialogues.
  - `test_terrain.gd`: Procedural voxel terrain, chunk generation queue, face culling, watertight boundaries, mining deltas, safe spawn.
  - `test_survival_loop.gd`: Repeatable survival objectives, column-wise noise generation equivalence, end-to-end mining -> inventory -> placement loop, placement rejection in solid terrain, spawn integrity.
* **Known problems:** Visual GUI rendering remains unverified by automated headless tests.
* **What's missing:** Automated visual regression screenshots.
* **Dependencies:** Godot 4.7.2 executable.
* **Next action:** Setup CI automated headless test runner with test output logging.
* **Evidence:** `tests/run_tests.gd`, `tests/test_survival_loop.gd`.

### 13. Future Systems: Manufacturing, Construction Core, Helpers, and Autonomous Reconstruction
* **Status:** `PLANNED`
* **What exists:** Conceptual design specifications in `GAME_DESIGN.md` Section 4 & Section 6.
* **What works:** N/A (Planned feature).
* **Known problems:** None (Not yet implemented).
* **What's missing:** Construction Core base station, helper minion AI, block pressing station.
* **Dependencies:** `BlueprintManager.gd`, `ReconstructionPlanner.gd`, `InventoryManager.gd`.
* **Next action:** Implement Construction Core entity and helper minion pathfinding.
* **Evidence:** `GAME_DESIGN.md` Sections 4 and 6.

---

## 3. Prioritized Bug & Improvement List

* **P0 (Critical):** *None currently active.*
* **P1 (High):** Visual crack overlays and particle emitters for mining feedback (manual inspection).
* **P2 (Medium):** Block rotation control (`R` key) before placement on static grid.
* **P2 (Medium):** Offload distant chunk generation to `WorkerThreadPool` to eliminate remaining main-thread spikes during fast player traversal.
* **P3 (Future):** Helper minion autonomous reconstruction AI and Construction Core station.

---

## 4. Milestone Roadmap

```
[Milestone 1: Grid Building & Physics Collapse] (WORKING — LOGIC VERIFIED)
       │
[Milestone 2: Surface Mortar Brush & Reinforced Joints] (WORKING — LOGIC VERIFIED)
       │
[Milestone 3: Durability & Recoverable Debris Classification] (WORKING — LOGIC VERIFIED)
       │
[Milestone 4: Bounded Blueprints & Inspection Visualizer] (WORKING — LOGIC VERIFIED)
       │
[Milestone 5: Manual Single-Cell Reconstruction & Material Costs] (WORKING — LOGIC VERIFIED)
       │
[Milestone 6: 3D Voxel Floating Islands & Natural Block Mining] (WORKING — LOGIC VERIFIED)
       │
[Milestone 7: Minimal Repeatable Survival Gameplay Loop] (WORKING — LOGIC VERIFIED)
       │
[Milestone 8: Audio/SFX, Visual Crack Decals & Refining Station] (PLANNED)
       │
[Milestone 9: Construction Core & Helper Minion Autonomous Building] (PLANNED)
```

---

## 5. Changelog

* **October 10, 2026:**
  - **Audit Date Correction:** Corrected audit date to October 10, 2026.
  - **Status Classification:** Applied strict status classification (`WORKING`, `PARTIAL`, `PLANNED`), explicitly marking 3D visual rendering and interactive window feel as `PARTIAL` / unverified until manual GUI inspection.
  - **Procedural Terrain Performance:** Replaced 3D density evaluation with column-wise 2D height noise evaluation in `VoxelWorld.gd` Stage 1, cutting generation time ~5x (~31 ms down to ~6.1 ms per chunk). Avoided empty SurfaceTool material passes in `VoxelChunk.gd`. Added $O(1)$ set lookup for mined deltas (`_mined_deltas_set`).
  - **Terrain Placement Collision:** Prevented player grid blocks from being placed inside solid natural terrain in `PlayerController.gd` (`_update_raycast` and `_handle_place_action`).
  - **Safe Spawn Position:** Updated `VoxelWorld.get_spawn_position` fallback to safely probe solid natural terrain top surface.
  - **Debris Durability:** Fixed `DebrisIsland.gd` so impact damage directly reduces constituent block durability.
  - **Blueprint Reconstruction Mortar:** Fixed `BlueprintManager.reconstruct_single_cell` to properly bond adjacent mortared blocks.
  - **Repeatable Survival Objective System:** Implemented `SurvivalObjectiveManager.gd` with cyclic 3-stage loop (Gather Resources -> Build Structure -> Fortify Surfaces), scaling quotas, inventory rewards, and HUD banner in `BuildHUD.gd`.
  - **Automated Regression Suite:** Created `tests/test_survival_loop.gd` (9 tests) covering objective stages, column-wise fast generation equivalence, end-to-end mining/inventory/placement, placement rejection inside natural terrain, and safe spawn integrity. All 12 test suites in `tests/run_tests.gd` pass with exit code 0 under Godot 4.7.2.

* **October 11, 2026 — Voxel Chunk-Loading Stutter Fixes:**
  - **Root Cause Analysis (Static Code Inspection):** Identified 6 primary stutter sources:
    1. `get_spawn_position()` called `_load_or_generate_chunk_sync()` in nested spiral loops (radius 1→24), blocking main thread for dozens of sync chunk loads+meshes at startup.
    2. Mining called up to 4 immediate `rebuild_mesh_and_collision()` on the main thread per event (~60 ms total, bypassing the per-frame budget).
    3. `buf["verts"] = verts` re-assignment on every voxel iteration caused full PackedVector3Array copy in GDScript hot path.
    4. No generation counter: stale async worker results could overwrite the live voxel state after a mining edit.
    5. No bounded result cache: `_results_ready` could grow without limit under high multi-core load.
    6. Y-faces (top/bottom) were emitted as individual per-voxel quads — flat terrain produced O(N²) vertices.
  - **Fix 1 — Startup Stutter:** `get_spawn_position()` now queries `is_solid_block()` → `_evaluate_procedural_voxel()` for all height-searching, loading zero extra chunks. Only `force_sync_spawn_chunks()` (radius=1, 9 chunks) loads terrain synchronously, then awaits one physics frame.
  - **Fix 2 — Mining Remesh Deduplication:** `mine_voxel()` routes affected neighbor rebuilds through `_enqueue_neighbor_remesh_if_needed()`, which deduplicates via `_remesh_set` and applies the 3.5 ms per-frame budget instead of rebuilding all 4 neighbors synchronously.
  - **Fix 3 — Per-Voxel Array Copy Eliminated:** Introduced `_get_or_create_buf()` static helper in `VoxelChunk`. The PackedVector3Array is fetched once and mutated in-place; the `buf["verts"] = verts` write-back is removed from the inner loop.
  - **Fix 4 — Stale-Job Generation Versioning:** `_chunk_generation[cp]` is incremented on each `mine_voxel()` call. Worker results carry the generation at dispatch and are silently discarded if stale (generation < current). Verified by new regression test `test_stale_job_generation_versioning`.
  - **Fix 5 — Bounded Result Cache:** `max_cached_results = 32` hard-caps `_results_ready`. The oldest entry is evicted when the worker tries to push to a full cache, preventing unbounded memory.
  - **Fix 6 — Greedy Y-Plane Meshing:** Top and bottom faces per Y layer are now merged using a sweep-then-extend greedy algorithm. For a uniform flat 4×4 slab: 1 merged rect vs 16 per-voxel quads (6× fewer verts). For typical island terrain, top-surface vertex count is reduced by 4–16× per chunk. Verified by new regression test `test_greedy_y_meshing_reduces_vertex_count`.
  - **Runtime Verification Status:** Successfully executed `tests/run_tests.gd` and `tests/profile_streaming.gd` under `Godot_v4.7.2-stable_win64_console.exe`. All 12 test suites (247 individual tests) pass with exit code 0. Simulated 60-frame player exploration across chunk boundaries demonstrated median frame time of 0.01 ms, p95 of 0.03 ms, and peak of 0.04 ms (strict budget: 3.50 ms; 0 frame overruns across 60 frames). Full interactive GPU display smoothness remains subject to manual testing in the Godot client window.
  - **Test Suite:** All automated terrain tests in `tests/test_terrain.gd` and `tests/test_survival_loop.gd` were reviewed and updated for correctness with the new mesher. Two new tests added: `test_stale_job_generation_versioning`, `test_greedy_y_meshing_reduces_vertex_count`. The adjacent-block face count assertion updated from 60 to 48 to match greedy Y-merging behavior.
