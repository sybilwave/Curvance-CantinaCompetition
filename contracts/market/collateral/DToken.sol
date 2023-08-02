// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { ERC165 } from "contracts/libraries/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";
import { GaugePool } from "contracts/gauge/GaugePool.sol";
import { InterestRateModel } from "contracts/market/interestRates/InterestRateModel.sol";

import { ILendtroller } from "contracts/interfaces/market/ILendtroller.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPositionFolding } from "contracts/interfaces/market/IPositionFolding.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMToken, accountSnapshot } from "contracts/interfaces/market/IMToken.sol";

/// @title Curvance's Debt Token Contract
contract DToken is ERC165, ReentrancyGuard {
    
    /// TYPES ///

    /// @notice Container for borrow balance information
    /// @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
    /// @member interestIndex Global borrowIndex as of the most recent balance-changing action
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    /// CONSTANTS ///

    uint256 internal constant expScale = 1e18;

    // Maximum borrow rate that can ever be applied (.0005% / second)
    uint256 internal constant borrowRateMaxScaled = 0.0005e16;

    // Maximum fraction of interest that can be set aside for reserves
    uint256 internal constant reserveFactorMaxScaled = 1e18;

    /// @notice Indicator that this is a DToken contract (for inspection)
    bool public constant isDToken = true;

    /// @notice Underlying asset for this DToken
    address public immutable underlying;

    /// @notice Decimals for this DToken
    uint8 public immutable decimals;

    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///
    string public name;
    string public symbol;
    ILendtroller public lendtroller;
    InterestRateModel public interestRateModel;
    /// Initial exchange rate used when minting the first DTokens (used when totalSupply = 0)
    uint256 internal initialExchangeRateScaled;
    /// @notice Fraction of interest currently set aside for reserves
    uint256 public reserveFactorScaled;
    /// @notice Timestamp that interest was last accrued at
    uint256 public accrualBlockTimestamp;
    /// @notice Accumulator of the total earned interest rate since the opening of the market
    uint256 public borrowIndex;
    /// @notice Total amount of outstanding borrows of the underlying in this market
    uint256 public totalBorrows;
    /// @notice Total amount of reserves of the underlying held in this market
    uint256 public totalReserves;
    /// @notice Total number of tokens in circulation
    uint256 public totalSupply;

    // @notice account => token balance
    mapping(address => uint256) internal _accountBalance;

    // @notice account => spender => approved amount
    mapping(address => mapping(address => uint256))
        internal transferAllowances;

    // @notice account => BorrowSnapshot (Principal Borrowed, User Interest Index)
    mapping(address => BorrowSnapshot) internal accountBorrows;

    /// EVENTS ///

    /// @notice Event emitted when interest is accrued
    event AccrueInterest(
        uint256 cashPrior,
        uint256 interestAccumulated,
        uint256 borrowIndex,
        uint256 totalBorrows
    );

    /// @notice Event emitted when tokens are minted
    event Mint(
        address user,
        uint256 mintAmount,
        uint256 mintTokens,
        address minter
    );

    /// @notice Event emitted when tokens are redeemed
    event Redeem(address redeemer, uint256 redeemAmount, uint256 redeemTokens);

    /// @notice Event emitted when underlying is borrowed
    event Borrow(
        address borrower,
        uint256 borrowAmount
    );

    /// @notice Event emitted when a borrow is repaid
    event Repay(
        address payer,
        address borrower,
        uint256 repayAmount
    );

    /// @notice Event emitted when a borrow is liquidated
    event Liquidated(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        address cTokenCollateral,
        uint256 seizeTokens
    );

    /// ADMIN EVENTS ///

    /// @notice Event emitted when lendtroller is changed
    event NewLendtroller(
        ILendtroller oldLendtroller,
        ILendtroller newLendtroller
    );

    /// @notice Event emitted when interestRateModel is changed
    event NewMarketInterestRateModel(
        InterestRateModel oldInterestRateModel,
        InterestRateModel newInterestRateModel
    );

    /// @notice Event emitted when the reserve factor is changed
    event NewReserveFactor(
        uint256 oldReserveFactorScaled,
        uint256 newReserveFactorScaled
    );

    /// @notice Event emitted when the reserves are added
    event ReservesAdded(
        address benefactor,
        uint256 addAmount,
        uint256 newTotalReserves
    );

    /// @notice Event emitted when the reserves are reduced
    event ReservesReduced(
        address admin,
        uint256 reduceAmount,
        uint256 newTotalReserves
    );

    /// @notice EIP20 Transfer event
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice EIP20 Approval event
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    /// Errors ///

    error DToken_InvalidSeizeTokenType();
    error InvalidUnderlying();
    error TransferFailure();
    error ActionFailure();
    error AddressUnauthorized();
    error FailedNotFromPositionFolding();
    error FailedFreshnessCheck();
    error CannotEqualZero();
    error ExcessiveValue();
    error TransferNotAllowed();
    error PreviouslyInitialized();
    error RedeemTransferOutNotPossible();
    error BorrowCashNotAvailable();
    error SelfLiquidationNotAllowed();
    error LendtrollerMismatch();
    error ValidationFailed();
    error ReduceReservesCashNotAvailable();
    error ReduceReservesCashValidation();

    /// MODIFIERS ///

    modifier onlyDaoPermissions() {
        require(
            centralRegistry.hasDaoPermissions(msg.sender),
            "DToken: UNAUTHORIZED"
        );
        _;
    }

    modifier onlyElevatedPermissions() {
        require(
            centralRegistry.hasElevatedPermissions(msg.sender),
            "DToken: UNAUTHORIZED"
        );
        _;
    }

    modifier interestUpdated() {
        require(
            accrualBlockTimestamp == block.timestamp, "DToken: Freshness check failed"
        );
        _;
    }

    /// @param centralRegistry_ The address of Curvances Central Registry
    /// @param underlying_ The address of the underlying asset
    /// @param lendtroller_ The address of the Lendtroller
    /// @param interestRateModel_ The address of the interest rate model
    /// @param initialExchangeRateScaled_ The initial exchange rate, scaled by 1e18
    constructor(
        ICentralRegistry centralRegistry_,
        address underlying_,
        address lendtroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateScaled_
    ) {

        if (initialExchangeRateScaled_ == 0) {
            revert CannotEqualZero();
        }

        // Set initial exchange rate
        initialExchangeRateScaled = initialExchangeRateScaled_;

        // Ensure that lendtroller parameter is a lendtroller
        if (!ILendtroller(lendtroller_).isLendtroller()) {
            revert LendtrollerMismatch();
        }

        // Set the lendtroller
        lendtroller = ILendtroller(lendtroller_);
        emit NewLendtroller(ILendtroller(address(0)), ILendtroller(lendtroller_));

        // Initialize timestamp and borrow index (timestamp mocks depend on lendtroller being set)
        accrualBlockTimestamp = block.timestamp;
        borrowIndex = expScale;

        // Ensure that interestRateModel_ parameter is an interest rate model
        if (!interestRateModel_.isInterestRateModel()) {
            revert ValidationFailed();
        }

        // Set Interest Rate Model
        interestRateModel = interestRateModel_;
        emit NewMarketInterestRateModel(
            InterestRateModel(address(0)),
            interestRateModel_
        );

        require(
            ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            ),
            "DToken: invalid central registry"
        );

        centralRegistry = centralRegistry_;
        underlying = underlying_;
        name = string(abi.encodePacked("Curvance interest bearing ", IERC20(underlying_).name()));
        symbol = string(abi.encodePacked("c", IERC20(underlying_).symbol()));
        decimals = IERC20(underlying_).decimals();

        // Sanity check underlying so that we know users will not need to mint anywhere close to balance cap
        require (IERC20(underlying).totalSupply() < type(uint208).max, "DToken: Underlying token assumptions not met");

    }

    /// @notice Transfer `amount` tokens from `msg.sender` to `to`
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return Whether or not the transfer succeeded
    function transfer(
        address to,
        uint256 amount
    ) external nonReentrant returns (bool) {
        transferTokens(msg.sender, msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from `from` to `to`
    /// @param from The address of the source account
    /// @param to The address of the destination account
    /// @param amount The number of tokens to transfer
    /// @return bool true = success
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external nonReentrant returns (bool) {
        transferTokens(msg.sender, from, to, amount);
        return true;
    }

    /// @notice Sender borrows assets from the protocol to their own address
    /// @param borrowAmount The amount of the underlying asset to borrow
    function borrow(uint256 borrowAmount) external nonReentrant {
        accrueInterest();

        // Reverts if borrow not allowed
        lendtroller.borrowAllowed(address(this), msg.sender, borrowAmount);

        _borrow(payable(msg.sender), borrowAmount, payable(msg.sender));
    }

    /// @notice Position folding contract will call this function
    /// @param user The user address
    /// @param borrowAmount The amount of the underlying asset to borrow
    function borrowForPositionFolding(
        address payable user,
        uint256 borrowAmount,
        bytes calldata params
    ) external nonReentrant {
        if (msg.sender != lendtroller.positionFolding()) {
            revert FailedNotFromPositionFolding();
        }

        accrueInterest();

        _borrow(user, borrowAmount, payable(msg.sender));

        IPositionFolding(msg.sender).onBorrow(
            address(this),
            user,
            borrowAmount,
            params
        );

        // Fail if position is not allowed, after position folding has re-invested
        lendtroller.borrowAllowed(address(this), user, 0);
    }

    /// @notice Sender repays their own borrow
    /// @param repayAmount The amount to repay, or 0 for the full outstanding amount
    function repay(uint256 repayAmount) external nonReentrant {
        accrueInterest();

        _repay(msg.sender, msg.sender, repayAmount);
    }

    function repayForPositionFolding(address user, uint256 repayAmount) external nonReentrant {

        if (msg.sender != lendtroller.positionFolding()) {
            revert FailedNotFromPositionFolding();
        }

        accrueInterest();

        _repay(msg.sender, user, repayAmount);
    }

    /// @notice Allows liquidation of a borrower's collateral,
    ///         Transferring the liquidated collateral to the liquidator
    /// @param borrower The address of the borrower to be liquidated
    /// @param repayAmount The amount of underlying asset the liquidator wishes to repay
    /// @param mTokenCollateral The market in which to seize collateral from the borrower
    function liquidateUser(
        address borrower,
        uint256 repayAmount,
        IMToken mTokenCollateral
    ) external nonReentrant {
        accrueInterest();

        _liquidateUser(
            msg.sender,
            borrower,
            repayAmount,
            mTokenCollateral
        );
    }

    /// @notice Sender redeems cTokens in exchange for the underlying asset
    /// @dev Accrues interest whether or not the operation succeeds, unless reverted
    /// @param tokensToRedeem The number of cTokens to redeem into underlying
    function redeem(uint256 tokensToRedeem) external nonReentrant {
        accrueInterest();

        _redeem(payable(msg.sender), tokensToRedeem, (exchangeRateStored() * tokensToRedeem) / expScale, payable(msg.sender));
    }

    /// @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
    /// @dev Accrues interest whether or not the operation succeeds, unless reverted
    /// @param redeemAmount The amount of underlying to redeem
    function redeemUnderlying(uint256 redeemAmount) external nonReentrant {
        accrueInterest();

        uint256 tokensToRedeem = (redeemAmount * expScale) / exchangeRateStored();

        // Fail if redeem not allowed
        lendtroller.redeemAllowed(address(this), msg.sender, tokensToRedeem);

        _redeem(payable(msg.sender), tokensToRedeem, redeemAmount, payable(msg.sender));
    }

    /// @notice Helper function for Position Folding contract to redeem underlying tokens
    /// @param user The user address
    /// @param tokensToRedeem The amount of the underlying asset to redeem
    function redeemUnderlyingForPositionFolding(
        address payable user,
        uint256 tokensToRedeem,
        bytes calldata params
    ) external nonReentrant {

        if (msg.sender != lendtroller.positionFolding()) {
            revert FailedNotFromPositionFolding();
        }

        accrueInterest();

        _redeem(user, (tokensToRedeem * expScale) / exchangeRateStored(), tokensToRedeem, payable(msg.sender));

        IPositionFolding(msg.sender).onRedeem(
            address(this),
            user,
            tokensToRedeem,
            params
        );

        // Fail if redeem not allowed, position folding has re-invested
        lendtroller.redeemAllowed(address(this), user, 0);
    }

    /// @notice Sender supplies assets into the market and receives cTokens in exchange
    /// @dev Accrues interest whether or not the operation succeeds, unless reverted
    /// @param mintAmount The amount of the underlying asset to supply
    /// @return bool true=success
    function mint(uint256 mintAmount) external nonReentrant returns (bool) {
        accrueInterest();

        _mint(msg.sender, msg.sender, mintAmount);
        return true;
    }

    /// @notice Sender supplies assets into the market and receives cTokens in exchange
    /// @dev Accrues interest whether or not the operation succeeds, unless reverted
    /// @param recipient The recipient address
    /// @param mintAmount The amount of the underlying asset to supply
    /// @return bool true=success
    function mintFor(
        uint256 mintAmount,
        address recipient
    ) external nonReentrant returns (bool) {
        accrueInterest();

        _mint(msg.sender, recipient, mintAmount);
        return true;
    }

    /// @notice The sender adds to reserves.
    /// @param addAmount The amount fo underlying token to add as reserves
    function depositReserves(uint256 addAmount) external nonReentrant onlyElevatedPermissions {
        accrueInterest();

        // We call doTransferIn for the caller and the addAmount
        // On success, the cToken holds an additional addAmount of cash.
        // it returns the amount actually transferred, in case of a fee.
        totalReserves = totalReserves + doTransferIn(msg.sender, addAmount);

        // emit ReservesAdded(msg.sender, actualAddAmount, totalReserves); /// changed to emit correct variable
        emit ReservesAdded(msg.sender, addAmount, totalReserves);
    }

    /// @notice Accrues interest and reduces reserves by transferring to admin
    /// @param reduceAmount Amount of reduction to reserves
    function withdrawReserves(
        uint256 reduceAmount
    ) external nonReentrant onlyElevatedPermissions {
        accrueInterest();

        // Make sure we have enough cash to cover withdrawal
        if (getCash() < reduceAmount) {
            revert ReduceReservesCashNotAvailable();
        }

        // Need underflow check to check if we have sufficient totalReserves
        totalReserves = totalReserves - reduceAmount;

        // Query current DAO operating address
        address payable daoAddress = payable(centralRegistry.daoAddress());

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(daoAddress, reduceAmount);

        emit ReservesReduced(daoAddress, reduceAmount, totalReserves);
    }

    /// @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
    ///
    /// Emits a {Approval} event.
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        transferAllowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    /// @dev Returns the amount of tokens that `spender` can spend on behalf of `owner`.
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /// Admin Functions

    /// @notice Rescue any token sent by mistake
    /// @param token The token to rescue.
    /// @param amount The amount of tokens to rescue.
    function rescueToken(
        address token,
        uint256 amount
    ) external onlyDaoPermissions {
        address daoOperator = centralRegistry.daoAddress();

        if (token == address(0)) {
            require(
                address(this).balance >= amount,
                "DToken: insufficient balance"
            );
            (bool success, ) = payable(daoOperator).call{ value: amount }("");
            require(success, "DToken: !successful");
        } else {
            require(token != underlying, "DToken: cannot withdraw underlying");
            require(
                IERC20(token).balanceOf(address(this)) >= amount,
                "DToken: insufficient balance"
            );
            SafeTransferLib.safeTransfer(token, daoOperator, amount);
        }
    }

    /// @notice Sets a new lendtroller for the market
    /// @dev Admin function to set a new lendtroller
    /// @param newLendtroller New lendtroller address
    function setLendtroller(
        ILendtroller newLendtroller
    ) external onlyElevatedPermissions {
        // Ensure we are switching to an actual lendtroller
        if (!newLendtroller.isLendtroller()) {
            revert LendtrollerMismatch();
        }

        // Cache the current lendtroller to save gas
        ILendtroller oldLendtroller = lendtroller;

        // Set new lendtroller
        lendtroller = newLendtroller;

        emit NewLendtroller(oldLendtroller, newLendtroller);
    }

    /// @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
    /// @dev Admin function to accrue interest and set a new reserve factor
    /// @param newReserveFactorScaled New reserve factor
    function setReserveFactor(
        uint256 newReserveFactorScaled
    ) external onlyElevatedPermissions {
        accrueInterest();
        
        // Check newReserveFactor ≤ maxReserveFactor
        if (newReserveFactorScaled > reserveFactorMaxScaled) {
            revert ExcessiveValue();
        }

        // Cache the current interest reserve factor to save gas
        uint256 oldReserveFactorScaled = reserveFactorScaled;

        // Set new reserver factor
        reserveFactorScaled = newReserveFactorScaled;

        emit NewReserveFactor(oldReserveFactorScaled, newReserveFactorScaled);
    }

    /// @notice accrues interest and updates the interest rate model
    /// @dev Admin function to accrue interest and update the interest rate model
    /// @param newInterestRateModel the new interest rate model to use
    function setInterestRateModel(
        InterestRateModel newInterestRateModel
    ) external onlyElevatedPermissions {
        accrueInterest();

        // Ensure we are switching to an actual Interest Rate Model
        if (!newInterestRateModel.isInterestRateModel()) {
            revert ValidationFailed();
        }
        
        // Cache the current interest rate model to save gas
        InterestRateModel oldInterestRateModel = interestRateModel;

        // Set new interest rate model
        interestRateModel = newInterestRateModel;

        emit NewMarketInterestRateModel(
            oldInterestRateModel,
            newInterestRateModel
        );
    }

    /// @notice Get the underlying balance of the `account`
    /// @dev This also accrues interest in a transaction
    /// @param account The address of the account to query
    /// @return The amount of underlying owned by `account`
    function balanceOfUnderlying(
        address account
    ) external returns (uint256) {
        return ((exchangeRateCurrent() * balanceOf(account)) / expScale);
    }

    /// @notice Get a snapshot of the account's balances, and the cached exchange rate
    /// @dev This is used by lendtroller to more efficiently perform liquidity checks.
    /// @param account Address of the account to snapshot
    /// @return tokenBalance
    /// @return borrowBalance
    /// @return exchangeRate scaled 1e18
    function getAccountSnapshot(
        address account
    ) external view returns (uint256, uint256, uint256) {
        return (
            balanceOf(account),
            borrowBalanceStored(account),
            exchangeRateStored()
        );
    }

    /// @notice Get a snapshot of the account's balances, and the cached exchange rate
    /// @dev This is used by lendtroller to more efficiently perform liquidity checks.
    /// @param account Address of the account to snapshot
    function getAccountSnapshotPacked(
        address account
    ) external view returns (accountSnapshot memory) {
        return (accountSnapshot({
            asset: IMToken(address(this)),
            mTokenBalance: balanceOf(account), 
            borrowBalance: 0, 
            exchangeRateScaled: exchangeRateStored()}));
    }

    /// @notice Returns the current per-second borrow interest rate for this dToken
    /// @return The borrow interest rate per second, scaled by 1e18
    function borrowRatePerSecond() external view returns (uint256) {
        return
            interestRateModel.getBorrowRate(
                getCash(),
                totalBorrows,
                totalReserves
            );
    }

    /// @notice Returns the current per-second supply interest rate for this dToken
    /// @return The supply interest rate per second, scaled by 1e18
    function supplyRatePerSecond() external view returns (uint256) {
        return
            interestRateModel.getSupplyRate(
                getCash(),
                totalBorrows,
                totalReserves,
                reserveFactorScaled
            );
    }

    /// @notice Returns the current total borrows plus accrued interest
    /// @return The total borrows with interest
    function totalBorrowsCurrent()
        external
        nonReentrant
        returns (uint256)
    {
        accrueInterest();
        return totalBorrows;
    }

    /// @notice Accrue interest to updated borrowIndex
    ///  and then calculate account's borrow balance using the updated borrowIndex
    /// @param account The address whose balance should be calculated after updating borrowIndex
    /// @return The calculated balance
    function borrowBalanceCurrent(
        address account
    ) external nonReentrant returns (uint256) {
        accrueInterest();
        return borrowBalanceStored(account);
    }

    /// @notice Get the token balance of the `account`
    /// @param account The address of the account to query
    /// @return balance The number of tokens owned by `account`
    // @dev Returns the balance of tokens for `account`
    function balanceOf(address account) public view returns (uint256) {
        return _accountBalance[account];
    }

    /// @notice Return the borrow balance of account based on stored data
    /// @param account The address whose balance should be calculated
    /// @return The calculated balance
    function borrowBalanceStored(
        address account
    ) public view returns (uint256) {
        // Get borrowBalance and borrowIndex
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        // If borrowBalance = 0 then borrowIndex is likely also 0.
        // Rather than failing the calculation with a division by 0, we immediately return 0 in this case.
        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        // Calculate new borrow balance using the interest index:
        // recentBorrowBalance = borrower.borrowBalance * market.borrowIndex / borrower.borrowIndex
        uint256 principalTimesIndex = borrowSnapshot.principal * borrowIndex;
        return principalTimesIndex / borrowSnapshot.interestIndex;
    }

    /// @notice Gets balance of this contract in terms of the underlying
    /// @dev This excludes changes in underlying token balance by the current transaction, if any
    /// @return The quantity of underlying tokens owned by this contract
    function getCash() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @notice Returns the type of Curvance token, 1 = Collateral, 0 = Debt
    function tokenType() public pure returns (uint256) {
        return 0;
    }

    /// @notice Returns gauge pool contract address
    /// @return gaugePool the gauge controller contract address
    function gaugePool() public view returns (address) {
        return lendtroller.gaugePool();
    }

    /// @notice Accrue interest then return the up-to-date exchange rate
    /// @return Calculated exchange rate scaled by 1e18
    function exchangeRateCurrent()
        public
        nonReentrant
        returns (uint256)
    {
        accrueInterest();
        return exchangeRateStored();
    }

    /// @notice Calculates the exchange rate from the underlying to the dToken
    /// @dev This function does not accrue interest before calculating the exchange rate
    /// @return Calculated exchange rate scaled by 1e18
    function exchangeRateStored() public view returns (uint256) {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // If there are no tokens minted:
            //  exchangeRate = initialExchangeRate
            return initialExchangeRateScaled;
        } else {
            // Otherwise:
            // exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
            uint256 cashPlusBorrowsMinusReserves = getCash() +
                totalBorrows -
                totalReserves;
            uint256 exchangeRate = (cashPlusBorrowsMinusReserves * expScale) /
                _totalSupply;

            return exchangeRate;
        }
    }

    /// @notice Applies accrued interest to total borrows and reserves
    /// @dev This calculates interest accrued from the last checkpointed second
    ///   up to the current second and writes new checkpoint to storage.
    function accrueInterest() public {
        // Pull last accrual timestamp from storage
        uint256 accrualBlockTimestampPrior = accrualBlockTimestamp;

        // If we are up to date there is no reason to continue
        if (accrualBlockTimestampPrior == block.timestamp) {
            return;
        }

        // Cache current values to save gas
        uint256 cashPrior = getCash();
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        // Calculate the current borrow interest rate
        uint256 borrowRateScaled = interestRateModel.getBorrowRate(
            cashPrior,
            borrowsPrior,
            reservesPrior
        );
        if (borrowRateMaxScaled < borrowRateScaled) {
            revert ExcessiveValue();
        }

        // Calculate the interest accumulated into borrows and reserves and the new index:
        // simpleInterestFactor = borrowRate * (block.timestamp - accrualBlockTimestampPrior)
        // interestAccumulated = simpleInterestFactor * totalBorrows
        // totalBorrowsNew = interestAccumulated + totalBorrows
        // borrowIndexNew = simpleInterestFactor * borrowIndex + borrowIndex

        uint256 simpleInterestFactor = borrowRateScaled * (block.timestamp -
            accrualBlockTimestampPrior);
        uint256 interestAccumulated = (simpleInterestFactor * borrowsPrior) /
            expScale;
        uint256 totalBorrowsNew = interestAccumulated + borrowsPrior;
        uint256 borrowIndexNew = ((simpleInterestFactor * borrowIndexPrior) /
            expScale) + borrowIndexPrior;

        // Update storage data
        accrualBlockTimestamp = block.timestamp;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        // totalReservesNew = interestAccumulated * reserveFactor + totalReserves
        totalReserves = ((reserveFactorScaled *
            interestAccumulated) / expScale) + reservesPrior;

        // We emit an AccrueInterest event
        emit AccrueInterest(
            cashPrior,
            interestAccumulated,
            borrowIndexNew,
            totalBorrowsNew
        );
    }

    /// @notice Transfer `tokens` tokens from `from` to `to` by `spender` internally
    /// @dev Called by both `transfer` and `transferFrom` internally
    /// @param spender The address of the account performing the transfer
    /// @param from The address of the source account
    /// @param to The address of the destination account
    /// @param tokens The number of tokens to transfer
    function transferTokens(
        address spender,
        address from,
        address to,
        uint256 tokens
    ) internal {
        
        // Do not allow self-transfers
        if (from == to) {
            revert TransferNotAllowed();
        }

        // Fails if transfer not allowed
        lendtroller.transferAllowed(address(this), from, to, tokens);

        // Get the allowance, if the spender is not the `from` address
        if (spender != from) {
            // Validate that spender has enough allowance for the transfer with underflow check
            transferAllowances[from][spender] -= tokens;
        }

        // Update token balances 
        _accountBalance[from] -= tokens;
        /// We know that from balance wont overflow due to totalSupply check in constructor and underflow check above
        unchecked {
            _accountBalance[to] += tokens;
        }
        
        // emit events on gauge pool
        GaugePool(gaugePool()).withdraw(address(this), from, tokens);
        GaugePool(gaugePool()).deposit(address(this), to, tokens);

        // We emit a Transfer event
        emit Transfer(from, to, tokens);
    }

    /// @notice User supplies assets into the market and receives dTokens in exchange
    /// @dev Assumes interest has already been accrued up to the current timestamp
    /// @param user The address of the account which is supplying the assets
    /// @param recipient The address of the account which will receive dToken
    /// @param mintAmount The amount of the underlying asset to supply
    function _mint(
        address user,
        address recipient,
        uint256 mintAmount   
    ) internal interestUpdated {
        // Fail if mint not allowed
        lendtroller.mintAllowed(address(this), recipient); //, mintAmount);

        // The function returns the amount actually transferred,
        // in case of a fee. On success, the dToken holds an additional `actualMintAmount` of cash.
        uint256 actualMintAmount = doTransferIn(user, mintAmount);

        // We get the current exchange rate and calculate the number of dTokens to be minted:
        //  mintTokens = actualMintAmount / exchangeRate
        uint256 mintTokens = (actualMintAmount * expScale) / exchangeRateStored();
        totalSupply += mintTokens;

        /// Calculate their new balance
        _accountBalance[recipient] += mintTokens;

        // emit events on gauge pool
        GaugePool(gaugePool()).deposit(address(this), recipient, mintTokens);

        // We emit a Mint event, and a Transfer event
        emit Mint(user, actualMintAmount, mintTokens, recipient);
        emit Transfer(address(this), recipient, mintTokens);
    }

    /// @notice User redeems dTokens in exchange for the underlying asset
    /// @dev Assumes interest has already been accrued up to the current timestamp
    /// @param redeemer The address of the account which is redeeming the tokens
    /// @param redeemTokens The number of dTokens to redeem into underlying
    /// @param redeemAmount The number of underlying tokens to receive from redeeming dTokens
    /// @param recipient The recipient address
    function _redeem(
        address payable redeemer,
        uint256 redeemTokens,
        uint256 redeemAmount,
        address payable recipient
    ) internal interestUpdated {

        // Check if we have enough cash to support the redeem
        if (getCash() < redeemAmount) {
            revert RedeemTransferOutNotPossible();
        }

        _accountBalance[redeemer] -= redeemTokens;
        // We have user underflow check above so we do not need a redundant check here
        unchecked {
            totalSupply -= redeemTokens;
        }
        
        // emit events on gauge pool
        GaugePool(gaugePool()).withdraw(address(this), redeemer, redeemTokens);

        // We invoke doTransferOut for the redeemer and the redeemAmount.
        // On success, the dToken has redeemAmount less of cash.
        doTransferOut(recipient, redeemAmount);

        // We emit a Transfer event, and a Redeem event
        emit Transfer(redeemer, address(this), redeemTokens);
        emit Redeem(redeemer, redeemAmount, redeemTokens);

        // We call the defense hook
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert CannotEqualZero();
        }
    }

    /// @notice Users borrow assets from the protocol to their own address
    /// @param borrowAmount The amount of the underlying asset to borrow
    function _borrow(
        address borrower,
        uint256 borrowAmount,
        address payable recipient
    ) internal interestUpdated {

        // Check if we have enough cash to support the borrow
        if (getCash() < borrowAmount) {
            revert BorrowCashNotAvailable();
        }

        // Record that a user borrowed before everything else is updated
        lendtroller.notifyAccountBorrow(borrower);
        // We calculate the new borrower and total borrow balances, failing on overflow:
        accountBorrows[borrower].principal = borrowBalanceStored(borrower) + borrowAmount;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows += borrowAmount;

        // doTransferOut reverts if anything goes wrong, since we can't be sure if side effects occurred.
        doTransferOut(recipient, borrowAmount);

        // We emit a Borrow event
        emit Borrow(
            borrower,
            borrowAmount
        );
    }

    /// @notice Allows a payer to repay a loan on behalf of the borrower, usually themselves
    /// @dev First validates that the payer is allowed to repay the loan, then repays
    ///      the loan by transferring in the repay amount. Emits a repay event on
    ///      successful repayment.
    /// @param payer The address paying off the borrow
    /// @param borrower The account with the debt being paid off
    /// @param repayAmount The amount the payer wishes to repay, or 0 for the full outstanding amount
    /// @return actualRepayAmount The actual amount repaid
    function _repay(
        address payer,
        address borrower,
        uint256 repayAmount
    ) internal interestUpdated returns (uint256) {
        // Validate that the payer is allowed to repay the loan
        lendtroller.repayAllowed(address(this), borrower);

        // Cache how much the borrower has to save gas
        uint256 accountBorrowsPrev = borrowBalanceStored(borrower);

        // If repayAmount == uint max, repayAmount = accountBorrows
        uint256 repayAmountFinal = repayAmount == 0
            ? accountBorrowsPrev
            : repayAmount;

        // We call doTransferIn for the payer and the repayAmount
        // Note: On success, the dToken holds an additional repayAmount of cash.
        //       it returns the amount actually transferred, in case of a fee.
        uint256 actualRepayAmount = doTransferIn(payer, repayAmountFinal);

        // We calculate the new borrower and total borrow balances, failing on underflow:
        accountBorrows[borrower].principal = accountBorrowsPrev - actualRepayAmount;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows -= actualRepayAmount;

        // We emit a Repay event
        emit Repay(
            payer,
            borrower,
            actualRepayAmount
        );

        return actualRepayAmount;
    }

    /// @notice The liquidator liquidates the borrowers collateral.
    ///  The collateral seized is transferred to the liquidator.
    /// @param borrower The borrower of this dToken to be liquidated
    /// @param liquidator The address repaying the borrow and seizing collateral
    /// @param mTokenCollateral The market in which to seize collateral from the borrower
    /// @param repayAmount The amount of the underlying borrowed asset to repay
    function _liquidateUser(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        IMToken mTokenCollateral
    ) internal interestUpdated {

        // Fail if borrower = liquidator
        if (borrower == liquidator) {
            revert SelfLiquidationNotAllowed();
        }

        /// The MToken must be a collateral token E.G. tokenType == 1
        if (mTokenCollateral.tokenType() < 1) {
            revert DToken_InvalidSeizeTokenType();
        }

        // Fail if liquidate not allowed, 
        // trying to pay down too much with excessive repayAmount will revert here
        lendtroller.liquidateUserAllowed(
            address(this),
            address(mTokenCollateral),
            borrower,
            repayAmount
        );

        // Verify cTokenCollateral market's interest timestamp is up to date as well
        // if (mTokenCollateral.accrualBlockTimestamp() != block.timestamp) {
        //     revert FailedFreshnessCheck();
        // }

        // Fail if repay fails
        uint256 actualRepayAmount = _repay(
            liquidator,
            borrower,
            repayAmount
        );

        // We calculate the number of collateral tokens that will be seized
        uint256 seizeTokens = lendtroller.liquidateCalculateSeizeTokens(
            address(this),
            address(mTokenCollateral),
            actualRepayAmount
        );

        // Revert if borrower collateral token balance < seizeTokens
        if (mTokenCollateral.balanceOf(borrower) < seizeTokens) {
            revert ExcessiveValue();
        }

        // We check above that the mToken must be a collateral token, 
        // so we cant be seizing this mToken as it is a debt token, 
        // so there is no reEntry risk
        mTokenCollateral.seize(liquidator, borrower, seizeTokens);

        // We emit a Liquidated event
        emit Liquidated(
            liquidator,
            borrower,
            actualRepayAmount,
            address(mTokenCollateral),
            seizeTokens
        );
    }

    /// @notice Handles incoming token transfers and notifies the amount received
    /// @dev This function uses the SafeTransferLib to safely perform the transfer. It doesn't support tokens with a transfer tax.
    /// @param from Address of the sender of the tokens
    /// @param amount Amount of tokens to transfer in
    /// @return Returns the amount transferred
    function doTransferIn(
        address from,
        uint256 amount
    ) internal returns (uint256) {

        /// SafeTransferLib will handle reversion from insufficient balance or allowance
        /// Note this will not support tokens with a transfer tax, which should not exist on a underlying asset anyway
        SafeTransferLib.safeTransferFrom(
            underlying,
            from,
            address(this),
            amount
        );

        return amount;
    }

    /// @notice Handles outgoing token transfers
    /// @dev This function uses the SafeTransferLib to safely perform the transfer.
    /// @param to Address receiving the token transfer 
    /// @param amount Amount of tokens to transfer out
    function doTransferOut(
        address to,
        uint256 amount
    ) internal {

        /// SafeTransferLib will handle reversion from insufficient cash held
        SafeTransferLib.safeTransfer(
            underlying,
            to,
            amount
        );

    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IMToken).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
