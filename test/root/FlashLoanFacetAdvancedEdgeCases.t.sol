// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FlashLoanFacet, IFlashLoanReceiver} from "../../src/equallend/FlashLoanFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

// Receiver that manipulates state during callback
contract StateManipulatingReceiver is IFlashLoanReceiver {
    FlashLoanFacet public facet;
    MockERC20 public token;
    uint256 public pid;
    uint16 public feeBps;
    bool public shouldTransferToSelf;

    constructor(address facet_, address token_, uint256 pid_) {
        facet = FlashLoanFacet(facet_);
        token = MockERC20(token_);
        pid = pid_;
    }

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setShouldTransferToSelf(bool flag) external {
        shouldTransferToSelf = flag;
    }

    function onFlashLoan(address, address token_, uint256 amount_, bytes calldata) external override returns (bytes32) {
        if (shouldTransferToSelf) {
            // Try to steal funds by transferring to self
            MockERC20(token_).transfer(address(this), amount_ / 2);
        }

        if (feeBps > 0) {
            // Leave balance in place; repayment will be pulled
            uint256 fee = (amount_ * feeBps) / 10_000;
            // Burn half the fee if attempting to grief
            MockERC20(token_).transfer(address(0xdead), fee / 2);
        }
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }
}

// Receiver that uses excessive gas
contract GasGriefingReceiver is IFlashLoanReceiver {
    uint16 public feeBps;
    uint256 public gasToWaste;

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setGasToWaste(uint256 amount) external {
        gasToWaste = amount;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external override returns (bytes32) {
        // Waste gas with expensive operations
        uint256 counter = 0;
        for (uint256 i = 0; i < gasToWaste; i++) {
            counter += i;
        }

        if (feeBps > 0) {
            // Leave funds for pull; optionally burn small amount to simulate deflation
            uint256 fee = (amount * feeBps) / 10_000;
            MockERC20(token).transfer(address(0xdead), fee / 10);
        }
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }
}

// Mock deflationary token (takes fee on transfer)
contract DeflationaryToken {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    uint256 public transferFeeBps = 100; // 1% fee on transfer

    function setTransferFeeBps(uint256 bps) external {
        transferFeeBps = bps;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * transferFeeBps) / 10_000;
        uint256 amountAfterFee = amount - fee;
        _balances[msg.sender] -= amount;
        _balances[to] += amountAfterFee;
        // Fee is burned
        _totalSupply -= fee;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * transferFeeBps) / 10_000;
        uint256 amountAfterFee = amount - fee;
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amountAfterFee;
        // Fee is burned
        _totalSupply -= fee;
        return true;
    }
}

contract FlashLoanHarness is FlashLoanFacet {
    function initPool(uint256 pid, address token, uint16 feeBps, bool antiSplit) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = token;
        p.initialized = true;
        p.poolConfig.flashLoanFeeBps = feeBps;
        p.poolConfig.flashLoanAntiSplit = antiSplit;
        p.totalDeposits = 1_000_000 ether;
        p.trackedBalance = MockERC20(token).balanceOf(address(this));
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setTreasuryShare(uint16 bps) external {
        LibAppStorage.AppStorage storage store = s();
        store.treasuryShareBps = bps;
        store.treasuryShareConfigured = true;
    }
}

contract FlashLoanReceiverMock is IFlashLoanReceiver {
    uint16 public feeBps;

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external override returns (bytes32) {
        uint256 fee = (amount * feeBps) / 10_000;
        MockERC20(token).transfer(msg.sender, amount + fee);
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }
}

contract FlashLoanFacetAdvancedEdgeCasesTest is Test {
    FlashLoanHarness internal facet;
    MockERC20 internal token;
    address internal constant TREASURY = address(0xA111);
    uint256 internal constant PID = 1;

    function setUp() public {
        facet = new FlashLoanHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);

        token.mint(address(facet), 1_000_000 ether);

        facet.initPool(PID, address(token), 50, true);
        facet.setTreasury(TREASURY);
        facet.setTreasuryShare(2000); // 20%
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MEDIUM PRIORITY - State Manipulation
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanStateManipulationSucceedsIfFundsAvailable() public {
        StateManipulatingReceiver receiver = new StateManipulatingReceiver(address(facet), address(token), PID);
        receiver.setFeeBps(50);
        receiver.setShouldTransferToSelf(true);

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        // Should succeed if receiver has enough funds despite manipulation
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    function testFlashLoanStateManipulationWithSufficientFunds() public {
        StateManipulatingReceiver receiver = new StateManipulatingReceiver(address(facet), address(token), PID);
        receiver.setFeeBps(50);
        receiver.setShouldTransferToSelf(false);

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        // Should succeed if receiver has enough funds
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MEDIUM PRIORITY - Gas Griefing
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanWithModerateGasUsage() public {
        GasGriefingReceiver receiver = new GasGriefingReceiver();
        receiver.setFeeBps(50);
        receiver.setGasToWaste(1000); // Moderate gas usage

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        // Should succeed with moderate gas usage
        facet.flashLoan(PID, address(receiver), 100 ether, "");
    }

    function testFlashLoanWithHighGasUsage() public {
        GasGriefingReceiver receiver = new GasGriefingReceiver();
        receiver.setFeeBps(50);
        receiver.setGasToWaste(10000); // High gas usage

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        // Should still succeed but use more gas
        uint256 gasBefore = gasleft();
        facet.flashLoan(PID, address(receiver), 100 ether, "");
        uint256 gasUsed = gasBefore - gasleft();

        // Verify significant gas was used
        assertTrue(gasUsed > 100000, "Should use significant gas");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MEDIUM PRIORITY - Deflationary Token
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanWithDeflationaryToken() public {
        DeflationaryToken deflToken = new DeflationaryToken();
        deflToken.mint(address(facet), 1_000_000 ether);

        facet.initPool(2, address(deflToken), 50, false);

        FlashLoanReceiverMock receiver = new FlashLoanReceiverMock();
        receiver.setFeeBps(50);

        deflToken.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        deflToken.approve(address(facet), type(uint256).max);

        // Pull-based repayment succeeds despite deflationary burn
        facet.flashLoan(2, address(receiver), 100 ether, "");
    }

    function testFlashLoanWithDeflationaryTokenStillFails() public {
        DeflationaryToken deflToken = new DeflationaryToken();
        deflToken.mint(address(facet), 1_000_000 ether);

        facet.initPool(2, address(deflToken), 50, false);

        // Custom receiver that accounts for deflationary fee
        DeflationaryAwareReceiver receiver = new DeflationaryAwareReceiver();
        receiver.setFeeBps(50);
        receiver.setDeflationaryFeeBps(100); // 1% deflation

        deflToken.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        deflToken.approve(address(facet), type(uint256).max);

        // Extra deflation plus intentional burn keeps repayment short
        vm.expectRevert("Flash: not repaid");
        facet.flashLoan(2, address(receiver), 100 ether, "");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOW PRIORITY - Fuzz Testing
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzzFlashLoanAmount(uint256 amount) public {
        // Bound amount to reasonable range
        amount = bound(amount, 1, 100_000 ether);

        FlashLoanReceiverMock receiver = new FlashLoanReceiverMock();
        receiver.setFeeBps(50);

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        facet.flashLoan(PID, address(receiver), amount, "");

        // Verify fee was collected
        uint256 expectedFee = (amount * 50) / 10_000;
        uint256 treasuryShare = (expectedFee * 2000) / 10_000;
        assertGe(token.balanceOf(TREASURY), treasuryShare);
    }

    function testFuzzFlashLoanFeeBps(uint16 feeBps) public {
        // Bound fee to reasonable range (0.01% to 10%)
        feeBps = uint16(bound(feeBps, 1, 1000));

        facet.initPool(2, address(token), feeBps, false);
        token.mint(address(facet), 1_000_000 ether);

        FlashLoanReceiverMock receiver = new FlashLoanReceiverMock();
        receiver.setFeeBps(feeBps);

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        uint256 amount = 100 ether;
        facet.flashLoan(2, address(receiver), amount, "");

        // Verify correct fee was collected
        uint256 expectedFee = (amount * feeBps) / 10_000;
        uint256 treasuryShare = (expectedFee * 2000) / 10_000;
        assertGe(token.balanceOf(TREASURY), treasuryShare);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LOW PRIORITY - Event Verification
    // ═══════════════════════════════════════════════════════════════════════════

    function testFlashLoanEmitsCorrectEvent() public {
        FlashLoanReceiverMock receiver = new FlashLoanReceiverMock();
        receiver.setFeeBps(50);

        token.mint(address(receiver), 1_000_000 ether);
        vm.prank(address(receiver));
        token.approve(address(facet), type(uint256).max);

        uint256 amount = 100 ether;
        uint256 expectedFee = (amount * 50) / 10_000;

        vm.expectEmit(true, true, false, true);
        emit FlashLoanFacet.FlashLoan(PID, address(receiver), amount, expectedFee, 50);

        facet.flashLoan(PID, address(receiver), amount, "");
    }
}

// Helper contract for deflationary token testing
contract DeflationaryAwareReceiver is IFlashLoanReceiver {
    uint16 public feeBps;
    uint256 public deflationaryFeeBps;

    function setFeeBps(uint16 bps) external {
        feeBps = bps;
    }

    function setDeflationaryFeeBps(uint256 bps) external {
        deflationaryFeeBps = bps;
    }

    function onFlashLoan(address, address token, uint256 amount, bytes calldata) external override returns (bytes32) {
        uint256 flashFee = (amount * feeBps) / 10_000;
        uint256 totalNeeded = amount + flashFee;

        // Account for deflationary fee on transfer by reserving extra, but leave pull to facet
        uint256 deflationFee = (totalNeeded * deflationaryFeeBps) / 10_000;
        DeflationaryToken(token).transfer(address(0xdead), deflationFee);
        return keccak256("IFlashLoanReceiver.onFlashLoan");
    }
}
