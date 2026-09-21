# Aether

An operating system you configure by talking to it.
AI lives alongside the OS itself, transforming your intentions into declarative operations that reconfigure the OS on demand.

You just say "I need a Postgres database on this machine, only reachable from my
laptop" and the agent writes a Nix module, compiles it, show you the diff, applies it...
or, if the change locks you out the machine, rolls itself back before you panic.

Aether is playbook, a set of rules, prompts and
guardrails for a separate, restricted LLM-agent account on a NixOS box.
It is a cooperative workflow guardrail, not a sandbox for hostile Nix or a way to
constrain an agent that already has root.

## The longer bet

Every few years someone argues we should go back to devices that do one thing well.
Buy the e-reader, buy the camera, buy the dedicated box, because the machine that
does everything does all of it adequately and none of it properly. The complaint is
valid but the fix is not: it means owning fifteen objects and binning fourteen of
them the moment your needs shift.

There is another way to read the same complaint. The specialisation does not have to
live in the hardware. A laptop that becomes a photo editing station in the morning
and a build server in the afternoon is not a compromise between two machines. It is
one machine wearing two configurations, each of them a file you can read and a boot
entry you can go back to. A five euro VPS is a mail server this week and a git host
next month, and undoing that is picking an older generation from a menu.

The idea is not new. Software defined networking did it to routers, virtualisation
did it to physical servers, immutable infrastructure has been doctrine since the early
2010s. What changes now is the interaction. Reshaping a machine has always meant writing the
description yourself, which is a real skill and a real afternoon. When the trigger is
a sentence you write, that cost drops far enough to change what you bother
reshaping at all. You stop asking which computer to buy and start asking what you
want this one to be today.

Of course this only reaches what is already programmable. A glucose monitor
needs a sensor, an e-reader needs e-ink, and no amount of declarative config conjures
hardware that is not there. But we do have all these Von Neumann machines around and can leverage that.

## Status

Alpha, and very. The playbook runs on one VPS. R1 and R2 have been through the full
pipeline end to end, and the rollback timer has been armed and allowed to fire three
times, which is how two bugs in it were found. Those runs are written down in
[docs/FIELD-NOTES-first-change-2026-09.md](docs/FIELD-NOTES-first-change-2026-09.md)
and
[docs/FIELD-NOTES-rollback-timer-2026-09.md](docs/FIELD-NOTES-rollback-timer-2026-09.md).
Those historical field notes predate the guarded apply entry point. The current
checks include disposable-VM scenarios for restricted sudo, human confirmation,
R4 refusal and recovery; see [the changelog](docs/CHANGELOG.md) for actual run
evidence rather than treating a test's existence as a passing result.
It has not been through a hundred hostile configurations. If you point it at
something you care about without reading it first, that is on you.

What exists today: the safety protocol, the system prompt, the rescue runbook,
worked examples, a NixOS module packaging `aether-apply`, human-only
`aether-confirm`, the rollback timer and pinned options index, and Linux VM checks.
What does not exist: an LLM conversation frontend, a semantic Nix security sandbox,
a broad system test suite or multi-host apply support.

## Why bother

Handing an LLM a shell on a running server is a bad idea and most "AI sysadmin"
tools do exactly that. The model emits commands, something runs them, and there is
no review surface and no honest undo.

NixOS changes the shape of the problem. Your system is a description, not an
accumulation of things you once typed. Builds are evaluated before they activate.
Old generations stick around in the bootloader. So you can constrain the model to
something far narrower than "run commands": produce a declarative module, and let
Nix decide whether it is valid. The model proposes. Nix judges. You confirm.

Besides, don't you want a self-configuring OS? Such a cool idea!

## How it works

Every request you make goes through the same pipeline.

```
you ask for something in plain language
  -> agent classifies the risk (R0 to R4)
  -> agent writes ONE isolated module into modules/agent/
  -> aether-apply build: freeze exact source, stage, check, build and show closure diff
  -> nothing has touched the running system yet
  -> R1/R2: review the diff, then aether-apply switch; helper commits after success
  -> R3: aether-apply test auto-arms the rollback timer; no commit yet
  -> R3: DIFFERENT human opens a fresh SSH session and runs aether-confirm
  -> R3: confirmation disarms and authorizes only the exact tested candidate
  -> R3: aether-apply switch consumes approval; helper commits only after success
```

Your `configuration.nix` is read for context and never rewritten. Each change is one
small file with a date in its name. The protected loader imports new proposal
files automatically. The helper rejects dirty files elsewhere and unsupported
dynamic syntax rather than pretending prefix scanning proves arbitrary Nix safe.
See [HARDENING.md](docs/HARDENING.md) for the exact supported forms and setup.

If the second session fails, stop and let the timer fire or reboot into the previous
generation. Only once rollback has completed, check `sudo aether-status`: it must succeed
and print an exact `not armed` line, even if it also prints the rollback target.
From the repo root, remove exactly the failed
request's `hosts/<host>/modules/agent/YYYY-MM-DD-topic.nix` and run
`sudo aether-apply build`. The persistent recovery gate compares the fresh build
with `/run/current-system`: it prints `repo matches running system` only on
equality, otherwise `repo and running system DIVERGE` and stops. A failed build
also means stop, with no follow-on commit or activation.
The recovered running system and boot-default profile must both match the
captured known-good target first. Successful activation after a failed profile
update does not clear that gate; a human must repair the boot default.
Do not clean unrelated dirty files or stage another request's changes. The
[post-rollback checklist](docs/RESCUE.md#post-rollback-checklist-for-a-failed-r3-test)
has the guarded console commands. A match completes recovery, not approval to retry.

## Risk levels

The agent announces and declares the level with `--risk` before acting. The helper
uses the higher of that declaration, its conservative prefix floor and the
closure-size floor (at least 40 nonempty diff lines). It never lowers a declaration.

| Level | What it covers | Policy |
| --- | --- | --- |
| R0 | Reading, diagnosis, explaining | Free |
| R1 | Packages, fonts, user programs | Normal flow |
| R2 | Services, timers, apps with no new network exposure | Normal flow, summary first |
| R3 | Networking, firewall, SSH, kernel, GPU | Rollback timer, test before switch, explicit confirmation |
| R4 | Users, secrets, disks, swap, bootloader, security, guardrail policy | Refuse without staging/build/activation; emit human review instructions |

R4 is the line I will not let an agent cross. Those are the changes where a failure
is not fixed by rolling back, because the thing you would roll back with is gone.
Kernel/initrd and all `hardware.*` changes, including GPU requests, are build-only
in this iteration: the helper refuses live test/switch and hands boot/reboot
decisions to a human.

## The rollback timer

This is the piece I would keep even if you threw the rest away. For an R3 proposal:

```bash
sudo aether-apply build --risk R3
sudo aether-apply test --risk R3
```

The test command arms automatically and refuses activation if arming fails.
A different human principal opens a fresh SSH session, reviews the candidate and
runs `sudo aether-confirm`. That command owns successful disarming and writes a
root-only, single-use token; the agent cannot confirm for you. Then the agent uses
`sudo aether-apply switch --risk R3`, and the helper commits only after successful
activation. If you cannot log in, let the timer fire.
It restores the running system, not the repo: the failed module must still be
removed and the repository-build comparison above must pass before another change.

It used to be a `systemd-run` line in this README that you were expected to paste
correctly from memory, in the one situation where you are least calm. Now it is a
NixOS module:

```nix
{
  inputs.aether.url = "github:jrcruciani/aether";

  # in your nixosSystem, with aether passed through specialArgs
  imports = [ aether.nixosModules.aether ];
  services.aether = {
    enable = true;
    rollbackTimeout = "10min";
    flake = "/etc/nixos"; # default; contains your reviewed flake.lock
    host = "vps";        # nixosConfigurations key, not the OS hostname
    agentUser = "agent"; # after following docs/HARDENING.md
  };
}
```

That gives you `aether-apply`, `aether-confirm`, `aether-arm`, `aether-disarm`,
`aether-status` and `aether-index`.
Nothing runs in the background and nothing touches your configuration on its own.
Enabling the module does not create accounts, grant sudo or fix permissions.
Timer-only installs can omit `host` and `agentUser`; apply/confirm report setup
errors and the index requires its explicit host.

Run `aether-index` as root after setup and after each host `flake.lock` or module
change. It builds
`/etc/nixos#nixosConfigurations.vps.config.system.build.manual.optionsJSON`
without updating the lock, and replaces `/var/lib/nixos-options` only after a
successful build. The JSON stays at
`/var/lib/nixos-options/share/doc/nixos/options.json`. Keep
`documentation.enable` and `documentation.nixos.enable` enabled: disabling either
removes this attribute on the tested 25.05 and 25.11 pins. Disabling only
`documentation.doc.enable` still permits the JSON build.
[Rule seven](docs/PLAYBOOK.md#rule-seven-ground-the-model-in-real-options) covers
name versus type checks, imported-module options and the direct build command.

`aether-arm` saves the running system's store path in
`/run/aether/rollback-target` before starting the timer. Recovery sets the system
profile to that exact path, then activates it. It does not go back one generation:
`nixos-rebuild test` leaves the profile alone, so that would skip the system I was
trying to get back to. If the pin is missing or invalid, recovery warns in the
journal and uses the current boot-default profile instead. It still attempts
activation if updating the profile fails, but reports the failure rather than
pretending the boot default is safe. `aether-status` shows the pin and the timer's
time remaining; `aether-disarm` remains a human manual timer helper, not agent
confirmation. During apply, the candidate and baseline also have GC roots.
Rollback invalidates confirmation and cancels a blocked activation with bounded
waits, without waiting indefinitely for an apply lock.

The line this README used to tell you to paste did not work. It called
`nixos-rebuild switch --rollback`, which re-evaluates your flake and looks for a
configuration named after the hostname, so it failed on the first live test and left
the system exactly where it was. The module rolls back without evaluating anything.
Full story in
[docs/FIELD-NOTES-rollback-timer-2026-09.md](docs/FIELD-NOTES-rollback-timer-2026-09.md),
including the second attempt, which rolled back the profile and then died before
activating it.

The regression suite lives in `tests/rollback.nix`, exposed once as
`checks.x86_64-linux.deadman`. On x86_64 Linux with KVM, run
`nix flake check --no-update-lock-file --print-build-logs`; GitHub Actions runs the
locked deadman target in a disposable NixOS VM. It test-activates a prebuilt
specialisation that stops sshd, then waits for real timer recovery of the running
path, system profile and SSH. It checks that the pin wins even when the boot
default has moved, and that missing or invalid pins warn and fall back. Separate
subtests outwait a disarmed timer, reject a second arm, and race two arms without
losing the pin. Journal checks use a fresh cursor for each recovery and disarm
scenario, and finished transient units must disappear, not just become inactive.
This is a direct-boot VM check, not a bootloader test or permission to try the timer
on a live host. It also checks that a timer-only install rejects `aether-index`
without guessing a host. The locked `nixpkgs-test` input is only for repository checks.
Importing the module still uses your own `pkgs`.

`checks.x86_64-linux.apply` exercises the actual account/sudoers setup, immutable
builds, package activation, R3 human confirmation and refusal/recovery paths.
`checks.x86_64-linux.apply-policy` covers the bounded reader and floor/threshold
rules. CI runs the locked VM targets in separate jobs; the aggregate command
above still covers all checks. This is disposable test infrastructure, not proof
that hostile Nix has been sandboxed or that a production bootloader was tested.

A separate Linux CI job runs `bash tests/index-pins.sh`: it copies the example
host, locks it to a fixed 25.05 revision, generates real options, bumps the fixture
lock to a fixed 25.11 revision, and requires a different option count. It runs the
packaged helper with an empty caller PATH and checks that failed builds preserve
the old index. Those networked builds do not run inside the deadman VM or change
the package set used by a host.

## Getting started

You need a NixOS machine you are willing to break, flakes enabled, and an LLM agent
that can run shell commands and read files. I use [Hermes](https://hermes-agent.nousresearch.com),
but nothing here is specific to it. Claude Code, Codex, Aider with a shell, or your
own loop will all work.

1. Read [docs/PLAYBOOK.md](docs/PLAYBOOK.md). It is the actual product. About fifteen
   minutes.
2. Set up your repo like [examples/](examples/), review and commit its lock, and
   complete [HARDENING.md](docs/HARDENING.md) with separate accounts and protected
   source ownership. Configure the explicit host key and generate the index.
3. Feed [prompt/AETHER.md](prompt/AETHER.md) to your agent as a system prompt or
   project instruction file.
4. Do the rescue drill in [docs/RESCUE.md](docs/RESCUE.md) *before* your first real
   change. Open the KVM console, log in as root, boot an older generation. Once. In
   calm conditions. The whole model rests on you having done this.
5. Ask for something small. "Install ripgrep." Watch what it does.

## What Aether is not

It's not autonomous, yet. It plans and proposes and waits. If you want a server that
administers itself while you sleep, this will disappoint you on purpose, at least in it's current iteration.

This is not a substitute for reading your config. If you cannot read the module, do not
approve it. The syntax gate catches malformed Nix, not bad ideas.

It packages policy helpers, not an LLM frontend or an always-running agent daemon.
The scanner deliberately refuses valid but unsupported Nix rather than
overpromising isolation. Kernel/initrd/hardware test/switch and all R4 operations are human
handoffs. Full root access or additive sudo grants bypass the account boundary.

## Prior art

As usual I thought I had a unique idea at first but a little digging turned out some very nice previous works.
Two projects got here first and both are worth your time:

- [nix-agent](https://github.com/ph0xphene/nix-agent) by ph0xphene. Rust CLI, strict
  plan and apply split, never lets the model emit shell commands. The risk tiers and
  the isolated module pattern in Aether come straight from it.
- [Nixi](https://codeberg.org/ewrogers/nixi) by Erik Rogers. Go, conversational, TUI
  and web UI, multi node, SQLite memory. Its confirmation model, where the runtime
  and not the LLM owns the confirmation flag, is a good idea I stole.

There is also an ongoing conversation on the NixOS Discourse about agentic control
layers that propose patches instead of mutating directly. Read that before you decide
any of us are being original.

What Aether adds: the rollback timer, an explicit rescue hierarchy for agents running
*inside* the box they administer, and architecture decisions recorded in the same repo
as the config rather than lost in a chat log.

## Contributing

Yes, please. Especially: reports of it breaking, other hypervisors' equivalent of the
KVM console, and anyone who has run this on a laptop rather than a VPS. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. Do what you like.
