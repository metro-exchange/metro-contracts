// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    XMetroDeFiAdapter,
    IUniswapV2Router02,
    IV3SwapRouter,
    IOneInchAggregationRouterV6,
    IAaveV3Pool,
    IAToken,
    IAaveV4Spoke,
    ISyrupRouter,
    IPoolPermissionManager
} from "../../src/XMetroDeFiAdapter.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";

contract CompactFlowToken is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract CompactSyrupToken is CompactFlowToken {
    address public immutable asset;

    constructor(address asset_) CompactFlowToken("Syrup USDC", "syrupUSDC", 6) {
        asset = asset_;
    }
}

contract CompactFlowCore {
    address public owner;
    bool public paused = true;
    address public deFiAdapter;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAdapter(address adapter) external {
        require(msg.sender == owner);
        deFiAdapter = adapter;
    }

    function setPaused(bool value) external {
        require(msg.sender == owner);
        paused = value;
    }

    function runManual(IERC20 usdc, IXMetroDeFiAdapter.ManualExecution calldata request)
        external
        returns (IXMetroDeFiAdapter.ExecutionResult memory result)
    {
        require(usdc.transfer(deFiAdapter, request.amountIn));
        return IXMetroDeFiAdapter(deFiAdapter).execute(request);
    }

    function runBatch(IERC20 usdc, IXMetroDeFiAdapter.BatchExecution calldata request)
        external
        returns (IXMetroDeFiAdapter.ExecutionResult memory result)
    {
        uint256 total;
        for (uint256 i; i < request.amountsIn.length; ++i) {
            total += request.amountsIn[i];
        }
        require(usdc.transfer(deFiAdapter, total));
        return IXMetroDeFiAdapter(deFiAdapter).executeBatch(request);
    }

    function runUnfunded(IXMetroDeFiAdapter.ManualExecution calldata request)
        external
        returns (IXMetroDeFiAdapter.ExecutionResult memory result)
    {
        return IXMetroDeFiAdapter(deFiAdapter).execute(request);
    }

    /// @dev Re-enters through the authorized Core address without transferring funds. The
    ///      Adapter's guard must reject before request validation can be reached.
    function rawReentry() external returns (IXMetroDeFiAdapter.ExecutionResult memory result) {
        IXMetroDeFiAdapter.ManualExecution memory request;
        return IXMetroDeFiAdapter(deFiAdapter).execute(request);
    }
}

contract CompactV2Router is IUniswapV2Router02 {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        CompactFlowToken(path[path.length - 1]).mint(to, amountIn);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }
}

contract CompactMisreportingV2Router is IUniswapV2Router02 {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        CompactFlowToken(path[path.length - 1]).mint(to, amountIn);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn + 1;
    }
}

contract CompactV3Router is IV3SwapRouter {
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        bytes calldata path = params.path;
        address input;
        address output;
        assembly ("memory-safe") {
            input := shr(96, calldataload(path.offset))
            output := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
        require(IERC20(input).transferFrom(msg.sender, address(this), params.amountIn));
        CompactFlowToken(output).mint(params.recipient, params.amountIn);
        return params.amountIn;
    }
}

contract CompactReentrantV2Router is IUniswapV2Router02 {
    CompactFlowCore public immutable core;
    bytes4 public observedRevert;

    constructor(CompactFlowCore core_) {
        core = core_;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        try core.rawReentry() {
            revert("reentry accepted");
        } catch (bytes memory reason) {
            if (reason.length >= 4) {
                assembly ("memory-safe") {
                    sstore(observedRevert.slot, shr(224, mload(add(reason, 32))))
                }
            }
        }
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        CompactFlowToken(path[path.length - 1]).mint(to, amountIn);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }
}

contract CompactOneInchExecutor {}

contract CompactOneInchRouter is IOneInchAggregationRouterV6 {
    uint256 public pullBps = 10_000;
    uint256 public outputBps = 10_000;
    int256 public reportDelta;
    address public forcedReceiver;

    function setBehavior(uint256 pullBps_, uint256 outputBps_, int256 reportDelta_, address forcedReceiver_) external {
        pullBps = pullBps_;
        outputBps = outputBps_;
        reportDelta = reportDelta_;
        forcedReceiver = forcedReceiver_;
    }

    function swap(address, SwapDescription calldata desc, bytes calldata)
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount)
    {
        spentAmount = desc.amount * pullBps / 10_000;
        if (spentAmount != 0) {
            require(desc.srcToken.transferFrom(msg.sender, address(this), spentAmount));
        }
        uint256 outputAmount = desc.amount * outputBps / 10_000;
        if (outputAmount != 0) {
            address receiver = forcedReceiver == address(0) ? desc.dstReceiver : forcedReceiver;
            CompactFlowToken(address(desc.dstToken)).mint(receiver, outputAmount);
        }
        returnAmount = reportDelta < 0 ? outputAmount - uint256(-reportDelta) : outputAmount + uint256(reportDelta);
    }
}

/// @dev Accepts arbitrary calldata so Adapter-side validation cannot rely on the
///      configured Router's Solidity ABI decoder rejecting malformed offsets.
contract CompactPermissiveOneInchRouter {
    IERC20 public immutable input;
    CompactFlowToken public immutable output;

    constructor(IERC20 input_, CompactFlowToken output_) {
        input = input_;
        output = output_;
    }

    fallback() external {
        uint256 amount = input.allowance(msg.sender, address(this));
        require(amount != 0 && input.transferFrom(msg.sender, address(this), amount));
        output.mint(msg.sender, amount);
        assembly ("memory-safe") {
            mstore(0, amount)
            mstore(32, amount)
            return(0, 64)
        }
    }
}

contract CompactOneInchReturndataBomb {
    IERC20 public immutable input;
    CompactFlowToken public immutable output;
    bool public shouldRevert;

    constructor(IERC20 input_, CompactFlowToken output_) {
        input = input_;
        output = output_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    fallback() external {
        if (shouldRevert) {
            assembly {
                revert(0, 0x10000)
            }
        }
        uint256 amount = input.allowance(msg.sender, address(this));
        require(amount != 0 && input.transferFrom(msg.sender, address(this), amount));
        output.mint(msg.sender, amount);
        assembly {
            mstore(0, amount)
            mstore(32, amount)
            return(0, 0x10000)
        }
    }
}

contract CompactAToken is ERC20, IAToken {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public immutable POOL;

    constructor(address underlying_, address pool_) ERC20("Aave USDC", "aUSDC") {
        UNDERLYING_ASSET_ADDRESS = underlying_;
        POOL = pool_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return balanceOf(user);
    }

    function mint(address receiver, uint256 amount) external {
        require(msg.sender == POOL);
        _mint(receiver, amount);
    }
}

contract CompactAaveV3Pool is IAaveV3Pool {
    IERC20 public immutable asset;
    CompactAToken public immutable aToken;
    bool public getterBroken;

    constructor(address asset_) {
        asset = IERC20(asset_);
        aToken = new CompactAToken(asset_, address(this));
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        require(asset_ == address(asset));
        require(asset.transferFrom(msg.sender, address(this), amount));
        aToken.mint(onBehalfOf, amount);
    }

    function getReserveNormalizedIncome(address asset_) external view returns (uint256) {
        require(asset_ == address(asset));
        return 1e27;
    }

    function setGetterBroken(bool value) external {
        getterBroken = value;
    }

    function getReserveData(address asset_) external view returns (ReserveData memory reserve) {
        require(!getterBroken, "broken getter");
        require(asset_ == address(asset));
        reserve.aTokenAddress = address(aToken);
    }
}

contract CompactAaveV4Spoke is IAaveV4Spoke {
    IERC20 public immutable asset;
    uint256 public immutable reserveId;
    mapping(address => bool) public active;
    mapping(address => mapping(address => bool)) public authorized;
    mapping(uint256 => mapping(address => uint256)) public shares;

    constructor(address asset_, uint256 reserveId_) {
        asset = IERC20(asset_);
        reserveId = reserveId_;
    }

    function setActive(address manager, bool value) external {
        active[manager] = value;
    }

    function setAuthorized(address user, address manager, bool value) external {
        authorized[user][manager] = value;
    }

    function getReserve(uint256 id) external view returns (Reserve memory reserve) {
        require(id == reserveId);
        reserve.underlying = address(asset);
        reserve.decimals = 6;
    }

    function getUserSuppliedShares(uint256 id, address user) external view returns (uint256) {
        return shares[id][user];
    }

    function isPositionManagerActive(address manager) external view returns (bool) {
        return active[manager];
    }

    function isPositionManager(address user, address manager) external view returns (bool) {
        return authorized[user][manager];
    }

    function supply(uint256 id, uint256 amount, address onBehalfOf)
        external
        returns (uint256 suppliedShares, uint256 suppliedAssets)
    {
        require(id == reserveId && active[msg.sender] && authorized[onBehalfOf][msg.sender]);
        require(asset.transferFrom(msg.sender, address(this), amount));
        shares[id][onBehalfOf] += amount;
        return (amount, amount);
    }
}

contract CompactPermissionManager is IPoolPermissionManager {
    mapping(address => mapping(bytes32 => uint256)) public poolBitmaps;
    mapping(address => uint256) public lenderBitmap;

    function setPoolBitmap(address manager, bytes32 functionId, uint256 bitmap) external {
        poolBitmaps[manager][functionId] = bitmap;
    }

    function setLenderBitmap(address lender, uint256 bitmap) external {
        lenderBitmap[lender] = bitmap;
    }

    function hasPermission(address manager, address lender, bytes32 functionId) external view returns (bool) {
        uint256 required = poolBitmaps[manager][functionId];
        return (lenderBitmap[lender] & required) == required;
    }
}

contract CompactSyrupRouter is ISyrupRouter {
    IERC20 public immutable assetToken;
    CompactSyrupToken public immutable syrupToken;
    CompactPermissionManager public immutable permissions;
    mapping(address => uint256) public nonces;

    constructor(address asset_, address syrupToken_, address permissions_) {
        assetToken = IERC20(asset_);
        syrupToken = CompactSyrupToken(syrupToken_);
        permissions = CompactPermissionManager(permissions_);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function pool() external view returns (address) {
        return address(syrupToken);
    }

    function poolManager() external view returns (address) {
        return address(this);
    }

    function poolPermissionManager() external view returns (address) {
        return address(permissions);
    }

    function deposit(uint256 amount, bytes32) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), amount));
        syrupToken.mint(msg.sender, amount);
        return amount;
    }

    function authorizeAndDeposit(uint256, uint256, uint8, bytes32, bytes32, uint256 amount, bytes32 data)
        external
        returns (uint256 shares)
    {
        ++nonces[msg.sender];
        return this.deposit(amount, data);
    }
}

abstract contract CompactAdapterFlowBase is Test {
    function _swapData(uint8 dex, uint256 cap, bytes memory route) internal pure returns (bytes memory) {
        return abi.encode(keccak256("XMETRO_SWAP_V2"), dex, cap, route);
    }

    bytes32 internal constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");
    bytes32 internal constant SETTLEMENT_TOPIC = keccak256("UserStrategySettled(bytes32,address,uint256,uint256)");

    CompactFlowToken internal usdc;
    CompactFlowToken internal metro;
    CompactFlowCore internal core;
    XMetroDeFiAdapter internal adapter;

    function setUp() public virtual {
        usdc = new CompactFlowToken("USD Coin", "USDC", 6);
        metro = new CompactFlowToken("Metro", "METRO", 18);
        core = new CompactFlowCore(address(this));
        bytes memory implementationInit = vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter");
        address implementation = _create(implementationInit);
        bytes memory initData =
            abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)));
        address proxy = address(new ERC1967Proxy(implementation, initData));
        core.setAdapter(proxy);
        adapter = XMetroDeFiAdapter(proxy);
    }

    function _strategyId(IXMetroDeFiAdapter.StrategyKind kind, address outputToken) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, STRATEGY_DOMAIN, kind, outputToken));
    }

    function _create(bytes memory initCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0));
    }

    function _settlementSummary(Vm.Log[] memory logs, bytes32 strategy, address[] memory users)
        internal
        view
        returns (uint256 settled, uint256 totalReward, uint256 totalOutput)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics.length != 3) continue;
            if (logs[i].topics[0] != SETTLEMENT_TOPIC) continue;
            assertLt(settled, users.length);
            (uint256 rewardAmount, uint256 amountOut) = _assertAndDecodeSettlement(logs[i], strategy, users[settled]);
            totalReward += rewardAmount;
            totalOutput += amountOut;
            ++settled;
        }
    }

    function _assertAndDecodeSettlement(Vm.Log memory entry, bytes32 strategy, address user)
        private
        pure
        returns (uint256 rewardAmount, uint256 amountOut)
    {
        assertEq(entry.topics[1], strategy);
        assertEq(entry.topics[2], bytes32(uint256(uint160(user))));
        return abi.decode(entry.data, (uint256, uint256));
    }
}

/// @dev Deliberately nonstandard ERC-20 return shapes for Adapter's low-level transfer helper.
contract CompactReturnShapeToken {
    string public constant name = "Return Shape";
    string public constant symbol = "RSHAPE";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    uint8 public mode;

    function setMode(uint8 value) external {
        mode = value;
    }

    function mint(address receiver, uint256 amount) external {
        balanceOf[receiver] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        if (mode == 0) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (mode == 1) return false;
        if (mode == 2) {
            assembly ("memory-safe") {
                mstore(0, 1)
                mstore(32, 1)
                return(0, 64)
            }
        }
        return true;
    }
}

contract CompactZeroFirstToken is CompactFlowToken {
    bool public rejectZero;

    constructor() CompactFlowToken("Zero First USDC", "ZFUSDC", 6) {}

    function setRejectZero(bool value) external {
        rejectZero = value;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (amount == 0 && rejectZero) revert("zero approval blocked");
        if (amount != 0 && allowance(msg.sender, spender) != 0) revert("must clear first");
        return super.approve(spender, amount);
    }
}

contract CompactERC20ReturnShapeTest is CompactAdapterFlowBase {
    function test_NoReturnTransferSucceedsWhileFalseOrOversizedReturnRollsBack() public {
        CompactV2Router routerV2 = new CompactV2Router();
        CompactV3Router routerV3 = new CompactV3Router();
        CompactOneInchRouter oneInch = new CompactOneInchRouter();
        CompactReturnShapeToken output = new CompactReturnShapeToken();
        adapter.setRouters(address(routerV2), address(routerV3), address(oneInch));
        bytes32 strategy = adapter.setSwapTokenConfig(address(output), true, true);
        core.setPaused(false);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);

        for (uint8 mode; mode < 4; ++mode) {
            output.setMode(mode);
            address account = makeAddr(string.concat("return-shape-", vm.toString(mode)));
            uint256 amount = 10e6;
            usdc.mint(address(core), amount);
            IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
                strategyId: strategy,
                account: account,
                amountIn: amount,
                minAmountOut: amount,
                deadline: block.timestamp + 1,
                executionData: _swapData(0, amount, abi.encode(path))
            });
            uint256 beforeCore = usdc.balanceOf(address(core));
            if (mode == 1 || mode == 2) {
                vm.expectRevert(XMetroDeFiAdapter.AccountingFailure.selector);
                core.runManual(usdc, request);
                assertEq(usdc.balanceOf(address(core)), beforeCore);
                assertEq(output.balanceOf(account), 0);
            } else {
                core.runManual(usdc, request);
                assertEq(output.balanceOf(account), amount);
                assertEq(usdc.balanceOf(address(core)), beforeCore - amount);
            }
            assertEq(output.balanceOf(address(adapter)), 0);
            assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
        }
    }

    function test_ZeroFirstApprovalFallbackAndFailedClearAreAtomic() public {
        CompactZeroFirstToken input = new CompactZeroFirstToken();
        CompactFlowToken output = new CompactFlowToken("Approval Output", "APOUT", 6);
        CompactFlowCore approvalCore = new CompactFlowCore(address(this));
        address implementation = _create(vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter"));
        address proxy = address(
            new ERC1967Proxy(
                implementation,
                abi.encodeCall(XMetroDeFiAdapter.initialize, (address(approvalCore), address(input), address(metro)))
            )
        );
        approvalCore.setAdapter(proxy);
        XMetroDeFiAdapter approvalAdapter = XMetroDeFiAdapter(proxy);
        CompactV2Router approvalRouter = new CompactV2Router();
        approvalAdapter.setRouters(
            address(approvalRouter), address(new CompactV3Router()), address(new CompactOneInchRouter())
        );
        bytes32 strategy = approvalAdapter.setSwapTokenConfig(address(output), true, true);
        approvalCore.setPaused(false);
        address account = makeAddr("zero-first-user");
        address[] memory path = new address[](2);
        path[0] = address(input);
        path[1] = address(output);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: account,
            amountIn: 10e6,
            minAmountOut: 10e6,
            deadline: block.timestamp + 1,
            executionData: _swapData(0, 10e6, abi.encode(path))
        });
        input.mint(address(approvalCore), 10e6);
        vm.prank(proxy);
        input.approve(address(approvalRouter), 1);
        input.setRejectZero(true);
        vm.expectRevert(XMetroDeFiAdapter.AccountingFailure.selector);
        approvalCore.runManual(input, request);
        assertEq(input.balanceOf(address(approvalCore)), 10e6);
        assertEq(output.balanceOf(account), 0);
        assertEq(input.allowance(proxy, address(approvalRouter)), 1);

        input.setRejectZero(false);
        approvalCore.runManual(input, request);
        assertEq(input.balanceOf(address(approvalCore)), 0);
        assertEq(output.balanceOf(account), 10e6);
        assertEq(input.allowance(proxy, address(approvalRouter)), 0);
    }
}

contract CompactSwapFlowTest is CompactAdapterFlowBase {
    CompactV2Router internal routerV2;
    CompactV3Router internal routerV3;
    CompactOneInchRouter internal oneInch;
    CompactOneInchExecutor internal oneInchExecutor;
    CompactFlowToken internal output;
    bytes32 internal strategy;

    function setUp() public override {
        super.setUp();
        routerV2 = new CompactV2Router();
        routerV3 = new CompactV3Router();
        oneInch = new CompactOneInchRouter();
        oneInchExecutor = new CompactOneInchExecutor();
        output = new CompactFlowToken("Output", "OUT", 6);
        adapter.setRouters(address(routerV2), address(routerV3), address(oneInch));
        strategy = adapter.setSwapTokenConfig(address(output), true, true);
        core.setPaused(false);
    }

    function test_SwapRejectsInvalidEnvelopeBeforeAnyRouterCall() public {
        uint256 amount = 100e6;
        usdc.mint(address(core), amount);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        vm.expectCall(
            address(routerV2), abi.encodeWithSelector(CompactV2Router.swapExactTokensForTokens.selector), uint64(0)
        );
        vm.expectCall(address(routerV3), abi.encodeWithSelector(CompactV3Router.exactInput.selector), uint64(0));
        vm.expectCall(address(oneInch), abi.encodeWithSelector(CompactOneInchRouter.swap.selector), uint64(0));
        for (uint8 dex; dex < 3; ++dex) {
            bytes memory route = dex == 0
                ? abi.encode(path)
                : dex == 1
                    ? abi.encodePacked(address(usdc), uint24(500), address(output))
                    : _oneInchCall(address(adapter), amount, amount, 0);
            IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
                strategyId: strategy,
                account: makeAddr("capped-user"),
                amountIn: amount,
                minAmountOut: amount,
                deadline: block.timestamp + 1,
                executionData: bytes("")
            });
            for (uint8 invalid; invalid < 6; ++invalid) {
                if (invalid == 0) {
                    request.executionData = _swapData(dex, 0, route);
                } else if (invalid == 1) {
                    request.executionData = _swapData(dex, amount - 1, route);
                } else if (invalid == 2) {
                    request.executionData = abi.encode(bytes32(0), dex, amount, route);
                } else if (invalid == 3) {
                    request.executionData = abi.encode(dex, route);
                } else if (invalid == 4) {
                    request.executionData = hex"01";
                } else {
                    request.executionData = _swapData(dex, amount, route);
                    bytes memory data = request.executionData;
                    assembly ("memory-safe") { mstore(add(data, 128), not(0)) }
                }
                if (invalid < 3) vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
                else vm.expectRevert();
                core.runManual(usdc, request);
                assertEq(usdc.balanceOf(address(core)), amount);
                assertEq(usdc.balanceOf(address(adapter)), 0);
                assertEq(output.balanceOf(request.account), 0);
                assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
                assertEq(usdc.allowance(address(adapter), address(routerV3)), 0);
                assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
            }
        }
    }

    function test_V2AndFixedOneInchFundEnvelopes() public {
        address userV2 = makeAddr("user-v2");
        uint256 amount = 100e6;
        usdc.mint(address(core), amount);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: userV2,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(0, amount, abi.encode(path))
        });
        IXMetroDeFiAdapter.ExecutionResult memory result = core.runManual(usdc, request);
        assertEq(result.amountOut, amount);
        assertEq(output.balanceOf(userV2), amount);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);

        address userOneInch = makeAddr("user-one-inch");
        usdc.mint(address(core), amount);
        request.account = userOneInch;
        request.executionData = _swapData(2, amount, _oneInchCall(address(adapter), amount, amount, 0));
        result = core.runManual(usdc, request);
        assertEq(result.amountOut, amount);
        assertEq(output.balanceOf(userOneInch), amount);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_V3SingleAndMultiHopFundEnvelopes() public {
        address user = makeAddr("user-v3");
        uint256 amount = 100e6;
        bytes memory singleHop = abi.encodePacked(address(usdc), uint24(500), address(output));
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: user,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(1, amount, singleHop)
        });
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ExecutionResult memory result = core.runManual(usdc, request);
        assertEq(result.amountOut, amount);
        assertEq(output.balanceOf(user), amount);
        assertEq(usdc.allowance(address(adapter), address(routerV3)), 0);

        CompactFlowToken middle = new CompactFlowToken("Middle", "MID", 18);
        bytes memory multiHop =
            abi.encodePacked(address(usdc), uint24(500), address(middle), uint24(3_000), address(output));
        request.executionData = _swapData(1, amount, multiHop);
        usdc.mint(address(core), amount);
        result = core.runManual(usdc, request);
        assertEq(result.amountOut, amount);
        assertEq(output.balanceOf(user), amount * 2);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(routerV3)), 0);
    }

    function test_UnknownDexAndMalformedPathsAreTypedAndAtomic() public {
        uint256 amount = 100e6;
        address user = makeAddr("invalid-route-user");
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: user,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(9, amount, bytes("unknown"))
        });
        usdc.mint(address(core), amount);
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        assertEq(usdc.balanceOf(address(core)), amount);

        address[] memory wrongV2 = new address[](2);
        wrongV2[0] = address(output);
        wrongV2[1] = address(usdc);
        request.executionData = _swapData(0, amount, abi.encode(wrongV2));
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        assertEq(usdc.balanceOf(address(core)), amount);

        request.executionData = _swapData(1, amount, abi.encodePacked(address(usdc), uint24(500), address(usdc)));
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        assertEq(usdc.balanceOf(address(core)), amount);
        assertEq(output.balanceOf(user), 0);
    }

    function test_ReentrantRouterIsRejectedBeforeNestedRequestValidation() public {
        core.setPaused(true);
        CompactReentrantV2Router reentrant = new CompactReentrantV2Router(core);
        adapter.setRouters(address(reentrant), address(routerV3), address(oneInch));
        core.setPaused(false);

        uint256 amount = 100e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: makeAddr("reentry-user"),
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(0, amount, abi.encode(path))
        });
        usdc.mint(address(core), amount);
        core.runManual(usdc, request);
        assertEq(reentrant.observedRevert(), XMetroDeFiAdapter.AccessStateFailure.selector);
        assertEq(usdc.allowance(address(adapter), address(reentrant)), 0);
    }

    function test_V2BatchEmitsOneVerifiedSettlementPerUser() public {
        address[] memory users = new address[](2);
        users[0] = makeAddr("batch-swap-a");
        users[1] = makeAddr("batch-swap-b");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 40e6;
        amounts[1] = 60e6;
        uint256 total = amounts[0] + amounts[1];
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: total,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1,
            executionData: _swapData(0, total, abi.encode(path))
        });
        usdc.mint(address(core), total);
        vm.recordLogs();
        core.runBatch(usdc, batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 settled, uint256 rewardTotal, uint256 outputTotal) = _settlementSummary(logs, strategy, users);
        assertEq(settled, users.length);
        assertEq(rewardTotal, total);
        assertEq(outputTotal, total);
        assertEq(output.balanceOf(users[0]), amounts[0]);
        assertEq(output.balanceOf(users[1]), amounts[1]);
    }

    function test_AccessAndConfigurationErrorsAreTyped() public {
        IXMetroDeFiAdapter.ManualExecution memory request;
        vm.expectRevert(XMetroDeFiAdapter.AccessStateFailure.selector);
        adapter.execute(request);

        core.setPaused(true);
        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setRouters(address(0), address(routerV3), address(oneInch));
    }

    function test_SlippageAndAccountingErrorsAreTyped() public {
        uint256 amount = 100e6;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: makeAddr("typed-errors-user"),
            amountIn: amount,
            minAmountOut: amount + 1,
            deadline: block.timestamp + 1,
            executionData: _swapData(0, amount, abi.encode(path))
        });
        usdc.mint(address(core), amount);
        vm.expectRevert(XMetroDeFiAdapter.SlippageFailure.selector);
        core.runManual(usdc, request);

        core.setPaused(true);
        CompactMisreportingV2Router badRouter = new CompactMisreportingV2Router();
        adapter.setRouters(address(badRouter), address(routerV3), address(oneInch));
        core.setPaused(false);
        request.minAmountOut = amount;
        usdc.mint(address(core), amount);
        vm.expectRevert(XMetroDeFiAdapter.AccountingFailure.selector);
        core.runManual(usdc, request);
    }

    function test_UnderfundedCoreRequestUsesTypedAccountingFailureInsteadOfPanic() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: makeAddr("underfunded-recipient"),
            amountIn: 1e6,
            minAmountOut: 1,
            deadline: block.timestamp + 1 hours,
            executionData: _swapData(0, 1e6, abi.encode(path))
        });
        vm.expectRevert(XMetroDeFiAdapter.AccountingFailure.selector);
        core.runUnfunded(request);
    }

    function test_OneInchRejectsWrongCriticalFieldsAndForbiddenFlags() public {
        uint256 amount = 100e6;
        address user = makeAddr("one-inch-validation-user");
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: user,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: bytes("")
        });

        _assertRejectedOneInch(
            request,
            _oneInchCallWith(
                address(oneInchExecutor),
                address(output),
                address(output),
                address(oneInchExecutor),
                address(adapter),
                amount,
                amount,
                0,
                hex"01"
            ),
            amount,
            user,
            address(oneInch)
        );
        _assertRejectedOneInch(
            request,
            _oneInchCallWith(
                address(oneInchExecutor),
                address(usdc),
                address(usdc),
                address(oneInchExecutor),
                address(adapter),
                amount,
                amount,
                0,
                hex"01"
            ),
            amount,
            user,
            address(oneInch)
        );
        _assertRejectedOneInch(
            request, _oneInchCall(makeAddr("wrong-receiver"), amount, amount, 0), amount, user, address(oneInch)
        );
        _assertRejectedOneInch(
            request, _oneInchCall(address(adapter), amount - 1, amount, 0), amount, user, address(oneInch)
        );
        _assertRejectedOneInch(
            request, _oneInchCall(address(adapter), amount, amount - 1, 0), amount, user, address(oneInch)
        );
        _assertRejectedOneInch(
            request, _oneInchCall(address(adapter), amount, amount, 1), amount, user, address(oneInch)
        );
        _assertRejectedOneInch(
            request, _oneInchCall(address(adapter), amount, amount, 2), amount, user, address(oneInch)
        );
        _assertRejectedOneInch(
            request, _oneInchCall(address(adapter), amount, amount, 4), amount, user, address(oneInch)
        );
        _assertRejectedOneInch(
            request,
            _oneInchCallWith(
                makeAddr("eoa-executor"),
                address(usdc),
                address(output),
                address(oneInchExecutor),
                address(adapter),
                amount,
                amount,
                0,
                hex"01"
            ),
            amount,
            user,
            address(oneInch)
        );
        _assertRejectedOneInch(
            request,
            _oneInchCallWith(
                address(oneInchExecutor),
                address(usdc),
                address(output),
                makeAddr("eoa-src-receiver"),
                address(adapter),
                amount,
                amount,
                0,
                hex"01"
            ),
            amount,
            user,
            address(oneInch)
        );
        _assertRejectedOneInch(
            request,
            _oneInchCallWith(
                address(oneInchExecutor),
                address(usdc),
                address(output),
                address(oneInchExecutor),
                address(adapter),
                amount,
                amount,
                0,
                bytes("")
            ),
            amount,
            user,
            address(oneInch)
        );
    }

    function test_OneInchMalformedSelectorOffsetAndLengthAreAtomic() public {
        CompactPermissiveOneInchRouter permissive = new CompactPermissiveOneInchRouter(usdc, output);
        core.setPaused(true);
        adapter.setRouters(address(routerV2), address(routerV3), address(permissive));
        core.setPaused(false);

        uint256 amount = 100e6;
        address user = makeAddr("malformed-one-inch-user");
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: user,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: bytes("")
        });

        _assertRejectedOneInch(request, hex"deadbeef", amount, user, address(permissive));
        _assertMalformedOneInch(request, hex"07ed2379", amount, user, address(permissive));

        bytes memory route = _oneInchCall(address(adapter), amount, amount, 0);
        _writeWord(route, 260, type(uint256).max);
        _assertMalformedOneInch(request, route, amount, user, address(permissive));

        route = _oneInchCall(address(adapter), amount, amount, 0);
        uint256 dataStart = 4 + _readWord(route, 260);
        _writeWord(route, dataStart, type(uint256).max);
        _assertMalformedOneInch(request, route, amount, user, address(permissive));
    }

    function test_OneInchAccountingUsesActualBalancesAndExactSpend() public {
        uint256 amount = 100e6;
        address user = makeAddr("one-inch-accounting-user");
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: user,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(2, amount, _oneInchCall(address(adapter), amount, amount, 0))
        });

        usdc.mint(address(core), amount);
        oneInch.setBehavior(5_000, 10_000, 0, address(0));
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);

        oneInch.setBehavior(10_001, 10_000, 0, address(0));
        vm.expectRevert();
        core.runManual(usdc, request);

        oneInch.setBehavior(10_000, 9_000, 0, address(0));
        vm.expectRevert(XMetroDeFiAdapter.SlippageFailure.selector);
        core.runManual(usdc, request);

        oneInch.setBehavior(10_000, 10_000, 0, makeAddr("wrong-output-receiver"));
        vm.expectRevert(XMetroDeFiAdapter.AccountingFailure.selector);
        core.runManual(usdc, request);

        oneInch.setBehavior(10_000, 10_000, 1, address(0));
        vm.expectRevert(XMetroDeFiAdapter.AccountingFailure.selector);
        core.runManual(usdc, request);

        assertEq(usdc.balanceOf(address(core)), amount);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(output.balanceOf(user), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_OneInchBatchDistributesActualOutputProRata() public {
        address[] memory users = new address[](2);
        users[0] = makeAddr("one-inch-batch-a");
        users[1] = makeAddr("one-inch-batch-b");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 40e6;
        amounts[1] = 60e6;
        uint256 total = amounts[0] + amounts[1];
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: total,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1,
            executionData: _swapData(2, total, _oneInchCall(address(adapter), total, total, 0))
        });
        usdc.mint(address(core), total);
        core.runBatch(usdc, batch);
        assertEq(output.balanceOf(users[0]), amounts[0]);
        assertEq(output.balanceOf(users[1]), amounts[1]);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_OneInchLargeReturnAndRevertDataAreBoundedAndAtomic() public {
        CompactOneInchReturndataBomb bomb = new CompactOneInchReturndataBomb(usdc, output);
        core.setPaused(true);
        adapter.setRouters(address(routerV2), address(routerV3), address(bomb));
        core.setPaused(false);

        uint256 amount = 100e6;
        address user = makeAddr("one-inch-bomb-user");
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: user,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(2, amount, _oneInchCall(address(adapter), amount, amount, 0))
        });

        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        _assertOneInchAtomic(amount, user, address(bomb));

        bomb.setShouldRevert(true);
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        _assertOneInchAtomic(amount, user, address(bomb));
    }

    function _assertRejectedOneInch(
        IXMetroDeFiAdapter.ManualExecution memory request,
        bytes memory route,
        uint256 amount,
        address user,
        address router
    ) internal {
        request.executionData = _swapData(2, request.amountIn, route);
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        _assertOneInchAtomic(amount, user, router);
    }

    function _assertMalformedOneInch(
        IXMetroDeFiAdapter.ManualExecution memory request,
        bytes memory route,
        uint256 amount,
        address user,
        address router
    ) internal {
        request.executionData = _swapData(2, request.amountIn, route);
        vm.expectRevert();
        core.runManual(usdc, request);
        _assertOneInchAtomic(amount, user, router);
    }

    function _assertOneInchAtomic(uint256 amount, address user, address router) internal view {
        assertEq(usdc.balanceOf(address(core)), amount);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), router), 0);
        assertEq(output.balanceOf(user), 0);
    }

    function _readWord(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        require(offset <= data.length && data.length - offset >= 32);
        assembly ("memory-safe") {
            value := mload(add(add(data, 32), offset))
        }
    }

    function _writeWord(bytes memory data, uint256 offset, uint256 value) internal pure {
        require(offset <= data.length && data.length - offset >= 32);
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), value)
        }
    }

    function _oneInchCall(address receiver, uint256 amount, uint256 minimum, uint256 flags)
        internal
        view
        returns (bytes memory)
    {
        return _oneInchCallWith(
            address(oneInchExecutor),
            address(usdc),
            address(output),
            address(oneInchExecutor),
            receiver,
            amount,
            minimum,
            flags,
            hex"01"
        );
    }

    function _oneInchCallWith(
        address executor,
        address input,
        address destination,
        address sourceReceiver,
        address destinationReceiver,
        uint256 amount,
        uint256 minimum,
        uint256 flags,
        bytes memory executorData
    ) internal pure returns (bytes memory) {
        IOneInchAggregationRouterV6.SwapDescription memory description =
            IOneInchAggregationRouterV6.SwapDescription({
                srcToken: IERC20(input),
                dstToken: IERC20(destination),
                srcReceiver: payable(sourceReceiver),
                dstReceiver: payable(destinationReceiver),
                amount: amount,
                minReturnAmount: minimum,
                flags: flags
            });
        return abi.encodeWithSelector(IOneInchAggregationRouterV6.swap.selector, executor, description, executorData);
    }
}

contract CompactAaveFlowTest is CompactAdapterFlowBase {
    function test_AaveV3ManualAndBatchExactScaledDistribution() public {
        CompactAaveV3Pool pool = new CompactAaveV3Pool(address(usdc));
        bytes32 strategy = adapter.setAaveV3Config(address(pool), address(pool.aToken()), 7, true, true);
        core.setPaused(false);

        address manualUser = makeAddr("manual-v3");
        uint256 amount = 100e6;
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory manual = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: manualUser,
            amountIn: amount,
            minAmountOut: amount,
            deadline: 0,
            executionData: bytes("")
        });
        core.runManual(usdc, manual);
        assertEq(pool.aToken().scaledBalanceOf(manualUser), amount);

        address[] memory users = new address[](2);
        users[0] = makeAddr("batch-v3-a");
        users[1] = makeAddr("batch-v3-b");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 40e6;
        amounts[1] = 60e6;
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: amount,
            minUserAmountsOut: new uint256[](0),
            deadline: 0,
            executionData: bytes("")
        });
        vm.recordLogs();
        core.runBatch(usdc, batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 settled, uint256 rewardTotal, uint256 outputTotal) = _settlementSummary(logs, strategy, users);
        assertEq(settled, users.length);
        assertEq(rewardTotal, amount);
        assertEq(outputTotal, amount);
        assertEq(pool.aToken().scaledBalanceOf(users[0]), amounts[0]);
        assertEq(pool.aToken().scaledBalanceOf(users[1]), amounts[1]);
        assertEq(pool.aToken().scaledBalanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(pool)), 0);
    }

    function test_AaveV4PerUserSupplyAndMinima() public {
        uint256 reserveId = 9;
        CompactAaveV4Spoke spoke = new CompactAaveV4Spoke(address(usdc), reserveId);
        MockAaveV4Giver giver = new MockAaveV4Giver(address(spoke));
        spoke.setActive(address(giver), true);
        adapter.setAaveV4Config(address(spoke), address(giver), reserveId, true, true);
        bytes32 strategy = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        address[] memory users = new address[](2);
        users[0] = makeAddr("v4-a");
        users[1] = makeAddr("v4-b");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 40e6;
        amounts[1] = 60e6;
        uint256[] memory minima = new uint256[](2);
        minima[0] = amounts[0];
        minima[1] = amounts[1];
        spoke.setActive(address(giver), true);
        spoke.setAuthorized(users[0], address(giver), true);
        spoke.setAuthorized(users[1], address(giver), true);
        core.setPaused(false);
        usdc.mint(address(core), 100e6);
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: 100e6,
            minUserAmountsOut: minima,
            deadline: 0,
            executionData: bytes("")
        });
        vm.recordLogs();
        core.runBatch(usdc, batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 settled, uint256 rewardTotal, uint256 outputTotal) = _settlementSummary(logs, strategy, users);
        assertEq(settled, users.length);
        assertEq(rewardTotal, 100e6);
        assertEq(outputTotal, 100e6);
        assertEq(spoke.getUserSuppliedShares(reserveId, users[0]), amounts[0]);
        assertEq(spoke.getUserSuppliedShares(reserveId, users[1]), amounts[1]);
        assertEq(usdc.allowance(address(adapter), address(spoke)), 0);
        assertEq(usdc.allowance(address(adapter), address(giver)), 0);
    }

    function test_AaveV4AuthorizationErrorIsTyped() public {
        uint256 reserveId = 10;
        CompactAaveV4Spoke spoke = new CompactAaveV4Spoke(address(usdc), reserveId);
        MockAaveV4Giver giver = new MockAaveV4Giver(address(spoke));
        spoke.setActive(address(giver), true);
        adapter.setAaveV4Config(address(spoke), address(giver), reserveId, true, true);
        address[] memory users = new address[](1);
        users[0] = makeAddr("v4-unauthorized");
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        uint256[] memory minima = new uint256[](1);
        minima[0] = amounts[0];
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)),
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: amounts[0],
            minUserAmountsOut: minima,
            deadline: 0,
            executionData: bytes("")
        });
        core.setPaused(false);
        usdc.mint(address(core), amounts[0]);
        vm.expectRevert(XMetroDeFiAdapter.AaveV4AuthorizationFailure.selector);
        core.runBatch(usdc, batch);
    }

    function test_DisableBrokenAaveV3NeverCallsOldProtocolAndRevisionAdvances() public {
        CompactAaveV3Pool pool = new CompactAaveV3Pool(address(usdc));
        address aToken = address(pool.aToken());
        bytes32 strategy = adapter.setAaveV3Config(address(pool), aToken, 7, true, true);
        IXMetroDeFiAdapter.StrategyInfo memory beforeInfo = adapter.strategyInfo(strategy);
        assertTrue(beforeInfo.enabled);
        assertTrue(beforeInfo.autoEnabled);

        pool.setGetterBroken(true);
        bytes32 disabledId = adapter.setAaveV3Config(address(0), address(0), 0, false, false);
        assertEq(disabledId, strategy);
        IXMetroDeFiAdapter.StrategyInfo memory disabled = adapter.strategyInfo(strategy);
        assertFalse(disabled.enabled);
        assertFalse(disabled.autoEnabled);
        assertEq(disabled.strategyRevision, beforeInfo.strategyRevision + 1);

        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setAaveV3Config(address(pool), aToken, 7, true, true);
        IXMetroDeFiAdapter.StrategyInfo memory afterFailure = adapter.strategyInfo(strategy);
        assertEq(afterFailure.strategyRevision, disabled.strategyRevision);
        assertFalse(afterFailure.enabled);
    }
}

contract CompactAdapterConfigurationSecurityTest is CompactAdapterFlowBase {
    function test_AllConfigurationSettersSucceedWhileCoreIsUnpaused() public {
        CompactV2Router v2 = new CompactV2Router();
        CompactV3Router v3 = new CompactV3Router();
        CompactOneInchRouter oneInch = new CompactOneInchRouter();
        CompactFlowToken output = new CompactFlowToken("Online Output", "ONLINE", 6);
        CompactAaveV3Pool pool = new CompactAaveV3Pool(address(usdc));
        CompactAaveV4Spoke spoke = new CompactAaveV4Spoke(address(usdc), 17);
        MockAaveV4Giver giver = new MockAaveV4Giver(address(spoke));
        spoke.setActive(address(giver), true);
        CompactSyrupToken syrup = new CompactSyrupToken(address(usdc));
        CompactPermissionManager permissions = new CompactPermissionManager();
        CompactSyrupRouter maple = new CompactSyrupRouter(address(usdc), address(syrup), address(permissions));

        core.setPaused(false);
        adapter.setRouters(address(v2), address(v3), address(oneInch));
        adapter.setSwapMetroConfig(true, true);
        bytes32 swapId = adapter.setSwapTokenConfig(address(output), true, true);
        bytes32 aaveV3Id = adapter.setAaveV3Config(address(pool), address(pool.aToken()), 7, true, true);
        adapter.setAaveV4Config(address(spoke), address(giver), 17, true, true);
        bytes32 mapleId = adapter.setMapleConfig(address(maple), bytes32("0:xMETRO"), true, true);

        assertFalse(core.paused());
        assertTrue(adapter.strategyInfo(swapId).enabled);
        assertTrue(adapter.strategyInfo(aaveV3Id).enabled);
        assertTrue(adapter.strategyInfo(_strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0))).enabled);
        assertTrue(adapter.strategyInfo(mapleId).enabled);

        vm.prank(makeAddr("not-owner"));
        vm.expectRevert(XMetroDeFiAdapter.AccessStateFailure.selector);
        adapter.setSwapMetroConfig(false, false);
    }

    function test_RevisionsAreMonotonicAndIdenticalConfigurationIsRejected() public {
        CompactV2Router v2 = new CompactV2Router();
        CompactV3Router v3 = new CompactV3Router();
        CompactOneInchRouter oneInch = new CompactOneInchRouter();
        CompactFlowToken output = new CompactFlowToken("Revision Output", "REV", 6);

        core.setPaused(false);
        adapter.setRouters(address(v2), address(v3), address(oneInch));
        bytes32 strategy = adapter.setSwapTokenConfig(address(output), true, true);
        IXMetroDeFiAdapter.StrategyInfo memory first = adapter.strategyInfo(strategy);
        assertEq(first.logicEpoch, 1);
        assertEq(first.domainRevision, 2);
        assertEq(first.strategyRevision, 1);

        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setSwapTokenConfig(address(output), true, true);

        adapter.setSwapTokenConfig(address(output), false, false);
        IXMetroDeFiAdapter.StrategyInfo memory disabled = adapter.strategyInfo(strategy);
        assertEq(disabled.strategyRevision, 2);
        assertFalse(disabled.enabled);
        adapter.setSwapTokenConfig(address(output), true, true);
        IXMetroDeFiAdapter.StrategyInfo memory reenabled = adapter.strategyInfo(strategy);
        assertEq(reenabled.strategyRevision, 3);

        CompactV2Router nextV2 = new CompactV2Router();
        adapter.setRouters(address(nextV2), address(v3), address(oneInch));
        IXMetroDeFiAdapter.StrategyInfo memory afterRouter = adapter.strategyInfo(strategy);
        assertEq(afterRouter.domainRevision, 3);
        assertEq(afterRouter.strategyRevision, 3);
    }

    function test_ReplacedProxyCannotConfigureButPausedOwnerCanRescueIt() public {
        CompactFlowToken donation = new CompactFlowToken("Donation", "DON", 6);
        donation.mint(address(adapter), 7e6);

        bytes memory implementationInit = vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter");
        address implementation = _create(implementationInit);
        bytes memory initData =
            abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)));
        address replacement = address(new ERC1967Proxy(implementation, initData));
        core.setAdapter(replacement);

        vm.expectRevert(XMetroDeFiAdapter.AccessStateFailure.selector);
        adapter.setSwapMetroConfig(true, true);

        address recipient = makeAddr("old-proxy-rescue-recipient");
        adapter.rescueERC20(address(donation), recipient, 7e6);
        assertEq(donation.balanceOf(recipient), 7e6);

        core.setPaused(false);
        donation.mint(address(adapter), 1e6);
        vm.expectRevert(XMetroDeFiAdapter.AccessStateFailure.selector);
        adapter.rescueERC20(address(donation), recipient, 1e6);
        assertEq(donation.balanceOf(address(adapter)), 1e6);
    }

    function test_ImplementationIsUninitializedAndCannotBeInitializedDirectly() public {
        bytes memory implementationInit = vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter");
        address implementation = _create(implementationInit);
        XMetroDeFiAdapter direct = XMetroDeFiAdapter(implementation);
        assertEq(direct.xMETRO(), address(0));
        assertEq(direct.USDC(), address(0));
        assertEq(direct.METRO(), address(0));
        assertEq(direct.logicEpoch(), 0);
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        direct.initialize(address(core), address(usdc), address(metro));
    }
}

contract CompactMapleFlowTest is CompactAdapterFlowBase {
    function test_MapleOneDepositAndProportionalDistribution() public {
        CompactSyrupToken syrup = new CompactSyrupToken(address(usdc));
        CompactPermissionManager permissions = new CompactPermissionManager();
        CompactSyrupRouter router = new CompactSyrupRouter(address(usdc), address(syrup), address(permissions));
        bytes32 depositPermission = bytes32("P:deposit");
        permissions.setPoolBitmap(address(router), depositPermission, 1);
        permissions.setLenderBitmap(address(router), 1);
        permissions.setLenderBitmap(address(adapter), 1);
        bytes32 strategy = adapter.setMapleConfig(address(router), bytes32(0), true, true);
        core.setPaused(false);

        address[] memory users = new address[](2);
        users[0] = makeAddr("maple-a");
        users[1] = makeAddr("maple-b");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 40e6;
        amounts[1] = 60e6;
        usdc.mint(address(core), 100e6);
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: 100e6,
            minUserAmountsOut: new uint256[](0),
            deadline: 0,
            executionData: bytes("")
        });
        vm.recordLogs();
        core.runBatch(usdc, batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 settled, uint256 rewardTotal, uint256 outputTotal) = _settlementSummary(logs, strategy, users);
        assertEq(settled, users.length);
        assertEq(rewardTotal, 100e6);
        assertEq(outputTotal, 100e6);
        assertEq(syrup.balanceOf(users[0]), amounts[0]);
        assertEq(syrup.balanceOf(users[1]), amounts[1]);
        assertEq(syrup.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }

    function test_MapleAuthorizationErrorIsTyped() public {
        CompactSyrupToken syrup = new CompactSyrupToken(address(usdc));
        CompactPermissionManager permissions = new CompactPermissionManager();
        CompactSyrupRouter router = new CompactSyrupRouter(address(usdc), address(syrup), address(permissions));
        bytes32 depositPermission = bytes32("P:deposit");
        permissions.setPoolBitmap(address(router), depositPermission, 1);
        permissions.setLenderBitmap(address(router), 1);
        bytes32 strategy = adapter.setMapleConfig(address(router), bytes32(0), true, true);
        address[] memory users = new address[](1);
        users[0] = makeAddr("maple-unauthorized");
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: amounts[0],
            minUserAmountsOut: new uint256[](0),
            deadline: 0,
            executionData: bytes("")
        });
        core.setPaused(false);
        usdc.mint(address(core), amounts[0]);
        vm.expectRevert(XMetroDeFiAdapter.MapleAuthorizationFailure.selector);
        core.runBatch(usdc, batch);
    }
}
