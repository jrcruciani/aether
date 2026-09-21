# Just the timer

Import `aether.nixosModules.deadman`, set `services.aether.enable = true`, and
optionally set `services.aether.rollbackTimeout` (default: `"10min"`).
You get `aether-arm`, `aether-disarm` and `aether-status`. No agent, host key,
Python apply policy or agent sudo setup is required.

The [installation and human firewall walkthrough](../README.md#just-the-timer)
covers arming, testing, a fresh SSH session and disarming. Recovery activates an
already-built system; it never evaluates your flake or rebuilds after losing SSH.

Use `nixosModules.aether` (also the `default` export) for the full guarded agent
workflow, including apply, human confirmation and the host-pinned options index.
Manual disarm is not apply confirmation. The split and migration are recorded in
[ADR 0003](../docs/adr/0003-deadman-standalone.md).
