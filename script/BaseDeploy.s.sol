// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DiamondCutFacet} from "../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/core/DiamondLoupeFacet.sol";
import {Diamond} from "../src/core/Diamond.sol";
import {DiamondInit} from "../src/core/DiamondInit.sol";
import {OwnershipFacet} from "../src/core/OwnershipFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {PositionNFT} from "../src/nft/PositionNFT.sol";
import {FacetCatalog} from "./releases/FacetCatalog.sol";

contract BaseDeployScript is FacetCatalog {
    struct BaseDeployment {
        address diamond;
        address positionNFT;
    }

    function runBase() external returns (BaseDeployment memory deployment) {
        address owner_ = vm.envAddress("OWNER");
        address timelock_ = vm.envAddress("TIMELOCK");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        deployment = _deployBase(owner_, timelock_);
        vm.stopBroadcast();
    }

    function deployBaseForTest(address owner_, address timelock_) external returns (BaseDeployment memory deployment) {
        vm.startPrank(owner_);
        deployment = _deployBase(owner_, timelock_);
        vm.stopPrank();
    }

    function _deployBase(address owner_, address timelock_) internal returns (BaseDeployment memory deployment) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet own = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(cut), _selectors(cut));
        cuts[1] = _cut(address(loupe), _selectors(loupe));
        cuts[2] = _cut(address(own), _selectors(own));

        Diamond diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: owner_}));
        PositionNFT nftContract = new PositionNFT();
        DiamondInit initializer = new DiamondInit();

        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, timelock_, address(nftContract))
        );

        deployment = BaseDeployment({diamond: address(diamond), positionNFT: address(nftContract)});
    }
}
