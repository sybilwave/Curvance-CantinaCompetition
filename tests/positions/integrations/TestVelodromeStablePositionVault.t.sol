// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ERC20 } from "contracts/deposits/adaptors/BasePositionVault.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeStablePositionVault, IVeloGauge, IVeloRouter, IVeloPairFactory } from "contracts/deposits/adaptors/VelodromeStablePositionVault.sol";
import { CToken } from "contracts/market/collateral/CToken.sol";

import "tests/market/TestBaseMarket.sol";

contract TestVelodromeStablePositionVault is TestBaseMarket {
    address internal constant _UNISWAP_V2_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    ERC20 public USDC = ERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607);
    ERC20 public DAI = ERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    ERC20 public VELO = ERC20(0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db);
    ERC20 public USDC_DAI = ERC20(0x19715771E30c93915A5bbDa134d782b81A820076);
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
    address public optiSwap = 0x6108FeAA628155b073150F408D0b390eC3121834;

    VelodromeStablePositionVault positionVault;
    CToken public cUSDCDAI;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock CToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

        _deployCentralRegistry();
        _deployGaugePool();
        _deployLendtroller();

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeAccumulator(address(this));

        positionVault = new VelodromeStablePositionVault(
            USDC_DAI,
            ICentralRegistry(address(centralRegistry)),
            gauge,
            veloPairFactory,
            veloRouter
        );

        cUSDCDAI = new CToken(
            ICentralRegistry(address(centralRegistry)),
            address(USDC_DAI),
            address(lendtroller),
            address(positionVault)
        );
        positionVault.initiateVault(address(cUSDCDAI));
    }

    function testUsdcDaiStablePool() public {
        uint256 assets = 100e18;
        deal(address(USDC_DAI), address(cUSDCDAI), assets);

        vm.prank(address(cUSDCDAI));
        USDC_DAI.approve(address(positionVault), assets);

        vm.prank(address(cUSDCDAI));
        positionVault.deposit(assets, address(this));

        assertEq(
            positionVault.totalAssets(),
            assets,
            "Total Assets should equal user deposit."
        );

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 1 days);

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(positionVault));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = address(VELO);
        swapData.inputAmount = amount;
        swapData.outputToken = address(USDC);
        swapData.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = address(VELO);
        routes[0].to = address(USDC);
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(positionVault),
            type(uint256).max
        );

        positionVault.harvest(abi.encode(swapData));

        assertEq(
            positionVault.totalAssets(),
            assets,
            "Total Assets should equal user deposit."
        );

        vm.warp(block.timestamp + 8 days);

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(positionVault));
        amount = (earned * 84) / 100;
        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(positionVault),
            type(uint256).max
        );
        positionVault.harvest(abi.encode(swapData));
        vm.warp(block.timestamp + 7 days);

        uint256 totalAssets = positionVault.totalAssets();

        assertGt(
            totalAssets,
            assets,
            "Total Assets should greater than original deposit."
        );

        vm.prank(address(cUSDCDAI));
        positionVault.withdraw(totalAssets, address(this), address(this));
    }
}