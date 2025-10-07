# Decentralized Stable Coin (DSC)

A minimal, over‑collateralized **algorithmic stablecoin** system built with **Solidity** and **Foundry**.
Users mint/burn DSC against exogenous crypto collateral (wETH/wBTC). Prices are sourced via Chainlink; engine
logic enforces collateralization and redemptions.

## Tech
- **Solidity** (Foundry: forge/cast/anvil)
- **Chainlink** price feeds
- Tests: unit + invariant (fuzz)

## Key Contracts (src/)
- `DecentralizedStableCoin.sol` — ERC20‑like stablecoin (mint/burn controlled).
- `DSCEngine.sol` — core logic: deposit, mint, redeem, liquidate; price checks/safety.

## Scripts (script/)
- `DeployDSC.s.sol` — deploy contracts and wire dependencies.
- `HelperConfig.s.sol` — network config & feed addresses.

## Quickstart
```bash
# 1) Install Foundry (if needed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2) Install deps & build
forge build

# 3) Run tests (unit + fuzz/invariants)
forge test -vvv

# 4) Local chain (optional)
anvil
```

## Deploy
```bash
# Example (specify RPC URL & private key via env)
forge script script/DeployDSC.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY \
  --broadcast --verify
```
Env vars typically needed:
- `RPC_URL` — RPC endpoint
- `PRIVATE_KEY` — deployer key (use a throwaway for testing)

## Project Structure
```
src/
  DecentralizedStableCoin.sol
  DSCEngine.sol
script/
  DeployDSC.s.sol
  HelperConfig.s.sol
test/
  unit/ DscEngineTest.t.sol
  fuzz/ InvariantsTest.t.sol, Handler.t.sol
```

## Notes
- Collateral: **wETH**, **wBTC** (configurable via `HelperConfig`).
- Price oracles via **Chainlink**; avoid stale or negative answers.
- Only the engine can mint/burn the DSC token.

---