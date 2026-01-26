// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";

/// @notice Property: Diamond-only token control
/// @notice Validates: Requirements 13.1, 13.2
/// forge-config: default.fuzz.runs = 100
contract DerivativeTokenControlPropertyTest is Test {
    OptionToken internal optionToken;
    FuturesToken internal futuresToken;
    address internal constant MANAGER = address(0xBEEF);

    function setUp() public {
        optionToken = new OptionToken("", address(this), MANAGER);
        futuresToken = new FuturesToken("", address(this), MANAGER);
    }

    function testProperty_DiamondOnlyTokenControl(address caller, uint256 id, uint256 amount) public {
        vm.assume(caller != MANAGER);
        id = bound(id, 1, type(uint128).max);
        amount = bound(amount, 0, type(uint96).max);

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.DerivativeToken_NotManager.selector, caller));
        optionToken.managerMint(caller, id, amount, "");
        vm.expectRevert(abi.encodeWithSelector(OptionToken.DerivativeToken_NotManager.selector, caller));
        optionToken.managerBurn(caller, id, amount);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = amount;
        vm.expectRevert(abi.encodeWithSelector(OptionToken.DerivativeToken_NotManager.selector, caller));
        optionToken.managerBurnBatch(caller, ids, amounts);
        vm.stopPrank();

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(FuturesToken.DerivativeToken_NotManager.selector, caller));
        futuresToken.managerMint(caller, id, amount, "");
        vm.expectRevert(abi.encodeWithSelector(FuturesToken.DerivativeToken_NotManager.selector, caller));
        futuresToken.managerBurn(caller, id, amount);
        vm.expectRevert(abi.encodeWithSelector(FuturesToken.DerivativeToken_NotManager.selector, caller));
        futuresToken.managerBurnBatch(caller, ids, amounts);
        vm.stopPrank();
    }
}
