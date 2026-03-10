# Releases

This directory contains the first-pass manifest-driven release system for the Diamond.

The goal is to separate:

- base bootstrap deployment
- facet catalog and selector lookup
- release composition
- staged upgrades

## Files

- `ManifestTypes.sol`
  Defines `FacetId`, `ApplyReport`, plan types, and the `IReleaseManifest` interface.
- `FacetCatalog.sol`
  Maps each `FacetId` to a concrete facet deployment and selector list, and plans incremental cuts.
- `manifests/ReleaseV1.sol` through `manifests/ReleaseV5.sol`
  Define cumulative release stages.

The executable scripts that use this directory live one level up:

- `script/BaseDeploy.s.sol`
- `script/ApplyManifest.s.sol`

## Model

The release model is cumulative.

- `v1` installs the initial launch surface
- `v2` means `v1 + direct lending`
- `v3` means `v2 + ILM isolated`
- `v4` means `v3 + ILM pooled`
- `v5` means `v4 + perps`

`ApplyManifestScript` does not assume a clean deploy every time. It plans against the current diamond selector table through `IDiamondLoupe`, reuses unchanged facet implementations when the selector routing and runtime code hash already match, and only deploys new implementations for new or changed facets.

## Release Stages

### `v1`

Launch surface:

- Self-secured lending
- AMM auctions
- MAM curves
- Index tokens / index lending
- Options
- Required core and view facets used by those products

### `v2`

Adds:

- Direct lending

### `v3`

Adds:

- ILM isolated

### `v4`

Adds:

- ILM pooled

### `v5`

Adds:

- Perps

## Base Bootstrap

`BaseDeployScript` only deploys the minimum Diamond scaffold:

- `DiamondCutFacet`
- `DiamondLoupeFacet`
- `OwnershipFacet`
- `Diamond`
- `PositionNFT`
- `DiamondInit`

Entry point:

```solidity
runBase()
```

Runtime inputs:

- `OWNER`
- `TIMELOCK`
- `PRIVATE_KEY`

Example:

```bash
forge script script/BaseDeploy.s.sol:BaseDeployScript \
  --sig "runBase()" \
  --rpc-url $RPC_URL \
  --broadcast
```

## Applying a Manifest

`ApplyManifestScript` is the main operator entrypoint.

Entry point:

```solidity
runApply()
```

Dry-run entry point:

```solidity
runPlan()
```

Runtime inputs:

- `OWNER`
- `TIMELOCK`
- `PRIVATE_KEY`
- `MANIFEST`
- optional `DIAMOND_ADDRESS`

Behavior:

- If `DIAMOND_ADDRESS` is unset or zero, the script deploys a new base diamond first, then applies the manifest.
- If `DIAMOND_ADDRESS` is set, the script applies the manifest to the existing diamond.

Supported `MANIFEST` values:

- `v1`
- `v2`
- `v3`
- `v4`
- `v5`

Examples:

Deploy a fresh `v1` release:

```bash
MANIFEST=v1 forge script script/ApplyManifest.s.sol:ApplyManifestScript \
  --sig "runApply()" \
  --rpc-url $RPC_URL \
  --broadcast \
  --skip-simulation
```

Upgrade an existing diamond from `v1` to `v2`:

```bash
DIAMOND_ADDRESS=0xYourDiamond \
MANIFEST=v2 \
forge script script/ApplyManifest.s.sol:ApplyManifestScript \
  --sig "runApply()" \
  --rpc-url $RPC_URL \
  --broadcast \
  --skip-simulation
```

Upgrade an existing diamond from `v4` to `v5`:

```bash
DIAMOND_ADDRESS=0xYourDiamond \
MANIFEST=v5 \
forge script script/ApplyManifest.s.sol:ApplyManifestScript \
  --sig "runApply()" \
  --rpc-url $RPC_URL \
  --broadcast \
  --skip-simulation
```

Preview the plan without broadcasting:

```bash
DIAMOND_ADDRESS=0xYourDiamond \
MANIFEST=v4 \
forge script script/ApplyManifest.s.sol:ApplyManifestScript \
  --sig "runPlan()" \
  --rpc-url $RPC_URL
```

## How the Diff Works

For each `FacetId` in the manifest:

1. Build a local plan for the manifest before broadcast
2. Load the shared selector list for each facet from the catalog
3. Compare current selector routing through `facetAddress(selector)`
4. Compare the currently routed facet runtime code hash to the expected facet runtime code hash
5. Reuse the current facet implementation when both selector routing and code hash already match
6. Only deploy a new implementation when the facet is new or changed
7. Put missing selectors into an `Add` cut and changed selectors into a `Replace` cut
8. Execute a single `diamondCut` with the computed delta

The report is returned as:

```solidity
struct ApplyReport {
    uint256 deployedFacetCount;
    uint256 reusedFacetCount;
    uint256 addCutCount;
    uint256 replaceCutCount;
    uint256 addedSelectorCount;
    uint256 replacedSelectorCount;
    uint256 unchangedSelectorCount;
}
```

Operationally, this means:

- applying the same manifest twice should become a no-op
- `v1 -> v2` should only deploy the direct-lending facet set
- later stages should leave unchanged earlier facet implementations in place

## Artifacts

After `runApply()`, the script writes a stage snapshot to:

```text
script/releases/deployments/<chainid>/<manifest>.json
```

The snapshot records:

- manifest name
- chain id
- diamond address
- position NFT address if one was created in that run
- apply report counts
- per-facet address and runtime code hash for the applied manifest

## Testing

Current tests:

- `test/releases/ApplyManifest.t.sol`
  Proves staged release application for `v1` through `v5`, incremental deployment, and no-op reapply
- `test/releases/FacetCatalogCoverage.t.sol`
  Proves every `FacetId` maps to a deployable facet with selectors

Run them individually:

```bash
forge test --match-path test/releases/ApplyManifest.t.sol
forge test --match-path test/releases/FacetCatalogCoverage.t.sol
```

## Operational Notes

- The manifests are cumulative. Applying `v4` to a `v2` diamond should bring it up to `v4` state directly.
- This system currently focuses on facet composition only. Product-specific post-deploy config is still handled separately.
- `FacetCatalog.sol` is the authoritative mapping between `FacetId` and the facet implementation + selector set.
- If a selector set changes in a facet, update the shared selector source before relying on the manifest system for upgrades.

## Current Limitation

This is a first-pass release system.

It does not yet model:

- post-cut initialization hooks per release
- removals for intentionally deprecated facets
- environment-specific deployment profiles

Those can be layered on later without changing the basic cumulative release model.
