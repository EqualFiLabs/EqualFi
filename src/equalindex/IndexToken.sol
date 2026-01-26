// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";
import "../libraries/Errors.sol";

interface IEqualIndexData {
    struct Index {
        address[] assets;
        uint256[] bundleAmounts;
        uint16[] mintFeeBps;
        uint16[] burnFeeBps;
        uint16 flashFeeBps;
        uint256 totalUnits;
        address token;
        bool paused;
    }

    function getIndex(uint256 indexId) external view returns (Index memory index_);

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256);

    function getFeePot(uint256 indexId, address asset) external view returns (uint256);
}

/// @notice ERC20 IndexToken with restricted mint/burn and integrator helpers.
contract IndexToken is ERC20, ERC20Permit, ReentrancyGuard {
    address public immutable minter;
    uint256 public immutable indexId;

    address[] internal _assets;
    uint256[] internal _bundleAmounts;
    uint256 public flashFeeBps;
    uint256 public bundleCount;
    bytes32 public bundleHash;

    uint256 public totalMintFeesCollected; // tracked in fee units (index units equivalent)
    uint256 public totalBurnFeesCollected; // tracked in fee units (index units equivalent)

    event MintDetails(
        address indexed user, uint256 units, address[] assets, uint256[] assetAmounts, uint256[] feeAmounts
    );
    event BurnDetails(
        address indexed user, uint256 units, address[] assets, uint256[] assetAmounts, uint256[] feeAmounts
    );

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address minter_,
        address[] memory assets_,
        uint256[] memory bundleAmounts_,
        uint256 flashFeeBps_,
        uint256 indexId_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (minter_ == address(0)) revert InvalidMinter();
        require(assets_.length == bundleAmounts_.length, "IndexToken: length mismatch");
        require(assets_.length > 0, "IndexToken: empty bundle");

        minter = minter_;
        indexId = indexId_;
        _assets = assets_;
        _bundleAmounts = bundleAmounts_;
        bundleCount = assets_.length;
        flashFeeBps = flashFeeBps_;
        bundleHash = keccak256(abi.encode(assets_, bundleAmounts_));
    }

    // --- Mint/burn control ---

    function mintIndexUnits(address to, uint256 amount) external nonReentrant onlyMinter {
        _mint(to, amount);
    }

    function burnIndexUnits(address from, uint256 amount) external nonReentrant onlyMinter {
        _burn(from, amount);
    }

    function recordMintDetails(
        address user,
        uint256 units,
        address[] calldata assets_,
        uint256[] calldata assetAmounts,
        uint256[] calldata feeAmounts,
        uint256 feeUnits
    ) external onlyMinter {
        if (feeUnits == 0 && feeAmounts.length == _bundleAmounts.length) {
            feeUnits = _feeAmountsToUnits(feeAmounts);
        }
        totalMintFeesCollected += feeUnits;
        emit MintDetails(user, units, assets_, assetAmounts, feeAmounts);
    }

    function recordBurnDetails(
        address user,
        uint256 units,
        address[] calldata assets_,
        uint256[] calldata assetAmounts,
        uint256[] calldata feeAmounts,
        uint256 feeUnits
    ) external onlyMinter {
        if (feeUnits == 0 && feeAmounts.length == _bundleAmounts.length) {
            feeUnits = _feeAmountsToUnits(feeAmounts);
        }
        totalBurnFeesCollected += feeUnits;
        emit BurnDetails(user, units, assets_, assetAmounts, feeAmounts);
    }

    function setFlashFeeBps(uint256 newFlashFeeBps) external onlyMinter {
        flashFeeBps = newFlashFeeBps;
    }

    // --- Introspection helpers ---

    /// @dev Internal helper for paginating bundle configuration
    function _sliceBundle(uint256 offset, uint256 limit)
        internal
        view
        returns (address[] memory assetsSlice, uint256[] memory bundleSlice)
    {
        uint256 total = bundleCount;
        if (offset >= total) {
            return (new address[](0), new uint256[](0));
        }

        uint256 remaining = total - offset;
        if (limit == 0 || limit > remaining) {
            limit = remaining;
        }

        assetsSlice = new address[](limit);
        bundleSlice = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            uint256 idx = offset + i;
            assetsSlice[i] = _assets[idx];
            bundleSlice[i] = _bundleAmounts[idx];
        }
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function bundleAmounts() external view returns (uint256[] memory) {
        return _bundleAmounts;
    }

    /// @notice Get paginated list of index assets
    /// @param offset Starting asset index (0-based)
    /// @param limit Maximum number of assets to return (0 = until end)
    function assetsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory assetsOut) {
        (assetsOut,) = _sliceBundle(offset, limit);
    }

    /// @notice Get paginated list of bundle amounts
    /// @param offset Starting bundle index (0-based)
    /// @param limit Maximum number of bundle entries to return (0 = until end)
    function bundleAmountsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory bundleOut)
    {
        (, bundleOut) = _sliceBundle(offset, limit);
    }

    function previewMint(uint256 units)
        external
        view
        returns (address[] memory assetsOut, uint256[] memory required, uint256[] memory feeAmounts)
    {
        assetsOut = _assets;
        uint256 len = _bundleAmounts.length;
        required = new uint256[](len);
        feeAmounts = new uint256[](len);
        IEqualIndexData.Index memory idx = IEqualIndexData(minter).getIndex(indexId);
        for (uint256 i = 0; i < len; i++) {
            uint256 need = Math.mulDiv(_bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
            uint256 fee = Math.mulDiv(need, idx.mintFeeBps[i], 10_000);
            required[i] = need + fee;
            feeAmounts[i] = fee;
        }
    }

    /// @notice Paginated preview of mint requirements for a given unit amount
    /// @param units Number of index units to mint
    /// @param offset Starting asset index (0-based)
    /// @param limit Maximum number of assets to return (0 = until end)
    function previewMintPaginated(uint256 units, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assetsOut, uint256[] memory required, uint256[] memory feeAmounts)
    {
        uint256[] memory bundleSlice;
        (assetsOut, bundleSlice) = _sliceBundle(offset, limit);
        uint256 len = bundleSlice.length;
        required = new uint256[](len);
        feeAmounts = new uint256[](len);
        IEqualIndexData.Index memory idx = IEqualIndexData(minter).getIndex(indexId);
        for (uint256 i = 0; i < len; i++) {
            uint256 need = Math.mulDiv(bundleSlice[i], units, LibEqualIndex.INDEX_SCALE);
            uint256 fee = Math.mulDiv(need, idx.mintFeeBps[offset + i], 10_000);
            required[i] = need + fee;
            feeAmounts[i] = fee;
        }
    }

    /// @notice Preview redemption at current NAV (includes accumulated fees in vault)
    function previewRedeem(uint256 units)
        external
        view
        returns (address[] memory assetsOut, uint256[] memory netOut, uint256[] memory feeAmounts)
    {
        assetsOut = _assets;
        uint256 len = _bundleAmounts.length;
        netOut = new uint256[](len);
        feeAmounts = new uint256[](len);
        
        IEqualIndexData.Index memory idx = IEqualIndexData(minter).getIndex(indexId);
        uint256 totalSupply = totalSupply();
        
        if (totalSupply == 0) {
            // No supply, return base bundle
            for (uint256 i = 0; i < len; i++) {
                uint256 gross = Math.mulDiv(_bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
                uint256 burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
                netOut[i] = gross - burnFee;
                feeAmounts[i] = burnFee;
            }
        } else {
            // Return proportional share of vault (current NAV)
            for (uint256 i = 0; i < len; i++) {
                uint256 vaultBalance = IEqualIndexData(minter).getVaultBalance(indexId, _assets[i]);
                uint256 potBalance = IEqualIndexData(minter).getFeePot(indexId, _assets[i]);
                uint256 navShare = Math.mulDiv(vaultBalance, units, totalSupply);
                uint256 potShare = Math.mulDiv(potBalance, units, totalSupply);
                uint256 gross = navShare + potShare;
                uint256 burnFee = Math.mulDiv(gross, idx.burnFeeBps[i], 10_000);
                netOut[i] = gross - burnFee;
                feeAmounts[i] = burnFee;
            }
        }
    }

    /// @notice Paginated preview of redemption at current NAV
    /// @param units Number of index units to redeem
    /// @param offset Starting asset index (0-based)
    /// @param limit Maximum number of assets to return (0 = until end)
    function previewRedeemPaginated(uint256 units, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assetsOut, uint256[] memory netOut, uint256[] memory feeAmounts)
    {
        uint256[] memory bundleSlice;
        (assetsOut, bundleSlice) = _sliceBundle(offset, limit);
        uint256 len = bundleSlice.length;
        netOut = new uint256[](len);
        feeAmounts = new uint256[](len);

        // Maintain parity with previewRedeem by consulting index metadata
        IEqualIndexData.Index memory idx = IEqualIndexData(minter).getIndex(indexId);
        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            // No supply, return base bundle for this slice
            for (uint256 i = 0; i < len; i++) {
                uint256 gross = Math.mulDiv(bundleSlice[i], units, LibEqualIndex.INDEX_SCALE);
                uint256 burnFee = Math.mulDiv(gross, idx.burnFeeBps[offset + i], 10_000);
                netOut[i] = gross - burnFee;
                feeAmounts[i] = burnFee;
            }
        } else {
            // Return proportional share of vault (current NAV) for this slice
            for (uint256 i = 0; i < len; i++) {
                uint256 vaultBalance = IEqualIndexData(minter).getVaultBalance(indexId, assetsOut[i]);
                uint256 potBalance = IEqualIndexData(minter).getFeePot(indexId, assetsOut[i]);
                uint256 navShare = Math.mulDiv(vaultBalance, units, totalSupply);
                uint256 potShare = Math.mulDiv(potBalance, units, totalSupply);
                uint256 gross = navShare + potShare;
                uint256 burnFee = Math.mulDiv(gross, idx.burnFeeBps[offset + i], 10_000);
                netOut[i] = gross - burnFee;
                feeAmounts[i] = burnFee;
            }
        }
    }

    function previewFlashLoan(uint256 units)
        external
        view
        returns (address[] memory assetsOut, uint256[] memory loanAmounts, uint256[] memory feeAmounts)
    {
        assetsOut = _assets;
        uint256 len = _bundleAmounts.length;
        loanAmounts = new uint256[](len);
        feeAmounts = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 amount = Math.mulDiv(_bundleAmounts[i], units, LibEqualIndex.INDEX_SCALE);
            loanAmounts[i] = amount;
            feeAmounts[i] = (amount * flashFeeBps) / 10_000;
        }
    }

    /// @notice Paginated preview of flash loan bundle amounts and fees
    /// @param units Number of index units to borrow
    /// @param offset Starting asset index (0-based)
    /// @param limit Maximum number of assets to return (0 = until end)
    function previewFlashLoanPaginated(uint256 units, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assetsOut, uint256[] memory loanAmounts, uint256[] memory feeAmounts)
    {
        uint256[] memory bundleSlice;
        (assetsOut, bundleSlice) = _sliceBundle(offset, limit);
        uint256 len = bundleSlice.length;
        loanAmounts = new uint256[](len);
        feeAmounts = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 amount = Math.mulDiv(bundleSlice[i], units, LibEqualIndex.INDEX_SCALE);
            loanAmounts[i] = amount;
            feeAmounts[i] = (amount * flashFeeBps) / 10_000;
        }
    }

    function snapshot()
        external
        view
        returns (
            address[] memory __assets,
            uint256[] memory __bundleAmounts,
            uint256 totalUnits,
            uint256 _flashFeeBps
        )
    {
        __assets = _assets;
        __bundleAmounts = _bundleAmounts;
        totalUnits = totalSupply();
        _flashFeeBps = flashFeeBps;
    }

    /// @notice Returns true if vault balances cover required bundles for total supply.
    function isSolvent() external view returns (bool) {
        uint256 supply = totalSupply();
        address[] memory assetList = _assets;
        uint256 len = assetList.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 required = Math.mulDiv(_bundleAmounts[i], supply, LibEqualIndex.INDEX_SCALE);
            uint256 bal = IEqualIndexData(minter).getVaultBalance(indexId, assetList[i]);
            if (bal < required) return false;
        }
        return true;
    }

    /// @dev Convert per-asset fee amounts into the equivalent index units using bundle ratios.
    function _feeAmountsToUnits(uint256[] calldata feeAmounts) internal view returns (uint256 feeUnits) {
        uint256 len = _bundleAmounts.length;
        if (feeAmounts.length != len) return 0;
        bool hasFee;
        feeUnits = type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            uint256 fee = feeAmounts[i];
            if (fee == 0) continue;
            hasFee = true;
            uint256 unitsForAsset = Math.mulDiv(fee, LibEqualIndex.INDEX_SCALE, _bundleAmounts[i]);
            if (unitsForAsset < feeUnits) {
                feeUnits = unitsForAsset;
            }
        }
        if (!hasFee) {
            return 0;
        }
    }
}
