// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";
import { CErc20 } from "contracts/market/collateral/CErc20.sol";
import { CEther } from "contracts/market/collateral/CEther.sol";
import { CToken } from "contracts/market/collateral/CToken.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IPriceRouter } from "contracts/interfaces/IPriceRouter.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { ILendtroller } from "contracts/interfaces/market/ILendtroller.sol";
import { IPositionFolding } from "contracts/interfaces/market/IPositionFolding.sol";

contract PositionFolding is ReentrancyGuard, IPositionFolding {
    /// TYPES ///

    struct LeverageStruct {
        CToken borrowToken;
        uint256 borrowAmount;
        CToken collateralToken;
        // borrow underlying -> zapper input token
        SwapperLib.Swap swapData;
        // zapper input token -> enter curvance
        SwapperLib.ZapperCall zapperCall;
    }

    struct DeleverageStruct {
        CToken collateralToken;
        uint256 collateralAmount;
        CToken borrowToken;
        // collateral underlying to a single token (can be borrow underlying)
        SwapperLib.ZapperCall zapperCall;
        // (optional) zapper outout to borrow underlying
        SwapperLib.Swap swapData;
        uint256 repayAmount;
    }

    /// CONSTANTS ///

    uint256 public constant MAX_LEVERAGE = 9900; // 0.99
    uint256 public constant DENOMINATOR = 10000;
    uint256 public constant SLIPPAGE = 500;

    ICentralRegistry public immutable centralRegistry;
    ILendtroller public immutable lendtroller;
    address public immutable cether;
    address public immutable weth;

    /// MODIFIERS ///

    modifier onlyDaoPermissions() {
        require(
            centralRegistry.hasDaoPermissions(msg.sender),
            "PositionFolding: UNAUTHORIZED"
        );
        _;
    }

    modifier checkSlippage(address user, uint256 slippage) {
        (uint256 sumCollateralBefore, , uint256 sumBorrowBefore) = lendtroller
            .getAccountPosition(user);
        uint256 userValueBefore = sumCollateralBefore - sumBorrowBefore;

        _;

        (uint256 sumCollateral, , uint256 sumBorrow) = lendtroller
            .getAccountPosition(user);
        uint256 userValue = sumCollateral - sumBorrow;

        uint256 diff = userValue > userValueBefore
            ? userValue - userValueBefore
            : userValueBefore - userValue;
        require(
            diff < (userValueBefore * slippage) / DENOMINATOR,
            "PositionFolding: slippage"
        );
    }

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address lendtroller_,
        address cether_,
        address weth_
    ) {
        require(
            ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            ),
            "PositionFolding: invalid central registry"
        );

        centralRegistry = centralRegistry_;

        require(
            centralRegistry.lendingMarket(lendtroller_),
            "PositionFolding: lendtroller is invalid"
        );

        lendtroller = ILendtroller(lendtroller_);
        cether = cether_;
        weth = weth_;
    }

    function getProtocolLeverageFee() public view returns (uint256) {
        return ICentralRegistry(centralRegistry).protocolLeverageFee();
    }

    function getDaoAddress() public view returns (address) {
        return ICentralRegistry(centralRegistry).daoAddress();
    }

    /// EXTERNAL FUNCTIONS ///

    function leverage(
        LeverageStruct calldata leverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _leverage(leverageData);
    }

    function batchLeverage(
        LeverageStruct[] calldata leverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) {
        uint256 numLeverageData = leverageData.length;

        for (uint256 i; i < numLeverageData; ++i) {
            _leverage(leverageData[i]);
        }
    }

    function onBorrow(
        address borrowToken,
        address borrower,
        uint256 borrowAmount,
        bytes calldata params
    ) external override {
        (bool isListed, ) = lendtroller.getIsMarkets(borrowToken);

        require(
            isListed && msg.sender == borrowToken,
            "PositionFolding: UNAUTHORIZED"
        );

        LeverageStruct memory leverageData = abi.decode(
            params,
            (LeverageStruct)
        );

        require(
            borrowToken == address(leverageData.borrowToken) &&
                borrowAmount == leverageData.borrowAmount,
            "PositionFolding: invalid params"
        );

        address borrowUnderlying;

        if (borrowToken == cether) {
            require(
                address(this).balance == borrowAmount,
                "PositionFolding: invalid amount"
            );

            IWETH(weth).deposit{ value: borrowAmount }(borrowAmount);
            borrowUnderlying = weth;
        } else {
            borrowUnderlying = CErc20(borrowToken).underlying();

            require(
                IERC20(borrowUnderlying).balanceOf(address(this)) ==
                    borrowAmount,
                "PositionFolding: invalid amount"
            );
        }

        // take protocol fee
        uint256 fee = (borrowAmount * getProtocolLeverageFee()) / 10000;
        if (fee > 0) {
            borrowAmount -= fee;
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                getDaoAddress(),
                fee
            );
        }

        if (leverageData.swapData.call.length > 0) {
            // swap borrow underlying to zapper input token
            require(
                centralRegistry.approvedSwapper(leverageData.swapData.target),
                "PositionFolding: invalid swapper"
            );

            SwapperLib.swap(
                leverageData.swapData,
                ICentralRegistry(centralRegistry).priceRouter(),
                SLIPPAGE
            );
        }

        // enter curvance
        SwapperLib.ZapperCall memory zapperCall = leverageData.zapperCall;

        if (zapperCall.call.length > 0) {
            require(
                centralRegistry.approvedZapper(leverageData.zapperCall.target),
                "PositionFolding: invalid zapper"
            );

            SwapperLib.zap(zapperCall);
        }

        // transfer remaining zapper input token back to the user
        uint256 remaining = IERC20(zapperCall.inputToken).balanceOf(
            address(this)
        );

        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                zapperCall.inputToken,
                borrower,
                remaining
            );
        }

        // transfer remaining borrow underlying back to the user
        remaining = IERC20(borrowUnderlying).balanceOf(address(this));

        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                borrowUnderlying,
                borrower,
                remaining
            );
        }
    }

    function deleverage(
        DeleverageStruct calldata deleverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) nonReentrant {
        _deleverage(deleverageData);
    }

    function batchDeleverage(
        DeleverageStruct[] calldata deleverageData,
        uint256 slippage
    ) external checkSlippage(msg.sender, slippage) {
        uint256 numLeverageData = deleverageData.length;

        for (uint256 i; i < numLeverageData; ++i) {
            _deleverage(deleverageData[i]);
        }
    }

    function onRedeem(
        address collateralToken,
        address redeemer,
        uint256 collateralAmount,
        bytes calldata params
    ) external override {
        (bool isListed, ) = lendtroller.getIsMarkets(collateralToken);

        require(
            isListed && msg.sender == collateralToken,
            "PositionFolding: UNAUTHORIZED"
        );

        DeleverageStruct memory deleverageData = abi.decode(
            params,
            (DeleverageStruct)
        );

        require(
            collateralToken == address(deleverageData.collateralToken) &&
                collateralAmount == deleverageData.collateralAmount,
            "PositionFolding: invalid params"
        );

        // swap collateral token to borrow token
        address collateralUnderlying;

        if (collateralToken == cether) {
            require(
                address(this).balance == collateralAmount,
                "PositionFolding: invalid amount"
            );

            collateralUnderlying = weth;
            IWETH(weth).deposit{ value: collateralAmount }(collateralAmount);
        } else {
            collateralUnderlying = CErc20(collateralToken).underlying();

            require(
                IERC20(collateralUnderlying).balanceOf(address(this)) ==
                    collateralAmount,
                "PositionFolding: invalid amount"
            );
        }

        // take protocol fee
        uint256 fee = (collateralAmount * getProtocolLeverageFee()) / 10000;
        if (fee > 0) {
            collateralAmount -= fee;
            SafeTransferLib.safeTransfer(
                collateralUnderlying,
                getDaoAddress(),
                fee
            );
        }

        SwapperLib.ZapperCall memory zapperCall = deleverageData.zapperCall;

        if (zapperCall.call.length > 0) {
            require(
                collateralUnderlying == zapperCall.inputToken,
                "PositionFolding: invalid zapper param"
            );
            require(
                centralRegistry.approvedZapper(
                    deleverageData.zapperCall.target
                ),
                "PositionFolding: invalid zapper"
            );

            SwapperLib.zap(zapperCall);
        }

        if (deleverageData.swapData.call.length > 0) {
            // swap for borrow underlying
            require(
                centralRegistry.approvedSwapper(
                    deleverageData.swapData.target
                ),
                "PositionFolding: invalid swapper"
            );

            SwapperLib.swap(
                deleverageData.swapData,
                ICentralRegistry(centralRegistry).priceRouter(),
                SLIPPAGE
            );
        }

        // repay debt
        uint256 repayAmount = deleverageData.repayAmount;
        CToken borrowToken = deleverageData.borrowToken;
        uint256 remaining;

        if (address(borrowToken) == cether) {
            remaining = address(this).balance - repayAmount;

            CEther(payable(address(borrowToken))).repayBorrowBehalf{
                value: repayAmount
            }(redeemer);

            if (remaining > 0) {
                // remaining borrow underlying back to user
                (bool sent, ) = redeemer.call{ value: remaining }("");
                require(sent, "failed to send ether");
            }
        } else {
            address borrowUnderlying = CErc20(address(borrowToken))
                .underlying();
            remaining =
                IERC20(borrowUnderlying).balanceOf(address(this)) -
                repayAmount;

            SwapperLib.approveTokenIfNeeded(
                borrowUnderlying,
                address(borrowToken),
                repayAmount + remaining
            );

            CErc20(address(borrowToken)).repayBorrowBehalf(
                redeemer,
                repayAmount
            );

            if (remaining > 0) {
                // remaining borrow underlying back to user
                SafeTransferLib.safeTransfer(
                    borrowUnderlying,
                    redeemer,
                    remaining
                );
            }
        }

        // transfer remaining collateral underlying back to the user
        remaining = IERC20(collateralUnderlying).balanceOf(address(this));

        if (remaining > 0) {
            SafeTransferLib.safeTransfer(
                collateralUnderlying,
                redeemer,
                remaining
            );
        }
    }

    /// PUBLIC FUNCTIONS ///

    function queryAmountToBorrowForLeverageMax(
        address user,
        address borrowToken
    ) public view returns (uint256) {
        (
            uint256 sumCollateral,
            uint256 maxBorrow,
            uint256 sumBorrow
        ) = lendtroller.getAccountPosition(user);
        uint256 maxLeverage = ((sumCollateral - sumBorrow) *
            MAX_LEVERAGE *
            sumCollateral) /
            (sumCollateral - maxBorrow) /
            DENOMINATOR -
            sumCollateral;

        (uint256 price, uint256 errorCode) = IPriceRouter(
            ICentralRegistry(centralRegistry).priceRouter()
        ).getPrice(address(borrowToken), true, false);

        require(errorCode == 0, "PositionFolding: invalid token price");

        return ((maxLeverage - sumBorrow) * 1e18) / price;
    }

    /// INTERNAL FUNCTIONS ///

    function _leverage(LeverageStruct memory leverageData) internal {
        CToken borrowToken = leverageData.borrowToken;
        uint256 borrowAmount = leverageData.borrowAmount;
        uint256 maxBorrowAmount = queryAmountToBorrowForLeverageMax(
            msg.sender,
            address(borrowToken)
        );

        require(
            borrowAmount <= maxBorrowAmount,
            "PositionFolding: exceeded maximum borrow amount"
        );

        bytes memory params = abi.encode(leverageData);

        if (address(borrowToken) == cether) {
            CEther(payable(address(borrowToken))).borrowForPositionFolding(
                msg.sender,
                borrowAmount,
                params
            );
        } else {
            CErc20(address(borrowToken)).borrowForPositionFolding(
                msg.sender,
                borrowAmount,
                params
            );
        }
    }

    function _deleverage(DeleverageStruct memory deleverageData) internal {
        bytes memory params = abi.encode(deleverageData);
        CToken collateralToken = deleverageData.collateralToken;
        uint256 collateralAmount = deleverageData.collateralAmount;

        if (address(collateralToken) == cether) {
            CEther(payable(address(collateralToken)))
                .redeemUnderlyingForPositionFolding(
                    msg.sender,
                    collateralAmount,
                    params
                );
        } else {
            CErc20(address(collateralToken))
                .redeemUnderlyingForPositionFolding(
                    msg.sender,
                    collateralAmount,
                    params
                );
        }
    }
}
