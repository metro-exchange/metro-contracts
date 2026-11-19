// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MetroToken} from "../../../src/metro.sol";
import {xMETRO} from "../../../src/xMETRO.sol";
import {RewardDistributor} from "../../../src/RewardDistributor.sol";
import {ThorMigrationEscrow} from "../../../src/ThorMigrationEscrow.sol";
import {IXMetroDeFiAdapter} from "../../../src/interfaces/IXMetroDeFiAdapter.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {CommissionVault} from "./vendor/CommissionVault.sol";

interface IUniswapV2RouterMainnet {
    function factory() external view returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IUniswapV2FactoryMainnet {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @notice Common fork setup: CREATE release bytecode and fund only by transfers from real token holders.
abstract contract MainnetForkBase is Test {
    uint256 internal constant FORK_BLOCK = 26_077_998;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDC_HOLDER = 0x28C6c06298d514Db089934071355E5743bf21d60;
    address internal constant THOR = 0xa5f2211B9b8170F694421f2046281775E8468044;
    address internal constant YTHOR = 0x8793CD69895C45b2d2474236b3Cb28FC5C764775;
    address internal constant THOR_HOLDER = 0x02d9E8506ba56d3F9bE6007f712720EEaDAc5FdC;
    address internal constant YTHOR_HOLDER = 0x46e3A8C8135647b48B2e82198E42E0C69EacbAb8;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address internal constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant V4_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address internal constant V4_GIVER = 0x17A54b8d6D9C68e7fa1C7112AC998EA1BA51d11e;
    uint256 internal constant V4_USDC_RESERVE = 7;
    address internal constant MAPLE_ROUTER = 0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76;
    address internal constant SYRUP_USDC = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address internal constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;

    MetroToken internal metro;
    xMETRO internal core;
    RewardDistributor internal distributor;
    ThorMigrationEscrow internal escrow;
    CommissionVault internal vault;
    IXMetroDeFiAdapter internal adapter;
    address internal implementation;
    address internal proxy;
    address internal forfeitureRecipient;

    function _fork() internal {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        require(bytes(rpc).length != 0, "ETH_RPC_URL required: never silently skip");
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertEq(block.number, FORK_BLOCK);
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertGt(IERC20(USDC).balanceOf(USDC_HOLDER), 10_000e6);
        assertEq(IERC20Metadata(THOR).decimals(), 18);
        assertEq(IERC20Metadata(YTHOR).decimals(), 18);
        assertEq(THOR_HOLDER.code.length, 0);
        assertEq(YTHOR_HOLDER.code.length, 0);
        assertGt(IERC20(THOR).balanceOf(THOR_HOLDER), 1_000 ether);
        assertGt(IERC20(YTHOR).balanceOf(YTHOR_HOLDER), 1_000 ether);
    }

    function _deploySystem() internal {
        // E-01.02: Execute release-profile creation code through normal CREATE, never etch.
        forfeitureRecipient = makeAddr("fork-forfeiture-recipient");
        metro = MetroToken(_create(abi.encodePacked(_artifact("out-core/metro.sol/MetroToken.json"), abi.encode("Metro", "METRO", address(this)))));
        core = xMETRO(_create(abi.encodePacked(_artifact("out-core/xMETRO.sol/xMETRO.json"), abi.encode(address(this), address(metro), USDC, forfeitureRecipient, 20_000))));
        assertFalse(core.paused(), "Core must deploy unpaused");
        // Pause explicitly for boundary tests; the normal constructor leaves Core operational.
        core.pause();
        implementation = _create(_artifact("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"));
        proxy = address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address,address,address)", address(core), USDC, address(metro))));
        adapter = IXMetroDeFiAdapter(proxy);
        distributor = RewardDistributor(_create(abi.encodePacked(_artifact("out-core/RewardDistributor.sol/RewardDistributor.json"), abi.encode(address(core), address(this)))));
        metro.setMinter(address(core), true);
        core.setDeFiAdapter(proxy);
        core.setRewardDistributor(address(distributor));
        distributor.setOperator(address(this), true);
        core.setAutoCompoundOperator(address(this), true);
        escrow = ThorMigrationEscrow(_create(abi.encodePacked(_artifact("out-core/ThorMigrationEscrow.sol/ThorMigrationEscrow.json"), abi.encode(address(this), address(core), THOR, YTHOR, block.timestamp))));
        escrow.setCaps(20_000_000 ether, 20_000_000 ether);
        escrow.setRatios(1e18, 1e18);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        core.setMigrationEscrow(address(escrow));
        // Deploy the verified Base Vault source afresh for this Distributor, initially with zero split.
        vault = new CommissionVault(USDC, address(distributor), address(this), address(this), 1_000_000e6, 1_000_000e6, false, 1 days, 1 days);
        distributor.setCommissionVault(address(vault));
    }

    function _configureSwaps() internal {
        IXMetroAdapterAdminFork(proxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        IXMetroAdapterAdminFork(proxy).setSwapMetroConfig(true, true);
    }

    function _fundUSDC(address recipient, uint256 amount) internal {
        uint256 beforeBalance = IERC20(USDC).balanceOf(recipient);
        vm.prank(USDC_HOLDER);
        assertTrue(IERC20(USDC).transfer(recipient, amount));
        assertEq(IERC20(USDC).balanceOf(recipient) - beforeBalance, amount);
    }

    function _fundMigrationToken(address token, address holder, address recipient, uint256 amount) internal {
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        vm.prank(holder);
        assertTrue(IERC20(token).transfer(recipient, amount));
        assertEq(IERC20(token).balanceOf(recipient) - beforeBalance, amount);
    }

    function _mintAndStake(address user, uint256 amount) internal {
        if (!metro.isMinter(address(this))) metro.setMinter(address(this), true);
        metro.mint(user, amount);
        vm.startPrank(user);
        metro.approve(address(core), amount);
        core.stake(amount);
        vm.stopPrank();
    }

    function _distribute(uint256 amount) internal {
        _fundUSDC(address(this), amount);
        IERC20(USDC).approve(address(distributor), amount);
        distributor.distribute(amount);
    }

    function _createMetroPool(uint256 metroAmount, uint256 usdcAmount) internal returns (address pair) {
        IUniswapV2RouterMainnet router = IUniswapV2RouterMainnet(V2_ROUTER);
        address factory = router.factory();
        assertEq(IUniswapV2FactoryMainnet(factory).getPair(address(metro), USDC), address(0));
        if (!metro.isMinter(address(this))) metro.setMinter(address(this), true);
        metro.mint(address(this), metroAmount);
        _fundUSDC(address(this), usdcAmount);
        metro.approve(V2_ROUTER, metroAmount);
        IERC20(USDC).approve(V2_ROUTER, usdcAmount);
        (uint256 usedMetro, uint256 usedUSDC, uint256 liquidity) = router.addLiquidity(address(metro), USDC, metroAmount, usdcAmount, metroAmount, usdcAmount, address(this), block.timestamp + 1 hours);
        assertEq(usedMetro, metroAmount);
        assertEq(usedUSDC, usdcAmount);
        assertGt(liquidity, 0);
        pair = IUniswapV2FactoryMainnet(factory).getPair(address(metro), USDC);
        assertGt(pair.code.length, 0);
    }

    function _artifact(string memory path) internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(path), ".bytecode.object");
    }

    function _create(bytes memory initcode) internal returns (address deployed) {
        assembly ("memory-safe") { deployed := create(0, add(initcode, 32), mload(initcode)) }
        require(deployed != address(0), "formal CREATE failed");
    }
}
