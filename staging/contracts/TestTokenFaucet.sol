// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Hands out the QA migration test tokens from a stock the owner tops up.
/// A claim picks any of THOR, yTHOR, uTHOR, vTHOR and USDC; the amounts are drawn
/// around a base amount down to the last wei, so testers see odd balances.
/// uTHOR and vTHOR are THOR deposited into the test vault for the claimer.
/// The draw is predictable from block data, which is fine for worthless tokens.
contract TestTokenFaucet is Ownable {
    using SafeERC20 for IERC20;

    uint8 public constant TOKEN_COUNT = 5;
    uint8 public constant THOR = 0;
    uint8 public constant YTHOR = 1;
    uint8 public constant UTHOR = 2;
    uint8 public constant VTHOR = 3;
    uint8 public constant USDC = 4;
    uint16 public constant MAX_SPREAD_BPS = 10_000;

    IERC20 public immutable thor;
    IERC20 public immutable yThor;
    IERC4626 public immutable uThor;
    IERC4626 public immutable vThor;
    IERC20 public immutable usdc;

    uint256[TOKEN_COUNT] public baseAmounts;
    uint16 public spreadBps;
    uint32 public cooldown;
    mapping(address => uint256) public lastClaimAt;
    uint256 private _nonce;

    /// @param token The THOR, yTHOR or USDC sent, or the uTHOR/vTHOR vault whose shares were minted.
    /// @param amount Tokens sent, or vault shares minted.
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event BaseAmountsUpdated(uint256[TOKEN_COUNT] baseAmounts);
    event SpreadUpdated(uint16 spreadBps);
    event CooldownUpdated(uint32 cooldown);

    error EmptySelection();
    error UnknownToken();
    error CoolingDown(uint256 nextClaimAt);
    error SpreadTooWide();

    constructor(
        address owner_,
        IERC20 thor_,
        IERC20 yThor_,
        IERC4626 uThor_,
        IERC4626 vThor_,
        IERC20 usdc_,
        uint256[TOKEN_COUNT] memory baseAmounts_,
        uint16 spreadBps_,
        uint32 cooldown_
    ) Ownable(owner_) {
        require(uThor_.asset() == address(thor_) && vThor_.asset() == address(thor_), "Vault asset is not THOR");
        thor = thor_;
        yThor = yThor_;
        uThor = uThor_;
        vThor = vThor_;
        usdc = usdc_;
        _setBaseAmounts(baseAmounts_);
        _setSpread(spreadBps_);
        _setCooldown(cooldown_);
        thor_.forceApprove(address(uThor_), type(uint256).max);
        thor_.forceApprove(address(vThor_), type(uint256).max);
    }

    /// @param selection Bitmask of the tokens to receive: bit THOR, YTHOR, UTHOR, VTHOR, USDC.
    function claim(uint8 selection) external {
        if (selection == 0) revert EmptySelection();
        if (selection >> TOKEN_COUNT != 0) revert UnknownToken();
        uint256 next = nextClaimAt(msg.sender);
        if (block.timestamp < next) revert CoolingDown(next);
        lastClaimAt[msg.sender] = block.timestamp;

        for (uint8 i = 0; i < TOKEN_COUNT; i++) {
            if ((selection >> i) & 1 == 0) continue;
            uint256 amount = _draw(baseAmounts[i]);
            if (i == UTHOR || i == VTHOR) {
                IERC4626 vault = i == UTHOR ? uThor : vThor;
                emit Claimed(msg.sender, address(vault), vault.deposit(amount, msg.sender));
            } else {
                IERC20 token = i == THOR ? thor : i == YTHOR ? yThor : usdc;
                token.safeTransfer(msg.sender, amount);
                emit Claimed(msg.sender, address(token), amount);
            }
        }
    }

    function nextClaimAt(address user) public view returns (uint256) {
        uint256 last = lastClaimAt[user];
        return last == 0 ? 0 : last + cooldown;
    }

    /// @notice The most a single claim can draw of each token, so a client can tell which ones the stock still covers.
    function maxAmounts() external view returns (uint256[TOKEN_COUNT] memory amounts) {
        for (uint8 i = 0; i < TOKEN_COUNT; i++) {
            amounts[i] = baseAmounts[i] + (baseAmounts[i] * spreadBps) / MAX_SPREAD_BPS;
        }
    }

    function setBaseAmounts(uint256[TOKEN_COUNT] calldata baseAmounts_) external onlyOwner {
        _setBaseAmounts(baseAmounts_);
    }

    function setSpread(uint16 spreadBps_) external onlyOwner {
        _setSpread(spreadBps_);
    }

    function setCooldown(uint32 cooldown_) external onlyOwner {
        _setCooldown(cooldown_);
    }

    function withdraw(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
    }

    function _draw(uint256 base) private returns (uint256) {
        uint256 spread = (base * spreadBps) / MAX_SPREAD_BPS;
        uint256 entropy = uint256(keccak256(abi.encode(block.prevrandao, msg.sender, _nonce++)));
        return base - spread + (entropy % (2 * spread + 1));
    }

    function _setBaseAmounts(uint256[TOKEN_COUNT] memory baseAmounts_) private {
        baseAmounts = baseAmounts_;
        emit BaseAmountsUpdated(baseAmounts_);
    }

    function _setSpread(uint16 spreadBps_) private {
        if (spreadBps_ > MAX_SPREAD_BPS) revert SpreadTooWide();
        spreadBps = spreadBps_;
        emit SpreadUpdated(spreadBps_);
    }

    function _setCooldown(uint32 cooldown_) private {
        cooldown = cooldown_;
        emit CooldownUpdated(cooldown_);
    }
}
