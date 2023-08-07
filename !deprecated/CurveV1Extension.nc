// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.17;

import { ICurvePool } from "contracts/interfaces/external/curve/ICurvePool.sol";
import { Extension } from "contracts/oracles/adaptors/Extension.sol";
import { PriceOps } from "contracts/oracles/PriceOps.sol";
import { Math } from "contracts/libraries/Math.sol";
import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import { ERC20, SafeTransferLib } from "contracts/libraries/ERC4626.sol";

// TODO Add Chainlink Curve VP bound check

contract CurveV1Extension is Extension {
    using Math for uint256;

    struct CurveDerivativeStorage {
        address[] coins;
        address pool;
        address asset;
    }

    /// @notice Curve Derivative Storage
    /// @dev Stores an array of the underlying token addresses in the curve pool.
    mapping(uint64 => CurveDerivativeStorage) public getCurveDerivativeStorage;

    constructor(PriceOps _priceOps) Extension(_priceOps) {}

    function setupSource(
        address asset,
        uint64 _sourceId,
        bytes calldata data
    ) external override onlyPriceOps {
        address source = abi.decode(data, (address));
        ICurvePool pool = ICurvePool(source);
        uint8 coinsLength = 0;
        // Figure out how many tokens are in the curve pool.
        while (true) {
            try pool.coins(coinsLength) {
                coinsLength++;
            } catch {
                break;
            }
        }

        // Save the pools tokens to reduce gas for pricing calls.
        address[] memory coins = new address[](coinsLength);
        for (uint256 i = 0; i < coinsLength; ++i) {
            coins[i] = pool.coins(i);
        }

        getCurveDerivativeStorage[_sourceId].coins = coins;
        getCurveDerivativeStorage[_sourceId].pool = source;
        getCurveDerivativeStorage[_sourceId].asset = asset;

        // curveAssets.push(asset);

        // Setup virtual price bound.
        // VirtualPriceBound memory vpBound = abi.decode(_storage, (VirtualPriceBound));
        // uint256 upper = uint256(vpBound.datum).mulDivDown(vpBound.posDelta, 1e8);
        // upper = upper.changeDecimals(8, 18);
        // uint256 lower = uint256(vpBound.datum).mulDivDown(vpBound.negDelta, 1e8);
        // lower = lower.changeDecimals(8, 18);
        // _checkBounds(lower, upper, pool.get_virtual_price());
        // if (vpBound.rateLimit == 0) vpBound.rateLimit = DEFAULT_RATE_LIMIT;
        // vpBound.timeLastUpdated = uint64(block.timestamp);
        // getVirtualPriceBound[address(_asset)] = vpBound;
    }

    function getPriceInBase(
        uint64 sourceId
    )
        external
        view
        override
        onlyPriceOps
        returns (uint256 upper, uint256 lower, uint8 errorCode)
    {
        CurveDerivativeStorage memory stor = getCurveDerivativeStorage[
            sourceId
        ];

        ICurvePool pool = ICurvePool(stor.pool);

        uint256 numStorCoins = stor.coins.length;
        uint256 maxUpper = 0;
        uint256 minLower = type(uint256).max;
        for (uint256 i = 0; i < numStorCoins; ++i) {
            (uint256 nextUpper, uint256 nextLower, uint8 _errorCode) = priceOps
                .getPriceInBase(stor.coins[i]);
            if (_errorCode == BAD_SOURCE) {
                // Completely blind as to what this price is return error code of BAD_SOURCE.
                return (0, 0, BAD_SOURCE);
            } else if (_errorCode == CAUTION) {
                // Update errorCode to be CAUTION.
                errorCode = CAUTION;
            }
            if (nextUpper > maxUpper) maxUpper = nextUpper;
            if (nextLower > 0 && nextLower < minLower) minLower = nextLower;
            if (nextUpper < minLower) minLower = nextUpper;
        }

        if (maxUpper == 0) errorCode = BAD_SOURCE;
        if (minLower == type(uint256).max) minLower = 0;

        // Check that virtual price is within bounds.
        uint256 virtualPrice = pool.get_virtual_price();
        // VirtualPriceBound memory vpBound = getVirtualPriceBound[address(asset)];
        // uint256 upper = uint256(vpBound.datum).mulDivDown(vpBound.posDelta, 1e8);
        // upper = upper.changeDecimals(8, 18);
        // uint256 lower = uint256(vpBound.datum).mulDivDown(vpBound.negDelta, 1e8);
        // lower = lower.changeDecimals(8, 18);
        // _checkBounds(lower, upper, virtualPrice);

        // Virtual price is based off the Curve Token decimals.
        uint256 curveTokenDecimals = ERC20(stor.asset).decimals();
        upper = maxUpper.mulDivDown(virtualPrice, 10 ** curveTokenDecimals);
        lower = minLower.mulDivDown(virtualPrice, 10 ** curveTokenDecimals);

        // It is possible that if not all sources provide a lower value, then lower can be greater than upper.
        // TODO pretty sure this is no longer needed.
        // if (lower > upper) (upper, lower) = (lower, upper);
    }

    // ======================================== CURVE VIRTUAL PRICE BOUND ========================================
    // /**
    //  * @notice Curve virtual price is susceptible to re-entrancy attacks, if the attacker adds/removes pool liquidity,
    //  *         and re-enters into one of our contracts. To mitigate this, all curve pricing operations check
    //  *         the current `pool.get_virtual_price()` against logical bounds.
    //  * @notice These logical bounds are updated when `addAsset` is called, or Chainlink Automation detects that
    //  *         the bounds need to be updated, and that the gas price is reasonable.
    //  * @notice Once the on chain virtual price goes out of bounds, all pricing operations will revert for that Curve LP,
    //  *         which means any Cellars using that Curve LP are effectively frozen until the virtual price bounds are updated
    //  *         by Chainlink. If this is not happening in a timely manner( IE network is abnormally busy), the owner of this
    //  *         contract can raise the `gasConstant` to a value that better reflects the floor gas price of the network.
    //  *         Which will cause Chainlink nodes to update virtual price bounds faster.
    //  */

    // /**
    //  * @param datum the virtual price to base posDelta and negDelta off of, 8 decimals
    //  * @param timeLastUpdated the timestamp this datum was updated
    //  * @param posDelta multipler >= 1e8 defining the logical upper bound for this virtual price, 8 decimals
    //  * @param negDelta multipler <= 1e8 defining the logical lower bound for this virtual price, 8 decimals
    //  * @param rateLimit the minimum amount of time that must pass between updates
    //  * @dev Curve virtual price values should update slowly, hence why this contract enforces a rate limit.
    //  * @dev During datum updates, the max/min new datum corresponds to the current upper/lower bound.
    //  */
    // struct VirtualPriceBound {
    //     uint96 datum;
    //     uint64 timeLastUpdated;
    //     uint32 posDelta;
    //     uint32 negDelta;
    //     uint32 rateLimit;
    // }

    // /**
    //  * @notice Returns a Curve asset virtual price bound
    //  */
    // mapping(address => VirtualPriceBound) public getVirtualPriceBound;

    // /**
    //  * @dev If ZERO is specified for an assets `rateLimit` this value is used instead.
    //  */
    // uint32 public constant DEFAULT_RATE_LIMIT = 1 days;

    // /**
    //  * @notice Chainlink Fast Gas Feed for ETH Mainnet.
    //  */
    // address public ETH_FAST_GAS_FEED = 0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C;

    // /**
    //  * @notice Allows owner to set a new gas feed.
    //  * @notice Can be set to zero address to skip gas check.
    //  */
    // function setGasFeed(address gasFeed) external onlyOwner {
    //     ETH_FAST_GAS_FEED = gasFeed;
    // }

    // /**
    //  * @notice Dictates how aggressive keepers are with updating Curve pool virtual price values.
    //  * @dev A larger `gasConstant` will raise the `gasPriceLimit`, while a smaller `gasConstant`
    //  *      will lower the `gasPriceLimit`.
    //  */
    // uint256 public gasConstant = 200e9;

    // /**
    //  * @notice Allows owner to set a new gas constant.
    //  */
    // function setGasConstant(uint256 newConstant) external onlyOwner {
    //     gasConstant = newConstant;
    // }

    // /**
    //  * @notice Dictates the minimum delta required for an upkeep.
    //  * @dev If the max delta found is less than this, then checkUpkeep returns false.
    //  */
    // uint256 public minDelta = 0.05e18;

    // /**
    //  * @notice Allows owner to set a new minimum delta.
    //  */
    // function setMinDelta(uint256 newMinDelta) external onlyOwner {
    //     minDelta = newMinDelta;
    // }

    // /**
    //  * @notice Stores all Curve Assets this contract prices, so Automation can loop through it.
    //  */
    // address[] public curveAssets;

    // /**
    //  * @notice Allows owner to update a Curve asset's virtual price parameters..
    //  */
    // function updateVirtualPriceBound(
    //     address _asset,
    //     uint32 _posDelta,
    //     uint32 _negDelta,
    //     uint32 _rateLimit
    // ) external onlyOwner {
    //     VirtualPriceBound storage vpBound = getVirtualPriceBound[_asset];
    //     vpBound.posDelta = _posDelta;
    //     vpBound.negDelta = _negDelta;
    //     vpBound.rateLimit = _rateLimit == 0 ? DEFAULT_RATE_LIMIT : _rateLimit;
    // }

    // /**
    //  * @notice Logic ran by Chainlink Automation to determine if virtual price bounds need to be updated.
    //  * @dev `checkData` should be a start and end value indicating where to start and end in the `curveAssets` array.
    //  * @dev The end index can be zero, or greater than the current length of `curveAssets`.
    //  *      Doing this makes end = curveAssets.length.
    //  * @dev `performData` is the target index in `curveAssets` that needs its bounds updated.
    //  */
    // function _checkVirtualPriceBound(
    //     bytes memory checkData
    // ) internal view returns (bool upkeepNeeded, bytes memory performData) {
    //     // Decode checkData to get start and end index.
    //     (uint256 start, uint256 end) = abi.decode(checkData, (uint256, uint256));
    //     if (end == 0 || end > curveAssets.length) end = curveAssets.length;

    //     // Loop through all curve assets, and find the asset with the largest delta(the one that needs to be updated the most).
    //     uint256 maxDelta;
    //     uint256 targetIndex;
    //     for (uint256 i = start; i < end; ++i) {
    //         address asset = curveAssets[i];
    //         VirtualPriceBound memory vpBound = getVirtualPriceBound[asset];

    //         // Check to see if this virtual price was updated recently.
    //         if ((block.timestamp - vpBound.timeLastUpdated) < vpBound.rateLimit) continue;

    //         // Check current virtual price against upper and lower bounds to find the delta.
    //         uint256 currentVirtualPrice = ICurvePool(getAssetSettings[ERC20(asset)].source).get_virtual_price();
    //         currentVirtualPrice = currentVirtualPrice.changeDecimals(18, 8);
    //         uint256 delta;
    //         if (currentVirtualPrice > vpBound.datum) {
    //             uint256 upper = uint256(vpBound.datum).mulDivDown(vpBound.posDelta, 1e8);
    //             uint256 ceiling = upper - vpBound.datum;
    //             uint256 current = currentVirtualPrice - vpBound.datum;
    //             delta = _getDelta(ceiling, current);
    //         } else {
    //             uint256 lower = uint256(vpBound.datum).mulDivDown(vpBound.negDelta, 1e8);
    //             uint256 ceiling = vpBound.datum - lower;
    //             uint256 current = vpBound.datum - currentVirtualPrice;
    //             delta = _getDelta(ceiling, current);
    //         }
    //         // Save the largest delta for the upkeep.
    //         if (delta > maxDelta) {
    //             maxDelta = delta;
    //             targetIndex = i;
    //         }
    //     }

    //     // If the largest delta must be greater/equal to `minDelta` to continue.
    //     if (maxDelta >= minDelta) {
    //         // If gas feed is not set, skip the gas check.
    //         if (ETH_FAST_GAS_FEED == address(0)) {
    //             // No Gas Check needed.
    //             upkeepNeeded = true;
    //             performData = abi.encode(targetIndex);
    //         } else {
    //             // Run a gas check to determine if it makes sense to update the target curve asset.
    //             uint256 gasPriceLimit = gasConstant.mulDivDown(maxDelta ** 3, 1e54); // 54 comes from 18 * 3.
    //             uint256 currentGasPrice = uint256(IChainlinkAggregator(ETH_FAST_GAS_FEED).latestAnswer());
    //             if (currentGasPrice <= gasPriceLimit) {
    //                 upkeepNeeded = true;
    //                 performData = abi.encode(targetIndex);
    //             }
    //         }
    //     }
    // }

    // /**
    //  * @notice Attempted to call a function only the Chainlink Registry can call.
    //  */
    // error PriceRouter__OnlyAutomationRegistry();

    // /**
    //  * @notice Attempted to update a virtual price too soon.
    //  */
    // error PriceRouter__VirtualPriceRateLimiter();

    // /**
    //  * @notice Attempted to update a virtual price bound that did not need to be updated.
    //  */
    // error PriceRouter__NothingToUpdate();

    // /**
    //  * @notice Chainlink's Automation Registry contract address.
    //  */
    // address public automationRegistry = 0x02777053d6764996e594c3E88AF1D58D5363a2e6;

    // /**
    //  * @notice Allows owner to update the Automation Registry.
    //  * @dev In rare cases, Chainlink's registry CAN change.
    //  */
    // function setAutomationRegistry(address newRegistry) external onlyOwner {
    //     automationRegistry = newRegistry;
    // }

    // /**
    //  * @notice Curve virtual price is susceptible to re-entrancy attacks, if the attacker adds/removes pool liquidity.
    //  *         To stop this we check the virtual price against logical bounds.
    //  * @dev Only the chainlink registry can call this function, so we know that Chainlink nodes will not be
    //  *      re-entering into the Curve pool, so it is safe to use the current on chain virtual price.
    //  * @notice Updating the virtual price is rate limited by `VirtualPriceBound.raetLimit` and can only be
    //  *         updated at most to the lower or upper bound of the current datum.
    //  *         This is intentional since curve pool price should not be volatile, and if they are, then
    //  *         we WANT that Curve LP pools TX pricing to revert.
    //  */
    // function _updateVirtualPriceBound(bytes memory performData) internal {
    //     // Make sure only the Automation Registry can call this function.
    //     if (msg.sender != automationRegistry) revert PriceRouter__OnlyAutomationRegistry();

    //     // Grab the target index from performData.
    //     uint256 index = abi.decode(performData, (uint256));
    //     address asset = curveAssets[index];
    //     VirtualPriceBound storage vpBound = getVirtualPriceBound[asset];

    //     // Enfore rate limit check.
    //     if ((block.timestamp - vpBound.timeLastUpdated) < vpBound.rateLimit)
    //         revert PriceRouter__VirtualPriceRateLimiter();

    //     // Determine what the new Datum should be.
    //     uint256 currentVirtualPrice = ICurvePool(getAssetSettings[ERC20(asset)].source).get_virtual_price();
    //     currentVirtualPrice = currentVirtualPrice.changeDecimals(18, 8);
    //     if (currentVirtualPrice > vpBound.datum) {
    //         uint256 upper = uint256(vpBound.datum).mulDivDown(vpBound.posDelta, 1e8);
    //         vpBound.datum = uint96(currentVirtualPrice > upper ? upper : currentVirtualPrice);
    //     } else if (currentVirtualPrice < vpBound.datum) {
    //         uint256 lower = uint256(vpBound.datum).mulDivDown(vpBound.negDelta, 1e8);
    //         vpBound.datum = uint96(currentVirtualPrice < lower ? lower : currentVirtualPrice);
    //     } else {
    //         revert PriceRouter__NothingToUpdate();
    //     }

    //     // Update the stored timestamp.
    //     vpBound.timeLastUpdated = uint64(block.timestamp);
    // }

    // /**
    //  * @notice Returns a percent delta representing where `current` is in reference to `ceiling`.
    //  * Example, if current == 0, this would return a 0.
    //  *          if current == ceiling, this would return a 1e18.
    //  *          if current == (ceiling) / 2, this would return 0.5e18.
    //  */
    // function _getDelta(uint256 ceiling, uint256 current) internal pure returns (uint256) {
    //     return current.mulDivDown(1e18, ceiling);
    // }

    // /**
    //  * @notice Attempted to price a curve asset that was below its logical minimum price.
    //  */
    // error PriceRouter__CurrentBelowLowerBound(uint256 current, uint256 lower);

    // /**
    //  * @notice Attempted to price a curve asset that was above its logical maximum price.
    //  */
    // error PriceRouter__CurrentAboveUpperBound(uint256 current, uint256 upper);

    // /**
    //  * @notice Enforces a logical price bound on Curve pool tokens.
    //  */
    // function _checkBounds(uint256 lower, uint256 upper, uint256 current) internal pure {
    //     if (current < lower) revert PriceRouter__CurrentBelowLowerBound(current, lower);
    //     if (current > upper) revert PriceRouter__CurrentAboveUpperBound(current, upper);
    // }

    // // =========================================== CURVE PRICE DERIVATIVE ===========================================

    // /**
    //  * @notice Setup function for pricing Curve derivative assets.
    //  * @dev _source The address of the Curve Pool.
    //  * @dev _storage A VirtualPriceBound value for this asset.
    //  * @dev Assumes that curve pools never add or remove tokens.
    //  */
    // function _setupPriceForCurveDerivative(ERC20 _asset, address _source, bytes memory _storage) internal {
    //     ICurvePool pool = ICurvePool(_source);
    //     uint8 coinsLength = 0;
    //     // Figure out how many tokens are in the curve pool.
    //     while (true) {
    //         try pool.coins(coinsLength) {
    //             coinsLength++;
    //         } catch {
    //             break;
    //         }
    //     }

    //     // Save the pools tokens to reduce gas for pricing calls.
    //     address[] memory coins = new address[](coinsLength);
    //     for (uint256 i = 0; i < coinsLength; ++i) {
    //         coins[i] = pool.coins(i);
    //     }

    //     getCurveDerivativeStorage[_asset] = coins;

    //     curveAssets.push(address(_asset));

    //     // Setup virtual price bound.
    //     VirtualPriceBound memory vpBound = abi.decode(_storage, (VirtualPriceBound));
    //     uint256 upper = uint256(vpBound.datum).mulDivDown(vpBound.posDelta, 1e8);
    //     upper = upper.changeDecimals(8, 18);
    //     uint256 lower = uint256(vpBound.datum).mulDivDown(vpBound.negDelta, 1e8);
    //     lower = lower.changeDecimals(8, 18);
    //     // _checkBounds(lower, upper, pool.get_virtual_price());
    //     if (vpBound.rateLimit == 0) vpBound.rateLimit = DEFAULT_RATE_LIMIT;
    //     vpBound.timeLastUpdated = uint64(block.timestamp);
    //     getVirtualPriceBound[address(_asset)] = vpBound;
    // }

    // /**
    //  * @notice Get the price of a CurveV1 derivative in terms of USD.
    //  */
    // function _getPriceForCurveDerivative(
    //     ERC20 asset,
    //     address _source,
    //     PriceCache[PRICE_CACHE_SIZE] memory cache
    // ) internal view returns (uint256 price) {
    //     ICurvePool pool = ICurvePool(_source);

    //     address[] memory coins = getCurveDerivativeStorage[asset];

    //     uint256 minPrice = type(uint256).max;
    //     for (uint256 i = 0; i < coins.length; ++i) {
    //         ERC20 poolAsset = ERC20(coins[i]);
    //         uint256 tokenPrice = _getPriceInUSD(poolAsset, getAssetSettings[poolAsset], cache);
    //         if (tokenPrice < minPrice) minPrice = tokenPrice;
    //     }

    //     if (minPrice == type(uint256).max) revert("Min price not found.");

    //     // Check that virtual price is within bounds.
    //     uint256 virtualPrice = pool.get_virtual_price();
    //     VirtualPriceBound memory vpBound = getVirtualPriceBound[address(asset)];
    //     uint256 upper = uint256(vpBound.datum).mulDivDown(vpBound.posDelta, 1e8);
    //     upper = upper.changeDecimals(8, 18);
    //     uint256 lower = uint256(vpBound.datum).mulDivDown(vpBound.negDelta, 1e8);
    //     lower = lower.changeDecimals(8, 18);
    //     _checkBounds(lower, upper, virtualPrice);

    //     // Virtual price is based off the Curve Token decimals.
    //     uint256 curveTokenDecimals = ERC20(asset).decimals();
    //     price = minPrice.mulDivDown(virtualPrice, 10 ** curveTokenDecimals);
    // }
}