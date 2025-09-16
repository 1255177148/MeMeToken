// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./DynamicFeeHook.sol";
import "forge-std/console.sol";

/*
    * 名称：ShibMeMeToken
    * 符号：SHIB
    * 总供应量：1,000,000,000,000,000
    * 小数位数：18
    * SHIB风格的 Meme 代币合约，
    * 具备自动流动性、交易税费、交易限制等功能
    * 基于Uniswap V2实现自动流动性
    * 交易税费分配给流动池、市场方和销毁
    * 合约部署时铸造全部代币，并分配给部署者，然后部署者可以将一部分代币添加到流动池
    * 合约所有者可以设置税费比例、交易限制、豁免地址等
    * 用户通过该合约使用ETH兑换代币时，合约会通过uniswap路由自动完成兑换和流动性添加，用来平衡流动性
 */
contract ShibMeMeToken is ERC20, Ownable, ReentrancyGuard {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000_000_000 * 10 ** 18;

    // --- 税费配置（单位：万分比） ---
    uint16 public liquidityTax = 150; // 流动池收的税，给LP 1.5%
    uint16 public marketingTax = 100; // 产品市场方收的税 1.0%
    uint16 public burnTax = 50; // 销毁 0.5%
    uint16 public totalTax; // 总税率

    address public marketing; // 市场方钱包地址
    address public immutable deadAddress = address(0xdead); // 销毁地址
    address public feeHook;

    // --- 交易限制 ---
    uint256 public maxTxAmount; // 最大交易量
    uint256 public dailyTxLimit; // 每日交易上限
    mapping(address => uint256) public lastTxTimestamp; // 记录每个地址的最后交易时间
    mapping(address => uint256) public dailyTxAmount; // 记录每个地址的每日交易金额

    // --- 豁免设置 ---
    mapping(address => bool) public isTaxExempt; // 税费豁
    mapping(address => bool) public isTxLimitExempt; // 交易限制豁免

    // --- uniswap 相关 ---
    IPoolManager public poolManager; // uniswap V4 PoolManager
    PositionManager public positionManager; // uniswap V4 PositionManager
    UniversalRouter public router;
    int256 public tickLower; // 流动性价格区间下限
    int256 public tickUpper; // 流动性价格区间上限
    uint256 public positionId; // 当前 NFT 流动性头寸 ID
    bool private inSwapAndLiquify; // 互斥锁，防止重入
    bool public swapAndLiquifyEnabled = true; // 是否开启自动流动性
    uint256 public swapThreshold = 500_000 * 10 ** 18; // 触发自动流动性的最小代币数量

    // --- 事件 ---
    event UpdateTax(uint16 indexed liquidityTax, uint16 indexed marketingTax, uint16 indexed burnTax);
    event UpdateMaxTxAmount(uint256 indexed maxTxAmount);
    event UpdateDailyTxLimit(uint256 indexed dailyTxLimit);
    event SetExempt(address indexed account, bool indexed isTaxExempt, bool indexed isTxLimitExempt);
    event UpdateMarketingAddress(address indexed marketing);
    event SwapAndLiquify(
        uint256 indexed tokensSwapped, uint256 indexed ethReceived, uint256 indexed tokensIntoLiqudity
    );
    event UpdateUniswapRouter(address indexed newAddress);
    event InitLiquidityPool(uint256 indexed positionId, uint256 indexed tokenAmount, uint256 indexed ethAmount);

    // 防重入锁修饰器
    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor(
        string memory name,
        string memory symbol,
        address router_,
        address poolManager_,
        address positionManager_,
        address marketing_,
        address feeHook_,
        int256 _tickLower,
        int256 _tickUpper
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, INITIAL_SUPPLY);
        router = UniversalRouter(payable(router_));
        poolManager = IPoolManager(poolManager_);
        positionManager = PositionManager(payable(positionManager_));
        marketing = marketing_ == address(0) ? msg.sender : marketing_;
        feeHook = feeHook_;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        // 设置默认交易限制：单笔最大 1%，每日最多 10 笔
        maxTxAmount = INITIAL_SUPPLY / 100;
        dailyTxLimit = 10;
        // 部署者和合约本身默认豁免税费与限制
        isTaxExempt[msg.sender] = true;
        isTxLimitExempt[msg.sender] = true;
        isTaxExempt[address(this)] = true;
        isTxLimitExempt[address(this)] = true;
        totalTax = liquidityTax + marketingTax + burnTax; // 计算总税率
    }

    // 设置税费比例，总税率不得超过20%
    function setTaxs(uint16 liquidityTax_, uint16 marketingTax_, uint16 burnTax_) external onlyOwner {
        liquidityTax = liquidityTax_;
        marketingTax = marketingTax_;
        burnTax = burnTax_;
        totalTax = liquidityTax + marketingTax + burnTax; // 计算总税率
        require(totalTax <= 2000, "Total tax must not exceed 20%");
        emit UpdateTax(liquidityTax, marketingTax, burnTax);
    }

    // 设置产品方钱包地址
    function setMarketing(address marketing_) external onlyOwner {
        require(marketing_ != address(0), "Marketing address cannot be zero");
        marketing = marketing_;
        emit UpdateMarketingAddress(marketing);
    }

    // 设置或切换uniswap router地址
    function setRouter(address router_) external onlyOwner {
        require(router_ != address(0), "Router address cannot be zero");
        router = UniversalRouter(payable(router_));
        emit UpdateUniswapRouter(router_);
    }

    // 开关自动流动性
    function setSwapAndLiquifyEnabled(bool enabled) external onlyOwner {
        swapAndLiquifyEnabled = enabled;
    }

    // 设置流动性触发阈值
    function setSwapThreshold(uint256 threshold) external onlyOwner {
        swapThreshold = threshold;
    }

    // 设置单笔最大交易量
    function setMaxTxAmount(uint256 maxTxAmount_) external onlyOwner {
        require(maxTxAmount_ >= INITIAL_SUPPLY / 1000, "Max tx amount must be at least 0.1%");
        maxTxAmount = maxTxAmount_;
        emit UpdateMaxTxAmount(maxTxAmount);
    }

    // 设置每日交易上限
    function setDailyTxLimit(uint256 dailyTxLimit_) external onlyOwner {
        require(dailyTxLimit_ >= 1, "Daily tx limit must be at least 1");
        dailyTxLimit = dailyTxLimit_;
        emit UpdateDailyTxLimit(dailyTxLimit);
    }

    // 设置税费或者交易限制豁免
    function setExemption(address account, bool isTaxExempt_, bool isTxLimitExempt_) external onlyOwner {
        isTaxExempt[account] = isTaxExempt_;
        isTxLimitExempt[account] = isTxLimitExempt_;
        emit SetExempt(account, isTaxExempt_, isTxLimitExempt_);
    }

    function getPoolKey() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(this)),
            currency1: Currency.wrap(address(0)), // ETH
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(feeHook)
        });
    }

    // 初始化Uniswap V3流动性池，并添加初始流动性
    // tokenAmount: 添加的代币数量
    // ethAmount: 添加的ETH数量
    function initLiquidity(uint256 tokenAmount) external payable onlyOwner nonReentrant {
        require(positionId == 0, "Already initialized");
        require(tokenAmount > 0, "Token required");
        uint256 ethAmount = msg.value; // 直接使用 msg.value 作为 ETH 数量
        require(ethAmount > 0, "ETH required");
        // 把 token 转到合约地址
        _transfer(msg.sender, address(this), tokenAmount);
        _approve(address(this), address(positionManager), tokenAmount);

        // 定义池子 Key，fee 可以为 0，Hook 控制实际费率
        PoolKey memory pool = getPoolKey();
        // 创建池子或获取已有池子
        uint160 initialSqrtPriceX96 = encodePriceSqrt(ethAmount, tokenAmount);
        // 步骤 2: 准备 multicall 参数
        bytes[] memory params = new bytes[](2);
        // 步骤 3: 编码 initializePool 调用
        params[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, pool, initialSqrtPriceX96);
        // 步骤 4: 编码 modifyLiquidities 操作
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), // 0 Actions.MINT_POSITION
            uint8(Actions.SETTLE_PAIR) // 1 Actions.SETTLE_PAIR
        );
        bytes[] memory mintParams = new bytes[](2);
        // 对于 DynamicFeeHook，hookData 可以为空，因为费率在 swap 时动态计算
        bytes memory hookData = new bytes(0);
        // 构造 mint 参数
        mintParams[0] = abi.encode(
            pool,
            actions,
            tokenAmount,
            ethAmount,
            tickLower,
            tickUpper,
            0, // amount0Min
            0, // amount1Min
            address(this), // recipient
            hookData
        );
        mintParams[1] = abi.encode(pool.currency0, pool.currency1); // 结算对
        uint256 deadline = block.timestamp + 3600; // 1 hour from now
        params[1] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(actions, mintParams), // 正确：封装actions和params
            deadline
        );
        // 步骤 5: 执行 multicall
        positionManager.multicall{value: msg.value}(params);
        positionId = 1; // 简化处理，假设第一个头寸ID为1,实际应该是从NFT transfer事件获取
        emit InitLiquidityPool(positionId, tokenAmount, ethAmount);
    }

    function encodePriceSqrt(uint256 reserve1, uint256 reserve0) private pure returns (uint160) {
        // 价格 = reserve1 / reserve0
        return uint160(
            (sqrt((reserve1 * 1e18) / reserve0) * (2 ** 96)) / 1e9 // 这里注意精度
        );
    }

    function sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _update(address sender, address recipient, uint256 amount) internal override {
        if (sender == address(0) || recipient == address(0)) {
            super._update(sender, recipient, amount);
            return;
        }
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        // 交易限制检查
        if (!isTxLimitExempt[sender] && !isTxLimitExempt[recipient]) {
            require(amount <= maxTxAmount, "Transfer amount exceeds the maxTxAmount");

            // 每日交易次数限制
            if (block.timestamp > lastTxTimestamp[sender] + 24 hours) {
                // 超过24小时，重置计数
                dailyTxAmount[sender] = 0;
                lastTxTimestamp[sender] = block.timestamp;
            }
            require(dailyTxAmount[sender] + 1 <= dailyTxLimit, "Exceeds daily transaction limit");
            dailyTxAmount[sender] += 1;
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        // 是否触发自动流动性
        if (contractTokenBalance >= swapThreshold && !inSwapAndLiquify && swapAndLiquifyEnabled) {
            _swapAndLiquify(contractTokenBalance);
        }

        // 税费处理
        if (isTaxExempt[sender] || isTaxExempt[recipient] || totalTax == 0) {
            super._update(sender, recipient, amount);
        } else {
            uint256 taxAmount = amount * totalTax / 10000;
            uint256 burnAmount = amount * burnTax / 10000;
            uint256 transferAmount = amount - taxAmount;

            // 扣税并转账
            super._update(sender, address(this), taxAmount - burnAmount); // 税费转到合约
            if (burnAmount > 0) {
                super._update(sender, deadAddress, burnAmount); // 销毁部分
            }
            super._update(sender, recipient, transferAmount); // 转账给接收方
        }
    }

    // 交换并添加流动性
    function _swapAndLiquify(uint256 contractTokenBalance) internal lockTheSwap {
        console.log("_swapAndLiquify", contractTokenBalance);
        if (contractTokenBalance == 0) return;
        uint256 totalSwapTax = liquidityTax + marketingTax;
        if (totalSwapTax == 0) return;
        // 计算出用于流动性和市场的代币数量
        uint256 tokensForLiquidity = contractTokenBalance * liquidityTax / totalSwapTax;
        uint256 halfLiquidityTokens = tokensForLiquidity / 2; // 一半用于兑换ETH
        uint256 otherHalfLiquidityTokens = tokensForLiquidity - halfLiquidityTokens; // 另一半保留用于添加流动性
        uint256 tokensForMarketing = contractTokenBalance - tokensForLiquidity; // 剩余的作为国库税(即市场税)
        uint256 tokensToSwap = halfLiquidityTokens + tokensForMarketing; // 需要兑换成ETH的代币总数
        if (tokensToSwap == 0) return;
        uint256 initialBalance = address(this).balance; // 交换前的ETH余额
        // 授权给路由合约
        _approve(address(this), address(router), tokensToSwap);
        // 执行兑换
        _swapTokensForEth(tokensToSwap);

        uint256 newBalance = address(this).balance - initialBalance; // 计算兑换得到的ETH数量
        console.log("newBalance", newBalance);
        if (newBalance == 0) return;
        // 按比例分配 WETH：一部分用于添加流动性，一部分用于市场营销
        uint256 ethForLiquidity = newBalance * halfLiquidityTokens / tokensToSwap;
        uint256 ethForMarketing = newBalance - ethForLiquidity;
        // 添加流动性
        if (otherHalfLiquidityTokens > 0 && ethForLiquidity > 0) {
            console.log("otherHalfLiquidityTokens", otherHalfLiquidityTokens);
            _addLiquidityV4(otherHalfLiquidityTokens, ethForLiquidity);
        }

        // 将市场部分的 WETH 兑换回 ETH 并发送给 marketing 地址
        if (ethForMarketing > 0) {
            payable(marketing).transfer(ethForMarketing); // 发送给市场方
        }
        emit SwapAndLiquify(tokensToSwap, newBalance, otherHalfLiquidityTokens);
    }

    // 使用 Uniswap 路由将代币兑换为 ETH
    function _swapTokensForEth(uint256 tokenAmount) private {
        PoolKey memory pool = getPoolKey();
        // 编码Universal Router命令
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1); // 这里只有一个交换操作
        // 编码V4Router动作
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        // 准备参数
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: pool,
                zeroForOne: true, // 从代币0（本代币）兑换到代币1（WETH）
                amountIn: uint128(tokenAmount),
                amountOutMinimum: 0, // 可根据需要设置最小输出
                hookData: bytes("") // 对于 DynamicFeeHook，hookData 可以为空
            })
        );
        params[1] = abi.encode(Currency.wrap(address(this)), tokenAmount);
        params[2] = abi.encode(Currency.wrap(address(0)), 0);
        // 组合动作和参数
        inputs[0] = abi.encode(actions, params);

        // 执行兑换
        uint256 deadline = block.timestamp + 20 minutes;
        router.execute(commands, inputs, deadline);
    }

    // 添加流动性 - V4版本
    function _addLiquidityV4(uint256 tokenAmount, uint256 ethAmount) internal {
        // --- 授权 PositionManager 使用代币 ---
        _approve(address(this), address(positionManager), tokenAmount);

        // 编码V4Router动作
        bytes memory actions =
            abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // 准备参数
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            positionId,
            uint128(tokenAmount), // 添加的 token 数量
            type(uint128).max, // amount0Max
            type(uint128).max, // amount1Max
            new bytes(0) // hookData，可为空
        );
        params[1] = abi.encode(Currency.wrap(address(this)), CurrencyLibrary.ADDRESS_ZERO);
        params[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, address(this));

        // 执行添加流动性
        uint256 deadline = block.timestamp + 20 minutes;
        positionManager.modifyLiquidities{value: ethAmount}(
            abi.encode(actions, params),
            deadline
        );
    }

    // 接收ETH, 用于接受流动池路由合约交换来的ETH
    receive() external payable {}

    // 紧急取回合约内的ERC20代币，防止误操作锁定合约内的代币
    function rescueERC20(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(this), "can't rescue self");
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    // 紧急取回合约内的ETH，防止误操作锁定合约内的ETH
    function rescueETH(uint256 amount) external onlyOwner {
        (bool sent,) = owner().call{value: amount}("");
        require(sent, "rescue failed");
    }
}
