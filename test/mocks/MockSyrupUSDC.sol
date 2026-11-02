// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IMockMaplePermissions {
    function hasPermission(address manager, address lender, bytes32 functionId) external view returns (bool);
}

/// @notice QA-only Maple Pool deposit and share-transfer surface; lending and redemption are omitted.
/// @dev Converts at the configured mock rate; does not model loan NAV, bootstrap, or governance.
///      Event fields match the archived Maple ABI for frontend decoding of the tested path.
contract MockSyrupUSDC is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    event Deposit(address indexed caller_, address indexed owner_, uint256 assets_, uint256 shares_);
    event Transfer(address indexed owner_, address indexed recipient_, uint256 amount_);
    event Approval(address indexed owner_, address indexed spender_, uint256 amount_);

    string public constant name = "Test Syrup USDC";
    string public constant symbol = "TestSyrupUSDC";
    uint8 public constant decimals = 6;
    address public immutable asset;
    address public manager;
    IMockMaplePermissions public permissions;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public shareBps = 10_000;

    constructor(address asset_) Ownable(msg.sender) {
        asset = asset_;
    }

    // These setters are QA controls, not production protocol configuration methods.
    // PoolManager is not reproduced; manager uses the Router address as its permission key.
    function configureMock(address manager_, address permissions_) external onlyOwner {
        manager = manager_;
        permissions = IMockMaplePermissions(permissions_);
    }

    function setShareBps(uint256 value) external {
        require(msg.sender == owner() || msg.sender == manager, "MockMaplePool: only admin");
        shareBps = value;
    }

    // Seed mock liquidity or donated shares; this is not evidence of a real deposit.
    function mint(address recipient_, uint256 amount_) external onlyOwner {
        _mint(recipient_, amount_);
    }

    function deposit(uint256 assets_, address receiver_) external nonReentrant returns (uint256 shares_) {
        require(receiver_ != address(0) && assets_ != 0, "MockMaplePool: empty deposit");
        _check(receiver_, bytes32("P:deposit"));
        shares_ = previewDeposit(assets_);
        require(shares_ != 0, "MockMaplePool: zero shares");
        // Match the tested Maple order: mint and emit Deposit before pulling assets; failure reverts all.
        _mint(receiver_, shares_);
        emit Deposit(msg.sender, receiver_, assets_, shares_);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets_);
    }

    function previewDeposit(uint256 assets_) public view returns (uint256 shares_) {
        return Math.mulDiv(assets_, shareBps, 10_000);
    }

    function approve(address spender_, uint256 amount_) external returns (bool success_) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address recipient_, uint256 amount_) external returns (bool success_) {
        _check(msg.sender, bytes32("P:transfer"));
        _check(recipient_, bytes32("P:transfer"));
        _transfer(msg.sender, recipient_, amount_);
        return true;
    }

    function transferFrom(address owner_, address recipient_, uint256 amount_) external returns (bool success_) {
        _check(owner_, bytes32("P:transferFrom"));
        _check(recipient_, bytes32("P:transferFrom"));
        uint256 allowed = allowance[owner_][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[owner_][msg.sender] = allowed - amount_;
            emit Approval(owner_, msg.sender, allowed - amount_);
        }
        _transfer(owner_, recipient_, amount_);
        return true;
    }

    function _check(address lender, bytes32 functionId) private view {
        require(address(permissions) != address(0), "MockMaplePool: not configured");
        require(permissions.hasPermission(manager, lender, functionId), "MockMaplePool: unauthorized");
    }

    function _mint(address recipient_, uint256 amount_) private {
        totalSupply += amount_;
        balanceOf[recipient_] += amount_;
        emit Transfer(address(0), recipient_, amount_);
    }

    function _transfer(address owner_, address recipient_, uint256 amount_) private {
        balanceOf[owner_] -= amount_;
        balanceOf[recipient_] += amount_;
        emit Transfer(owner_, recipient_, amount_);
    }
}
