#![no_std]
//! agUSD — Agama's synthetic dollar on Stellar (SEP-41).
//!
//! Minted 1:1 by depositing the base USDC. The deposited USDC is held by this
//! contract as a reserve; the admin can `sweep` part of it to the treasury
//! (strategist) address, which runs the yield strategy off-chain. Redeeming burns
//! agUSD and returns USDC 1:1 from whatever reserve remains.

use soroban_sdk::{contract, contractimpl, contracttype, token::TokenClient, Address, Env, String};
use token as tok;

#[derive(Clone)]
#[contracttype]
enum Cfg {
    Admin,
    Usdc,
    Treasury,
}

#[contract]
pub struct AgUsd;

#[contractimpl]
impl AgUsd {
    /// Wire up the synthetic dollar. `usdc` is the base-asset token contract,
    /// `treasury` is the strategist address that receives swept reserves.
    pub fn initialize(
        e: Env,
        admin: Address,
        usdc: Address,
        treasury: Address,
        decimal: u32,
        name: String,
        symbol: String,
    ) {
        e.storage().instance().set(&Cfg::Admin, &admin);
        e.storage().instance().set(&Cfg::Usdc, &usdc);
        e.storage().instance().set(&Cfg::Treasury, &treasury);
        tok::set_metadata(&e, decimal, name, symbol);
        tok::bump_instance(&e);
    }

    /// Deposit USDC and mint agUSD 1:1.
    pub fn deposit(e: Env, from: Address, amount: i128) {
        from.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        // Pull USDC from the user into this contract's reserve.
        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
        // Mint agUSD 1:1 (same 7 decimals).
        tok::mint(&e, &from, amount);
    }

    /// Redeem agUSD for USDC 1:1, burning the agUSD.
    pub fn redeem(e: Env, from: Address, amount: i128) {
        from.require_auth();
        if amount <= 0 {
            panic!("amount must be positive");
        }
        tok::burn_unchecked(&e, &from, amount);
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        // Return USDC from reserve (invoker auth: this contract is the direct caller).
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &from, &amount);
    }

    /// Admin moves part of the USDC reserve to the treasury (strategist) address.
    /// Models the off-chain "allocation to strategy" — keep a buffer for redemptions.
    pub fn sweep(e: Env, amount: i128) {
        let admin: Address = e.storage().instance().get(&Cfg::Admin).unwrap();
        admin.require_auth();
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        let treasury: Address = e.storage().instance().get(&Cfg::Treasury).unwrap();
        TokenClient::new(&e, &usdc).transfer(&e.current_contract_address(), &treasury, &amount);
    }

    /// Treasury returns USDC to the reserve (so redemptions can be served).
    pub fn refund_reserve(e: Env, from: Address, amount: i128) {
        from.require_auth();
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        TokenClient::new(&e, &usdc).transfer(&from, &e.current_contract_address(), &amount);
    }

    /// USDC currently held as reserve by this contract.
    pub fn reserve(e: Env) -> i128 {
        let usdc: Address = e.storage().instance().get(&Cfg::Usdc).unwrap();
        TokenClient::new(&e, &usdc).balance(&e.current_contract_address())
    }

    pub fn admin(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Admin).unwrap()
    }
    pub fn treasury(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Treasury).unwrap()
    }
    pub fn usdc(e: Env) -> Address {
        e.storage().instance().get(&Cfg::Usdc).unwrap()
    }

    // ---- SEP-41 ----
    pub fn balance(e: Env, id: Address) -> i128 {
        tok::balance(&e, &id)
    }
    pub fn transfer(e: Env, from: Address, to: Address, amount: i128) {
        tok::transfer(&e, from, to, amount)
    }
    pub fn transfer_from(e: Env, spender: Address, from: Address, to: Address, amount: i128) {
        tok::transfer_from(&e, spender, from, to, amount)
    }
    pub fn approve(e: Env, from: Address, spender: Address, amount: i128, expiration_ledger: u32) {
        tok::approve(&e, from, spender, amount, expiration_ledger)
    }
    pub fn allowance(e: Env, from: Address, spender: Address) -> i128 {
        tok::allowance(&e, &from, &spender)
    }
    pub fn burn(e: Env, from: Address, amount: i128) {
        tok::burn(&e, from, amount)
    }
    pub fn burn_from(e: Env, spender: Address, from: Address, amount: i128) {
        tok::burn_from(&e, spender, from, amount)
    }
    pub fn decimals(e: Env) -> u32 {
        tok::decimals(&e)
    }
    pub fn name(e: Env) -> String {
        tok::name(&e)
    }
    pub fn symbol(e: Env) -> String {
        tok::symbol(&e)
    }
    pub fn total_supply(e: Env) -> i128 {
        tok::total_supply(&e)
    }
}

mod test;
