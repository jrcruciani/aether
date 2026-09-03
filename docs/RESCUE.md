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

### 1. Wait ten minutes

If the change was made under the hardened protocol, a rollback timer is running and
the machine will revert on its own. Check whether you can reconnect before doing
anything drastic.

### 2. Reboot from the provider console

`nixos-rebuild test` does not write the boot default. If the breaking change was
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

You have a shell. Edit the offending module, or delete it:

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
