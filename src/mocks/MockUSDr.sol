// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDr
/// @notice ERC20 mock standing in for the Rayls-native USDr stablecoin in V1
///         testnet. Real native USDr is the chain's gas token; this mock is
///         used exclusively as the LendingPool's reserve asset so all
///         protocol math stays ERC20-shaped.
/// @dev    18 decimals to match agTOKEN. PUBLIC unrestricted mint — anyone
///         can self-mint test tokens. This is intentional for a testnet mock;
///         the real mainnet stablecoin would have proper role gating. Burn
///         remains caller-only.
contract MockUSDr is ERC20 {
    constructor(
        address /* admin — kept for backwards compatibility, unused */
    )
        ERC20("Mock USDr", "mUSDr")
    {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Public unrestricted mint. Testnet mock only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
