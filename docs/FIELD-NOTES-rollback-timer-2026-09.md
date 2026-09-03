# Field notes: the rollback timer did not roll back

The README has been saying for a while that the deadman timer is the piece worth
keeping even if you throw the rest of this away. Packaging it as a NixOS module
meant testing it, which meant arming it and letting it fire instead of stopping it
in time like you would on a real change.

It fired. Nothing rolled back. The system sat exactly where it was.

Three firings on the live VPS to get from there to a timer that works. Here they
are in order, because the second failure is more interesting than the first.

## Firing one: the obvious command was the wrong command

```
$ readlink /nix/var/nix/profiles/system
system-11-link
$ aether-arm 30s
$ sleep 75
$ readlink /nix/var/nix/profiles/system
system-11-link
```

The journal:

```
nixos-rebuild[8063]: error: flake 'git+file:///etc/nixos' does not provide
attribute '...nixosConfigurations."nixos-experimento".config.system.build.nixos-rebuild'
deadman-rollback.service: Failed with result 'exit-code'.
```

`nixos-rebuild switch --rollback` re-evaluates the flake, and it derives the
configuration name from the machine's hostname. The host is `nixos-experimento`.
The configuration is called `vps`. There is no `nixosConfigurations.nixos-experimento`,
so the rollback failed on a mismatch between two names that had never needed to
agree before.

Read that line again with the actual situation in mind. The timer exists for the
case where you just cut off your own SSH access. That is the moment it chooses to
need a working flake evaluation, a correctly guessed attribute name, and a Nix
store that can build. Every one of those is a thing that can be broken by the change
you were testing.

So the fix is not to guess the attribute name better. It is to stop evaluating
anything at all. The previous generation is already built and sitting on disk:

```bash
nix-env --profile /nix/var/nix/profiles/system --rollback
"$(readlink -f /nix/var/nix/profiles/system)"/bin/switch-to-configuration switch
```

Nothing to evaluate, nothing to build, nothing to resolve.

## Firing two: half a rollback, which is worse

```
aether-rollback[9668]: switching profile from version 12 to 11
aether-rollback[9671]: aether-rollback: line 12: readlink: command not found
deadman-rollback.service: Failed with result 'exit-code'
```

`writeShellApplication` builds a wrapper with a closed PATH containing exactly the
`runtimeInputs` you declared, which is the whole reason to use it. I declared `nix`
and `systemd` and forgot that `readlink` lives in coreutils.

The state this leaves you in is the bad one. The profile pointer moved back to
generation 11. The running system was still 12. A reboot would have "fixed" it in a
way that looks like the rollback worked, which is exactly the kind of thing you do
not want to discover later while trying to reconstruct what happened.

Worth stating plainly: a deadman switch that fails when it fires is worse than not
having one, because you made a riskier change than you otherwise would have,
counting on it.

## Firing three

```
=== ANTES: system-13-link ===
ARMED
aether-rollback: activating the configuration...
aether-rollback: setting up /etc...
nixos: finished switching to system configuration /nix/store/wxqgmi...
deadman-rollback.service: Deactivated successfully.
=== DESPUES: system-12-link ===
```

Machine still up, sshd still running, timer disarmed and gone.

## What to take from this

The timer had been in the README since the beginning, described confidently, in the
section that says it is the one thing to keep. It had never been fired. It did not
work, and it did not work for a reason that only exists on hosts where the
configuration is not named after the machine, which is most of them.

You cannot review your way to this. The command reads correctly. It is the command
everyone writes. It appears in other people's runbooks. The only way to find out
was to arm it and wait.

Which is the argument for doing the rescue drill in `docs/RESCUE.md` before you need
it, and it is now also an argument for arming the timer once, deliberately, on a
machine you do not care about, before you rely on it on one you do.
