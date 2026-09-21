# Rescue runbook

Write this once, adapt it to your provider, then do not let the agent edit it.

If you are reading this because something is already broken, skip to "You are locked
out".

## The drill, before your first real change

Do this in calm conditions. It takes fifteen minutes and it is the reason the rest of
the system is safe to use.

1. Open your provider's console. On Hetzner Cloud it is the `>_` console button on
   the server page. On Proxmox it is noVNC. On DigitalOcean it is "Launch Droplet
   Console". Find yours and open it now.
2. Log in as root at that console. If you cannot, stop and fix that before doing
   anything else. Set a root password, store it in your password manager, and
   confirm it works.
3. Reboot and interrupt the boot menu. Confirm you can see previous NixOS
   generations listed.
4. Boot into the previous generation. Confirm the machine comes up.
5. Reboot back into the current one.

You have now practised the recovery path while nothing was on fire. This matters
more than any rule in the playbook.

## You are locked out

Work down this list. Each step is more independent of the failure than the one above.
Once a failed R3 test has rolled back or rebooted into the previous generation,
leave this list and follow the post-rollback checklist below before any further
change. Getting a shell back does not mean the repo is safe to apply.

### 1. Wait ten minutes

If the change was made under the hardened protocol, a rollback timer is running and
the machine will revert on its own. Check whether you can reconnect before doing
anything drastic.

### 2. Reboot from the provider console

`aether-apply test` does not write the boot default. If the breaking change was
applied with `test`, a plain reboot returns you to the last good generation. Use the
console's power controls, or type `reboot` if you have console login.

### 3. Boot an older generation

At the boot menu, pick the entry below the current one. NixOS keeps every generation
you have switched to. This undoes a `switch` that a reboot alone would not.

Once you are in, make it permanent:

```bash
nixos-rebuild switch --rollback
```

Or, to go back further:

```bash
nix-env --list-generations --profile /nix/var/nix/profiles/system
nix-env --switch-generation <N> --profile /nix/var/nix/profiles/system
/nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### 4. Fix the config from the console

For an already committed change, use the history to undo it. An unconfirmed R3 test
has no commit to revert; use the post-rollback checklist instead.

```bash
cd /etc/nixos
git log --oneline -10
git revert <the bad commit>
nixos-rebuild switch --flake .#<host>
```

Reverting through git is better than editing in place. It keeps the history honest
about what happened.

### 5. Restore a snapshot

Last resort. You lose everything since the snapshot was taken, so check the timestamp
before you commit to it. Provider panel, restore, wait.

## Post-rollback checklist for a failed R3 test

Only after the timer has fired and rollback has completed, or the machine has
rebooted into the previous generation, recover the repo. An inactive timer alone
does not prove rollback completed. Do not disarm early to enter this branch.

At the console, or from the recovered restricted account, change to your
configuration repo (`cd /etc/nixos` for the usual layout). Inspect the source and
`sudo aether-status` and identify the exact module from the failed
request. Replace `<host>` and `YYYY-MM-DD-topic.nix` below with that host and file,
not a wildcard. Do not clean unrelated dirty files. If other requests or unexplained
changes are present, stop and tell the human before staging anything.

`sudo aether-status` must succeed and print an exact `not armed` line before removing the
file; it may also print a rollback-target line. Its exit code alone is not a check:
it can succeed while printing `ARMED`. The block checks for the exact line and stops
on command errors, including a failed status check, build or unreadable system path.

```bash
(
  set -e
  status=$(sudo aether-status)
  printf '%s\n' "$status"
  if ! printf '%s\n' "$status" | grep -Fxq 'not armed'; then
    printf '%s\n' 'stop: expected not armed; tell the human' >&2
    exit 1
  fi

  rm -- hosts/<host>/modules/agent/YYYY-MM-DD-topic.nix
  sudo aether-apply build
)
```

Report the result to the human and stop. If the build fails, show the error. If the
paths differ, say `repo and running system DIVERGE`. Neither failure permits a
follow-on commit or activation. Do not switch to make the paths agree. The repo must
build to exactly the running system before any further change. A match completes
recovery, not approval to retry; the agent never confirms on the human's behalf.

The helper's pending marker survives reboot only to enforce this fresh-build
comparison. It does not preserve human approval. A successful build prints
`repo matches running system` only if the paths are equal; a mismatch prints
`repo and running system DIVERGE`. Do not remove state files to bypass that gate.

If human confirmation already disarmed the timer before a later edit or abort,
there may be no timer left to wait for. Use the exact root-console recovery
commands printed by the helper, targeting its captured known-good store path,
then perform the same module cleanup/build comparison. The restricted agent
cannot run those console commands. `aether-disarm` alone is not confirmation,
and only a different authorized human may run `aether-confirm`.

The raw recovery commands earlier in this runbook are **human console
procedures**, not extra agent sudo grants. See [HARDENING.md](HARDENING.md) for
the account and permission boundary.

## Things that will not save you

The emergency SSH user, if the change that broke you also removed it or closed its
port. It is declared in the same config you were editing. Treat it as convenience,
not insurance.

The agent. If the network is down, it cannot reach you and you cannot reach it. It is
inside the problem.

A backup you have never restored. If you have not tested it, you do not have it.

## Per-provider console notes

**Hetzner Cloud.** Console button on the server detail page, opens in browser. Works
with networking fully down. Rescue mode is separate and boots a Linux image with your
disks unmounted, useful if the bootloader itself is gone.

**Proxmox.** noVNC or SPICE from the VM page. If the guest agent is dead the console
still works, it is at the hypervisor level.

**DigitalOcean, Vultr, Linode.** All have a web console under a similar name. All
require a root password set inside the guest, which is the step people skip.

**Bare metal laptop.** The console is the screen in front of you. The boot menu is
the same. This is the easy case, and a good place to practise.
