# The Aether playbook

This is the operational core. Everything else in the repo supports what is written
here.

The audience is two readers at once: a human deciding whether to trust this, and an
agent that has been handed it as instructions. I have tried not to write it in a way
that patronises either.

## The premise

You are letting a language model change a running system. The model will occasionally
be confidently wrong. Design for that, rather than hoping for a better model.

Three properties of NixOS make it survivable:

Your system is a description. The agent does not need to guess what is installed, it
reads the config. There is no drift between what the file says and what the machine
is, so there is no archaeology.

Changes are evaluated before they activate. A module that does not compile never
reaches your running system. This eliminates an entire category of failure that would
otherwise require you to notice it.

Old generations persist. Every applied change leaves the previous system intact and
bootable. Rollback is a boot menu entry, not a restore procedure.

None of that helps if the agent runs `switch` on a broken firewall rule and drops
your SSH session. Which is what the rest of this document is about.

## Rule one: git tracks it or Nix cannot see it

Nix flakes only copy files tracked by git into the store. An untracked file is
silently ignored. You will edit it, rebuild, see no change, and spend twenty minutes
debugging a config the system never read.

So: `git add -A` after every edit, always, before any build. This is not tidiness,
it is a functional requirement.

Commit *after* the build passes, not before. Tracking is enough for Nix; committing
early only fills your history with states that never worked. One green commit per
request.

```bash
git -C /etc/nixos status        # clean, or stash what you cannot explain
# edit
git add -A
nix flake check                 # cheap gate, fast to fail
nixos-rebuild build --flake .#vps
git commit -m "one line: what and why"
```

`nix flake check` does not evaluate your whole configuration and can be slow on a
system flake. Treat it as a cheap filter, not proof. The build is the real gate.

## Rule two: one module per request, never touch configuration.nix

The agent writes to `hosts/<name>/modules/agent/YYYY-MM-DD-topic.nix` and nowhere
else. Your main configuration imports that directory and is otherwise read-only from
the agent's point of view.

This buys three things. The diff for any change is one new file, readable in ten
seconds. Reverting is `rm`. And an agent editing a scoped file cannot accidentally
mangle a line it was not asked to think about, which is the failure mode that makes
people stop trusting these tools.

If the build fails, delete the generated module. Do not leave it staged for later.
Later never comes and you will forget it is there.

## Rule three: classify before you act

Say the level out loud before touching anything.

| Level | Scope | Policy |
| --- | --- | --- |
| R0 | Read-only: diagnosis, explanation, log reading | Always allowed |
| R1 | Packages, fonts, harmless userland programs | Normal flow |
| R2 | Services, systemd timers, applications with no new network exposure | Normal flow plus a summary before applying |
| R3 | Networking, firewall, SSH, kernel parameters, GPU | Hardened protocol. Rollback timer, test before switch, explicit human confirmation |
| R4 | Users, secrets, filesystems, bootloader, disk encryption | Not applied by the agent. Emitted as manual instructions |

The R4 refusal is the one people push back on, so here is the reasoning. Rollback is
the safety net that makes all the other levels acceptable. R4 changes are the ones
that can damage the net itself: an encryption change you cannot undo without the old
key, a bootloader change that makes old generations unbootable, a user change that
removes the account you would log in with to fix it. When the recovery mechanism is
what is at risk, a human should be typing.

## Rule four: never `switch` as a child of the agent's own process

If the agent runs inside the machine it manages, this one will eventually bite you.

`nixos-rebuild switch` restarts systemd units during activation. If the rebuild is a
child of your SSH session, or of a unit that gets restarted, it dies partway through
and leaves the system half-applied. That is the worst possible state: not the old
config, not the new one, and no clean way to describe what you are looking at.

Detach it.

```bash
systemd-run --scope --collect --unit=rb-$(date +%s) \
  nixos-rebuild switch --flake .#vps
```

Then read the result from `journalctl -u rb-<unit>` rather than the stdout of a
process that may not exist any more. Do this for every `switch`, `test` and `boot`,
including the ones you think are safe. An application service sharing a cgroup with
your agent is not always obvious from the config.

## Rule five: arm the rollback before you need it

For anything at R3, set a dead man's switch before applying.

```bash
# 1. Arm
aether-arm 10min

# 2. Activate without persisting
systemd-run --scope --collect --unit=rb-$(date +%s) \
  nixos-rebuild test --flake .#vps

# 3. Open a SECOND SSH session. Do not close the first one.
#    Confirm you can still get in.

# 4. Only now, disarm and persist
aether-disarm
systemd-run --scope --collect --unit=rb-$(date +%s) \
  nixos-rebuild switch --flake .#vps
```

`aether-arm` comes from `services.aether.enable`, the module in `modules/deadman.nix`.
Arm while the known-good system is still running. It records that system's store
path in `/run/aether/rollback-target`; `aether-status` shows the pin and time left.
When the timer fires, it sets the system profile to the pin and activates it,
without rebuilding or evaluating a flake. `test` leaves the profile unchanged, so
rolling it back one generation would go too far. A missing or invalid pin produces
a journal warning and falls back to the current boot-default profile, not an older
generation. A profile-update failure is reported but does not prevent an attempt
to activate the recovery system. Disarming removes the pin.

Earlier versions of this playbook told you to arm the timer with a `systemd-run` line
calling `nixos-rebuild switch --rollback`. Do not do that. It re-evaluates the flake
and derives the configuration name from the hostname, so unless those two names
happen to match it fails when it fires, which is the worst possible time to find out.
See `docs/FIELD-NOTES-rollback-timer-2026-09.md`.

Two independent safety nets are running here. The timer reverts the machine on its
own if you vanish. And `test` does not write the boot default, so a reboot returns
you to the last known good generation regardless.

If the second session fails to connect, stop. Do not debug it from inside the first
session by making another change. Let the timer fire.

## Rule six: pick the right verb

`build` compiles and activates nothing.

`test` activates now but does not survive a reboot. Use it to try risky things.

`boot` writes the boot default without activating now. Use it for kernel, initrd and
bootloader changes, which cannot take effect on a running system anyway.

`switch` does both. It is the normal ending, not the normal beginning.

## Rule seven: ground the model in real options

Hallucinated NixOS options are the most common failure by a wide margin. The model
half-remembers an option name from a nixpkgs version that no longer exists, and you
get an evaluation error with no obvious cause.

Dump the actual option set from the actual system and consult it before writing:

```bash
nix-build -E '(import <nixpkgs/nixos> { configuration = {}; }).config.system.build.manual.optionsJSON' \
  -o /var/lib/nixos-options
```

That `-o` flag writes a symlink to a build output *directory*, not to a file, so the
JSON you actually want to grep is one level down:

```bash
grep -o '"services.openssh.enable"' \
  /var/lib/nixos-options/share/doc/nixos/options.json
```

Worth stating plainly because pointing an agent at the top-level path just gives it
`IsADirectoryError` and it will improvise from there.

Regenerate after every flake.lock bump. Grepping this file before writing a module
costs a second and catches errors the syntax gate cannot.

## Rule eight: confirmation belongs to the human, not the model

An agent must not infer, anticipate, or assume your approval. A yes covers one
change, not a category. "You approved a firewall edit yesterday" is not approval for
today's firewall edit.

Nixi implements this well by never exposing the `confirmed` flag in the tool schema
the LLM sees, so the model is structurally unable to confirm on your behalf. If you
are building tooling around this playbook, copy that. If you are running the playbook
by hand in a chat window, the equivalent is discipline: the confirmation is a message
you typed, not a state the agent decided you were in.

## Rescue hierarchy

Ordered by independence from the thing that just broke. Verify the top two work
before your first real change, not after.

1. **Provider console (KVM/VNC).** Works with networking completely dead. Hetzner,
   OVH, Vultr, DigitalOcean and Proxmox all have one. Find yours now.
2. **A root password you actually know.** The only layer that depends on neither the
   network nor the Nix config. Set it at install time, store it in a password manager.
   Without this, the console shows you a login prompt you cannot get past, which is a
   uniquely frustrating way to learn this lesson.
3. **Older generation in the boot menu.** Reboot from the console, pick the previous
   entry. Undoes any `switch`.
4. **Provider snapshot.** Take one before large sessions. Hot snapshots are
   crash-consistent; shut down first if you want a clean one.
5. **Emergency SSH user.** Useful, but understand its limit: it is declared in the
   same config being edited, so a bad change can delete it along with everything else.
   It is a convenience layer, not the foundation. Layers 1 and 2 are the foundation.

## Secrets

Never in a plain git repo. Use [sops-nix](https://github.com/Mic92/sops-nix) or
[agenix](https://github.com/ryantm/agenix) from the beginning. Retrofitting secret
management after you have committed an API key means rewriting history, and you will
miss one.

The agent may reference a secret by name. It should not read, print, or generate
secret values.

## Decision records

Keep an ADR in `docs/adr/NNNN-title.md` for every non-trivial choice: why this
service, why that port, why you rejected the obvious alternative. Three months from
now you will look at a config line and have no memory of the constraint that produced
it.

Put them in the same repo as the config, not in the agent's memory. Agent memory is
not auditable, does not survive a tool change, and cannot be reviewed in a pull
request. See [../docs/adr/0001-record-architecture-decisions.md](adr/0001-record-architecture-decisions.md)
for the format.

## Known limits

Configurations vary enormously. What is idiomatic on one machine is wrong on another.
Generated modules are a starting point.

The syntax gate catches malformed Nix, not bad ideas. Semantic review is yours.

`nixos-rebuild test` does change the running system. It does not change the boot
default, which is not the same as changing nothing.

An agent running inside the box it administers is a compromise. It is convenient and
it is genuinely riskier than running from outside. The detached-rebuild and rollback
timer rules exist to make it survivable, not to make it free. If you want the safer
architecture, run the agent elsewhere and have it push changes over git.
