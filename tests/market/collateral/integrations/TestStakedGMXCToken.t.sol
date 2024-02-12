// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { Math } from "contracts/libraries/external/Math.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IStakedGMX } from "contracts/interfaces/external/gmx/IStakedGMX.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { StakedGMXCToken, IERC20 } from "contracts/market/collateral/StakedGMXCToken.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestStakedGMXCToken is TestBaseMarket {
    using Math for uint256;

    address private _GMX_REWARD_ROUTER =
        0x159854e14A862Df9E39E1D128b8e5F70B4A3cE9B;
    address private _GMX_FEE_GMX_TRACKER =
        0xd2D1162512F927a7e282Ef43a362659E4F2a728F;
    address private _GMX = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
    address private _WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private _UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    StakedGMXCToken public cStakedGMX;
    IERC20 public gmx = IERC20(_GMX);

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 180000000);

        _deployCentralRegistry();
        _deployCVE();
        _deployCVELocker();
        _deployVeCVE();
        _deployGaugePool();
        _deployMarketManager();

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeAccumulator(address(this));

        cStakedGMX = new StakedGMXCToken(
            ICentralRegistry(address(centralRegistry)),
            gmx,
            address(marketManager),
            _GMX_REWARD_ROUTER,
            _WETH
        );

        gaugePool.start(address(marketManager));
    }

    function testGmxStakedGMX() public {
        uint256 assets = 100e18;
        deal(_GMX, user1, assets);
        deal(_GMX, address(this), 42069);

        gmx.approve(address(cStakedGMX), 42069);
        marketManager.listToken(address(cStakedGMX));

        vm.prank(user1);
        gmx.approve(address(cStakedGMX), assets);

        vm.prank(user1);
        cStakedGMX.deposit(assets, user1);

        assertEq(
            cStakedGMX.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        // Advance time to earn rewards
        skip(1 days);

        IStakedGMX(_GMX_FEE_GMX_TRACKER).updateRewards();
        uint256 amount = IStakedGMX(_GMX_FEE_GMX_TRACKER).claimable(
            address(cStakedGMX)
        );
        amount -= amount.mulDivDown(
            centralRegistry.protocolHarvestFee(),
            1e18
        );

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _WETH;
        swapData.inputAmount = amount;
        swapData.outputToken = _GMX;
        swapData.target = _UNISWAP_V3_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH;
        params.tokenOut = _GMX;
        params.fee = 10000;
        params.recipient = address(cStakedGMX);
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        centralRegistry.addSwapper(_UNISWAP_V3_ROUTER);

        cStakedGMX.harvest(abi.encode(swapData));

        assertEq(
            cStakedGMX.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        skip(8 days);

        IStakedGMX(_GMX_FEE_GMX_TRACKER).updateRewards();
        amount = IStakedGMX(_GMX_FEE_GMX_TRACKER).claimable(
            address(cStakedGMX)
        );
        amount -= amount.mulDivDown(
            centralRegistry.protocolHarvestFee(),
            1e18
        );

        swapData.inputAmount = amount;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        cStakedGMX.harvest(abi.encode(swapData));

        skip(7 days);

        assertGt(
            cStakedGMX.totalAssets(),
            assets + 42069,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        cStakedGMX.withdraw(assets, user1, user1);
    }
}
