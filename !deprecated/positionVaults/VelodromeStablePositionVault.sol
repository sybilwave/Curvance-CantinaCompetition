// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BasePositionVault, SafeTransferLib, ERC20, Math, ICentralRegistry } from "contracts/deposits/adaptors/BasePositionVault.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { VelodromeLib } from "contracts/market/zapper/protocols/VelodromeLib.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";
import { WAD } from "contracts/libraries/Constants.sol";

contract VelodromeStablePositionVault is BasePositionVault {
    using Math for uint256;

    /// TYPES ///

    struct StrategyData {
        IVeloGauge gauge; // Velodrome Gauge contract
        IVeloPairFactory pairFactory; // Velodrome Pair Factory contract
        IVeloRouter router; // Velodrome Router contract
        address token0; // LP first token address
        address token1; // LP second token address
        uint256 decimalsA; // token0 decimals
        uint256 decimalsB; // token1 decimals
    }

    /// CONSTANTS ///

    // Optimism VELO contract address
    ERC20 public constant rewardToken =
        ERC20(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);
    // Whether VELO is an underlying token of the pair
    bool public immutable rewardTokenIsUnderlying;

    /// STORAGE ///

    StrategyData public strategyData; // position vault packed configuration

    /// Token => underlying token of the sAMM LP or not
    mapping(address => bool) public isUnderlyingToken;

    /// EVENTS ///

    event Harvest(uint256 yield);

    /// ERRORS ///

    error VelodromeStablePositionVault__StakingTokenIsNotAsset(
        address stakingToken
    );
    error VelodromeStablePositionVault__AssetIsNotStable();
    error VelodromeStablePositionVault__SlippageError();
    error VelodromeStablePositionVault__InvalidSwapper(address invalidSwapper);

    /// CONSTRUCTOR ///

    constructor(
        ERC20 asset_,
        ICentralRegistry centralRegistry_,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router
    ) BasePositionVault(asset_, centralRegistry_) {
        // Cache assigned asset address
        address _asset = asset();
        // Validate that we have the proper gauge linked with the proper LP
        // and pair factory
        if (gauge.stakingToken() != _asset) {
            revert VelodromeStablePositionVault__StakingTokenIsNotAsset(
                gauge.stakingToken()
            );
        }

        if (!IVeloPool(_asset).stable()) {
            revert VelodromeStablePositionVault__AssetIsNotStable();
        }

        // Query underlying token data from the pool
        strategyData.token0 = IVeloPool(_asset).token0();
        strategyData.token1 = IVeloPool(_asset).token1();
        // make sure token0 is VELO if one of underlying tokens is VELO
        // so that it can be used properly in harvest function.
        if (strategyData.token1 == address(rewardToken)) {
            strategyData.token1 = strategyData.token0;
            strategyData.token0 = address(rewardToken);
        }
        strategyData.decimalsA = 10 ** ERC20(strategyData.token0).decimals();
        strategyData.decimalsB = 10 ** ERC20(strategyData.token1).decimals();

        strategyData.gauge = gauge;
        strategyData.router = router;
        strategyData.pairFactory = pairFactory;

        isUnderlyingToken[strategyData.token0] = true;
        isUnderlyingToken[strategyData.token1] = true;

        rewardTokenIsUnderlying = (address(rewardToken) ==
            strategyData.token0 ||
            address(rewardToken) == strategyData.token1);
    }

    /// PUBLIC FUNCTIONS ///

    // REWARD AND HARVESTING LOGIC

    /// @notice Harvests and compounds outstanding vault rewards
    ///         and vests pending rewards
    /// @dev Only callable by Gelato Network bot
    /// @param data Bytes array for aggregator swap data
    /// @return yield The amount of new assets acquired from compounding vault yield
    function harvest(
        bytes calldata data
    ) external override onlyHarvestor returns (uint256 yield) {
        if (_vaultIsActive == 1) {
            _revert(VAULT_NOT_ACTIVE_SELECTOR);
        }

        uint256 pending = _calculatePendingRewards();

        if (pending > 0) {
            // claim vested rewards
            _vestRewards(_totalAssets + pending);
        }

        // can only harvest once previous reward period is done
        if (_checkVestStatus(_vaultData)) {
            // cache strategy data
            StrategyData memory sd = strategyData;

            // claim velodrome rewards
            sd.gauge.getReward(address(this));

            {
                uint256 rewardAmount = rewardToken.balanceOf(address(this));
                if (rewardAmount > 0) {
                    // take protocol fee
                    uint256 protocolFee = rewardAmount.mulDivDown(
                        centralRegistry.protocolHarvestFee(),
                        1e18
                    );
                    rewardAmount -= protocolFee;
                    SafeTransferLib.safeTransfer(
                        address(rewardToken),
                        centralRegistry.feeAccumulator(),
                        protocolFee
                    );

                    // swap from VELO to underlying LP token if necessary
                    if (!rewardTokenIsUnderlying) {
                        SwapperLib.Swap memory swapData = abi.decode(
                            data,
                            (SwapperLib.Swap)
                        );

                        if (!centralRegistry.isSwapper(swapData.target)) {
                            revert VelodromeStablePositionVault__InvalidSwapper(
                                swapData.target
                            );
                        }

                        SwapperLib.swap(swapData);
                    }
                }
            }

            // token0 is VELO of one of underlying tokens is VELO
            // swap token0 to LP Token underlying tokens
            uint256 totalAmountA = ERC20(sd.token0).balanceOf(address(this));

            if (totalAmountA == 0) {
                revert VelodromeStablePositionVault__SlippageError();
            }

            // Cache asset so we don't need to pay gas multiple times
            address _asset = asset();
            (uint256 r0, uint256 r1, ) = IVeloPair(_asset).getReserves();
            (uint256 reserveA, uint256 reserveB) = sd.token0 ==
                IVeloPair(_asset).token0()
                ? (r0, r1)
                : (r1, r0);
            // Feed library pair factory, lpToken, and stable = true, plus calculated data
            uint256 swapAmount = VelodromeLib._optimalDeposit(
                address(sd.pairFactory),
                _asset,
                totalAmountA,
                reserveA,
                reserveB,
                sd.decimalsA,
                sd.decimalsB,
                true
            );
            // Query router and feed calculated data, and stable = true
            VelodromeLib._swapExactTokensForTokens(
                address(sd.router),
                _asset,
                sd.token0,
                sd.token1,
                swapAmount,
                true
            );
            totalAmountA -= swapAmount;

            // add liquidity to velodrome lp with stable params
            yield = VelodromeLib._addLiquidity(
                address(sd.router),
                sd.token0,
                sd.token1,
                true,
                totalAmountA,
                ERC20(sd.token1).balanceOf(address(this)), // totalAmountB
                VelodromeLib.VELODROME_ADD_LIQUIDITY_SLIPPAGE
            );

            // deposit assets into velodrome gauge
            _deposit(yield);

            // update vesting info
            // Cache vest period so we do not need to load it twice
            uint256 _vestPeriod = vestPeriod;
            _vaultData = _packVaultData(
                yield.mulDivDown(WAD, _vestPeriod),
                block.timestamp + _vestPeriod
            );

            emit Harvest(yield);
        }
        // else yield is zero
    }

    /// INTERNAL FUNCTIONS ///

    // INTERNAL POSITION LOGIC

    /// @notice Deposits specified amount of assets into velodrome gauge pool
    /// @param assets The amount of assets to deposit
    function _deposit(uint256 assets) internal override {
        IVeloGauge gauge = strategyData.gauge;
        SafeTransferLib.safeApprove(asset(), address(gauge), assets);
        gauge.deposit(assets);
    }

    /// @notice Withdraws specified amount of assets from velodrome gauge pool
    /// @param assets The amount of assets to withdraw
    function _withdraw(uint256 assets) internal override {
        strategyData.gauge.withdraw(assets);
    }

    /// @notice Gets the balance of assets inside velodrome gauge pool
    /// @return The current balance of assets
    function _getRealPositionBalance()
        internal
        view
        override
        returns (uint256)
    {
        return strategyData.gauge.balanceOf(address(this));
    }

    /// @notice pre calculation logic for migration start
    /// @param newVault The new vault address
    function _migrationStart(
        address newVault
    ) internal override returns (bytes memory) {
        // claim velodrome rewards
        strategyData.gauge.getReward(address(this));
        SafeTransferLib.safeApprove(
            address(rewardToken),
            newVault,
            type(uint256).max
        );
    }
}