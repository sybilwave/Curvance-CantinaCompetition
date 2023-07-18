// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { CErc20, IERC20 } from "contracts/market/collateral/CErc20.sol";

import { ILendtroller } from "contracts/interfaces/market/ILendtroller.sol";
import { ICurveSwap } from "contracts/interfaces/external/curve/ICurve.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";

contract ZapperGeneric {

    struct Swap {
        address target;
        bytes call;
    }

    ILendtroller public immutable lendtroller;
    address public immutable weth;
    address public constant ETH = address(0);

    constructor(address _lendtroller, address _weth) {
        lendtroller = ILendtroller(_lendtroller);
        weth = _weth;
    }

    /// @dev Deposit inputToken and enter curvance
    /// @param cToken The curvance deposit token address
    /// @param inputToken The input token address
    /// @param inputAmount The amount to deposit
    /// @param lpMinter The minter address of Curve LP
    /// @param lpToken The Curve LP token address
    /// @param lpMinOutAmount The minimum output amount
    /// @param tokens The underlying coins of curve LP token
    /// @param tokenSwaps The swap aggregation data
    /// @return cTokenOutAmount The output amount
    function curvanceIn(
        address cToken,
        address inputToken,
        uint256 inputAmount,
        address lpMinter,
        address lpToken,
        uint256 lpMinOutAmount,
        address[] calldata tokens,
        Swap[] memory tokenSwaps
    ) external payable returns (uint256 cTokenOutAmount) {
        if (inputToken == ETH) {
            require(inputAmount == msg.value, "invalid amount");
            inputToken = weth;
            IWETH(weth).deposit{ value: inputAmount }(inputAmount);
        } else {
            SafeTransferLib.safeTransferFrom(inputToken,
                msg.sender,
                address(this),
                inputAmount
            );
        }

        // check valid cToken
        (bool isListed, ) = lendtroller.getIsMarkets(cToken);
        require(isListed, "invalid cToken address");
        // check cToken underlying
        require(CErc20(cToken).underlying() == lpToken, "invalid lp address");

        uint256 numTokenSwaps = tokenSwaps.length;

        // prepare tokens to mint LP
        for (uint256 i; i < numTokenSwaps; ++i) {
            // swap input token to underlying token
            _swap(inputToken, tokenSwaps[i]);
        }

        // enter curve
        uint256 lpOutAmount = _enterCurve(
            lpMinter,
            lpToken,
            tokens,
            lpMinOutAmount
        );

        // enter curvance
        cTokenOutAmount = _enterCurvance(cToken, lpToken, lpOutAmount);

        // transfer cToken back to user
        SafeTransferLib.safeTransfer(cToken, msg.sender, cTokenOutAmount);
    }

    /// @dev Swap input token
    /// @param _inputToken The input asset address
    /// @param _swapData The swap aggregation data
    function _swap(address _inputToken, Swap memory _swapData) private {
        _approveTokenIfNeeded(_inputToken, address(_swapData.target));

        (bool success, bytes memory retData) = _swapData.target.call(
            _swapData.call
        );

        propagateError(success, retData, "swap");

        require(success == true, "calling swap got an error");
    }

    /// @dev Approve token if needed
    /// @param _token The token address
    /// @param _spender The spender address
    function _approveTokenIfNeeded(address _token, address _spender) private {
        if (IERC20(_token).allowance(address(this), _spender) == 0) {
            SafeTransferLib.safeApprove(_token, _spender, type(uint256).max);
        }
    }

    /// @dev Propagate error message
    /// @param success If transaction is successful
    /// @param data The transaction result data
    /// @param errorMessage The custom error message
    function propagateError(
        bool success,
        bytes memory data,
        string memory errorMessage
    ) public pure {
        if (!success) {
            if (data.length == 0) revert(errorMessage);
            assembly {
                revert(add(32, data), mload(data))
            }
        }
    }

    /// @dev Enter curvance
    /// @param lpMinter The minter address of Curve LP
    /// @param lpToken The Curve LP token address
    /// @param tokens The underlying coin addresses of Curve LP
    /// @param lpMinOutAmount The minimum output amount
    function _enterCurve(
        address lpMinter,
        address lpToken,
        address[] memory tokens,
        uint256 lpMinOutAmount
    ) private returns (uint256 lpOutAmount) {
        bool hasETH = false;

        uint256 numTokens = tokens.length;

        // approve tokens
        for (uint256 i; i < numTokens; ++i) {
            _approveTokenIfNeeded(tokens[i], lpMinter);
            if (tokens[i] == ETH) {
                hasETH = true;
            }
        }

        // enter curve lp minter
        if (numTokens == 4) {
            uint256[4] memory amounts;
            amounts[0] = _getBalance(tokens[0]);
            amounts[1] = _getBalance(tokens[1]);
            amounts[2] = _getBalance(tokens[2]);
            amounts[3] = _getBalance(tokens[3]);
            if (hasETH) {
                ICurveSwap(lpMinter).add_liquidity{ value: _getBalance(ETH) }(
                    amounts,
                    0
                );
            } else {
                ICurveSwap(lpMinter).add_liquidity(amounts, 0);
            }
        } else if (numTokens == 3) {
            uint256[3] memory amounts;
            amounts[0] = _getBalance(tokens[0]);
            amounts[1] = _getBalance(tokens[1]);
            amounts[2] = _getBalance(tokens[2]);
            if (hasETH) {
                ICurveSwap(lpMinter).add_liquidity{ value: _getBalance(ETH) }(
                    amounts,
                    0
                );
            } else {
                ICurveSwap(lpMinter).add_liquidity(amounts, 0);
            }
        } else {
            uint256[2] memory amounts;
            amounts[0] = _getBalance(tokens[0]);
            amounts[1] = _getBalance(tokens[1]);

            if (hasETH) {
                ICurveSwap(lpMinter).add_liquidity{ value: _getBalance(ETH) }(
                    amounts,
                    0
                );
            } else {
                ICurveSwap(lpMinter).add_liquidity(amounts, 0);
            }
        }

        // check min out amount
        lpOutAmount = IERC20(lpToken).balanceOf(address(this));
        require(
            lpOutAmount >= lpMinOutAmount,
            "Received less than lpMinOutAmount"
        );
    }

    /// @dev Get token balance of this contract
    /// @param token The token address
    function _getBalance(address token) private view returns (uint256) {
        if (token == ETH) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    /// @dev Enter curvance
    /// @param cToken The curvance deposit token address
    /// @param lpToken The Curve LP token address
    /// @param amount The amount to deposit
    /// @return out The output amount
    function _enterCurvance(
        address cToken,
        address lpToken,
        uint256 amount
    ) private returns (uint256 out) {
        // approve lp token
        _approveTokenIfNeeded(lpToken, cToken);

        // enter curvance
        require(CErc20(cToken).mint(amount), "curvance");

        out = _getBalance(cToken);
    }
}