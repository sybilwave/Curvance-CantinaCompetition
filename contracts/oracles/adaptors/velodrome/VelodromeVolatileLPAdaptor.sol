// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPriceRouter } from "contracts/interfaces/IPriceRouter.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { Math } from "contracts/libraries/Math.sol";

contract VelodromeVolatileLPAdaptor is BaseOracleAdaptor {
    /// TYPES ///

    /// @notice Adaptor storage
    /// @param token0 token0 address
    /// @param decimals0 token0 decimals
    /// @param token1 token1 address
    /// @param decimals1 token1 decimals
    struct AdaptorData {
        address token0;
        uint8 decimals0;
        address token1;
        uint8 decimals1;
    }

    /// CONSTANTS ///

    /// @notice Error code for bad source.
    uint256 public constant BAD_SOURCE = 2;

    /// STORAGE ///

    /// @notice Balancer Stable Pool Adaptor Storage
    mapping(address => AdaptorData) public adaptorData;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_
    ) BaseOracleAdaptor(centralRegistry_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Called during pricing operations.
    /// @param asset the bpt being priced
    /// @param inUSD indicates whether we want the price in USD or ETH
    /// @param getLower Since this adaptor calls back into the price router
    ///                 it needs to know if it should be working with the
    ///                 upper or lower prices of assets
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view override returns (PriceReturnData memory pData) {
        require(
            isSupportedAsset[asset],
            "VelodromeVolatileLPAdaptor: asset not supported"
        );

        // Read Adaptor storage and grab pool tokens
        AdaptorData memory data = adaptorData[asset];
        IVeloPair pool = IVeloPair(asset);

        // LP total supply
        uint256 totalSupply = pool.totalSupply();
        // LP reserves
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
        // convert to 18 decimals
        reserve0 = (reserve0 * 1e18) / (10 ** data.decimals0);
        reserve1 = (reserve1 * 1e18) / (10 ** data.decimals1);

        // sqrt(reserve0 * reserve1)
        uint256 sqrtReserve = Math.sqrt(reserve0 * reserve1);

        // sqrt(price0 * price1)
        uint256 price0;
        uint256 price1;
        uint256 errorCode;
        IPriceRouter priceRouter = IPriceRouter(centralRegistry.priceRouter());
        (price0, errorCode) = priceRouter.getPrice(
            data.token0,
            inUSD,
            getLower
        );
        if (errorCode > 0) {
            pData.hadError = true;
            if (errorCode == BAD_SOURCE) return pData;
        }
        (price1, errorCode) = priceRouter.getPrice(
            data.token1,
            inUSD,
            getLower
        );
        if (errorCode > 0) {
            pData.hadError = true;
            if (errorCode == BAD_SOURCE) return pData;
        }
        uint256 sqrtPrice = Math.sqrt(price0 * price1);

        // price = 2 * sqrt(reserve0 * reserve1) * sqrt(price0 * price1) / totalSupply
        pData.inUSD = inUSD;
        pData.price = uint240((2 * sqrtReserve * sqrtPrice) / totalSupply);
    }

    /// @notice Add a Balancer Stable Pool Bpt as an asset.
    /// @dev Should be called before `PriceRotuer:addAssetPriceFeed` is called.
    /// @param asset the address of the bpt to add
    function addAsset(address asset) external onlyElevatedPermissions {
        require(
            !isSupportedAsset[asset],
            "VelodromeVolatileLPAdaptor: asset already supported"
        );
        IVeloPair pool = IVeloPair(asset);
        AdaptorData memory data;
        data.token0 = pool.token0();
        data.token1 = pool.token1();
        data.decimals0 = IERC20(data.token0).decimals();
        data.decimals1 = IERC20(data.token1).decimals();

        // Save values in Adaptor storage.
        adaptorData[asset] = data;
        isSupportedAsset[asset] = true;
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into price router to notify it of its removal
    function removeAsset(address asset) external override onlyDaoPermissions {
        require(
            isSupportedAsset[asset],
            "VelodromeVolatileLPAdaptor: asset not supported"
        );

        // Notify the adaptor to stop supporting the asset
        delete isSupportedAsset[asset];
        // Wipe config mapping entries for a gas refund
        delete adaptorData[asset];

        // Notify the price router that we are going to stop supporting the asset
        IPriceRouter(centralRegistry.priceRouter())
            .notifyAssetPriceFeedRemoval(asset);
    }
}
