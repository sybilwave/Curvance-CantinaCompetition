// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { ERC4626, SafeTransferLib, ERC20 } from "contracts/libraries/ERC4626.sol";
import { Math } from "contracts/libraries/Math.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { WAD } from "contracts/libraries/Constants.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev The position vaults run must be a LOSSLESS position, since totalAssets
///      is not actually using the balances stored in the position,
///      rather it only uses an internal balance.
abstract contract BasePositionVault is ERC4626, ReentrancyGuard {
    using Math for uint256;

    /// TYPES ///

    struct VaultData {
        uint128 rewardRate; // The rate that the vault vests fresh rewards
        uint64 vestingPeriodEnd; // When the current vesting period ends
        uint64 lastVestClaim; // Last time vesting rewards were claimed
    }

    /// CONSTANTS ///

    // Period harvested rewards are vested over
    uint256 public constant vestPeriod = 1 days;
    ERC20 private immutable _asset; // underlying asset for the vault
    bytes32 private immutable _name; // token name metadata
    bytes32 private immutable _symbol; // token symbol metadata
    uint8 private immutable _decimals; // vault assets decimals of precision
    ICentralRegistry public immutable centralRegistry; // Curvance DAO hub

    // `bytes4(keccak256(bytes("BasePositionVault__NotCToken()")))`
    uint256 internal constant NOT_C_TOKEN_SELECTOR = 0xac056953;
    // `bytes4(keccak256(bytes("BasePositionVault__VaultNotActive()")))`
    uint256 internal constant VAULT_NOT_ACTIVE_SELECTOR = 0xd4387e2b;
    // `bytes4(keccak256(bytes("BasePositionVault__VaultIsActive()")))`
    uint256 internal constant VAULT_IS_ACTIVE_SELECTOR = 0xa10a588e;

    // Mask of reward rate entry in packed vault data
    uint256 private constant _BITMASK_REWARD_RATE = (1 << 128) - 1;

    // Mask of a timestamp entry in packed vault data
    uint256 private constant _BITMASK_TIMESTAMP = (1 << 64) - 1;

    // Mask of all bits in packed vault data except the 64 bits for `lastVestClaim`
    uint256 private constant _BITMASK_LAST_CLAIM_COMPLEMENT = (1 << 192) - 1;

    // The bit position of `vestingPeriodEnd` in packed vault data
    uint256 private constant _BITPOS_VEST_END = 128;

    // The bit position of `lastVestClaim` in packed vault data
    uint256 private constant _BITPOS_LAST_VEST = 192;

    /// STORAGE ///

    address public cToken; // cToken tied to this position vault

    // Internal stored vault accounting
    // Bits Layout:
    // - [0..127]    `rewardRate`
    // - [128..191]  `vestingPeriodEnd`
    // - [192..255] `lastVestClaim`
    uint256 internal _vaultData; // Packed vault data
    uint256 internal _totalAssets; // total vault assets minus vesting
    uint256 internal _sharePriceHighWatermark; // incremented on reward vesting
    uint256 internal _vaultIsActive; // Vault Status: 2 = active; 0 or 1 = inactive

    /// EVENTS ///

    event vaultStatusChanged(bool isShutdown);

    /// ERRORS ///

    error BasePositionVault__Unauthorized();
    error BasePositionVault__InvalidCentralRegistry();
    error BasePositionVault__NotCToken();
    error BasePositionVault__VaultNotActive();
    error BasePositionVault__VaultIsActive();
    error BasePositionVault__ZeroShares();
    error BasePositionVault__ZeroAssets();

    /// MODIFIERS ///

    modifier onlyCToken() {
        if (cToken != msg.sender) {
            revert BasePositionVault__Unauthorized();
        }
        _;
    }

    modifier onlyHarvestor() {
        if (!centralRegistry.isHarvester(msg.sender)) {
            revert BasePositionVault__Unauthorized();
        }
        _;
    }

    modifier onlyDaoPermissions() {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert BasePositionVault__Unauthorized();
        }
        _;
    }

    modifier onlyElevatedPermissions() {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert BasePositionVault__Unauthorized();
        }
        _;
    }

    /// CONSTRUCTOR ///

    constructor(ERC20 asset_, ICentralRegistry centralRegistry_) {
        _asset = asset_;
        _name = bytes32(abi.encodePacked("Curvance ", asset_.name()));
        _symbol = bytes32(abi.encodePacked("cve", asset_.symbol()));
        _decimals = asset_.decimals();

        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert BasePositionVault__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns current position vault yield information in the form:
    ///         rewardRate: Yield per second in underlying asset
    ///         vestingPeriodEnd: When the current vesting period ends and a new harvest can execute
    ///         lastVestClaim: Last time pending vested yield was claimed
    function getVaultYieldStatus() external view returns (VaultData memory) {
        return _unpackedVaultData(_vaultData);
    }

    /// @notice Vault compound fee is in basis point form
    /// @dev Returns the vaults current amount of yield used
    ///      for compounding rewards
    ///      Used for frontend data query only
    function vaultCompoundFee() external view returns (uint256) {
        return centralRegistry.protocolCompoundFee();
    }

    /// @notice Vault yield fee is in basis point form
    /// @dev Returns the vaults current protocol fee for compounding rewards
    ///      Used for frontend data query only
    function vaultYieldFee() external view returns (uint256) {
        return centralRegistry.protocolYieldFee();
    }

    /// @notice Vault harvest fee is in basis point form
    /// @dev Returns the vaults current harvest fee for compounding rewards
    ///      that pays for yield and compound fees
    ///      Used for frontend data query only
    function vaultHarvestFee() external view returns (uint256) {
        return centralRegistry.protocolHarvestFee();
    }

    // PERMISSIONED FUNCTIONS

    /// @notice Initializes the vault and the cToken attached to it
    function initiateVault(address cTokenAddress) external onlyDaoPermissions {
        if (_vaultIsActive != 0) {
            _revert(VAULT_IS_ACTIVE_SELECTOR);
        }

        _activateVault(cTokenAddress);
    }

    /// @notice Shuts down the vault
    /// @dev Used in an emergency or if the vault has been deprecated
    function initiateShutdown() external onlyDaoPermissions {
        if (_vaultIsActive != 2) {
            _revert(VAULT_NOT_ACTIVE_SELECTOR);
        }

        _vaultIsActive = 1;

        emit vaultStatusChanged(true);
    }

    /// @notice Reactivate the vault
    /// @dev Allows for reconfiguration of cToken attached to vault
    function liftShutdown(
        address cTokenAddress
    ) external onlyElevatedPermissions {
        if (_vaultIsActive == 2) {
            _revert(VAULT_IS_ACTIVE_SELECTOR);
        }

        _activateVault(cTokenAddress);
    }

    // EXTERNAL POSITION LOGIC TO OVERRIDE

    function harvest(bytes calldata) external virtual returns (uint256 yield);

    /// PUBLIC FUNCTIONS ///

    // VAULT DATA QUERY FUNCTIONS

    /// @notice Returns the name of the token
    function name() public view override returns (string memory) {
        return string(abi.encodePacked(_name));
    }

    /// @notice Returns the symbol of the token
    function symbol() public view override returns (string memory) {
        return string(abi.encodePacked(_symbol));
    }

    /// @notice Returns the address of the underlying asset
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @notice Returns the position vaults current status
    function vaultStatus() public view returns (string memory) {
        return _vaultIsActive == 2 ? "Active" : "Inactive";
    }

    function maxDeposit(
        address to
    ) public view override returns (uint256 maxAssets) {
        maxAssets = _vaultIsActive == 2 ? super.maxDeposit(to) : 0;
    }

    function maxMint(
        address to
    ) public view override returns (uint256 maxShares) {
        maxShares = _vaultIsActive == 2 ? super.maxMint(to) : 0;
    }

    // DEPOSIT AND WITHDRAWAL LOGIC

    function deposit(
        uint256 assets,
        address receiver
    ) public override onlyCToken nonReentrant returns (uint256 shares) {
        if (_vaultIsActive == 1) {
            _revert(VAULT_NOT_ACTIVE_SELECTOR);
        }

        // Save _totalAssets and pendingRewards to memory
        uint256 pending = _calculatePendingRewards();
        uint256 ta = _totalAssets + pending;

        // Check for rounding error since we round down in previewDeposit
        if ((shares = _previewDeposit(assets, ta)) == 0) {
            revert BasePositionVault__ZeroShares();
        }

        // Need to transfer before minting or ERC777s could reenter
        SafeTransferLib.safeTransferFrom(
            asset(),
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // Add the users newly deposited assets
        unchecked {
            // We know that this will not overflow as rewards are part vested and assets added and hasnt overflown from those operations
            ta = ta + assets;
        }

        // If there are pending rewards to vest,
        // or if high watermark is not set, vestRewards
        if (pending > 0 || _sharePriceHighWatermark == 0) {
            _vestRewards(ta);
        } else {
            _totalAssets = ta;
        }

        _deposit(assets);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override onlyCToken nonReentrant returns (uint256 assets) {
        if (_vaultIsActive == 1) {
            _revert(VAULT_NOT_ACTIVE_SELECTOR);
        }

        // Save _totalAssets and pendingRewards to memory
        uint256 pending = _calculatePendingRewards();
        uint256 ta = _totalAssets + pending;

        // No need to check for rounding error, previewMint rounds up
        assets = _previewMint(shares, ta);

        // Need to transfer before minting or ERC777s could reenter
        SafeTransferLib.safeTransferFrom(
            asset(),
            msg.sender,
            address(this),
            assets
        );

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        // Add the users newly deposited assets
        unchecked {
            // We know that this will not overflow as rewards are part vested and assets added and hasnt overflown from those operations
            ta = ta + assets;
        }

        // If there are pending rewards to vest,
        // or if high watermark is not set, vestRewards.
        if (pending > 0 || _sharePriceHighWatermark == 0) {
            _vestRewards(ta);
        } else {
            _totalAssets = ta;
        }

        _deposit(assets);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlyCToken nonReentrant returns (uint256 shares) {
        // Save _totalAssets and pendingRewards to memory
        uint256 pending = _calculatePendingRewards();
        uint256 ta = _totalAssets + pending;

        // No need to check for rounding error, previewWithdraw rounds up
        shares = _previewWithdraw(assets, ta);

        /// We do not need to check for msg.sender == owner or msg.sender != owner
        /// since CToken is the only contract who can call deposit, mint, withdraw, or redeem
        /// We just keep owner parameter for 4626 compliance

        // Remove the users withdrawn assets
        ta = ta - assets;

        // If there are pending rewards to vest,
        // or if high watermark is not set, vestRewards
        if (pending > 0 || _sharePriceHighWatermark == 0) {
            _vestRewards(ta);
        } else {
            _totalAssets = ta;
        }

        _withdraw(assets);
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        SafeTransferLib.safeTransfer(asset(), receiver, assets);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlyCToken nonReentrant returns (uint256 assets) {
        // Save _totalAssets and pendingRewards to memory
        uint256 pending = _calculatePendingRewards();
        uint256 ta = _totalAssets + pending;

        // We do not need to check for msg.sender == owner or msg.sender != owner
        // since CToken is the only contract who can call deposit, mint, withdraw, or redeem
        // We just keep owner parameter for 4626 compliance

        // Check for rounding error since we round down in previewRedeem
        if ((assets = _previewRedeem(shares, ta)) == 0) {
            revert BasePositionVault__ZeroAssets();
        }

        // Remove the users withdrawn assets
        ta = ta - assets;

        // If there are pending rewards to vest,
        // or if high watermark is not set, vestRewards
        if (pending > 0 || _sharePriceHighWatermark == 0) {
            _vestRewards(ta);
        } else {
            _totalAssets = ta;
        }

        _withdraw(assets);
        _burn(owner, shares);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        SafeTransferLib.safeTransfer(asset(), receiver, assets);
    }

    function _migrationStart(
        address
    ) internal virtual returns (bytes memory data) {}

    function _migrationConfirm(address, bytes memory) internal virtual {}

    function migrateStart(
        address newVault
    ) public onlyCToken nonReentrant returns (bytes memory) {
        bytes memory data = _migrationStart(newVault);

        // withdraw all assets (including pending rewards)
        uint256 assets = _getRealPositionBalance();
        uint256 shares = balanceOf(msg.sender);
        _withdraw(assets);

        SafeTransferLib.safeTransfer(asset(), newVault, assets);

        // Record current vault data to move over
        return
            abi.encode(
                _totalAssets,
                _sharePriceHighWatermark,
                _vaultData,
                shares,
                data
            );
    }

    /// @notice migrate confirm function
    /// @dev this function can be upgraded on new vault contract
    function migrateConfirm(
        address oldVault,
        bytes memory params
    ) public onlyCToken nonReentrant {
        uint256 shares;
        bytes memory data;
        (
            _totalAssets,
            _sharePriceHighWatermark,
            _vaultData,
            shares,
            data
        ) = abi.decode(params, (uint256, uint256, uint256, uint256, bytes));

        _mint(msg.sender, shares);

        _migrationConfirm(oldVault, data);

        // deposit all assets (including pending rewards)
        _deposit(_asset.balanceOf(address(this)));
    }

    // ACCOUNTING LOGIC

    /// @notice Returns the current per second yield of the vault
    function rewardRate() public view returns (uint256) {
        return _vaultData & _BITMASK_REWARD_RATE;
    }

    /// @notice Returns the timestamp when the current vesting period ends
    function vestingPeriodEnd() public view returns (uint256) {
        return (_vaultData >> _BITPOS_VEST_END) & _BITMASK_TIMESTAMP;
    }

    /// @notice Returns the timestamp of the last claim during the current vesting period
    function lastVestClaim() public view returns (uint256) {
        return uint64(_vaultData >> _BITPOS_LAST_VEST);
    }

    function totalAssetsSafe() public nonReentrant returns (uint256) {
        // Returns stored internal balance + pending rewards that are vested.
        // Has added re-entry lock for protocols building ontop of us to have confidence in data quality
        return _totalAssets + _calculatePendingRewards();
    }

    function totalAssets() public view override returns (uint256) {
        // Returns stored internal balance + pending rewards that are vested.
        return _totalAssets + _calculatePendingRewards();
    }

    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToShares(assets, totalAssets());
    }

    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {
        return _convertToAssets(shares, totalAssets());
    }

    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        return _previewMint(shares, totalAssets());
    }

    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        return _previewWithdraw(assets, totalAssets());
    }

    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Packs parameters together with current block timestamp to calculate the new packed vault data value
    /// @param newRewardRate The new rate per second that the vault vests fresh rewards
    /// @param newVestPeriod The timestamp of when the new vesting period ends, which is block.timestamp + vestPeriod
    function _packVaultData(
        uint256 newRewardRate,
        uint256 newVestPeriod
    ) internal view returns (uint256 result) {
        assembly {
            // Mask `newRewardRate` to the lower 128 bits, in case the upper bits somehow aren't clean
            newRewardRate := and(newRewardRate, _BITMASK_REWARD_RATE)
            // `newRewardRate | (newVestPeriod << _BITPOS_VEST_END) | block.timestamp`
            result := or(
                newRewardRate,
                or(
                    shl(_BITPOS_VEST_END, newVestPeriod),
                    shl(_BITPOS_LAST_VEST, timestamp())
                )
            )
        }
    }

    /// @notice Returns the unpacked `VaultData` struct from `packedVaultData`
    /// @param packedVaultData The current packed vault data value
    /// @return vault Current vault data value but unpacked into a VaultData struct
    function _unpackedVaultData(
        uint256 packedVaultData
    ) internal pure returns (VaultData memory vault) {
        vault.rewardRate = uint128(packedVaultData);
        vault.vestingPeriodEnd = uint64(packedVaultData >> _BITPOS_VEST_END);
        vault.lastVestClaim = uint64(packedVaultData >> _BITPOS_LAST_VEST);
    }

    /// @notice Returns whether the current vesting period has ended based on the last vest timestamp
    /// @param packedVaultData Current packed vault data value
    function _checkVestStatus(
        uint256 packedVaultData
    ) internal pure returns (bool) {
        return
            uint64(packedVaultData >> _BITPOS_LAST_VEST) >=
            uint64(packedVaultData >> _BITPOS_VEST_END);
    }

    /// @notice Sets the last vest claim data for the vault
    /// @param newVestClaim The new timestamp to record as the last vesting claim
    function _setlastVestClaim(uint64 newVestClaim) internal {
        uint256 packedVaultData = _vaultData;
        uint256 lastVestClaimCasted;
        // Cast `newVestClaim` with assembly to avoid redundant masking
        assembly {
            lastVestClaimCasted := newVestClaim
        }
        packedVaultData =
            (packedVaultData & _BITMASK_LAST_CLAIM_COMPLEMENT) |
            (lastVestClaimCasted << _BITPOS_LAST_VEST);
        _vaultData = packedVaultData;
    }

    /// @dev Returns the decimals of the underlying asset
    function _underlyingDecimals() internal view override returns (uint8) {
        return _decimals;
    }

    function _activateVault(address cTokenAddress) internal {
        if (!IMToken(cTokenAddress).isCToken()) {
            _revert(NOT_C_TOKEN_SELECTOR);
        }

        cToken = cTokenAddress;
        _vaultIsActive = 2;

        emit vaultStatusChanged(false);
    }

    // REWARD AND HARVESTING LOGIC

    /// @notice Calculates the pending rewards
    /// @dev If there are no pending rewards or the vesting period has ended,
    ///      it returns 0
    /// @return pendingRewards The calculated pending rewards
    function _calculatePendingRewards()
        internal
        view
        returns (uint256 pendingRewards)
    {
        VaultData memory vaultData = _unpackedVaultData(_vaultData);
        if (
            vaultData.rewardRate > 0 &&
            vaultData.lastVestClaim < vaultData.vestingPeriodEnd
        ) {
            // If the vesting period has not ended:
            // pendingRewards = rewardRate * (block.timestamp - lastTimeVestClaimed)
            // If the vesting period has ended:
            // rewardRate * (vestingPeriodEnd - lastTimeVestClaimed))
            // Divide the pending rewards by WAD
            pendingRewards =
                (
                    block.timestamp < vaultData.vestingPeriodEnd
                        ? (vaultData.rewardRate *
                            (block.timestamp - vaultData.lastVestClaim))
                        : (vaultData.rewardRate *
                            (vaultData.vestingPeriodEnd -
                                vaultData.lastVestClaim))
                ) /
                WAD;
        }
        // else there are no pending rewards
    }

    /// @notice Vests the pending rewards, updates vault data
    ///         and share price high watermark
    /// @param currentAssets The current assets of the vault
    function _vestRewards(uint256 currentAssets) internal {
        // Update the lastVestClaim timestamp
        _setlastVestClaim(uint64(block.timestamp));

        // Set internal balance equal to totalAssets value
        _totalAssets = currentAssets;

        // Update share price high watermark since rewards have been vested.
        _sharePriceHighWatermark = _convertToAssets(
            10 ** _decimals,
            currentAssets
        );
    }

    function _convertToShares(
        uint256 assets,
        uint256 _ta
    ) internal view returns (uint256 shares) {
        uint256 totalShares = totalSupply();

        shares = totalShares == 0
            ? assets
            : assets.mulDivDown(totalShares, _ta);
    }

    function _convertToAssets(
        uint256 shares,
        uint256 _ta
    ) internal view returns (uint256 assets) {
        uint256 totalShares = totalSupply();

        assets = totalShares == 0
            ? shares
            : shares.mulDivDown(_ta, totalShares);
    }

    function _previewDeposit(
        uint256 assets,
        uint256 _ta
    ) internal view returns (uint256) {
        return _convertToShares(assets, _ta);
    }

    function _previewMint(
        uint256 shares,
        uint256 _ta
    ) internal view returns (uint256 assets) {
        uint256 totalShares = totalSupply();

        assets = totalShares == 0 ? shares : shares.mulDivUp(_ta, totalShares);
    }

    function _previewWithdraw(
        uint256 assets,
        uint256 _ta
    ) internal view returns (uint256 shares) {
        uint256 totalShares = totalSupply();

        shares = totalShares == 0 ? assets : assets.mulDivUp(totalShares, _ta);
    }

    function _previewRedeem(
        uint256 shares,
        uint256 _ta
    ) internal view returns (uint256) {
        return _convertToAssets(shares, _ta);
    }

    /// INTERNAL POSITION LOGIC TO OVERRIDE

    function _deposit(uint256 assets) internal virtual;

    function _withdraw(uint256 assets) internal virtual;

    function _getRealPositionBalance() internal view virtual returns (uint256);
}