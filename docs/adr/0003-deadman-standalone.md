# 3. Keep the deadman timer usable without an agent

Date: 2026-09-21

## Status

Accepted

## Context

The README says the timer is the piece worth keeping if you throw the rest away.
The module did not quite mean it. Importing the timer also installed the options
index, apply policy and human confirmation commands, and even a manual disarm
called Python to revoke an agent transaction.

Simply removing those calls would break the full installation. Its rollback must
invalidate approval and cancel a blocked activation before recovering the pinned
system. A worker can still hold the apply lock when the timer fires; waiting for
that lock would defeat the timer.

## Decision

Export `nixosModules.deadman` for the timer and `nixosModules.aether` for the full
bundle. Keep `nixosModules.default` pointing to `aether`. Both retain
`services.aether.enable`, `rollbackTimeout`, `unitName` and `rollbackCommand`.

Keep the helper bodies in `modules/deadman.nix`. The full `modules/aether.nix`
aggregator composes them with the index and apply modules, using a private module
argument to include their existing transaction integration. This is not a public
hook API. Preserve the existing helper package order.

The standalone helpers install only arm, disarm and status, with a store-built
rollback command. They need neither agent configuration nor Python policy state.
The full bundle additionally installs apply, confirm and index, and retains
recovery-begin, recovery-finish, revocation and transaction status. Hook errors
remain visible; a failed cancellation/state update must not prevent an attempt
to recover. Recovery stays bounded independently of the apply lock.

Both variants recover an already-built system. Neither evaluates a flake nor
calls `nixos-rebuild` during rollback. Manual disarm never grants apply approval.
Existing full-module consumers need no changes. A human choosing timer-only use
changes the import from `aether` to `deadman` and removes full-only settings.

## Consequences

A human can try a firewall change with a timer without configuring an agent,
host key or agent sudo policy. The guarded agent flow still requires the full
bundle and its separate account/ownership setup.

There are now two compiled variants of the same helpers to cover. The deadman
VM check exercises the standalone import with no agent settings and retains
full-bundle integration checks. The apply VM keeps its actual restricted account,
blocked-activation recovery and exact fixture/preload module layout. The options
index still builds against both real host pins. These are disposable Linux
checks, not permission to experiment on a live host.
