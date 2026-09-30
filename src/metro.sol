// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MetroToken is ERC20Capped, ERC20Permit, Ownable {
    uint256 public constant MAX_SUPPLY = 100_000_000 ether;

    /// @notice Minter allowlist for `mint()`.
    mapping(address => bool) public isMinter;

    event MinterStatusUpdated(address indexed minter, bool status);

    constructor(string memory name_, string memory symbol_, address owner_)
        ERC20(name_, symbol_)
        ERC20Capped(MAX_SUPPLY)
        ERC20Permit(name_)
        Ownable(owner_)
    {}

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

    /// @dev Resolve the ERC20Permit/ERC20Capped inheritance path and enforce the immutable cap on every mint.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}
