// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

abstract contract BaseOracleAdaptor {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Asset => Supported by adaptor.
    mapping(address => bool) public isSupportedAsset;

    /// ERRORS ///

    error BaseOracleAdaptor__Unauthorized();
    error BaseOracleAdaptor__InvalidCentralRegistry();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert BaseOracleAdaptor__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Called by OracleRouter to price an asset.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return PriceReturnData A structure containing the price, error status,
    ///                         and the quote format of the price.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view virtual returns (PriceReturnData memory);

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks whether `price` would overflow based on a
    ///         uint240 maximum.
    function _checkOracleOverflow(
        uint256 price
    ) internal pure returns (bool) {
        return price > type(uint240).max;
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert BaseOracleAdaptor__Unauthorized();
        }
    }

    /// @notice Checks whether the caller has sufficient permissioning.
    function _checkElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert BaseOracleAdaptor__Unauthorized();
        }
    }

    /// @notice Checks whether the caller is the Oracle Router.
    function _checkIsOracleRouter() internal view {
        if (msg.sender != centralRegistry.oracleRouter()) {
            revert BaseOracleAdaptor__Unauthorized();
        }
    }

    /// FUNCTIONS TO OVERRIDE ///

    /// @notice Removes a supported asset from the adaptor.
    function removeAsset(address asset) external virtual;
}
