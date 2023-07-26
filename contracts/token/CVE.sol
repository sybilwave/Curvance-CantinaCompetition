// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../layerzero/OFTV2.sol";

contract CVE is OFTV2 {
    /// CONSTANTS ///

    uint256 public constant DENOMINATOR = 10000;
    uint256 public constant MONTH = 2_629_746;
    uint256 public immutable tokenGenerationEventTimestamp;

    uint256 public immutable daoTreasuryAllocation;
    uint256 public immutable callOptionAllocation;
    uint256 public immutable teamAllocation;
    uint256 public immutable teamAllocationPerMonth;

    /// STORAGE ///

    address public teamAddress;
    uint256 public daoTreasuryTokensMinted;
    uint256 public teamAllocationTokensMinted;
    uint256 public callOptionTokensMinted;

    /// MODIFIERS ///

    modifier onlyProtocolMessagingHub() {
        require(
            msg.sender == centralRegistry.protocolMessagingHub(),
            "CVE: UNAUTHORIZED"
        );

        _;
    }

    modifier onlyTeam() {
        require(msg.sender == teamAddress, "CVE: UNAUTHORIZED");

        _;
    }

    /// CONSTRUCTOR ///

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 sharedDecimals_,
        address lzEndpoint_,
        ICentralRegistry centralRegistry_,
        address team_,
        uint256 daoTreasuryAllocation_,
        uint256 callOptionAllocation_,
        uint256 teamAllocation_,
        uint256 initialTokenMint_
    ) OFTV2(name_, symbol_, sharedDecimals_, lzEndpoint_, centralRegistry_) {
        tokenGenerationEventTimestamp = block.timestamp;

        if (team_ == address(0)) {
            team_ = msg.sender;
        }

        teamAddress = team_;
        daoTreasuryAllocation = daoTreasuryAllocation_;
        callOptionAllocation = callOptionAllocation_;
        teamAllocation = teamAllocation_;
        teamAllocationPerMonth = teamAllocation_ / (48 * MONTH); // Team Vesting is for 4 years and unlocked monthly

        _mint(msg.sender, initialTokenMint_);

        // TODO:
        // Permission sendAndCall?
        // Write sendEmissions in votingHub
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Mint new gauge emissions
    /// @dev Allows the VotingHub to mint new gauge emissions.
    /// @param gaugeEmissions The amount of gauge emissions to be minted.
    /// Emission amount is multiplied by the lock boost value from the central registry.
    /// Resulting tokens are minted to the voting hub contract.
    function mintGaugeEmissions(
        uint256 gaugeEmissions
    ) external onlyProtocolMessagingHub {
        _mint(
            msg.sender,
            (gaugeEmissions * centralRegistry.lockBoostValue()) / DENOMINATOR
        );
    }

    /// @notice Mint CVE for the DAO treasury
    /// @param tokensToMint The amount of treasury tokens to be minted.
    /// The number of tokens to mint cannot not exceed the available treasury allocation.
    function mintTreasuryTokens(
        uint256 tokensToMint
    ) external onlyElevatedPermissions {
        require(
            daoTreasuryAllocation >= daoTreasuryTokensMinted + tokensToMint,
            "CVE: insufficient token allocation"
        );

        daoTreasuryTokensMinted += tokensToMint;
        _mint(msg.sender, tokensToMint);
    }

    /// @notice Mint CVE for deposit into callOptionCVE contract
    /// @param tokensToMint The amount of call option tokens to be minted.
    /// The number of tokens to mint cannot not exceed the available call option allocation.
    function mintCallOptionTokens(
        uint256 tokensToMint
    ) external onlyDaoPermissions {
        require(
            callOptionAllocation >= callOptionTokensMinted + tokensToMint,
            "CVE: insufficient token allocation"
        );

        callOptionTokensMinted += tokensToMint;
        _mint(msg.sender, tokensToMint);
    }

    /// @notice Mint CVE from team allocation
    /// @dev Allows the DAO Manager to mint new tokens for the team allocation.
    /// @dev The amount of tokens minted is calculated based on the time passed since the Token Generation Event.
    /// @dev The number of tokens minted is capped by the total team allocation.
    function mintTeamTokens() external onlyTeam {
        uint256 timeSinceTGE = block.timestamp - tokenGenerationEventTimestamp;
        uint256 monthsSinceTGE = timeSinceTGE / MONTH;

        uint256 tokensToMint = (monthsSinceTGE * teamAllocationPerMonth) -
            teamAllocationTokensMinted;

        if (teamAllocation <= teamAllocationTokensMinted + tokensToMint) {
            tokensToMint = teamAllocation - teamAllocationTokensMinted;
        }

        require(tokensToMint != 0, "CVE:  no tokens to mint");

        teamAllocationTokensMinted += tokensToMint;
        _mint(msg.sender, tokensToMint);
    }

    /// @notice Set the team address
    /// @dev Allows the team to change the team's address.
    /// @param _address The new address for the team.
    function setTeamAddress(address _address) external onlyTeam {
        require(_address != address(0), "CVE: invalid parameter");
        teamAddress = _address;
    }
}
