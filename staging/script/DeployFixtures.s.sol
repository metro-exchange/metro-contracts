// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mintable} from "xmetro-mocks/ERC20Mintable.sol";
import {MockSyrupUSDC} from "xmetro-mocks/MockSyrupUSDC.sol";
import {MockAaveV4Giver} from "xmetro-mocks/MockAaveV4Giver.sol";
import {
    MockAaveV3Pool,
    MockAaveV4Spoke,
    MockPoolPermissionManager,
    MockSyrupRouter
} from "xmetro-mocks/MockDepositProtocols.sol";
import {TestUSDC} from "../contracts/TestUSDC.sol";
import {TestTHOR} from "../contracts/TestTHOR.sol";
import {TestYTHOR} from "../contracts/TestYTHOR.sol";
import {TestUSDT} from "../contracts/TestUSDT.sol";
import {TestWBTC} from "../contracts/TestWBTC.sol";
import {TestGHO} from "../contracts/TestGHO.sol";
import {TestXAUT} from "../contracts/TestXAUT.sol";
import {TestExtraToken} from "../contracts/TestExtraToken.sol";
import {TestUTHOR} from "../contracts/TestUTHOR.sol";
import {TestVTHOR} from "../contracts/TestVTHOR.sol";
import {TestTokenFaucet} from "../contracts/TestTokenFaucet.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
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
}

/// @notice Deploys the long-lived staging fixtures on Base: test tokens, protocol mocks, the
/// uTHOR/vTHOR test vaults, the test-token faucet and USDC liquidity for every swap output.
/// Run it only to rebuild the fixtures from scratch; deploy-system.sh reuses the recorded ones.
contract DeployFixtures is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant AAVE_V3_INDEX = 1e27;
    uint256 internal constant AAVE_V4_USDC_RESERVE_ID = 7;
    uint256 internal constant MAPLE_LENDER_BITMAP = 16;
    uint16 internal constant FAUCET_SPREAD_BPS = 2000;
    uint32 internal constant FAUCET_COOLDOWN = 5 minutes;
    bytes32 internal constant P_DEPOSIT = "P:deposit";
    bytes32 internal constant P_TRANSFER = "P:transfer";
    bytes32 internal constant P_TRANSFER_FROM = "P:transferFrom";

    struct Fixtures {
        ERC20Mintable usdc;
        ERC20Mintable thor;
        ERC20Mintable yThor;
        ERC20Mintable usdt;
        ERC20Mintable wbtc;
        ERC20Mintable gho;
        ERC20Mintable xaut;
        ERC20Mintable extra;
        MockSyrupUSDC syrup;
        MockAaveV3Pool aaveV3Pool;
        MockAaveV4Spoke aaveV4Spoke;
        MockAaveV4Giver aaveV4Giver;
        MockPoolPermissionManager permissionManager;
        MockSyrupRouter syrupRouter;
        TestUTHOR uThor;
        TestVTHOR vThor;
        TestTokenFaucet faucet;
    }

    function run() external {
        require(block.chainid == BASE_CHAIN_ID, "DeployFixtures: not Base");
        address owner = vm.envAddress("STAGING_OWNER");
        address permissionAdmin = vm.envAddress("STAGING_MAPLE_PERMISSION_ADMIN");
        IUniswapV2Router02 router = IUniswapV2Router02(vm.envAddress("UNISWAP_V2_ROUTER"));
        require(address(router).code.length != 0, "DeployFixtures: V2 router has no code");

        vm.startBroadcast(owner);
        Fixtures memory f = _deployTokens();
        _deployProtocolMocks(f, owner, permissionAdmin);
        _deployThorVaultsAndFaucet(f, owner);
        address[6] memory pairs = _seedPools(f, owner, router);
        vm.stopBroadcast();

        _write(f, pairs);
    }

    function _deployTokens() internal returns (Fixtures memory f) {
        f.usdc = new TestUSDC();
        f.thor = new TestTHOR();
        f.yThor = new TestYTHOR();
        f.usdt = new TestUSDT();
        f.wbtc = new TestWBTC();
        f.gho = new TestGHO();
        f.xaut = new TestXAUT();
        f.extra = new TestExtraToken();
        f.syrup = new MockSyrupUSDC(address(f.usdc));
    }

    function _deployProtocolMocks(Fixtures memory f, address owner, address permissionAdmin) internal {
        f.aaveV3Pool = new MockAaveV3Pool(address(f.usdc), AAVE_V3_INDEX);
        f.aaveV4Spoke = new MockAaveV4Spoke(address(f.usdc), AAVE_V4_USDC_RESERVE_ID);
        f.aaveV4Giver = new MockAaveV4Giver(address(f.aaveV4Spoke));
        f.aaveV4Spoke.updatePositionManager(address(f.aaveV4Giver), true);

        f.permissionManager = new MockPoolPermissionManager();
        f.syrupRouter =
            new MockSyrupRouter(address(f.usdc), address(f.syrup), address(f.permissionManager), permissionAdmin);
        f.syrup.configureMock(address(f.syrupRouter), address(f.permissionManager));
        f.permissionManager.setPermissionAdmin(permissionAdmin, true);
        f.permissionManager.setPermissionAdmin(owner, true);
        f.permissionManager.setPermissionAdmin(address(f.syrupRouter), true);
        f.permissionManager.setPoolBitmap(address(f.syrupRouter), P_DEPOSIT, MAPLE_LENDER_BITMAP);
        f.permissionManager.setPoolBitmap(address(f.syrupRouter), P_TRANSFER, 0);
        f.permissionManager.setPoolBitmap(address(f.syrupRouter), P_TRANSFER_FROM, 0);
        f.permissionManager.setLenderBitmap(address(f.syrupRouter), MAPLE_LENDER_BITMAP);
        f.permissionManager.setLenderBitmap(owner, MAPLE_LENDER_BITMAP);
    }

    function _deployThorVaultsAndFaucet(Fixtures memory f, address owner) internal {
        f.uThor = new TestUTHOR(IERC20(address(f.thor)), IERC20(address(f.usdc)));
        f.vThor = new TestVTHOR(IERC20(address(f.thor)));
        f.faucet = new TestTokenFaucet(
            owner,
            IERC20(address(f.thor)),
            IERC20(address(f.yThor)),
            f.uThor,
            f.vThor,
            IERC20(address(f.usdc)),
            [uint256(1000e18), 1000e18, 500e18, 500e18, 100e6],
            FAUCET_SPREAD_BPS,
            FAUCET_COOLDOWN
        );
        f.thor.mint(address(f.faucet), 10_000_000e18);
        f.yThor.mint(address(f.faucet), 5_000_000e18);
        f.usdc.mint(address(f.faucet), 1_000_000e6);
    }

    function _seedPools(Fixtures memory f, address owner, IUniswapV2Router02 router)
        internal
        returns (address[6] memory pairs)
    {
        IUniswapV2Factory factory = IUniswapV2Factory(router.factory());
        address[6] memory outputs =
            [address(f.usdt), address(f.wbtc), address(f.gho), address(f.xaut), address(f.syrup), address(f.extra)];
        uint8[6] memory decimals = [6, 8, 18, 6, 6, 18];
        uint256 usdcPerPool = 1000e6;
        f.usdc.mint(owner, usdcPerPool * outputs.length);
        f.usdc.approve(address(router), usdcPerPool * outputs.length);

        for (uint256 i; i < outputs.length; ++i) {
            pairs[i] = factory.createPair(address(f.usdc), outputs[i]);
            uint256 amount = 1000 * 10 ** decimals[i];
            if (outputs[i] == address(f.syrup)) {
                f.permissionManager.setLenderBitmap(pairs[i], MAPLE_LENDER_BITMAP);
                f.syrup.mint(owner, amount);
            } else {
                ERC20Mintable(outputs[i]).mint(owner, amount);
            }
            IERC20(outputs[i]).approve(address(router), amount);
            router.addLiquidity(
                address(f.usdc), outputs[i], usdcPerPool, amount, usdcPerPool, amount, owner, block.timestamp + 1 hours
            );
        }
    }

    function _write(Fixtures memory f, address[6] memory pairs) internal {
        string memory o = "fixtures";
        vm.serializeAddress(o, "TestUSDC", address(f.usdc));
        vm.serializeAddress(o, "TestTHOR", address(f.thor));
        vm.serializeAddress(o, "TestYTHOR", address(f.yThor));
        vm.serializeAddress(o, "TestUSDT", address(f.usdt));
        vm.serializeAddress(o, "TestWBTC", address(f.wbtc));
        vm.serializeAddress(o, "TestGHO", address(f.gho));
        vm.serializeAddress(o, "TestXAUT", address(f.xaut));
        vm.serializeAddress(o, "TestExtraToken", address(f.extra));
        vm.serializeAddress(o, "TestSyrupUSDC", address(f.syrup));
        vm.serializeAddress(o, "uTHOR", address(f.uThor));
        vm.serializeAddress(o, "vTHOR", address(f.vThor));
        vm.serializeAddress(o, "TestTokenFaucet", address(f.faucet));
        vm.serializeAddress(o, "MockAaveV3Pool", address(f.aaveV3Pool));
        vm.serializeAddress(o, "MockScaledAToken", address(f.aaveV3Pool.aUsdc()));
        vm.serializeAddress(o, "MockAaveV4Spoke", address(f.aaveV4Spoke));
        vm.serializeAddress(o, "MockAaveV4Giver", address(f.aaveV4Giver));
        vm.serializeAddress(o, "MockSyrupRouter", address(f.syrupRouter));
        vm.serializeAddress(o, "MockPoolPermissionManager", address(f.permissionManager));
        vm.serializeAddress(o, "TestUSDT/USDC", pairs[0]);
        vm.serializeAddress(o, "TestWBTC/USDC", pairs[1]);
        vm.serializeAddress(o, "TestGHO/USDC", pairs[2]);
        vm.serializeAddress(o, "TestXAUT/USDC", pairs[3]);
        vm.serializeAddress(o, "TestSyrupUSDC/USDC", pairs[4]);
        string memory json = vm.serializeAddress(o, "TestExtraToken/USDC", pairs[5]);
        vm.createDir("output", true);
        vm.writeJson(json, "output/fixtures.json");
        console2.log("Fixture addresses written to staging/output/fixtures.json");
    }
}
