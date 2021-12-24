//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract ERC1155MockContract is ERC1155 {
    constructor(string memory name_, string memory symbol_)
        ERC1155("mockURI")
    {}

    function mint(address to, uint256 tokenId, uint256 amount, bytes memory data) external {
        _mint(to, tokenId, amount, data);
    }
}
