# Field notes: the first change that actually went through

The playbook describes a pipeline. Until today nothing had gone through it end to
end on the live box, which meant the pipeline was a claim and not a fact. So here
is the smallest possible request, run against the real VPS, with the real output
pasted in and the two things that broke left where they broke.

The request: install ripgrep and fd. Risk level R1, packages only, no new network
exposure, normal flow with no deadman timer.

## Checking the preconditions

```
$ git status --porcelain
(empty)
$ ls /var/lib/nixos-options
nix-support  share
```

Clean tree, index present. And there is the first surprise already, but it takes
a couple of failures before it registers.

## Grounding the option in something real

The prompt says to check the option index before writing a module, so:

```
IsADirectoryError: [Errno 21] Is a directory: '/var/lib/nixos-options'
```

Right. `nix-build -o` writes a symlink to a build output directory, not to a file.
The JSON is one level down, at `/var/lib/nixos-options/share/doc/nixos/options.json`,
and the playbook telling you to "grep this file" was wrong on both counts. Fixed in
`prompt/AETHER.md` and `docs/PLAYBOOK.md`.

Small thing. It cost two failed attempts, and any agent following the instructions
literally would hit exactly the same wall and then start improvising, which is the
behaviour the whole document exists to prevent.

With the right path:

```
environment.systemPackages exists: True | type: list of package
total options: 24649
```

24,649 options on this system. That is the number the model would otherwise be
guessing against from memory.

## The module

`hosts/<host>/modules/agent/2026-09-03-ripgrep-and-fd.nix`, one concern, nothing
else touched. `configuration.nix` read for context and left alone.

```
$ nix flake check
warning: Git tree '/etc/nixos' is dirty
evaluating flake...
checking flake output 'nixosConfigurations'...
checking NixOS configuration 'nixosConfigurations.vps'...
all checks passed!
```

```
$ nixos-rebuild build --flake .#vps
Done. The new configuration is /nix/store/d4b8nzz...-nixos-system-...
```

Nothing has been activated at this point. There are now two systems in the store,
the one that is running and the one that would run.

## The step that should have been in the playbook from the start

```
$ nix store diff-closures /run/current-system ./result
fd: ∅ → 10.4.2, 3.9 MiB
ripgrep: ∅ → 15.1.0, 6.2 MiB
```

Two lines, for a request that asked for two things.

This is the best review surface in the whole flow and it was not in the playbook
until this run. Reading a Nix module tells you what the agent wrote. `diff-closures`
tells you what the system will actually become, compared against what is running
right now, and it does it before anything is activated. If a request for two CLI
tools prints forty lines, you found out for free.

It is now a required step in the normal flow.

## Switch

```
$ nixos-rebuild switch --flake .#vps
updating GRUB 2 menu...
activating the configuration...
$ rg --version
ripgrep 15.1.0
$ fd --version
fd 10.4.2
```

Generation 10. Generation 9 still sits in the bootloader.

## The second thing that broke

```
$ git status --porcelain
 M result
```

`result` is in `.gitignore`. It is also tracked, because it got committed before
anyone thought to ignore it, and `.gitignore` has no opinion about files git is
already tracking.

Which means every build dirties the tree, and the prompt tells the agent to stop
when the tree is dirty in ways it cannot explain. The workflow disables itself on
the second run. Not the first, the second, which is the kind of bug you only find
by running something twice.

```
$ git rm --cached result
$ nixos-rebuild build --flake .#vps >/dev/null
$ git status --porcelain
(empty)
```

## What this run was worth

Two real bugs, both of them in the instructions rather than in the machine, and
both of them the sort that only surface when someone runs the thing instead of
describing it. Neither was visible from reading the repo. One of them would have
silently stopped the workflow the second time anyone used it.

Plus `diff-closures`, which was not in the design and is now the step I would keep
if I had to throw the rest away, along with the rollback timer.

Everything above is a copy-paste from one session on one VPS. It is one host, one
R1 change, and a sample size of one. R3 and R4 remain untested against anything
except a careful reading.
