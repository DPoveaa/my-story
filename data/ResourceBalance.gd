class_name ResourceBalance
extends RefCounted

## Shared resource & recipe balance configuration.
## Single source of truth for voxel yields, fragment values, and pallet recipes.

## Average/standard resource yield when mining one ordinary voxel block.
const VOXEL_RESOURCE_YIELD: int = 16

## Material quantity required per standard crafted voxel block on a pallet.
const FRAGMENTS_PER_BLOCK: int = VOXEL_RESOURCE_YIELD

## Standard batch of blocks crafted at once on a pallet (2x2x2 cube).
const PALLET_CRAFT_BATCH_BLOCKS: int = 8

## Total material units required to complete a full pallet craft batch.
const PALLET_CRAFT_REQUIRED_UNITS: int = FRAGMENTS_PER_BLOCK * PALLET_CRAFT_BATCH_BLOCKS

## Units withdrawn in a single batch from a pallet.
const PALLET_WITHDRAW_BATCH: int = FRAGMENTS_PER_BLOCK
