// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import "./MockIV4Router.sol";
import "forge-std/console.sol";

contract MockUniversalRouter {
    event Executed(bytes commands, bytes[] inputs, uint256 deadline);
    event SwapExecuted(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);
    event LiquidityAdded(address token, uint256 tokenAmount, uint256 ethAmount, uint256 positionId);
    event LiquidityIncreased(uint256 positionId, uint256 tokenAmount, uint256 ethAmount);

    uint256 public constant EXCHANGE_RATE = 0.001 ether;

    // 记录流动性头寸
    struct LiquidityPosition {
        address owner;
        address token;
        uint256 tokenAmount;
        uint256 ethAmount;
    }

    mapping(uint256 => LiquidityPosition) public positions;
    uint256 public nextPositionId = 1;

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        emit Executed(commands, inputs, deadline);

        if (commands.length > 0) {
            uint8 command = uint8(commands[0]);
            console.log("Command:", command);
            
            if (command == Commands.V4_SWAP) {
                // V4_SWAP (Commands.V4_SWAP)
                _handleV4Swap(inputs[0], msg.sender);
            }
        }
    }

    function _handleV4Swap(bytes calldata input, address account) internal {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));
        console.log("Actions length:", actions.length);
        if (actions.length >= 1 && uint8(actions[0]) == uint8(Actions.SWAP_EXACT_IN_SINGLE)) {
            // SWAP_EXACT_IN_SINGLE
            (MockIV4Router.ExactInputSingleParams memory swapParams) =
                abi.decode(params[0], (MockIV4Router.ExactInputSingleParams));
            console.log("Swap Amount In:", swapParams.amountIn);
            console.log("Swap Amount Out Min:", swapParams.amountOutMinimum);
            console.log("Pool Fee:", swapParams.poolKey.fee);
            console.log("Tick Spacing:", swapParams.poolKey.tickSpacing);
            console.log("Hook Data Length:", swapParams.hookData.length);

            address tokenIn = Currency.unwrap(swapParams.poolKey.currency0);
            address tokenOut = Currency.unwrap(swapParams.poolKey.currency1);

            if (tokenIn != address(0) && tokenOut == address(0)) {
                _swapTokenToETH(tokenIn, swapParams.amountIn, account);
            } else if (tokenIn == address(0) && tokenOut != address(0)) {
                _swapETHToToken(tokenOut, swapParams.amountIn, account);
            }
        }
    }

    function _handleV4AddLiquidity(bytes calldata input) internal {
        (bytes memory actions, bytes[] memory params) = abi.decode(input, (bytes, bytes[]));

        // 解析 Actions
        if (actions.length >= 1) {
            uint8 action1 = uint8(actions[0]);

            if (action1 == 0x00) {
                // INCREASE_LIQUIDITY (Actions.INCREASE_LIQUIDITY)
                _handleIncreaseLiquidity(params);
            } else if (action1 == 0x01) {
                // MINT_POSITION (Actions.MINT_POSITION) - 创建新头寸
                _handleMintPosition(params);
            }
        }
    }

    function _handleIncreaseLiquidity(bytes[] memory params) internal {
        // 解析增加流动性参数
        (uint256 positionId, uint128 amount0, uint128 amount1,,, bytes memory hookData) =
            abi.decode(params[0], (uint256, uint128, uint128, uint128, uint128, bytes));

        // 解析结算货币
        (Currency currency0, Currency currency1) = abi.decode(params[1], (Currency, Currency));

        address token = Currency.unwrap(currency0);
        bool isETH = Currency.unwrap(currency1) == address(0);

        require(isETH, "Only ETH pairs supported");

        // 检查头寸是否存在
        require(positions[positionId].owner != address(0), "Position does not exist");
        require(positions[positionId].owner == msg.sender, "Not position owner");

        // 转移代币
        if (amount0 > 0) {
            IERC20(token).transferFrom(msg.sender, address(this), amount0);
        }

        // ETH 通过 msg.value 已经发送

        // 更新头寸信息
        positions[positionId].tokenAmount += amount0;
        positions[positionId].ethAmount += amount1;

        emit LiquidityIncreased(positionId, amount0, amount1);
    }

    function _handleMintPosition(bytes[] memory params) internal {
        // 解析创建头寸参数
        (
            MockIV4Router.PoolKey memory poolKey,
            bytes memory actions,
            uint256 amount0,
            uint256 amount1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint256 amount0Min,
            uint256 amount1Min,
            address recipient,
            bytes memory hookData
        ) = abi.decode(
            params[0],
            (MockIV4Router.PoolKey, bytes, uint256, uint256, uint24, int24, int24, uint256, uint256, address, bytes)
        );

        // 解析结算货币
        (Currency currency0, Currency currency1) = abi.decode(params[1], (Currency, Currency));

        address token = Currency.unwrap(currency0);
        bool isETH = Currency.unwrap(currency1) == address(0);

        require(isETH, "Only ETH pairs supported");

        // 转移代币
        if (amount0 > 0) {
            IERC20(token).transferFrom(msg.sender, address(this), amount0);
        }

        // ETH 通过 msg.value 已经发送

        // 创建新头寸
        uint256 positionId = nextPositionId++;
        positions[positionId] =
            LiquidityPosition({owner: recipient, token: token, tokenAmount: amount0, ethAmount: amount1});

        emit LiquidityAdded(token, amount0, amount1, positionId);
    }

    function _swapTokenToETH(address token, uint128 amountIn, address account) internal {
        require(amountIn > 0, "Invalid amount");
        console.log("Token In:", token);
        uint256 ethAmountOut = 1 ether;
        require(address(this).balance >= ethAmountOut, "Insufficient ETH in router");

        IERC20(token).transferFrom(account, address(this), amountIn);
        payable(account).transfer(ethAmountOut);

        emit SwapExecuted(token, amountIn, address(0), ethAmountOut);
    }

    function _swapETHToToken(address token, uint128 amountIn, address account) internal {
        require(amountIn > 0, "Invalid amount");
        require(msg.value >= amountIn, "Insufficient ETH sent");

        uint256 tokenAmountOut = uint256(amountIn) * (10 ** 18) / EXCHANGE_RATE;
        uint256 routerBalance = IERC20(token).balanceOf(address(this));
        require(routerBalance >= tokenAmountOut, "Insufficient tokens in router");

        IERC20(token).transfer(account, tokenAmountOut);

        emit SwapExecuted(address(0), amountIn, token, tokenAmountOut);
    }

    // 查询头寸信息
    function getPosition(uint256 positionId) external view returns (address, address, uint256, uint256) {
        LiquidityPosition memory position = positions[positionId];
        return (position.owner, position.token, position.tokenAmount, position.ethAmount);
    }

    function depositETH() external payable {}

    function depositToken(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    receive() external payable {}
}
