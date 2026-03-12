// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {OptionToken} from "../../../src/derivatives/OptionToken.sol";

contract OptionTokenStatefulHandler is Test {
    OptionToken internal token;
    address internal owner;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA11);
    address internal constant DAVE = address(0xD0D0);

    uint256 internal constant SERIES_A = 1;
    uint256 internal constant SERIES_B = 2;
    uint256 internal constant SERIES_C = 3;

    mapping(uint256 => uint256) internal expectedSupplyBySeries;

    constructor(OptionToken token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    function managerMint(uint256 actorSeed, uint256 seriesSeed, uint256 amountSeed) external {
        address recipient = _actor(actorSeed);
        uint256 seriesId = _series(seriesSeed);
        uint256 amount = bound(amountSeed, 1, 1_000_000);

        vm.prank(token.manager());
        token.managerMint(recipient, seriesId, amount, "");
        expectedSupplyBySeries[seriesId] += amount;
    }

    function managerBurn(uint256 actorSeed, uint256 seriesSeed, uint256 amountSeed) external {
        address holder = _actor(actorSeed);
        uint256 seriesId = _series(seriesSeed);
        uint256 bal = token.balanceOf(holder, seriesId);
        if (bal == 0) return;

        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(token.manager());
        token.managerBurn(holder, seriesId, amount);
        expectedSupplyBySeries[seriesId] -= amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 seriesSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed + 1);
        uint256 seriesId = _series(seriesSeed);
        uint256 bal = token.balanceOf(from, seriesId);
        if (bal == 0) return;

        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(from);
        token.safeTransferFrom(from, to, seriesId, amount, "");
    }

    function setSeriesURI(uint256 seriesSeed, uint256 salt) external {
        uint256 seriesId = _series(seriesSeed);
        string memory uri_ = string(abi.encodePacked("ipfs://series/", _toString(seriesId), "/", _toString(salt)));
        vm.prank(token.manager());
        token.setSeriesURI(seriesId, uri_);
    }

    function rotateManager(uint256 actorSeed) external {
        address newManager = _actor(actorSeed);
        vm.prank(owner);
        token.setManager(newManager);
    }

    function expectedSupply(uint256 seriesId) external view returns (uint256) {
        return expectedSupplyBySeries[seriesId];
    }

    function actor(uint256 idx) external pure returns (address) {
        return _actor(idx);
    }

    function seriesA() external pure returns (uint256) {
        return SERIES_A;
    }

    function seriesB() external pure returns (uint256) {
        return SERIES_B;
    }

    function seriesC() external pure returns (uint256) {
        return SERIES_C;
    }

    function _actor(uint256 seed) internal pure returns (address) {
        uint256 slot = seed % 4;
        if (slot == 0) return ALICE;
        if (slot == 1) return BOB;
        if (slot == 2) return CAROL;
        return DAVE;
    }

    function _series(uint256 seed) internal pure returns (uint256) {
        uint256 slot = seed % 3;
        if (slot == 0) return SERIES_A;
        if (slot == 1) return SERIES_B;
        return SERIES_C;
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 n = v;
        while (n != 0) {
            digits++;
            n /= 10;
        }
        bytes memory buf = new bytes(digits);
        n = v;
        while (n != 0) {
            digits -= 1;
            buf[digits] = bytes1(uint8(48 + (n % 10)));
            n /= 10;
        }
        return string(buf);
    }
}

contract OptionTokenStatefulInvariantV1Test is StdInvariant, Test {
    string internal constant BASE_URI = "ipfs://base/options";

    OptionToken internal token;
    OptionTokenStatefulHandler internal handler;

    function setUp() public {
        token = new OptionToken(BASE_URI, address(this), address(0xA11CE));
        handler = new OptionTokenStatefulHandler(token, address(this));
        targetContract(address(handler));
    }

    function invariant_supplyMatchesTrackedBalances() public {
        uint256[3] memory series =
            [handler.seriesA(), handler.seriesB(), handler.seriesC()];

        for (uint256 i = 0; i < series.length; i++) {
            uint256 id = series[i];
            uint256 expected = handler.expectedSupply(id);
            uint256 sumBalances;
            for (uint256 j = 0; j < 4; j++) {
                sumBalances += token.balanceOf(handler.actor(j), id);
            }
            assertEq(sumBalances, expected);
        }
    }

    function invariant_managerIsNeverZero() public {
        assertTrue(token.manager() != address(0));
    }

    function invariant_unsetSeriesUsesBaseUri() public {
        assertEq(token.uri(999_999), BASE_URI);
    }
}
