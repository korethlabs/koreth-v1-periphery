# Security Policy

## Status of this code

Koreth is **pre-beta and has not been audited**. The contracts in this repository are
**not production-ready** and must not be used to custody funds. They have not completed
an external security review, parameters are not final, and the deployed addresses are
test deployments only. Assume that bugs capable of causing total loss of funds are
present.

## Supported versions

Only `main` is supported. Tags, branches and prior commits receive no security fixes;
a report is only acted on if it still reproduces against `main`.

## Reporting a vulnerability

Use **GitHub private vulnerability reporting**: open the repository's **Security** tab
and press **Report a vulnerability**. That creates a private advisory visible only to
the reporter and the maintainers, and it is the channel for all security reports.

Please **do not** open a public issue, a pull request, a discussion, or any other public
thread for a suspected vulnerability. Public disclosure before a fix exposes anyone
running the code.

A useful report includes the affected contract and function, the invariant you believe
is broken, the preconditions an attacker needs, and the impact. A Foundry test that
demonstrates the behaviour is the most helpful thing you can send, since it removes any
ambiguity about whether the issue reproduces.

## What to expect

Reports are reviewed on a best-effort basis. Koreth is a small team and there is **no
response-time commitment** — no acknowledgement SLA, no fix deadline, and no guarantee
that a given report will be acted on.

There is **no bug bounty programme**. No payment, reward or other compensation is
offered for a report. Please do not submit one expecting a bounty.

## Scope

In scope is everything under `src/` in this repository — the one-transaction leverage
and deleverage path, fee compounding, flash-loan liquidation, the swap-router bridge and
the batched view contract. The properties most worth attacking are the ones these
contracts depend on rather than enforce alone:

- the transform authorisation boundary, which is what allows collateral to be added and
  debt to be drawn mid-callback;
- callback identity on both the transform and flash-loan entry points, including its
  second role as the reentrancy guard;
- token approvals, which are expected to leave no standing allowance once a call
  returns;
- the administrative setters on the fee-compounding contract, whose authority is read
  from the protocol's access-control manager at call time;
- the end-to-end profit check that the liquidation path relies on in place of per-swap
  slippage limits.

Most contracts here are intended to be stateless for the duration of a single
transaction and to hold no user funds between calls. A way to leave value sitting in one
of them, or to make a balance survive a transaction, is in scope even when no
accounting in this repository is wrong.

## Reports about the core protocol

This repository builds on `koreth-v1-core`, which it consumes as a submodule and
compiles from source. Health factors, debt and share accounting, liquidation sequencing,
role definitions, pricing and the DEX adapters all live there, not here.

If the flaw is in those core contracts, please report it through the **Security** tab of
the `koreth-v1-core` repository, so it reaches the people who own that code. If a
periphery contract is what makes a core weakness reachable, report it here and say which
core behaviour it depends on.
