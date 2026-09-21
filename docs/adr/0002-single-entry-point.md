# 2. Use one guarded entry point for configuration changes

Date: 2026-09-21

## Status

Accepted

This filename was specified by work-order item 05. The earlier ADR 0002,
`0002-agent-runs-inside-the-managed-host.md`, keeps its existing number and history.

## Context

The prompt currently asks an agent to assemble staging, checks, builds, risk
classification, activation, rollback arming, human confirmation and commits.
Forgetting one command changes the safety policy. A conversational "yes" is also
not a durable authorization for a particular built system.

Moving those commands behind sudo is useful, but does not make arbitrary Nix safe.
Trusted modules and packages can run privileged activation code. Prefix matching
cannot prove the meaning of computed Nix, nor can sudoers constrain an agent that
already has root, wheel membership or another privileged route.

## Decision

Install `aether-apply build|test|switch` as the agent's only activation interface.
Use the explicitly configured flake directory and host key, never the hostname.
Read a deliberately restricted static module syntax, assign conservative risk
floors and refuse unsupported constructs. A model declaration can raise the level
but cannot lower it. A large closure diff also raises the floor. R4 is a manual
handoff without staging, building or activation; boot-only changes do not enter
the live test/switch path.

Scan and build the same root-owned candidate snapshot. Stage its exact content,
show the real closure diff and activate only its built store path in a separate
systemd scope. Root owns the trusted baseline, Git metadata, importer and
transaction state; the agent can write only the protected proposal directory.
Disable caller-selected configuration, Git hooks and command execution helpers
in privileged operations.

R3 test activation automatically arms the deadman first and refuses to activate
if arming fails. A separate human principal opens a fresh SSH session and runs
`aether-confirm`, which verifies the candidate and successfully disarms before
creating a root-only, single-use `/run` token. The token binds the exact candidate,
host, boot and transaction, not a category of changes. The model cannot create
confirmation through a flag. Fresh SSH access is a human attestation, not something
an environment variable proves.

Commit only after successful final activation, and for R3 only after confirmation
and disarming. Recovery invalidates approval and cancels a stuck activation with
bounded waits; it must never wait indefinitely for an apply lock. Recovery still
uses an already-built system and never evaluates a flake or runs `nixos-rebuild`.
After failure or reboot, a persistent pending record blocks further changes until
the failed proposal is removed and a fresh repository build equals the running
system. Approval itself never survives reboot.

Document and test a separate, non-wheel agent account with sudo grants only for
apply, status and index. Human confirmation and console recovery use separate
principals. This is a cooperative-agent guardrail, explicitly not a hostile-Nix
sandbox. A structured data-only proposal language and stronger isolation are
different work, not claims made by this iteration.

## Consequences

The executable, rather than prompt compliance, owns the supported workflow. A
reviewed build cannot silently become a different activation, a failed test stays
uncommitted, and the restricted agent cannot bypass the human gate through the
documented sudo commands.

Setup now includes real ownership and permission requirements. Conservative
syntax restrictions reject some perfectly valid Nix and send it to a human.
Trusted configuration and package behavior remain outside the scanner's proof.
The extra transaction state needs recovery tests, particularly for cancellation,
reboot and stale approval. Evidence comes from disposable NixOS VMs with actual
sudoers and activations, not from trying rollback timers on a live host.
