//! Shared math + cross-contract interfaces for the Agama Arbitrum protocol.
//!
//! All internal accounting is done in WAD (1e18) fixed point. USDC is 6 decimals
//! and is scaled to WAD with [`usdc_to_wad`] / [`wad_to_usdc`].
#![no_std]
#[macro_use]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::alloy_primitives::U256;

/// 1e18 — the fixed-point unit used everywhere internally.
pub const WAD: u128 = 1_000_000_000_000_000_000;
/// USDC has 6 decimals; multiply by 1e12 to reach WAD.
pub const USDC_SCALE: u128 = 1_000_000_000_000;
/// Seconds in a (365-day) year, for per-second rate math.
pub const SECONDS_PER_YEAR: u64 = 31_536_000;

#[inline]
pub fn wad() -> U256 {
    U256::from(WAD)
}

/// a * b / 1e18
#[inline]
pub fn wad_mul(a: U256, b: U256) -> U256 {
    a.saturating_mul(b) / wad()
}

/// a * 1e18 / b  (returns 0 if b == 0)
#[inline]
pub fn wad_div(a: U256, b: U256) -> U256 {
    if b.is_zero() {
        return U256::ZERO;
    }
    a.saturating_mul(wad()) / b
}

/// Scale a USDC (6dec) amount up to WAD (1e18).
#[inline]
pub fn usdc_to_wad(amount: U256) -> U256 {
    amount.saturating_mul(U256::from(USDC_SCALE))
}

/// Scale a WAD amount down to USDC (6dec).
#[inline]
pub fn wad_to_usdc(amount: U256) -> U256 {
    amount / U256::from(USDC_SCALE)
}

/// Aave-style kinked interest curve. All inputs/outputs in WAD.
///
/// `util` is the utilization ratio in WAD (0..=1e18).
/// Below `kink` the rate goes from `base` to `base + slope1`; above `kink`
/// it adds the steep `slope2` portion. Returns the **per-year** borrow rate in WAD.
pub fn borrow_rate(util: U256, base: U256, slope1: U256, slope2: U256, kink: U256) -> U256 {
    if util <= kink {
        // base + slope1 * (util / kink)
        let frac = wad_div(util, kink);
        base + wad_mul(slope1, frac)
    } else {
        // base + slope1 + slope2 * ((util - kink) / (1 - kink))
        let excess = util - kink;
        let denom = wad().saturating_sub(kink);
        let frac = wad_div(excess, denom);
        base + slope1 + wad_mul(slope2, frac)
    }
}

/// Interest factor for `dt` seconds at per-year `rate` (WAD), linear simple interest.
/// Returns the multiplier-minus-one in WAD (i.e. the growth, so 0.05e18 == +5%).
pub fn linear_interest(rate_per_year: U256, dt: u64) -> U256 {
    rate_per_year.saturating_mul(U256::from(dt)) / U256::from(SECONDS_PER_YEAR)
}

stylus_sdk::stylus_proc::sol_interface! {
    interface IERC20 {
        function transfer(address to, uint256 amount) external returns (bool);
        function transferFrom(address from, address to, uint256 amount) external returns (bool);
        function balanceOf(address who) external view returns (uint256);
        function mint(address to, uint256 amount) external;
        function burn(address from, uint256 amount) external;
    }

    interface INavOracle {
        function navOf(address vault) external view returns (uint256);
    }

    interface IRwaVault {
        function sharesOf(address who) external view returns (uint256);
        function navPerShare() external view returns (uint256);
        function asset() external view returns (address);
    }
}
