#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ETHERSCAN_API_KEY=... ./script/verify_facets.sh
#
# Optional:
#   BROADCAST_FILE=broadcast/DeployDiamond.s.sol/421614/run-latest.json
#   CHAIN=421614 (defaults to chain id found in BROADCAST_FILE)

BROADCAST_FILE="${BROADCAST_FILE:-}"
CHAIN="${CHAIN:-}"
API_KEY="${ETHERSCAN_API_KEY:-}"

if [[ -z "${API_KEY}" ]]; then
  echo "Missing API key. Set ETHERSCAN_API_KEY."
  exit 1
fi

if [[ -z "${BROADCAST_FILE}" ]]; then
  BROADCAST_FILE="$(
    python3 - <<'PY'
import glob
import os

candidates = glob.glob("broadcast/DeployDiamond.s.sol/*/run-latest.json")
if not candidates:
    raise SystemExit(1)
candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
print(candidates[0])
PY
  )" || {
    echo "Could not auto-locate broadcast/DeployDiamond.s.sol/*/run-latest.json"
    exit 1
  }
fi

if [[ ! -f "${BROADCAST_FILE}" ]]; then
  echo "Broadcast file not found: ${BROADCAST_FILE}"
  exit 1
fi

if [[ -z "${CHAIN}" ]]; then
  CHAIN="$(
    python3 - <<'PY' "${BROADCAST_FILE}"
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)
chain = data.get("chain")
if chain is None:
    raise SystemExit(1)
print(chain)
PY
  )" || {
    echo "Could not infer chain from ${BROADCAST_FILE}. Set CHAIN explicitly."
    exit 1
  }
fi

declare -A CONTRACT_IDS=(
  [ActiveCreditViewFacet]=src/views/ActiveCreditViewFacet.sol:ActiveCreditViewFacet
  [DiamondCutFacet]=src/core/DiamondCutFacet.sol:DiamondCutFacet
  [DiamondLoupeFacet]=src/core/DiamondLoupeFacet.sol:DiamondLoupeFacet
  [OwnershipFacet]=src/core/OwnershipFacet.sol:OwnershipFacet
  [Diamond]=src/core/Diamond.sol:Diamond
  [DiamondInit]=src/core/DiamondInit.sol:DiamondInit
  [AdminFacet]=src/admin/AdminFacet.sol:AdminFacet
  [PointsAdminFacet]=src/admin/PointsAdminFacet.sol:PointsAdminFacet
  [PointsViewFacet]=src/views/PointsViewFacet.sol:PointsViewFacet
  [PointsRedemptionFacet]=src/points/PointsRedemptionFacet.sol:PointsRedemptionFacet
  [MaintenanceFacet]=src/core/MaintenanceFacet.sol:MaintenanceFacet
  [FlashLoanFacet]=src/equallend/FlashLoanFacet.sol:FlashLoanFacet
  [FeeFacet]=src/core/FeeFacet.sol:FeeFacet
  [AdminGovernanceFacet]=src/admin/AdminGovernanceFacet.sol:AdminGovernanceFacet
  [PoolManagementFacet]=src/equallend/PoolManagementFacet.sol:PoolManagementFacet
  [EqualIndexAdminFacetV3]=src/equalindex/EqualIndexAdminFacetV3.sol:EqualIndexAdminFacetV3
  [EqualIndexActionsFacetV3]=src/equalindex/EqualIndexActionsFacetV3.sol:EqualIndexActionsFacetV3
  [EqualIndexPositionFacet]=src/equalindex/EqualIndexPositionFacet.sol:EqualIndexPositionFacet
  [EqualIndexViewFacetV3]=src/views/EqualIndexViewFacetV3.sol:EqualIndexViewFacetV3
  [LiquidityViewFacet]=src/views/LiquidityViewFacet.sol:LiquidityViewFacet
  [LoanViewFacet]=src/views/LoanViewFacet.sol:LoanViewFacet
  [ConfigViewFacet]=src/views/ConfigViewFacet.sol:ConfigViewFacet
  [EnhancedLoanViewFacet]=src/views/EnhancedLoanViewFacet.sol:EnhancedLoanViewFacet
  [PoolUtilizationViewFacet]=src/views/PoolUtilizationViewFacet.sol:PoolUtilizationViewFacet
  [LoanPreviewFacet]=src/views/LoanPreviewFacet.sol:LoanPreviewFacet
  [PositionViewFacet]=src/views/PositionViewFacet.sol:PositionViewFacet
  [PositionNFTMetadataFacet]=src/views/PositionNFTMetadataFacet.sol:PositionNFTMetadataFacet
  [MultiPoolPositionViewFacet]=src/views/MultiPoolPositionViewFacet.sol:MultiPoolPositionViewFacet
  [AuctionManagementViewFacet]=src/views/AuctionManagementViewFacet.sol:AuctionManagementViewFacet
  [PositionManagementFacet]=src/equallend/PositionManagementFacet.sol:PositionManagementFacet
  [LendingFacet]=src/equallend/LendingFacet.sol:LendingFacet
  [PenaltyFacet]=src/equallend/PenaltyFacet.sol:PenaltyFacet
  [EqualLendDirectAgreementFacet]=src/equallend-direct/EqualLendDirectAgreementFacet.sol:EqualLendDirectAgreementFacet
  [EqualLendDirectAgreementRatioFacet]=src/equallend-direct/EqualLendDirectAgreementRatioFacet.sol:EqualLendDirectAgreementRatioFacet
  [AmmAuctionFacet]=src/EqualX/AmmAuctionFacet.sol:AmmAuctionFacet
  [CommunityAuctionFacet]=src/EqualX/CommunityAuctionFacet.sol:CommunityAuctionFacet
  [AtomicDeskFacet]=src/EqualX/AtomicDeskFacet.sol:AtomicDeskFacet
  [SettlementEscrowFacet]=src/EqualX/SettlementEscrowFacet.sol:SettlementEscrowFacet
  [EqualLendDirectOfferFacet]=src/equallend-direct/EqualLendDirectOfferFacet.sol:EqualLendDirectOfferFacet
  [EqualLendDirectLifecycleFacet]=src/equallend-direct/EqualLendDirectLifecycleFacet.sol:EqualLendDirectLifecycleFacet
  [EqualLendDirectRollingOfferFacet]=src/equallend-direct/EqualLendDirectRollingOfferFacet.sol:EqualLendDirectRollingOfferFacet
  [EqualLendDirectRollingAgreementFacet]=src/equallend-direct/EqualLendDirectRollingAgreementFacet.sol:EqualLendDirectRollingAgreementFacet
  [EqualLendDirectRollingLifecycleFacet]=src/equallend-direct/EqualLendDirectRollingLifecycleFacet.sol:EqualLendDirectRollingLifecycleFacet
  [EqualLendDirectRollingPaymentFacet]=src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol:EqualLendDirectRollingPaymentFacet
  [EqualLendDirectRollingViewFacet]=src/views/EqualLendDirectRollingViewFacet.sol:EqualLendDirectRollingViewFacet
  [EqualLendDirectViewFacet]=src/views/EqualLendDirectViewFacet.sol:EqualLendDirectViewFacet
  [MamCurveCreationFacet]=src/EqualX/MamCurveCreationFacet.sol:MamCurveCreationFacet
  [MamCurveManagementFacet]=src/EqualX/MamCurveManagementFacet.sol:MamCurveManagementFacet
  [MamCurveExecutionFacet]=src/EqualX/MamCurveExecutionFacet.sol:MamCurveExecutionFacet
  [OptionsFacet]=src/derivatives/OptionsFacet.sol:OptionsFacet
  [FuturesFacet]=src/derivatives/FuturesFacet.sol:FuturesFacet
  [DerivativeViewFacet]=src/views/DerivativeViewFacet.sol:DerivativeViewFacet
  [MamCurveViewFacet]=src/views/MamCurveViewFacet.sol:MamCurveViewFacet
  [PositionAgentTBAFacet]=src/agent-wallet/erc6551/PositionAgentTBAFacet.sol:PositionAgentTBAFacet
  [PositionAgentRegistryFacet]=src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol:PositionAgentRegistryFacet
  [PositionAgentViewFacet]=src/agent-wallet/erc6551/PositionAgentViewFacet.sol:PositionAgentViewFacet
  [PositionAgentConfigFacet]=src/agent-wallet/erc6551/PositionAgentConfigFacet.sol:PositionAgentConfigFacet
  [ModuleRegistryFacet]=src/modules/ModuleRegistryFacet.sol:ModuleRegistryFacet
  [ModuleGatewayFacet]=src/modules/ModuleGatewayFacet.sol:ModuleGatewayFacet
  [ModuleViewFacet]=src/modules/ModuleViewFacet.sol:ModuleViewFacet
  [PositionNFT]=src/nft/PositionNFT.sol:PositionNFT
  [PositionMSCAImpl]=src/agent-wallet/erc6900/PositionMSCAImpl.sol:PositionMSCAImpl
  [PositionAgentAmmSkillModule]=src/agent-wallet/erc6900/PositionAgentAmmSkillModule.sol:PositionAgentAmmSkillModule
  [Faucet]=src/faucet/Faucet.sol:Faucet
  [Mailbox]=src/EqualX/Mailbox.sol:Mailbox
  [ExecutionFlowLib]=lib/agent-wallet-core/src/libraries/ExecutionFlowLib.sol:ExecutionFlowLib
  [ExecutionManagementLib]=lib/agent-wallet-core/src/libraries/ExecutionManagementLib.sol:ExecutionManagementLib
  [ValidationFlowLib]=lib/agent-wallet-core/src/libraries/ValidationFlowLib.sol:ValidationFlowLib
  [ValidationManagementLib]=lib/agent-wallet-core/src/libraries/ValidationManagementLib.sol:ValidationManagementLib
  [LocalERC6551Registry]="script/DeployDiamond.s.sol:LocalERC6551Registry|script/leanDeploy.s.sol:LocalERC6551Registry"
  [UpgradeableBeacon]="lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon|lib/aave-v3-origin/lib/solidity-utils/lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon"
  [BeaconProxy]="lib/agent-wallet-core/src/core/BeaconProxy.sol:BeaconProxy|lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol:BeaconProxy"
  [FuturesToken]="src/derivatives/FuturesToken.sol:FuturesToken|src/derivatives/OptionToken.sol:OptionToken"
  [MockERC20]="src/mocks/MockERC20.sol:MockERC20|lib/forge-std/src/mocks/MockERC20.sol:MockERC20"
)

missing_map=0
verify_fail=0
verified_count=0
declare -A SEEN=()

while read -r name addr; do
  [[ -z "${name}" || -z "${addr}" ]] && continue

  key="${name}@${addr,,}"
  if [[ -n "${SEEN[$key]:-}" ]]; then
    continue
  fi
  SEEN["$key"]=1

  ids="${CONTRACT_IDS[$name]:-}"
  if [[ -z "${ids}" ]]; then
    echo "No contract id mapping for deployed ${name} @ ${addr}"
    missing_map=1
    continue
  fi

  echo "Verifying ${name} @ ${addr}"
  IFS='|' read -r -a candidates <<< "${ids}"
  ok=0
  for contract_id in "${candidates[@]}"; do
    echo "  -> trying ${contract_id}"
    if forge verify-contract \
      --chain "${CHAIN}" \
      --etherscan-api-key "${API_KEY}" \
      --guess-constructor-args \
      --watch \
      "${addr}" \
      "${contract_id}"; then
      ok=1
      verified_count=$((verified_count + 1))
      break
    fi
  done

  if [[ "${ok}" -ne 1 ]]; then
    echo "Verification failed for ${name} @ ${addr}"
    verify_fail=1
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

echo "Verified ${verified_count} deployed contract addresses from ${BROADCAST_FILE}"
if [[ "${missing_map}" -ne 0 || "${verify_fail}" -ne 0 ]]; then
  echo "Verification did not complete successfully."
  exit 1
fi
