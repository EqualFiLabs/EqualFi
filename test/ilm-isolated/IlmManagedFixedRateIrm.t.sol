// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {IlmManagedFixedRateIrm} from "../../src/ilm-isolated/irm/IlmManagedFixedRateIrm.sol";

contract IlmManagedFixedRateIrmTest is Test {
    uint256 internal constant MAX_RATE_PER_SECOND_WAD = 1e15;

    function test_constructor_rejectsRateAboveBound() public {
        uint256 tooHigh = MAX_RATE_PER_SECOND_WAD + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IlmManagedFixedRateIrm.IlmManagedFixedRateIrmRateTooHigh.selector,
                tooHigh,
                MAX_RATE_PER_SECOND_WAD
            )
        );
        new IlmManagedFixedRateIrm(tooHigh);
    }

    function test_constructor_acceptsBoundedRates() public {
        IlmManagedFixedRateIrm irmZero = new IlmManagedFixedRateIrm(0);
        assertEq(irmZero.ratePerSecondWad(), 0);

        IlmManagedFixedRateIrm irmMax = new IlmManagedFixedRateIrm(MAX_RATE_PER_SECOND_WAD);
        assertEq(irmMax.ratePerSecondWad(), MAX_RATE_PER_SECOND_WAD);
    }

    function testFuzz_borrowRate_returnsImmutableRate(
        uint128 loanPoolIdRaw,
        uint128 collateralPoolIdRaw,
        uint128 lltvRaw,
        uint128 supplyAssetsRaw,
        uint128 supplySharesRaw,
        uint128 borrowAssetsRaw,
        uint128 borrowSharesRaw,
        uint128 feeRaw,
        uint256 rateRaw
    ) public {
        uint256 rate = rateRaw % (MAX_RATE_PER_SECOND_WAD + 1);
        IlmManagedFixedRateIrm irm = new IlmManagedFixedRateIrm(rate);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: uint256(loanPoolIdRaw) + 1,
            collateralPoolId: uint256(collateralPoolIdRaw) + 1,
            oracle: address(uint160(uint256(keccak256("oracle")))),
            irm: address(irm),
            lltv: uint256(lltvRaw) % IlmIsolatedTypes.WAD
        });
        IlmIsolatedTypes.IlmIsolatedMarket memory market = IlmIsolatedTypes.IlmIsolatedMarket({
            totalSupplyAssets: supplyAssetsRaw,
            totalSupplyShares: supplySharesRaw,
            totalBorrowAssets: borrowAssetsRaw,
            totalBorrowShares: borrowSharesRaw,
            lastUpdate: 1,
            fee: feeRaw
        });

        assertEq(irm.borrowRate(params, market), rate);
    }
}
