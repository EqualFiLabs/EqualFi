#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ETHERSCAN_API_KEY=... ./script/verify_facets.sh
#
# Optional:
#   BROADCAST_FILE=broadcast/leanDeploy.s.sol/84532/run-latest.json
#   CHAIN=sepolia (default: sepolia)

CHAIN="${CHAIN:-arbitrum-sepolia}"
BROADCAST_FILE="${BROADCAST_FILE:-broadcast/UpgradeManagedPoolSystemShare.s.sol/421614/run-latest.json}"
API_KEY="${ETHERSCAN_API_KEY:-}"

if [[ -z "${API_KEY}" ]]; then
  echo "Missing API key. Set ETHERSCAN_API_KEY."
  exit 1
fi

if [[ ! -f "${BROADCAST_FILE}" ]]; then
  echo "Broadcast file not found: ${BROADCAST_FILE}"
  exit 1
fi

declare -A CONTRACTS=(
  [DiamondCutFacet]=src/core/DiamondCutFacet.sol:DiamondCutFacet
  [DiamondLoupeFacet]=src/core/DiamondLoupeFacet.sol:DiamondLoupeFacet
  [OwnershipFacet]=src/core/OwnershipFacet.sol:OwnershipFacet
  [AdminFacet]=src/admin/AdminFacet.sol:AdminFacet
  [MaintenanceFacet]=src/core/MaintenanceFacet.sol:MaintenanceFacet
  [AdminGovernanceFacet]=src/admin/AdminGovernanceFacet.sol:AdminGovernanceFacet
  [PoolManagementFacet]=src/equallend/PoolManagementFacet.sol:PoolManagementFacet
  [EqualIndexAdminFacetV3]=src/equalindex/EqualIndexAdminFacetV3.sol:EqualIndexAdminFacetV3
  [EqualIndexActionsFacetV3]=src/equalindex/EqualIndexActionsFacetV3.sol:EqualIndexActionsFacetV3
  [EqualIndexPositionFacet]=src/equalindex/EqualIndexPositionFacet.sol:EqualIndexPositionFacet
  [EqualIndexViewFacetV3]=src/views/EqualIndexViewFacetV3.sol:EqualIndexViewFacetV3
  [ConfigViewFacet]=src/views/ConfigViewFacet.sol:ConfigViewFacet
  [PositionViewFacet]=src/views/PositionViewFacet.sol:PositionViewFacet
  [PositionNFTMetadataFacet]=src/views/PositionNFTMetadataFacet.sol:PositionNFTMetadataFacet
  [MultiPoolPositionViewFacet]=src/views/MultiPoolPositionViewFacet.sol:MultiPoolPositionViewFacet
  [AuctionManagementViewFacet]=src/views/AuctionManagementViewFacet.sol:AuctionManagementViewFacet
  [PositionManagementFacet]=src/equallend/PositionManagementFacet.sol:PositionManagementFacet
  [LendingFacet]=src/equallend/LendingFacet.sol:LendingFacet
  [PenaltyFacet]=src/equallend/PenaltyFacet.sol:PenaltyFacet
  [AmmAuctionFacet]=src/EqualX/AmmAuctionFacet.sol:AmmAuctionFacet
  [CommunityAuctionFacet]=src/EqualX/CommunityAuctionFacet.sol:CommunityAuctionFacet
  [EqualLendDirectOfferFacet]=src/equallend-direct/EqualLendDirectOfferFacet.sol:EqualLendDirectOfferFacet
  [MamCurveCreationFacet]=src/EqualX/MamCurveCreationFacet.sol:MamCurveCreationFacet
  [MamCurveManagementFacet]=src/EqualX/MamCurveManagementFacet.sol:MamCurveManagementFacet
  [MamCurveExecutionFacet]=src/EqualX/MamCurveExecutionFacet.sol:MamCurveExecutionFacet
  [ActiveCreditViewFacet]=src/views/ActiveCreditViewFacet.sol:ActiveCreditViewFacet
  [MamCurveViewFacet]=src/views/MamCurveViewFacet.sol:MamCurveViewFacet
)

contract_names=(
  DiamondCutFacet
  DiamondLoupeFacet
  OwnershipFacet
  AdminFacet
  MaintenanceFacet
  AdminGovernanceFacet
  PoolManagementFacet
  EqualIndexAdminFacetV3
  EqualIndexActionsFacetV3
  EqualIndexPositionFacet
  EqualIndexViewFacetV3
  ConfigViewFacet
  PositionViewFacet
  PositionNFTMetadataFacet
  MultiPoolPositionViewFacet
  AuctionManagementViewFacet
  PositionManagementFacet
  LendingFacet
  PenaltyFacet
  AmmAuctionFacet
  CommunityAuctionFacet
  EqualLendDirectOfferFacet
  MamCurveCreationFacet
  MamCurveManagementFacet
  MamCurveExecutionFacet
  ActiveCreditViewFacet
  MamCurveViewFacet
)

declare -A ADDRS=()
while read -r name addr; do
  if [[ -n "${name}" && -n "${addr}" ]]; then
    ADDRS["${name}"]="${addr}"
  fi
done < <(python3 - <<'PY' "${BROADCAST_FILE}"
import json
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

for tx in data.get("transactions", []):
    name = tx.get("contractName") or ""
    addr = tx.get("contractAddress") or ""
    if name and addr:
        print(name, addr)
PY
)

for name in "${contract_names[@]}"; do
  contract="${CONTRACTS[$name]:-}"
  addr="${ADDRS[$name]:-}"

  if [[ -z "${contract}" ]]; then
    echo "Missing contract mapping for ${name}"
    continue
  fi
  if [[ -z "${addr}" ]]; then
    echo "Missing address for ${name} in ${BROADCAST_FILE}"
    continue
  fi

  echo "Verifying ${name} @ ${addr} => ${contract}"
  forge verify-contract \
    --chain "${CHAIN}" \
    --etherscan-api-key "${API_KEY}" \
    "${addr}" \
    "${contract}" \
    --watch
done
