# The Aether playbook

You are letting a language model change the machine it runs on. The model will
occasionally be confidently wrong. Design for that, rather than hoping for a
better model.

NixOS gives us a reviewable description, a build before activation, and older
generations. None of those alone prevents a firewall change from killing SSH.
`aether-apply` owns the supported pipeline so remembering a prompt is no longer
what decides whether the timer and human gate were used.

First complete [HARDENING.md](HARDENING.md) and the [rescue drill](RESCUE.md).
The intended agent is a separate non-wheel account, not root. This is a scoped
cooperative guardrail, not a hostile-Nix sandbox; packages and trusted modules
can still contain privileged code.

## Rule one: git tracks it or Nix cannot see it

Nix flakes ignore untracked files. The helper freezes the proposal in a root-owned
snapshot, runs `git add -A` there and stages those exact content objects in the
managed checkout. It then runs the flake check and `nixos-rebuild build`, without
updating the lock, and prints the real closure diff.

For R1/R2, use:

```bash
sudo aether-apply build --risk R1
# Read the printed closure diff before proceeding.
sudo aether-apply switch --risk R1
```

Declare R2 for R2 work. One command per step; do not separately stage, commit or
rebuild. The helper commits only after successful final activation. R3 additionally
requires human confirmation and successful disarming first. A failed test stays
uncommitted rather than becoming the next switch's ready-to-apply mistake.

A flake check is a filter, not proof that the system is safe. The build validates
configuration types; the closure diff shows what changes. Two requested CLI tools
should not quietly pull in forty unrelated changes. The tool raises the floor at
40 nonempty diff lines, but the human should review smaller surprises too.

## Rule two: one module per request, never touch configuration.nix

Write `hosts/<host>/modules/agent/YYYY-MM-DD-topic.nix`. The human-owned
`default.nix` automatically imports regular `.nix` files in sorted order.
Never edit that loader, the trusted host files, the lock, or another host.
The helper rejects dirty tracked, staged and untracked paths outside its allowed
proposal files. A tracked `result` is a human setup error.

The first reader deliberately supports only static assignments and literal
values/lists/package references. Dynamic names, interpolation, imports, `let`,
arbitrary functions and unsupported option families require manual review.
Do not disguise unsupported behavior to get it past the reader.

If the build fails, show the error and remove only the failed request's module.
Run the build gate after cleanup. Do not delete unrelated dirty files or begin
another request with an unresolved transaction.

## Rule three: classify before you act

Say the level and reason before touching anything, and declare it with `--risk`.

| Level | Scope | Policy |
| --- | --- | --- |
| R0 | Reading, diagnosis, explanation | Read freely |
| R1 | Packages, fonts, bounded user programs | Build/review/switch |
| R2 | Supported services without new network exposure | Summarize, then normal flow |
| R3 | Networking, firewall, SSH, kernel, hardware; uncertain service exposure | Automatic deadman test, separate human confirmation |
| R4 | Users, secrets, filesystems, swap, bootloader, security and guardrail configuration | Human handoff; no automatic staging/build/activation |

The tool uses the highest of the model declaration, lexical floor and closure-size
floor. It scans deleted/previous definitions too; removing an SSH setting is still
risky. Unknown syntax never defaults to low risk. R2 service support is bounded:
the documented local PostgreSQL form includes explicit `enableTCPIP = false`,
and PostgreSQL backup scheduling is supported. Ambiguous service exposure is
at least R3, not an assertion that every service is safe.

R4 changes can damage the recovery mechanism itself. A bootloader change that
removes old generations, a user change that removes your login, or a secret/key
change is not made safe by a timer. Hand those proposals to a human.

## Rule four: never activate as a child of the agent's own process

Activation restarts services. If it is a child of the SSH session or agent unit
being restarted, it can die halfway through.

All supported agent activation uses `aether-apply test|switch`. The helper runs a
private worker in `systemd-run --scope`, with detached input and root-owned
logs/completion state rather than relying on the agent's terminal. That worker
activates the frozen store path, performs final checks and commits on success.
It does not re-evaluate the editable worktree.

There is no supported raw rebuild, direct activation, systemctl, nix-env or root
shell workaround for the restricted agent. Use `sudo aether-status` for transaction
and timer state. Report interrupted/failed completion instead of inferring success.

## Rule five: arm the rollback before you need it

Before R3, describe the proposed change and independent rescue layer, and obtain
the human's go-ahead to test. This is not final approval.

```bash
sudo aether-apply build --risk R3
sudo aether-apply test --risk R3
```

The helper automatically pins the known-good running system and arms the timer
before activation. If arming fails, it refuses to activate. Test changes the running
system but not the boot default and does not commit.

Stop. A DIFFERENT human principal opens a fresh second SSH session, keeps the first
one open, checks access and reviews the exact candidate. In that session:

```bash
sudo aether-confirm
```

The agent never runs that command. Confirmation successfully disarms first, checks
that recovery is not racing it, then writes a root-only, candidate-bound token in
`/run/aether`. Failed disarm means no approval. A chat reply or manual
`aether-disarm` is not a token. SSH freshness is human attestation, not a fact the
helper can infer from an environment variable.

Only then does the agent run:

```bash
sudo aether-apply switch --risk R3
```

Approval is consumed before the exact candidate switches. Only successful final
activation permits the helper's commit. Editing, rollback, reboot or another
transaction invalidates the token; there is no model-accessible confirmation flag.

`aether-arm` and `aether-disarm` remain human timer helpers, not extra agent sudo
grants. The timer pins `/run/current-system` in `/run/aether/rollback-target`.
Recovery sets the system profile to that path and activates it directly, never
evaluating a flake or using `nixos-rebuild`. A test left the profile unchanged, so
going back one generation would recover the wrong system. A missing/invalid pin
warns and falls back to the current boot default. A profile-update failure still
attempts recovery activation and returns an error.

Recovery invalidates approval and cancels the recorded activation scope with
bounded waits. It never waits indefinitely on an apply lock. State/cancellation
failures remain loud rather than preventing the recovery attempt.

If the fresh SSH session fails, stop and let the timer fire or reboot from the
provider console. Do not disarm or debug by making another configuration change.

### Recovery after a failed second session

Wait for actual recovery or a known-good reboot; an inactive timer alone does not
prove the machine recovered. `sudo aether-status` must succeed and print an exact
`not armed` line. Identify only the failed request's module:

```bash
rm -- hosts/<host>/modules/agent/YYYY-MM-DD-topic.nix
sudo aether-apply build
```

The persistent pending gate requires that fresh build to equal
`/run/current-system`. Only equality prints `repo matches running system`.
`repo and running system DIVERGE`, a failed build, incomplete recovery or
unexplained dirty files means stop: no commit, activation or new request.
Do not switch to make the paths agree. Equality is recovery, not approval to retry.

If confirmation already disarmed the timer and the source then changed, there is
no timer to wait for. A human must use the helper's captured root-console recovery
instructions before cleanup and the same build comparison. The agent cannot run
those commands under the restricted sudo policy.

## Rule six: pick the right verb

`build` checks and builds, activating nothing. `test` activates without a persistent
boot change. `switch` makes the reviewed candidate persistent. A direct R1/R2
switch can perform the preparation pipeline first, but build/review/switch is the
recommended conversational flow.

There is no agent `boot` verb. Kernel/initrd changes may build, but test/switch
refuse them. Bootloader changes are R4 and refuse earlier. Hand the appropriate
boot/reboot instructions to a human instead of pretending a live test covers them.

## Rule seven: ground the model in real options

Configure the explicit host key and reviewed local lock:

```nix
services.aether = {
  enable = true;
  flake = "/etc/nixos";
  host = "vps"; # not networking.hostName
  agentUser = "agent"; # after completing HARDENING.md
};
```

Run `sudo aether-index` after setup, lock bumps and host-module changes. It builds
the host's `config.system.build.manual.optionsJSON`, with `--no-update-lock-file`,
and replaces `/var/lib/nixos-options` only on success. It accepts no arguments and
never guesses the hostname. Host names use letters, digits, underscores or hyphens;
absolute flake paths may contain spaces but not `#`, `?` or line breaks.

The symlink points to a directory:

```bash
grep -o '"services.openssh.enable"' \
  /var/lib/nixos-options/share/doc/nixos/options.json
nix eval --no-update-lock-file \
  /etc/nixos#nixosConfigurations.<host>.options.services.openssh.enable.type.description
```

Names are not type checks. The default JSON covers base nixpkgs modules;
imported-module options may require querying `.options` directly or human-reviewed
`documentation.nixos.includeAllModules = true`.

On the tested 25.05 and 25.11 pins, disabling `documentation.enable` or
`documentation.nixos.enable` removes `config.system.build.manual`.
`documentation.doc.enable = false` preserves options JSON while skipping HTML
installation. The helper does not change documentation policy or use another
nixpkgs to mask a failure. An old preserved index is not validated for a new config.

## Rule eight: confirmation belongs to the human, not the model

One approval covers one exact candidate. The agent cannot write the root-only
token, invoke confirm via its sudo grant, or raise its privilege through a flag.
Another host, edited source, rollback, reboot or consumed token invalidates it.
The proposing UID cannot be its own confirmer, including via a fresh same-account
sudo session.

These are workflow controls under the documented ownership and sudo assumptions.
They do not constrain a root/wheel agent or establish a hostile-code sandbox.

## Rescue, secrets and decision records

The provider console plus a known root password is independent of SSH and the
managed configuration. Practise it first. Older boot generations and provider
snapshots are additional layers; an emergency SSH account lives in the same
configuration and is a convenience, not the foundation. See [RESCUE.md](RESCUE.md).

Never store, read, print or generate secret values in the agent workflow. Reference
sops/agenix secrets by name and hand secret-management changes to a human.

Record nontrivial choices using [ADR 0001's format](adr/0001-record-architecture-decisions.md).
Have a human review and commit trusted-baseline documentation separately before
an operational transaction; do not bypass the module-only dirty gate to stage an
ADR. Historical field notes retain their original commands as evidence, not the
current agent interface.
