// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ShibMeMeToken.sol";
import "../src/DynamicFeeHook.sol";
import "../src/mock/MockPoolManager.sol";
import "../src/mock/MockPositionManager.sol";
import "../src/mock/MockUniversalRouter.sol";

contract ShibMeMeTokenTest is Test {
    ShibMeMeToken shibMeMeToken;
    DynamicFeeHook feeHook;
    MockPoolManager poolManager;
    MockPositionManager positionManager;
    MockUniversalRouter router;

    address owner = address(0x1);
    address marketing = address(0x2);
    address user = address(0x3);

    function setUp() public {
        vm.deal(owner, 100 ether);
        vm.deal(user, 10 ether);
        // 部署Mock合约
        poolManager = new MockPoolManager();
        positionManager = new MockPositionManager(poolManager);
        router = new MockUniversalRouter();
        vm.deal(address(router), 10 ether);
        // 部署DynamicFeeHook
        feeHook = new DynamicFeeHook(poolManager);
        // 部署 ShibMeMeToken
        vm.startPrank(owner);
        shibMeMeToken = new ShibMeMeToken(
            "ShibMeMeToken",
            "SHIB",
            address(router),
            address(poolManager),
            address(positionManager),
            marketing,
            address(feeHook),
            -887220, // tickLower
            887220 // tickUpper
        );
        // 预充路由合约的ETH流动性
        router.depositETH{value: 10 ether}();

        vm.stopPrank();
    }

    function testSetTaxs() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, false);
        emit ShibMeMeToken.UpdateTax(160, 110, 60);
        shibMeMeToken.setTaxs(160, 110, 60);
        vm.stopPrank();
    }

    function testSetTaxsFail() public {
        vm.startPrank(owner);
        vm.expectRevert();
        shibMeMeToken.setTaxs(1990, 110, 60);
        vm.stopPrank();
    }

    function testSetMarketing() public {
        vm.startPrank(owner);
        address newMarketing = address(0x4);
        vm.expectEmit(true, true, true, false);
        emit ShibMeMeToken.UpdateMarketingAddress(newMarketing);
        shibMeMeToken.setMarketing(newMarketing);
        vm.stopPrank();
    }

    function testSetMarketingFail() public {
        vm.startPrank(owner);
        vm.expectRevert();
        shibMeMeToken.setMarketing(address(0));
        vm.stopPrank();
    }

    function testSetRouter() public {
        vm.startPrank(owner);
        address newRouter = address(0x5);
        vm.expectEmit(true, true, true, false);
        emit ShibMeMeToken.UpdateUniswapRouter(newRouter);
        shibMeMeToken.setRouter(newRouter);
        vm.stopPrank();
    }

    function testSetRouterFail() public {
        vm.startPrank(owner);
        vm.expectRevert();
        shibMeMeToken.setRouter(address(0));
        vm.stopPrank();
    }

    function testSetSwapAndLiquifyEnabled() public {
        vm.startPrank(owner);
        shibMeMeToken.setSwapAndLiquifyEnabled(false);
        assertFalse(shibMeMeToken.swapAndLiquifyEnabled(), "Swap and liquify should be disabled");
        vm.stopPrank();
    }

    function testSetSwapThreshold() public {
        vm.startPrank(owner);
        uint256 newThreshold = 500 * 10**18;
        shibMeMeToken.setSwapThreshold(newThreshold);
        assertEq(shibMeMeToken.swapThreshold(), newThreshold, "Swap threshold should be updated");
        vm.stopPrank();
    }

    function testSetMaxTxAmount() public {
        vm.startPrank(owner);
        uint256 newMaxTxAmount = 1_000_000_000_000 * 10**18;
        shibMeMeToken.setMaxTxAmount(newMaxTxAmount);
        assertEq(shibMeMeToken.maxTxAmount(), newMaxTxAmount, "Max tx amount should be updated");
        vm.stopPrank();
    }

    function testSetMaxTxAmountFail() public {
        vm.startPrank(owner);
        vm.expectRevert();
        shibMeMeToken.setMaxTxAmount(100 * 10**18);
        vm.stopPrank();
    }

    function testSetDailyTxLimit() public {
        vm.startPrank(owner);
        uint256 newDailyTxLimit = 2;
        shibMeMeToken.setDailyTxLimit(newDailyTxLimit);
        assertEq(shibMeMeToken.dailyTxLimit(), newDailyTxLimit, "Daily tx limit should be updated");
        vm.stopPrank();
    }

    function testSetDailyTxLimitFail() public {
        vm.startPrank(owner);
        vm.expectRevert();
        shibMeMeToken.setDailyTxLimit(0);
        vm.stopPrank();
    }

    function testSetExemption() public {
        vm.startPrank(owner);
        shibMeMeToken.setExemption(user, true, true);
        assertTrue(shibMeMeToken.isTaxExempt(user), "User should be exempted");
        assertTrue(shibMeMeToken.isTxLimitExempt(user), "User should be exempted from tx limit");
        vm.stopPrank();
    }

    function testInitLiquidity() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, false);
        vm.recordLogs();
        emit ShibMeMeToken.InitLiquidityPool(1, 3000, 1 ether);
        shibMeMeToken.initLiquidity{value: 1 ether}(3000);
        vm.stopPrank();
    }

    function testTransfer() public {
        vm.startPrank(owner);
        shibMeMeToken.transfer(address(shibMeMeToken), 1_000_000 * 10**18);
        shibMeMeToken.transfer(user, 3000);
        assertEq(shibMeMeToken.balanceOf(user), 3000, "User should receive 3000 tokens");
        vm.stopPrank();
    }
}
