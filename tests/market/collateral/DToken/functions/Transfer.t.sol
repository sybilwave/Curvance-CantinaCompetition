// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseDToken } from "../TestBaseDToken.sol";
import { GaugeErrors } from "contracts/gauge/GaugeErrors.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { Lendtroller } from "contracts/market/lendtroller/Lendtroller.sol";

contract DTokenTransferTest is TestBaseDToken {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function test_dTokenTransfer_fail_whenSenderAndReceiverAreSame() public {
        vm.expectRevert(DToken.DToken__TransferNotAllowed.selector);
        dUSDC.transfer(address(this), 100e6);
    }

    function test_dTokenTransfer_fail_whenTransferZeroAmount() public {
        vm.expectRevert(GaugeErrors.InvalidAmount.selector);
        dUSDC.transfer(user1, 0);
    }

    function test_dTokenTransfer_fail_whenTransferIsNotAllowed() public {
        lendtroller.setTransferPaused(true);

        vm.expectRevert(Lendtroller.Lendtroller__Paused.selector);
        dUSDC.transfer(user1, 0);
    }

    function test_dTokenTransfer_success() public {
        deal(address(dUSDC), address(this), 100e6);

        uint256 balance = dUSDC.balanceOf(address(this));
        uint256 user1Balance = dUSDC.balanceOf(user1);

        vm.expectEmit(true, true, true, true, address(dUSDC));
        emit Transfer(address(this), user1, 100e6);

        dUSDC.transfer(user1, 100e6);

        assertEq(dUSDC.balanceOf(address(this)), balance - 100e6);
        assertEq(dUSDC.balanceOf(user1), user1Balance + 100e6);
    }
}