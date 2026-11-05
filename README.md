# Koreth v1 Periphery

User-facing helper contracts for **Koreth** that build on top of
[`koreth-v1-core`](https://github.com/korethlabs/koreth-v1-core). These are not required by the
core protocol — they add convenience, leverage, and liquidation UX on top of it.

## Contracts

```
src/
├── LeverageTransformer.sol   one-tx leverage/deleverage via PositionManager.transform()
├── CompoundSwapRouter.sol    swap-and-compound a position's fees back into principal
├── LPCompounder.sol          keeper-friendly fee compounding helper
├── FlashloanLiquidator.sol   single-asset liquidation UX via flash loan
├── SwapRouterAdapter.sol     thin swap adapter used by the transformers
└── PositionViewer.sol        read-only aggregated position/market views for UIs
```

## Dependency on core

The core is a git submodule at `lib/koreth-v1-core`, fetched over HTTPS with no credentials:

```bash
git submodule update --init --recursive
```

Remapped as `@koreth/v1-core/` (see `remappings.txt`). Contracts import core via
`@koreth/v1-core/src/...`; tests reuse the core's `test/e2e/E2EBase` fixture and mocks.

## Build & test

```bash
forge install
forge build
forge test --match-path "test/unit/*.t.sol"                 # unit
forge test --fork-url "$ETH_RPC_URL" --match-path "test/e2e/**"  # fork e2e
```

Secrets (RPC key) live in a local `.env` (gitignored) — never commit keys.

## License

`BUSL-1.1` (see [LICENSE](./LICENSE)) — converts to `GPL-2.0-or-later` on the Change Date.

## Security

Unaudited / pre-launch. Do not use in production.

Report vulnerabilities through GitHub private vulnerability reporting — the **Security**
tab above, **Report a vulnerability** — and not as a public issue or pull request. See
[SECURITY.md](./SECURITY.md) for scope, supported versions and what to expect. A finding
in the core contracts belongs in the `koreth-v1-core` repository instead.
