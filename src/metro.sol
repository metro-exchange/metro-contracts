// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";



contract MetroToken is ERC20, ERC20Permit, Ownable {
    /// @notice Minter allowlist for `mint()`.
    mapping(address => bool) public isMinter;


    event MinterStatusUpdated(address indexed minter, bool status);

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(owner_)
    {
    }

    /**
     * @notice Set/unset a minter (onlyOwner).
     */
    function setMinter(address minter, bool status) external onlyOwner {
        require(isMinter[minter] != status, "MetroToken: same status");
        isMinter[minter] = status;
        emit MinterStatusUpdated(minter, status);
    }

    /**
     * @notice Mint function for allowlisted minters.
     */
    function mint(address to, uint256 amount) external {
        require(isMinter[msg.sender], "MetroToken: not minter");
        require(to != address(0), "MetroToken: bad to");
        require(amount > 0, "MetroToken: zero amount");
        _mint(to, amount);
    }
}
