// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBasePriceRouter } from "../TestBasePriceRouter.sol";
import { Curve2PoolAdaptor } from "contracts/oracles/adaptors/curve/Curve2PoolAdaptor.sol";
import { CurveBaseAdaptor } from "contracts/oracles/adaptors/curve/CurveBaseAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PriceRouter } from "contracts/oracles/PriceRouter.sol";

contract TestCurve2PoolAdaptor is TestBasePriceRouter {
    address private CHAINLINK_PRICE_FEED_ETH =
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private CHAINLINK_PRICE_FEED_STETH =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;

    address private ETH_STETH = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address private ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    Curve2PoolAdaptor adaptor;

    function setUp() public override {
        _fork(18031848);

        _deployCentralRegistry();
        _deployPriceRouter();

        adaptor = new Curve2PoolAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor.setReentrancyConfig(2, 10000);
    }

    function testRevertWhenUnderlyingAssetPriceNotSet() public {
        Curve2PoolAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlyingOrConstituent0 = ETH;
        data.underlyingOrConstituent1 = STETH;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        vm.expectRevert(
            Curve2PoolAdaptor
                .Curve2PoolAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adaptor.addAsset(ETH_STETH, data);
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(ETH, CHAINLINK_PRICE_FEED_ETH, 0, true);
        chainlinkAdaptor.addAsset(STETH, CHAINLINK_PRICE_FEED_STETH, 0, true);
        priceRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        priceRouter.addAssetPriceFeed(ETH, address(chainlinkAdaptor));
        priceRouter.addAssetPriceFeed(STETH, address(chainlinkAdaptor));

        Curve2PoolAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlyingOrConstituent0 = ETH;
        data.underlyingOrConstituent1 = STETH;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        adaptor.addAsset(ETH_STETH, data);

        priceRouter.addApprovedAdaptor(address(adaptor));
        priceRouter.addAssetPriceFeed(ETH_STETH, address(adaptor));
        (uint256 ethPrice, ) = priceRouter.getPrice(ETH, true, false);

        (uint256 price, uint256 errorCode) = priceRouter.getPrice(
            ETH_STETH,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(price, ethPrice, 0.02 ether);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();
        adaptor.removeAsset(ETH_STETH);

        vm.expectRevert(PriceRouter.PriceRouter__NotSupported.selector);
        priceRouter.getPrice(ETH_STETH, true, false);
    }
}
