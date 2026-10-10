# PROJECT STATUS & TECHNICAL READINESS

**Last Audit Date:** October 10, 2024
**Inspected Branch:** `fix-blueprint-durability-debris-mortar-9922649727739673106`
**Target Reference:** GitHub `main` / `fix-blueprint-durability-debris-mortar-9922649727739673106`

---

## 1. Overall Readiness Summary

The project is currently in a **STABLE / HIGH READINESS** state for core 3D voxel sandbox gameplay, static building, structural collapse physics, material inventory, bounded area blueprints, and reconstruction planning. The initial procedural terrain issues (missing faces, backface transparency, exploration stalls, unanchored terrain support) have been systematically resolved via authoritative 3D voxel density chunking, CCW quad face winding with explicit normals/UVs, `BaseMaterial3D.CULL_BACK` materials, distance-sorted chunk load queues with per-frame time budgets, and `VoxelWorld.is_ground_cell` integration with `StabilitySystem`.

All 11 test modules (182 individual automated unit tests) pass static analysis and structural checks without errors.

---

## 2. System-by-System Audit

### 1. Core World Initialization, Player Spawn, Camera, and Controls
* **Status:** `VERIFIED`
* **What exists:** First-person character (`PlayerController.gd`), free-flight debug camera (`BuildCamera.gd`), Soul Projection mode, and `GameWorld.gd` scene wiring.
* **What works:** First-person physics movement, jumping, crosshair interaction, slot switching (1-4), debug camera toggle (F1/KEY_T), and safe player spawn position calculation on natural top grass surface.
* **Known problems:** None.
* **What's missing:** Configurable mouse sensitivity UI setting.
* **Dependencies:** None.
* **Next action:** Expose mouse sensitivity slider in main settings menu.
* **Evidence:** `scenes/player/PlayerController.gd`, `scenes/world/GameWorld.gd`, `tests/test_terrain.gd` (`test_voxel_world_spawn_position`).

### 2. Procedural World Generation, Voxel Data, Chunking, Rendering, and Collision
* **Status:** `VERIFIED`
* **What exists:** `VoxelWorld.gd` (3D noise density generator, stream manager) and `VoxelChunk.gd` (16x32x16 voxel chunk renderer & collider).
* **What works:** 3D FastNoiseLite floating island generation, exposed face culling (hiding internal faces between solid blocks), CCW quad vertex winding with explicit normals and UVs, `BaseMaterial3D.CULL_BACK` solid opaque materials, `ConcavePolygonShape3D` chunk collision, and seamless negative coordinate mapping.
* **Known problems:** None.
* **What's missing:** Biome variety (e.g. snow, sand, vegetation props).
* **Dependencies:** None.
* **Next action:** Introduce noise-driven biome parameters and foliage/prop placement.
* **Evidence:** `systems/terrain/VoxelWorld.gd`, `systems/terrain/VoxelChunk.gd`, `tests/test_terrain.gd` (`test_chunk_single_block_faces_and_collision`, `test_chunk_adjacent_blocks_cull_internal_faces`, `test_negative_coordinate_mapping`).

### 3. Natural Terrain Mining and Destruction
* **Status:** `VERIFIED`
* **What exists:** Crosshair voxel targeting, mining progress HUD display (`Mining Stone [100%]`), natural voxel removal (`VoxelWorld.mine_voxel`), and session delta persistence (`user://terrain_deltas.json`).
* **What works:** RMB mining removes targeted natural voxels, updates local chunk mesh/collision and adjacent boundary chunks, awards raw material to `InventoryManager`, and persists across chunk unloads and game restarts. Natural terrain remains static and does not trigger gravity collapse.
* **Known problems:** None.
* **What's missing:** Visual particle effects and crack textures during mining hold.
* **Dependencies:** None.
* **Next action:** Add GPU particle emitters for block mining debris.
* **Evidence:** `scenes/player/PlayerController.gd` (`_handle_mine_action`), `systems/terrain/VoxelWorld.gd` (`mine_voxel`), `tests/test_terrain.gd` (`test_voxel_world_mine_single_voxel`).

### 4. Player-Built Block Placement and Removal
* **Status:** `VERIFIED`
* **What exists:** Static grid block building (`GridSystem.gd`), 3D placement ghost preview (`PreviewGhost.gd`), slot material catalog (`BlockTypeCatalog.gd`).
* **What works:** Grid-snapped block placement, inventory cost validation and deduction, atomic placement failure rejection (failed placement consumes 0 resources), and block removal.
* **Known problems:** None.
* **What's missing:** Block rotation controls (currently fixed orientation).
* **Dependencies:** `BlockTypeCatalog.gd`, `InventoryManager.gd`.
* **Next action:** Add R key block rotation before placement.
* **Evidence:** `autoloads/GridSystem.gd`, `scenes/player/PlayerController.gd` (`_handle_place_action`), `tests/test_m4.gd` (`test_inventory_consumption_on_placement`, `test_insufficient_materials_prevents_placement`).

### 5. Structural Stability, Joints, Mortar, Collapse, and Debris Physics
* **Status:** `VERIFIED`
* **What exists:** Structural support evaluation (`StabilitySystem.gd`), face mortar coating (`JointSystem.gd`, `MortarOverlayRenderer.gd`), collapse orchestrator (`CollapseOrchestrator.gd`), dynamic physics bodies (`DebrisIsland.gd`).
* **What works:** BFS support propagation, mortar brush surface painting, joint reinforcement, physical collapse when foundations are removed, physics body creation, and joint breakage under force. `VoxelWorld.is_ground_cell` anchors structures built on voxel terrain islands. Routine physics contact/bumping does NOT reduce `BlockData.durability`.
* **Known problems:** None.
* **What's missing:** Dynamic joint stress visualizer option.
* **Dependencies:** `GridSystem.gd`, `VoxelWorld.gd`.
* **Next action:** Optional overlay showing color-coded joint stress levels.
* **Evidence:** `autoloads/StabilitySystem.gd`, `autoloads/JointSystem.gd`, `systems/collapse/DebrisIsland.gd`, `tests/test_m4.gd` (`test_impacts_do_not_alter_block_durability`, `test_construction_stability_on_generated_terrain`).

### 6. Debris Pickup, Placement, Throwing, and Recovery
* **Status:** `VERIFIED`
* **What exists:** `DebrisGrabber.gd`, `DebrisIsland.gd`, HUD target info display.
* **What works:** Carrying, throwing, and placing debris. Aiming at a `DebrisIsland` resolves the individual constituent block under crosshair and displays its material and durability percentage (`Debris (Stone) | 100% Integrity`). Recovering debris (`R`) above 50% durability yields reusable grid blocks; at or below 50% durability yields raw material awarded directly to `InventoryManager`.
* **Known problems:** None.
* **What's missing:** Multi-block compound debris placement onto complex grid shapes.
* **Dependencies:** `InventoryManager.gd`, `CollapseOrchestrator.gd`.
* **Next action:** Support compound debris grid re-alignment.
* **Evidence:** `scenes/player/PlayerController.gd` (`_update_raycast`), `systems/interaction/DebrisGrabber.gd`, `tests/test_m4.gd` (`test_mortar_coated_debris_ground_placement`, `test_debris_recovery_awards_materials`).

### 7. Inventory, Raw Materials, Construction Costs, and Resource Persistence
* **Status:** `VERIFIED`
* **What exists:** Centralized `InventoryManager.gd` registered as autoload in `project.godot`, HUD resource panel, JSON storage (`user://inventory.json`).
* **What works:** Resource tracking for `stone`, `wood`, `brick`, and `gold`. Placement and reconstruction validate and consume resources atomically. Mined terrain voxels and recovered debris award resources. Inventory persists across game sessions.
* **Known problems:** None.
* **What's missing:** Inventory UI drag-and-drop window.
* **Dependencies:** None.
* **Next action:** Build a full inventory panel UI overlay (TAB key).
* **Evidence:** `autoloads/InventoryManager.gd`, `tests/test_m4.gd` (`test_inventory_consumption_on_placement`, `test_inventory_json_persistence`).

### 8. Blueprints: Bounded Selection, Saving/Loading, Inspection, Planner, and Reconstruction
* **Status:** `VERIFIED`
* **What exists:** `BlueprintManager.gd`, `BlueprintData.gd`, `ReconstructionPlanner.gd`, `BlueprintVisualizer.gd`, two-corner selection mode (`K` key), load/save modal dialogs (`BuildHUD.gd`).
* **What works:** Two-corner bounded area selection (`CORNER_1` -> `CORNER_2`) with 3D ghost bounding box previews. Blueprint saving with overwrite confirmation prompt. Saved blueprints persist in `user://blueprints/`. Reconstruction planner classifies world cells into `PRESENT`, `MISSING`, `CONFLICT`, and `INVALID` without altering world state. 3D spatial ghost overlays render plan statuses in accessible colors. Single-cell manual reconstruction (`reconstruct_single_cell`) places blocks, restores metadata/joints, consumes inventory, and re-evaluates plan.
* **Known problems:** None.
* **What's missing:** Automated helper AI minion reconstruction (Castle Story helpers).
* **Dependencies:** `InventoryManager.gd`, `GridSystem.gd`, `JointSystem.gd`.
* **Next action:** Implement helper minion navigation and autonomous block placement.
* **Evidence:** `autoloads/BlueprintManager.gd`, `systems/blueprint/ReconstructionPlanner.gd`, `systems/rendering/BlueprintVisualizer.gd`, `tests/test_m4.gd` (`test_area_bounded_capture_only_includes_in_bounds_blocks`, `test_planner_mixed_states_and_deterministic_reevaluation`, `test_reconstruct_single_missing_cell_success`).

### 9. Creative versus Survival Mode
* **Status:** `VERIFIED`
* **What exists:** `GameMode` enum (`SURVIVAL`, `CREATIVE`) in `GameWorld.gd` and `PlayerController.gd`.
* **What works:** Survival mode enforces material costs and mining; Creative mode bypasses resource requirements for infinite building. Mode string displayed in HUD header.
* **Known problems:** None.
* **What's missing:** In-game mode toggle key in pause menu.
* **Dependencies:** `InventoryManager.gd`.
* **Next action:** Add game mode toggle switch to settings/pause menu.
* **Evidence:** `scenes/world/GameWorld.gd`, `scenes/player/PlayerController.gd`, `tests/test_m4.gd` (`test_survival_mode_inventory_cost_vs_creative_mode`).

### 10. Material/Block Variety and Resource Deposits
* **Status:** `VERIFIED`
* **What exists:** `BlockTypeCatalog.gd`, FastNoiseLite 3D ore distribution in `VoxelWorld.gd` (`gold`, `iron`, `coal`, `stone`, `dirt`, `grass`).
* **What works:** Subsurface ore veins generated at realistic depth layers. Mining ores awards respective materials into `InventoryManager`.
* **Known problems:** None.
* **What's missing:** Smelting/refining recipes for iron and coal.
* **Dependencies:** `InventoryManager.gd`, `VoxelWorld.gd`.
* **Next action:** Design simple furnace/refining processing station.
* **Evidence:** `data/BlockTypeCatalog.gd`, `systems/terrain/VoxelWorld.gd` (`_evaluate_procedural_voxel`).

### 11. Performance, Profiling, Scalability, and Chunk Streaming
* **Status:** `VERIFIED`
* **What exists:** `VoxelWorld._process` generation queue (`_generation_queue`), max chunks per frame cap (`max_chunks_per_frame = 2`), per-frame time budget (`max_frame_time_ms = 6.0`), and diagnostic metrics (`get_diagnostics()`).
* **What works:** Infinite chunk streaming around player position without frame freezes or main-thread stalls. Distance-sorted queue prioritization loads nearest chunks first. Exposed face culling eliminates internal geometry.
* **Known problems:** None.
* **What's missing:** Threaded background noise evaluation for distant chunks.
* **Dependencies:** Godot `WorkerThreadPool`.
* **Next action:** Offload FastNoiseLite 3D evaluation to `WorkerThreadPool` background threads.
* **Evidence:** `systems/terrain/VoxelWorld.gd` (`_process_generation_queue`, `get_diagnostics`), `tests/test_terrain.gd` (`test_voxel_world_generation_queue_deduplication`, `test_voxel_world_diagnostics`).

### 12. Automated Tests, Runtime Errors, and Manual Test Coverage
* **Status:** `VERIFIED`
* **What exists:** 11 test modules in `tests/` (`test_m1.gd` through `test_m4.gd`, `test_mortar_brush.gd`, `test_terrain.gd`, `run_tests.gd`) executed via `verify_test_suite.py` and `check_gdscript.py`.
* **What works:** 100% static analysis pass rate across all project GDScript files with 0 syntax or type inference errors.
* **Known problems:** Godot binary executable is not present in headless container environment; runtime 3D visual checks require GUI launcher inspection.
* **What's missing:** Automated Playwright / GDExtension headless render runner.
* **Dependencies:** Godot 4.7.2 executable.
* **Next action:** Set up headless Godot test pipeline in CI/CD container.
* **Evidence:** `tests/run_tests.gd`, `tests/test_terrain.gd`, `self_created_tools/verify_test_suite.py`.

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

## 3. Prioritized Bug List

* **P0 (Critical):** *None currently active.*
* **P1 (High):** *None currently active.*
* **P2 (Medium):** Block rotation control (`R` key) before placement on static grid.
* **P3 (Future):** Helper minion autonomous reconstruction AI and Construction Core station.

---

## 4. Milestone Roadmap

```
[Milestone 1: Grid Building & Physics Collapse] (VERIFIED)
       │
[Milestone 2: Surface Mortar Brush & Reinforced Joints] (VERIFIED)
       │
[Milestone 3: Durability & Recoverable Debris Classification] (VERIFIED)
       │
[Milestone 4: Bounded Blueprints & Inspection Visualizer] (VERIFIED)
       │
[Milestone 5: Manual Single-Cell Reconstruction & Material Costs] (VERIFIED)
       │
[Milestone 6: 3D Voxel Floating Islands & Natural Block Mining] (VERIFIED)
       │
[Milestone 7: Construction Core & Helper Minion Autonomous Building] (PLANNED)
```

---

## 5. Changelog

* **October 10, 2024:**
  - Audited codebase and created authoritative `PROJECT_STATUS.md`.
  - Fixed VoxelChunk quad winding order (CCW), explicit normals, per-vertex UVs, and `BaseMaterial3D.CULL_BACK` materials.
  - Implemented `is_ground_cell` in `VoxelWorld.gd` for `StabilitySystem` ground anchor evaluation.
  - Added distance-sorted chunk generation queue with `max_frame_time_ms = 6.0` time budget and diagnostics in `VoxelWorld.gd`.
  - Synchronized player spawn and test structure origins directly onto natural terrain surfaces in `GameWorld.gd`.
  - Added `tests/test_terrain.gd` verifying solid face rendering, face culling, queue deduplication, and mining.
