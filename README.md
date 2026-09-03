# Aether

An operating system you configure by talking to it.

Aether is not a program you install but rather a playbook: a set of rules, prompts and
guardrails that turn any competent LLM agent into something you can trust with root
on a NixOS box. You just say "I need a Postgres database on this machine, only reachable from my
laptop" and the agent should write a Nix module, compiles it, show you the diff, apply it,
and (if the change locks you out the machine) roll itself back before you panic.

The idea is to make the blast radius small enough that letting it roll stops being reckless.

## Status

Alpha, and very. The playbook is written and in daily use on a single VPS. 
It has not been through a hundred hostile configurations. If you point
it at something you care about without reading it first, that is on you.

What exists today: the safety protocol, the system prompt, the rescue runbook, and
worked examples. What does not exist: a packaged binary, a test suite, multi-host
support.

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
  -> for risky changes: arm a rollback timer, then nixos-rebuild test
  -> you confirm from a second SSH session that you are still alive
  -> disarm the timer, commit, nixos-rebuild switch
```

Your `configuration.nix` is read for context and never rewritten. Each change is one
small file with a date in its name. Reverting is deleting a file. If the build
fails, the generated module is removed rather than left half-applied.

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
anything that touches the network:

```bash
systemd-run --collect --unit=deadman-rollback \
  --on-active=10min nixos-rebuild switch --rollback
```

Then apply the change. If you can still log in, you stop the timer. If you cannot,
the machine reverts itself in ten minutes without you finding the console password
you wrote down eighteen months ago. It costs one line and it removes most of the
fear from remote firewall edits.

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
