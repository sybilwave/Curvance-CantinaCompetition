// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BalancerBaseAdaptor, IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";

import { IBalancerPool } from "contracts/interfaces/external/balancer/IBalancerPool.sol";
import { IRateProvider } from "contracts/interfaces/external/balancer/IRateProvider.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPriceRouter } from "contracts/interfaces/IPriceRouter.sol";

contract BalancerStablePoolAdaptor is BalancerBaseAdaptor {
    /// TYPES ///

    /// @notice Adaptor storage
    /// @param poolId the pool id of the BPT being priced
    /// @param poolDecimals the decimals of the BPT being priced
    /// @param rateProviders array of rate providers for each constituent
    ///        a zero address rate provider means we are using an underlying
    ///        correlated to the pools virtual base.
    /// @param underlyingOrConstituent the ERC20 underlying asset or
    ///                                the constituent in the pool
    /// @dev Only use the underlying asset, if the underlying is correlated
    ///      to the pools virtual base.
    struct AdaptorData {
        bytes32 poolId;
        uint8 poolDecimals;
        uint8[8] rateProviderDecimals;
        address[8] rateProviders;
        address[8] underlyingOrConstituent;
    }

    /// CONSTANTS ///

    /// @notice Token amount to check uniswap twap price against
    uint128 public constant PRECISION = 1e18;
    /// @notice Error code for bad source.
    uint256 public constant BAD_SOURCE = 2;

    /// STORAGE ///

    /// @notice Balancer Stable Pool Adaptor Storage
    mapping(address => AdaptorData) public adaptorData;

    /// EVENTS ///

    event BalancerStablePoolAssetAdded(address asset, AdaptorData assetConfig);

    event BalancerStablePoolAssetRemoved(address asset);

    /// ERRORS ///

    error BalancerStablePoolAdaptor__AssetIsNotSupported();
    error BalancerStablePoolAdaptor__ConfigurationError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IVault balancerVault_
    ) BalancerBaseAdaptor(centralRegistry_, balancerVault_) {}

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
        if (!isSupportedAsset[asset]) {
            revert BalancerStablePoolAdaptor__AssetIsNotSupported();
        }

        _ensureNotInVaultContext(balancerVault);
        // Read Adaptor storage and grab pool tokens
        AdaptorData memory data = adaptorData[asset];
        IBalancerPool pool = IBalancerPool(asset);

        pData.inUSD = inUSD;
        IPriceRouter priceRouter = IPriceRouter(centralRegistry.priceRouter());

        // Find the minimum price of all the pool tokens.
        uint256 numUnderlyingOrConstituent = data
            .underlyingOrConstituent
            .length;
        uint256 averagePrice;
        uint256 availablePriceCount;

        uint256 price;
        uint256 errorCode;
        for (uint256 i; i < numUnderlyingOrConstituent; ++i) {
            // Break when a zero address is found.
            if (address(data.underlyingOrConstituent[i]) == address(0)) {
                break;
            }

            (price, errorCode) = priceRouter.getPrice(
                data.underlyingOrConstituent[i],
                inUSD,
                getLower
            );
            // If error code is BAD_SOURCE we can't use this price so continue.
            if (errorCode == BAD_SOURCE) {
                continue;
            }

            averagePrice += price;
            availablePriceCount += 1;
        }

        if (averagePrice == 0) {
            pData.hadError = true;
        } else {
            averagePrice = averagePrice / availablePriceCount;
            pData.price = uint240((price * pool.getRate()) / PRECISION);
        }
    }

    /// @notice Add a Balancer Stable Pool Bpt as an asset.
    /// @dev Should be called before `PriceRotuer:addAssetPriceFeed` is called.
    /// @param asset the address of the bpt to add
    /// @param data AdaptorData needed to add `asset`
    function addAsset(address asset, AdaptorData memory data) external {
        _checkElevatedPermissions();

        if (isSupportedAsset[asset]) {
            revert BalancerStablePoolAdaptor__ConfigurationError();
        }

        IBalancerPool pool = IBalancerPool(asset);

        // Grab the poolId and decimals.
        data.poolId = pool.getPoolId();
        data.poolDecimals = pool.decimals();

        uint256 numUnderlyingOrConstituent = data
            .underlyingOrConstituent
            .length;

        // Make sure we can price all underlying tokens.
        for (uint256 i; i < numUnderlyingOrConstituent; ++i) {
            // Break when a zero address is found.
            if (address(data.underlyingOrConstituent[i]) == address(0)) {
                continue;
            }

            if (
                !IPriceRouter(centralRegistry.priceRouter()).isSupportedAsset(
                    data.underlyingOrConstituent[i]
                )
            ) {
                revert BalancerStablePoolAdaptor__ConfigurationError();
            }

            if (data.rateProviders[i] != address(0)) {
                // Make sure decimals were provided.
                if (data.rateProviderDecimals[i] == 0) {
                    revert BalancerStablePoolAdaptor__ConfigurationError();
                }

                // Make sure we can call it and get a non zero value.
                if (IRateProvider(data.rateProviders[i]).getRate() == 0) {
                    revert BalancerStablePoolAdaptor__ConfigurationError();
                }
            }
        }

        // Save values in Adaptor storage.
        adaptorData[asset] = data;
        isSupportedAsset[asset] = true;
        emit BalancerStablePoolAssetAdded(asset, data);
    }

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into price router to notify it of its removal
    function removeAsset(address asset) external override {
        _checkElevatedPermissions();

        if (!isSupportedAsset[asset]) {
            revert BalancerStablePoolAdaptor__AssetIsNotSupported();
        }

        // Notify the adaptor to stop supporting the asset
        delete isSupportedAsset[asset];
        // Wipe config mapping entries for a gas refund
        delete adaptorData[asset];

        // Notify the price router that we are going to stop supporting the asset
        IPriceRouter(centralRegistry.priceRouter()).notifyFeedRemoval(asset);
        emit BalancerStablePoolAssetRemoved(asset);
    }
}
