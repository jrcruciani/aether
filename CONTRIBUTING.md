# Contributing

Aether is a playbook, so most useful contributions are text rather than code.

## What I actually want

**Reports of it failing.** The most valuable thing you can send. What did you ask
for, what did the agent generate, what broke, which rescue layer got you back. Even
if the answer is "I had to restore a snapshot", especially then. Open an issue with
the failure template.

**Other providers' console procedures.** The rescue runbook covers Hetzner, Proxmox
and the usual VPS crowd. If you run this on Oracle Cloud, Scaleway, AWS, a Raspberry
Pi, or a laptop, the equivalent steps for your setup are a direct improvement.

**Laptop and desktop experience.** The playbook assumes a remote server, which shapes
several rules. Someone who has run this on a workstation will find assumptions that
do not apply.

**Prompt improvements that survived contact.** If you changed `prompt/AETHER.md` and
it measurably behaved better, say what changed and what you observed. "It felt better"
is not enough, and I would rather have five honest observations than a rewrite.

**Rules that turned out to be wrong.** If a rule in the playbook is cargo cult, say
so with the reasoning. I would rather cut a rule than keep one nobody understands.

## What I will push back on

Changes that make the agent more autonomous. The waiting is deliberate.

Moving R4 operations into the automated path. Users, secrets, disks, bootloader and
encryption stay manual, because they can damage the recovery mechanism itself.

Removing the rollback timer for simplicity. It is one line and it is the highest
value line in the repo.

A rewrite into a packaged tool as the first contribution. Tooling will probably
happen. It should follow the rules settling down, not precede it.

## Style

Write like a person explaining something to a colleague. Specific over grand. No
"leverage", no "seamless", no "in today's rapidly evolving landscape". If a sentence
could open a press release, cut it.

Say what something costs, not only what it gives you. Every rule here has a downside
and the docs should name it.

## Practically

Fork, branch, pull request. Keep changes focused. If you touch the playbook, say in
the PR description what problem you hit that made you want the change.

The rollback VM check runs in Linux GitHub Actions. With x86_64 Linux and KVM,
`nix flake check --print-build-logs` runs it locally too. It uses the locked
test-only nixpkgs input, not the package set of a host importing the module. If
you add Nix that is meant to evaluate, say what you tested and on which NixOS
release. A disposable VM run is not a live-host field note.
