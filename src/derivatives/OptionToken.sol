// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice ERC-1155 token for options rights, controlled by a manager (Diamond).
contract OptionToken is ERC1155, Ownable {
    error DerivativeToken_NotManager(address caller);
    error DerivativeToken_InvalidManager(address manager);

    address public manager;
    string private baseURI;
    mapping(uint256 => string) private seriesURI;

    modifier onlyManager() {
        if (msg.sender != manager) {
            revert DerivativeToken_NotManager(msg.sender);
        }
        _;
    }

    constructor(string memory baseURI_, address owner_, address manager_) ERC1155("") Ownable(owner_) {
        baseURI = baseURI_;
        if (manager_ != address(0)) {
            manager = manager_;
        }
    }

    function setManager(address manager_) external onlyOwner {
        if (manager_ == address(0)) {
            revert DerivativeToken_InvalidManager(manager_);
        }
        manager = manager_;
    }

    function setSeriesURI(uint256 seriesId, string calldata uri_) external onlyManager {
        seriesURI[seriesId] = uri_;
    }

    function managerMint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyManager {
        _mint(to, id, amount, data);
    }

    function managerBurn(address from, uint256 id, uint256 amount) external onlyManager {
        _burn(from, id, amount);
    }

    function managerBurnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) external onlyManager {
        _burnBatch(from, ids, amounts);
    }

    function uri(uint256 id) public view override returns (string memory) {
        string memory custom = seriesURI[id];
        if (bytes(custom).length != 0) {
            return custom;
        }
        return baseURI;
    }
}
