// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract MockPoolManager is IPoolManager {
    struct Pool {
        bool initialized;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    mapping(bytes32 => Pool) public pools;
    mapping(address => mapping(Currency => uint256)) public balances;

    // --------------------
    // Pool management
    // --------------------
    function initialize(
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external override returns (int24) {
        bytes32 poolId = _toId(key);
        require(!pools[poolId].initialized, "Pool already initialized");

        pools[poolId] = Pool({
            initialized: true,
            sqrtPriceX96: sqrtPriceX96,
            tick: 0
        });
        return pools[poolId].tick;
    }

    function _toId(PoolKey memory key) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    key.currency0,
                    key.currency1,
                    key.fee,
                    key.tickSpacing,
                    key.hooks
                )
            );
    }

    function getSlot0(
        bytes32
    )
        external
        view
        returns (uint160, int24, uint24, uint24, uint24, uint8, bool)
    {
        return (0, 0, 0, 0, 0, 0, false);
    }

    function getLiquidity(bytes32) external view returns (uint128) {
        return 0;
    }

    // --------------------
    // Core Pool Operations
    // --------------------
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata hookData
    )
        external
        pure
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        return (BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external pure override returns (BalanceDelta swapDelta) {
        return BalanceDeltaLibrary.ZERO_DELTA;
    }

    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external pure override returns (BalanceDelta) {
        return BalanceDeltaLibrary.ZERO_DELTA;
    }

    function sync(Currency currency) external pure override {}

    function settleFor(
        address recipient
    ) external payable override returns (uint256) {
        return msg.value;
    }

    function clear(Currency currency, uint256 amount) external pure override {}

    function mint(
        address to,
        uint256 id,
        uint256 amount
    ) external pure override {}

    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) external pure override {}

    function updateDynamicLPFee(
        PoolKey memory key,
        uint24 newDynamicLPFee
    ) external pure override {}

    function unlock(
        bytes calldata data
    ) external pure override returns (bytes memory) {
        return data;
    }

    // --------------------
    // Settlement / Balances
    // --------------------
    function take(
        Currency currency,
        address to,
        uint256 amount
    ) external override {
        if (Currency.unwrap(currency) == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    function settle() external payable override returns (uint256) {
        // For native currency
        balances[msg.sender][Currency.wrap(address(0))] += msg.value;
        return msg.value;
    }

    // --------------------
    // Testing helpers
    // --------------------
    function getBalance(
        address account,
        Currency currency
    ) external view returns (uint256) {
        return balances[account][currency];
    }

    function depositToken(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function withdrawToken(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    function protocolFeesAccrued(
        Currency currency
    ) external view override returns (uint256 amount) {}

    function setProtocolFee(
        PoolKey memory key,
        uint24 newProtocolFee
    ) external override {}

    function setProtocolFeeController(address controller) external override {}

    function collectProtocolFees(
        address recipient,
        Currency currency,
        uint256 amount
    ) external override returns (uint256 amountCollected) {}

    function protocolFeeController() external view override returns (address) {}

    function balanceOf(
        address owner,
        uint256 id
    ) external view override returns (uint256 amount) {}

    function allowance(
        address owner,
        address spender,
        uint256 id
    ) external view override returns (uint256 amount) {}

    function isOperator(
        address owner,
        address spender
    ) external view override returns (bool approved) {}

    function transfer(
        address receiver,
        uint256 id,
        uint256 amount
    ) external override returns (bool) {}

    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) external override returns (bool) {}

    function approve(
        address spender,
        uint256 id,
        uint256 amount
    ) external override returns (bool) {}

    function setOperator(
        address operator,
        bool approved
    ) external override returns (bool) {}

    function extsload(
        bytes32 slot
    ) external view override returns (bytes32 value) {}

    function extsload(
        bytes32 startSlot,
        uint256 nSlots
    ) external view override returns (bytes32[] memory values) {}

    function extsload(
        bytes32[] calldata slots
    ) external view override returns (bytes32[] memory values) {}

    function exttload(
        bytes32 slot
    ) external view override returns (bytes32 value) {}

    function exttload(
        bytes32[] calldata slots
    ) external view override returns (bytes32[] memory values) {}
}
