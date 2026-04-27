// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPricedToken} from "../interfaces/IPricedToken.sol";

/// @title MockTrancheToken
/// @notice Generic yield-bearing ERC20 mock for an AmFi-style pool tranche.
///         Replaces the single-tranche `MockAMFI` in the V2 multi-pool
///         design. Each deployment represents one tranche of one pool —
///         e.g. Resolvi Senior, Sector Condo Junior — and tracks its own
///         APR so each can crash independently in a demo.
/// @dev    `pricePerShare()` accrues linearly at `aprRay` (RAY-fixed APR,
///         e.g. 0.12e27 == 12%). The ERC20 balance is static (denominated
///         in shares); only the par value grows over time.
///
///         Public unrestricted mint() — anyone can self-mint test tokens.
///         Burn remains caller-only.
contract MockTrancheToken is ERC20, IPricedToken {
    uint256 public constant SHARE_PRICE_UNIT = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant RAY = 1e27;

    /// @notice Human-readable pool identifier (e.g. "Resolvi", "Sector Condo").
    string public poolName;
    /// @notice Tranche type — "Senior" or "Junior".
    string public trancheType;

    /// @dev Linear-accrual anchor. `pricePerShare()` reads from these and APR.
    uint256 public anchorPrice;
    uint256 public anchorTimestamp;
    /// @notice APR in RAY (e.g. 0.12e27 == 12%). Zero disables accrual.
    uint256 public aprRay;

    /// @notice Admin (deployer) — can adjust APR / re-anchor price for demo
    ///         scenarios. Not used by lifecycle paths.
    address public admin;

    event AccrualSet(uint256 newAprRay, uint256 anchorPrice, uint256 anchorTimestamp);
    event PricePerShareSet(uint256 newPrice, uint256 anchorTimestamp);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error InvalidPrice();
    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory pool_,
        string memory tranche_,
        uint256 initialAprRay,
        address admin_
    ) ERC20(name_, symbol_) {
        poolName = pool_;
        trancheType = tranche_;
        anchorPrice = SHARE_PRICE_UNIT;
        anchorTimestamp = block.timestamp;
        aprRay = initialAprRay;
        admin = admin_;
    }

    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 18;
    }

    /// @notice Current price-per-share in 1e18-fixed (1.16e18 == 1.16x par).
    function pricePerShare() public view returns (uint256) {
        if (aprRay == 0) return anchorPrice;
        uint256 elapsed = block.timestamp - anchorTimestamp;
        uint256 increment = (anchorPrice * aprRay * elapsed) / (SECONDS_PER_YEAR * RAY);
        return anchorPrice + increment;
    }

    /// @notice Update the APR (re-anchors at current pricePerShare to avoid jumps).
    function setAccrual(uint256 newAprRay) external onlyAdmin {
        anchorPrice = pricePerShare();
        anchorTimestamp = block.timestamp;
        aprRay = newAprRay;
        emit AccrualSet(newAprRay, anchorPrice, anchorTimestamp);
    }

    /// @notice Owner-controlled jump to a specific price-per-share (demo cheat:
    ///         e.g. crash a junior tranche by setting its price below par).
    function setPricePerShare(uint256 newPrice) external onlyAdmin {
        if (newPrice == 0) revert InvalidPrice();
        anchorPrice = newPrice;
        anchorTimestamp = block.timestamp;
        emit PricePerShareSet(newPrice, block.timestamp);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Public unrestricted mint — testnet mock only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
