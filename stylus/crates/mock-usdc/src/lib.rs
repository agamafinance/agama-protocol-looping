//! MockUSDC — a 6-decimal ERC-20 with a public, capped faucet.
//!
//! Stands in for circle USDC on the Arbitrum Sepolia demo: anyone can `faucet()`
//! up to the per-call cap so juges can fund themselves in one click.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::{string::String, vec::Vec};
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::sol,
    prelude::*,
};

sol! {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error FaucetCapExceeded();
}

#[derive(SolidityError)]
pub enum Erc20Error {
    InsufficientBalance(InsufficientBalance),
    InsufficientAllowance(InsufficientAllowance),
    FaucetCapExceeded(FaucetCapExceeded),
}

sol_storage! {
    #[entrypoint]
    pub struct MockUsdc {
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        uint256 total_supply;
    }
}

/// 100,000 USDC per faucet call (6 decimals).
const FAUCET_CAP: u128 = 100_000_000_000;

#[public]
impl MockUsdc {
    pub fn name(&self) -> String {
        String::from("Mock USD Coin")
    }
    pub fn symbol(&self) -> String {
        String::from("USDC")
    }
    pub fn decimals(&self) -> u8 {
        6
    }
    pub fn total_supply(&self) -> U256 {
        self.total_supply.get()
    }
    pub fn balance_of(&self, who: Address) -> U256 {
        self.balances.get(who)
    }
    pub fn allowance(&self, owner: Address, spender: Address) -> U256 {
        self.allowances.getter(owner).get(spender)
    }

    /// Mint up to FAUCET_CAP to the caller. Permissionless on purpose.
    pub fn faucet(&mut self, amount: U256) -> Result<(), Erc20Error> {
        if amount > U256::from(FAUCET_CAP) {
            return Err(Erc20Error::FaucetCapExceeded(FaucetCapExceeded {}));
        }
        let to = self.vm().msg_sender();
        self._mint(to, amount);
        Ok(())
    }

    pub fn approve(&mut self, spender: Address, amount: U256) -> bool {
        let owner = self.vm().msg_sender();
        self.allowances.setter(owner).insert(spender, amount);
        self.vm().log(Approval { owner, spender, value: amount });
        true
    }

    pub fn transfer(&mut self, to: Address, amount: U256) -> Result<bool, Erc20Error> {
        let from = self.vm().msg_sender();
        self._transfer(from, to, amount)?;
        Ok(true)
    }

    pub fn transfer_from(&mut self, from: Address, to: Address, amount: U256) -> Result<bool, Erc20Error> {
        let spender = self.vm().msg_sender();
        self._spend_allowance(from, spender, amount)?;
        self._transfer(from, to, amount)?;
        Ok(true)
    }
}

impl MockUsdc {
    fn _mint(&mut self, to: Address, amount: U256) {
        let new_bal = self.balances.get(to) + amount;
        self.balances.setter(to).set(new_bal);
        self.total_supply.set(self.total_supply.get() + amount);
        self.vm().log(Transfer { from: Address::ZERO, to, value: amount });
    }

    fn _transfer(&mut self, from: Address, to: Address, amount: U256) -> Result<(), Erc20Error> {
        let bal = self.balances.get(from);
        if bal < amount {
            return Err(Erc20Error::InsufficientBalance(InsufficientBalance {}));
        }
        self.balances.setter(from).set(bal - amount);
        let to_bal = self.balances.get(to) + amount;
        self.balances.setter(to).set(to_bal);
        self.vm().log(Transfer { from, to, value: amount });
        Ok(())
    }

    fn _spend_allowance(&mut self, owner: Address, spender: Address, amount: U256) -> Result<(), Erc20Error> {
        let cur = self.allowances.getter(owner).get(spender);
        if cur < amount {
            return Err(Erc20Error::InsufficientAllowance(InsufficientAllowance {}));
        }
        if cur != U256::MAX {
            self.allowances.setter(owner).insert(spender, cur - amount);
        }
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn faucet_and_transfer() {
        let vm = TestVM::default();
        let mut t = MockUsdc::from(&vm);
        let me = vm.msg_sender();
        assert!(t.faucet(U256::from(1_000_000u64)).is_ok());
        assert_eq!(t.balance_of(me), U256::from(1_000_000u64));
        let bob = Address::from([7u8; 20]);
        assert!(t.transfer(bob, U256::from(400_000u64)).is_ok());
        assert_eq!(t.balance_of(bob), U256::from(400_000u64));
        assert_eq!(t.decimals(), 6);
    }

    #[test]
    fn faucet_cap() {
        let vm = TestVM::default();
        let mut t = MockUsdc::from(&vm);
        assert!(t.faucet(U256::from(FAUCET_CAP) + U256::from(1u8)).is_err());
    }
}
