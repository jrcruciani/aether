# Aether

An operating system you configure by talking to it.
AI lives alongside the OS itself, transforming your intentions into declarative operations that reconfigure the OS on demand.

You just say "I need a Postgres database on this machine, only reachable from my
laptop" and the agent writes a Nix module, compiles it, show you the diff, applies it...
or, if the change locks you out the machine, rolls itself back before you panic.

Aether is playbook, a set of rules, prompts and
guardrails that turn any competent LLM agent into something you can trust with root
on a NixOS box. The idea is to make the blast radius small enough that letting it roll stops being reckless.

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
R3 and R4 have not been exercised against anything except a careful reading.
It has not been through a hundred hostile configurations. If you point it at
something you care about without reading it first, that is on you.

What exists today: the safety protocol, the system prompt, the rescue runbook,
worked examples, and a NixOS module packaging the rollback timer. What does not
exist: a CLI, a test suite, multi-host support.

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
  -> git add, nix flake check, nixos-rebuild build
  -> nothing has touched the running system yet
  -> R1/R2: after a successful build, review the diff, commit, nixos-rebuild switch
  -> R3: arm a rollback timer, then nixos-rebuild test; no commit yet
  -> R3: stop and wait for your explicit second-SSH-session confirmation
  -> R3: only after aether-disarm succeeds, commit, nixos-rebuild switch
```

Your `configuration.nix` is read for context and never rewritten. Each change is one
small file with a date in its name. Reverting is deleting a file. If the build
fails, the generated module is removed rather than left half-applied.

If the second session fails, stop and let the timer fire or reboot into the previous
generation. Only once rollback has completed, check `aether-status`: it must say
`not armed`, not merely return success. From the repo root, remove exactly the failed
request's `hosts/<host>/modules/agent/YYYY-MM-DD-topic.nix`, run `git add -A` and
`nixos-rebuild build --flake .#<host>`, then compare `readlink -f ./result` with
`readlink -f /run/current-system`. Report `repo matches running system` only if they
are equal; otherwise report `repo and running system DIVERGE` and stop. A failed
build also means stop and show the error, with no follow-on commit or activation.
Do not clean unrelated dirty files or stage another request's changes. The
[post-rollback checklist](docs/RESCUE.md#post-rollback-checklist-for-a-failed-r3-test)
has the guarded console commands. A match completes recovery, not approval to retry.

## Risk levels

The agent announces the level before it touches anything.

| Level | What it covers | Policy |
| --- | --- | --- |
| R0 | Reading, diagnosis, explaining | Free |
| R1 | Packages, fonts, user programs | Normal flow |
| R2 | Services, timers, apps with no new network exposure | Normal flow, summary first |
| R3 | Networking, firewall, SSH, kernel, GPU | Rollback timer, test before switch, explicit confirmation |
| R4 | Users, secrets, disks, bootloader, encryption | Never applied automatically. Emitted as instructions for you to run |

R4 is the line I will not let an agent cross. Those are the changes where a failure
is not fixed by rolling back, because the thing you would roll back with is gone.

## The rollback timer

This is the piece I would keep even if you threw the rest away. Before applying
anything that touches the network, arm it:

```bash
aether-arm 10min
```

Then apply with `nixos-rebuild test`. If you explicitly confirm you can still log in
from a second SSH session, run `aether-disarm`; only if it succeeds, commit and
switch. The agent cannot confirm for you. If you cannot log in, let the timer fire.
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
  };
}
```

That gives you `aether-arm`, `aether-disarm` and `aether-status`. Nothing runs in
the background and nothing touches your configuration on its own.

The line this README used to tell you to paste did not work. It called
`nixos-rebuild switch --rollback`, which re-evaluates your flake and looks for a
configuration named after the hostname, so it failed on the first live test and left
the system exactly where it was. The module rolls back without evaluating anything.
Full story in
[docs/FIELD-NOTES-rollback-timer-2026-09.md](docs/FIELD-NOTES-rollback-timer-2026-09.md),
including the second attempt, which rolled back the profile and then died before
activating it.

## Getting started

You need a NixOS machine you are willing to break, flakes enabled, and an LLM agent
that can run shell commands and read files. I use [Hermes](https://hermes-agent.nousresearch.com),
but nothing here is specific to it. Claude Code, Codex, Aider with a shell, or your
own loop will all work.

1. Read [docs/PLAYBOOK.md](docs/PLAYBOOK.md). It is the actual product. About fifteen
   minutes.
2. Set up your repo like [examples/](examples/) and get `nixos-rebuild build` passing.
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

It's not yet a package. There is no binary and no daemon. Some of this will probably become
tooling later, but the rules matter more than the wrapper, and rules ship faster.

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
