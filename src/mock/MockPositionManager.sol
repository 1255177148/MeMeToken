// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockPositionManager {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    uint256 public nextTokenId = 1;

    struct Position {
        address owner;
        uint256 liquidity;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public ownerTokens;

    event ModifyLiquidity(uint256 indexed tokenId, address indexed owner, uint256 indexed liquidity);
    event MulticallExecuted(uint256 indexed callCount);
    event Settled(address indexed receiver, address indexed token, uint256 indexed amount);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // Mock 一个 initializePool
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96)
        external
        payable
        returns (int24)
    {
        // 模拟成功初始化池子，不做任何检查，直接返回空结果
        return 0;
    }


    function modifyLiquidities(bytes calldata params, uint256 deadline) external payable{
        // 调用真实 poolManager.modifyLiquidity (mock 时可注释掉)
        // (BalanceDelta delta, uint256 liquidity) = abi.decode(poolManager.modifyLiquidity(params), (BalanceDelta, uint256));

        // 简单分配一个 tokenId
        uint256 tokenId = nextTokenId++;
        positions[tokenId] = Position(msg.sender, 1 ether); // 假设流动性=1
        ownerTokens[msg.sender].push(tokenId);

        emit ModifyLiquidity(tokenId, msg.sender, 1 ether);
    }

    function multicall(bytes[] calldata data)
        external
        payable
        returns (bytes[] memory results)
    {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory ret) = address(this).delegatecall(data[i]);
            require(success, "Multicall failed");
            results[i] = ret;
        }
        emit MulticallExecuted(data.length);
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        require(index < ownerTokens[owner].length, "Index out of bounds");
        return ownerTokens[owner][index];
    }

    function settle(Currency currency, uint256 amount) external {
        if (Currency.unwrap(currency) == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH");
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(Currency.unwrap(currency)).transfer(msg.sender, amount);
        }
        emit Settled(msg.sender, Currency.unwrap(currency), amount);
    }

    receive() external payable {}
}
