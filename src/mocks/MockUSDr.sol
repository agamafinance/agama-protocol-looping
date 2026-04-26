// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockUSDr
/// @notice ERC20 mock standing in for the Rayls-native USDr stablecoin in V1
///         testnet. Real native USDr is the chain's gas token; this mock is used
///         exclusively as the LendingPool's reserve asset so all protocol math
///         stays ERC20-shaped.
/// @dev    18 decimals to match agTOKEN. MINTER_ROLE-gated mint; admin can
///         grant/revoke. Burnable by holders.
contract MockUSDr is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address admin) ERC20("Mock USDr", "mUSDr") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
