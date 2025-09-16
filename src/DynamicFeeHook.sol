// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {
    IPoolManager, PoolKey, SwapParams, ModifyLiquidityParams
} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract DynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => uint256) public beforeSwapCount;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function validateHookAddress(BaseHook) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice 根据交易中 ETH（WETH）数量动态计算手续费
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        int256 wethAmount;

        // 判断交易方向，确定 WETH 数量
        if (params.zeroForOne) {
            // 卖 token0，买 token1（WETH）
            // exact input: token0 amount -> 通过池子价格换算到 token1 量
            // exact output: amountSpecified = -
            wethAmount = params.amountSpecified;
            if (wethAmount > 0) {
                // 卖 token0（exact input）
                wethAmount = wethAmount / 1000; // 预先设定1000:1的兑换比例，然后根据这个计算 token1 数量
            } else {
                // 卖 token1（exact output）
                wethAmount = int256(uint256(-params.amountSpecified));
            }
        } else {
            // 卖 token1（WETH），买 token0
            wethAmount = params.amountSpecified;
            if (wethAmount > 0) {
                // 卖 token1（exact input）
                wethAmount = int256(uint256(wethAmount));
            } else {
                // 卖 token0（exact output）
                wethAmount = wethAmount / 1000; // 预先设定1000:1的兑换比例，然后根据这个计算 token1 数量
            }
        }

        // 根据 WETH 数量动态设置手续费
        uint24 fee;
        if (wethAmount < 1 ether) {
            fee = 3000; // 0.3%
        } else if (wethAmount < 10 ether) {
            fee = 2000; // 0.2%
        } else {
            fee = 1000; // 0.1%
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }
}
