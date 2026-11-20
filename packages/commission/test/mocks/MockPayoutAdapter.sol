// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICommissionPayoutAdapter} from "../../contracts/interfaces/ICommissionPayoutAdapter.sol";

contract MockToken is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FakeXMetro is ERC20 {
    IERC20 public immutable metro;
    bool public paused;

    constructor(IERC20 metro_) ERC20("xMETRO", "xMETRO") {
        metro = metro_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function stake(uint256 amount) external returns (uint256) {
        require(!paused, "xMETRO paused");
        metro.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
        return amount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!paused, "xMETRO paused");
        return super.transfer(to, amount);
    }
}

contract MockPayoutAdapter is ICommissionPayoutAdapter {
    address constant SWAP_SINK = address(0xdead);

    IERC20 public immutable usdc;
    uint256 public rateNum = 1e12;
    uint256 public rateDen = 1;
    mapping(bytes32 => StrategyInfo) internal _strategies;

    uint256 public calls;
    address[] internal _lastAccounts;
    uint256[] internal _lastAmounts;

    address public reenterTarget;
    bytes public reenterData;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setStrategy(bytes32 id, StrategyKind kind, address outputToken) external {
        _strategies[id] = StrategyInfo(kind, true, true, 1, 1, 1, outputToken);
    }

    function setRate(uint256 num, uint256 den) external {
        rateNum = num;
        rateDen = den;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function lastRequest() external view returns (address[] memory, uint256[] memory) {
        return (_lastAccounts, _lastAmounts);
    }

    function strategyInfo(bytes32 id) external view returns (StrategyInfo memory) {
        return _strategies[id];
    }

    function execute(ManualExecution calldata request) external returns (ExecutionResult memory result) {
        address[] memory accounts = new address[](1);
        accounts[0] = request.account;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = request.amountIn;
        return _swap(request.strategyId, accounts, amounts, request.minAmountOut);
    }

    function executeBatch(BatchExecution calldata request) external returns (ExecutionResult memory result) {
        return _swap(request.strategyId, request.accounts, request.amountsIn, request.minTotalAmountOut);
    }

    function _swap(bytes32 id, address[] memory accounts, uint256[] memory amounts, uint256 minOut)
        internal
        returns (ExecutionResult memory)
    {
        calls++;
        _lastAccounts = accounts;
        _lastAmounts = amounts;

        uint256 totalIn;
        uint256 largest;
        for (uint256 i; i < amounts.length; ++i) {
            totalIn += amounts[i];
            if (amounts[i] > amounts[largest]) largest = i;
        }
        usdc.transfer(SWAP_SINK, totalIn);

        StrategyInfo memory info = _strategies[id];
        MockToken output = MockToken(info.outputToken);
        uint256 amountOut = totalIn * rateNum / rateDen;
        require(amountOut >= minOut, "Slippage");

        if (info.kind == StrategyKind.SwapMetro) {
            output.mint(msg.sender, amountOut);
        } else {
            uint256 distributed;
            for (uint256 i; i < accounts.length; ++i) {
                if (i == largest) continue;
                uint256 share = amountOut * amounts[i] / totalIn;
                distributed += share;
                output.mint(accounts[i], share);
            }
            output.mint(accounts[largest], amountOut - distributed);
        }

        if (reenterTarget != address(0)) {
            (bool ok, bytes memory err) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(err, 32), mload(err))
                }
            }
        }
        return ExecutionResult(info.outputToken, totalIn, amountOut);
    }
}
