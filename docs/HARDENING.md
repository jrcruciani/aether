# Restricted-account setup and the apply contract

This is a **cooperative-agent guardrail, not a hostile-Nix sandbox**. Trusted host
modules and packages can perform privileged activation. The static reader is not
a proof of Nix semantics. Arbitrary hostile Nix needs a different proposal language
and isolation boundary.

Sudo rules are additive. Root, wheel, another sudo grant, access to a privileged
container daemon, a trusted Nix account, writable root inputs, or a general
privileged shell defeats this setup. Never claim that an already-root agent has
been constrained by adding a command allowlist.

## Human setup, before an agent session

Use distinct agent and human accounts. This example intentionally grants the human
only confirmation; provider-console root remains the independent rescue path.
Do not apply these account/security changes through the agent: they are R4.

```nix
services.aether = {
  enable = true;
  flake = "/etc/nixos";
  host = "vps"; # nixosConfigurations key; never derived from hostName
  agentUser = "agent";
  rollbackTimeout = "10min";
};

users.groups.agent = {};
users.users.agent = {
  isNormalUser = true;
  group = "agent";
  extraGroups = []; # in particular, not wheel, docker or another privileged group
};
users.users.human.isNormalUser = true;

security.sudo.extraRules = [
  {
    users = [ "agent" ];
    commands = map (name: {
      command = "/run/current-system/sw/bin/${name}";
      options = [ "NOPASSWD" "NOSETENV" ];
    }) [ "aether-apply" "aether-status" "aether-index" ];
  }
  {
    users = [ "human" ];
    commands = [{
      command = "/run/current-system/sw/bin/aether-confirm";
      options = [ "NOPASSWD" "NOSETENV" ];
    }];
  }
];
```

Keep sudo environment resetting enabled. Do not add SETENV, environment-preserving
exceptions, command wildcards outside these parsers, `nixos-rebuild`,
`switch-to-configuration`, `aether-confirm`/`aether-disarm` for the agent,
`systemctl`, `nix-env`, `nix`, `git`, a general shell, or `ALL`.
Inspect `sudo -l -U agent` and all other account/group privilege routes; this
example cannot subtract an existing grant.

The checkout must be a standalone Git repository on a named branch, not a linked
worktree. Its path/ancestors, trusted files and `.git` metadata must be root-owned
and not group/world writable. Commit the reviewed base and lock first. The helper
rejects dirty files outside the selected host's flat proposal directory.

As console root, with no session using this checkout:

```bash
chown -R root:root /etc/nixos
chmod -R go-w /etc/nixos
chown root:agent /etc/nixos/hosts/vps/modules/agent
chmod 1775 /etc/nixos/hosts/vps/modules/agent
```

Install the exact `examples/hosts/vps/modules/agent/default.nix` from this Aether
revision as the root-owned loader, and ensure the host imports that directory.
Commit this setup before applying proposals. The sticky directory matters: an
ordinary root-owned file in a writable directory can otherwise be unlinked and
replaced by the agent. New proposals are agent-owned regular `.nix` files; the
loader remains root-owned. Do not make other directories writable. Symlinked,
hardlinked and nested proposals are unsupported.

Ignore `result` and ensure it is not already tracked. Keep Git metadata ordinary:
custom includes, filters, attributes, signing helpers and fsmonitor configuration
are unsupported. Privileged operations disable hooks, signing, external diff and
caller-supplied global/system Git configuration. They do not execute a user's
Git configuration as root.

`agentUser = null` leaves timer/index-only installations usable. Enabling Aether
does not create accounts, configure sudo, rewrite permissions or initialize a
repository for you.

## Supported entry points

```text
aether-apply <build|test|switch> [--host <configured-key>] [--risk R1|R2|R3|R4]
aether-confirm
aether-status
aether-index
```

`--host` is an equality check, not a way to select another privileged target.
`--risk` is a model declaration that can only raise the policy floor. There are no
force, confirmed, arbitrary-command, alternate-flake or worker-selection flags.
Malformed arguments fail. Index/status/confirm accept no arguments.

The reader accepts conventional module arguments and static dotted/nested
assignments containing literal values, lists and package references. It supports
`environment.systemPackages`, `fonts.packages`, fontconfig defaults, and the
enable switches for bash, zsh, fish, vim, neovim, git, tmux and htop. The documented
PostgreSQL example is R2 only with explicit `enableTCPIP = false` and supported
literal settings; PostgreSQL backup enable/scheduling is R2. Other static service
settings are at least R3 when exposure is not established. Executable service
hooks and static command options such as `networking.firewall.extraCommands`,
systemd definitions, imports, functions, interpolation, dynamic attributes
and unrecognized option families require human review.

The minimum prefix floors are R3 for networking, SSH, kernel and hardware; R4 for
users, bootloader, filesystems, swap, sops, age and security. Changing Aether's own
policy is also R4. Deletions and staged definitions are scanned as well as new
content. At least 40 nonempty closure-diff lines raises the floor to R3. None of
these lexical rules proves that an accepted package or inherited setting is safe.

R4/unsupported proposals return refusal status 4 and print module paths and
human review/build instructions without staging, changing HEAD/result/state,
building or activating. Other errors return nonzero with their failing step.
Kernel/initrd and **all `hardware.*` changes** can build, but `test`/`switch`
refuse: a human must review the appropriate `boot` and reboot procedure. Hardware
options can imply kernel/driver changes that this lexical reader cannot prove
safe for a live test, including GPU requests. There is deliberately no agent
`boot` verb.

## Exact candidate and commits

`build` freezes a root-owned snapshot, runs `git add -A` there, stages those exact
content objects in the managed checkout, checks the flake, runs
`nixos-rebuild build` against the frozen source and prints the actual
`nix store diff-closures /run/current-system ./result`. Lock updates and
flake-supplied runtime configuration are not accepted. It activates nothing.

The result link is a convenience, not authority. Activation uses the recorded
store path from the private snapshot, never a new evaluation of the editable
worktree. GC roots retain the candidate and captured known-good system through
the transaction. Source content and change metadata are checked around each
transition; ordinary edit-and-restore invalidates approval too.

An unchanged prepared candidate is reused by the next step. A direct R1/R2
`switch` can build first, but the recommended flow is build, review the diff, then
switch. `test` changes the running system without committing or making the boot
default persistent. The detached scope worker owns activation and completion;
losing the originating shell is not supposed to kill it.

Only after successful final activation does the helper commit the exact candidate
tree using its recorded parent. It does not execute commit hooks or sweep a later
edit into that commit. The model does not run a separate `git commit`.
Prepare nontrivial ADRs as separate human-reviewed clean-baseline changes; they are
not an exception to the proposal-only gate.

## Human confirmation

R3 test activation automatically arms the timer first. Arming failure prevents
candidate activation. The agent then stops while a different human account opens
a fresh SSH session, reviews the candidate and verifies access:

```bash
sudo aether-confirm
```

The invocation attests that the human performed that check. The command checks
the tested store path and source context, successfully disarms and verifies
recovery quiescence before writing `/run/aether/confirmed-<module-hash>`.
The directory is root-owned `0700` and the token root-only. The token binds the
tree, closure, parent, host/flake, boot, proposing UID and unique transaction.

Under sudo, the effective/real UID may be zero; the original sudo UID/account is
cross-checked rather than treating that zero as the human. Confirmation rejects
the configured agent UID and the proposing principal. Console root is an explicit
human administrative path, not containment of an agent that already has root.
Neither `SSH_CONNECTION` nor a chat reply proves freshness.

The agent now runs `sudo aether-apply switch --risk R3`. Approval is consumed
before switching and cannot be replayed. Source changes, rollback, another
candidate or host, and reboot invalidate it. Manual `aether-disarm` does not create
confirmation. Failed disarming creates no token; do not commit or switch.

## Errors, aborts and recovery

Do not start concurrent requests. Apply/confirm return a busy error when another
operation is active. Rollback does not wait for that operation's lock: it
invalidates approval, cancels only the recorded activation scope with bounded
waits, then attempts recovery from the pin or validated boot-default fallback.
State/cancellation errors are loud and must not suppress recovery activation.
Rollback never evaluates a flake or calls `nixos-rebuild`.

After a failed fresh SSH session, wait for completed timer recovery or reboot
from the provider console. An inactive timer alone is insufficient. After the
known-good system is running, remove only the failed request's module and run:

```bash
sudo aether-status
sudo aether-apply build
```

The pending marker in `/var/lib/aether` survives reboot only to require the fresh
repository build to equal `/run/current-system`. A mismatch prints
`repo and running system DIVERGE` and blocks further work. A match clears the
recovery gate, not approval for a retry. No failed candidate is committed.

If approval had already disarmed the timer before a later source edit or abort,
do not wait for a nonexistent timer. Use the helper's exact captured
root-console recovery commands, then the same cleanup/build comparison. The
agent is not authorized to run those console commands. Partial activation,
commit failures and missing completion receipts are errors, not successful
transactions; inspect `aether-status` and the journal before proceeding. A commit
that already succeeded is not rolled back merely because cleanup failed: the
next invocation verifies its HEAD/running/profile state, finishes cleanup and
asks you to rerun the requested action.

Never delete all of `/run/aether`, reset Git, or remove unrelated proposal files
to bypass a pending gate. Root administrators should not concurrently modify
the managed repository or system during an apply transaction.
