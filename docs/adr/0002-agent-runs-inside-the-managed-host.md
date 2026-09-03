# 2. Run the agent inside the host it manages

Date: 2026-09-03

## Status

Accepted, with reservations

## Context

Two architectures were available.

Outside: the agent runs on a separate machine, edits a git repo, and pushes changes
that the target pulls and applies, possibly through CI. This is what most of the
NixOS Discourse conversation recommends, and it is genuinely safer. The agent cannot
kill itself, cannot be affected by a broken firewall on the target, and the review
surface is a pull request.

Inside: the agent runs on the machine it manages. It can read live state, tail
journals, check whether a service actually came up, and iterate without a round trip.
It can also delete its own network access, and it dies partway through any rebuild
that restarts its cgroup.

## Decision

Inside, with compensating controls.

The immediacy is the point of the project. An agent that can only propose patches to
a repo is a code assistant with extra steps; it cannot answer "is it working now"
without a human relaying the answer. Conversational administration means the agent
sees what happens after it acts.

Compensating controls, all mandatory:

- Every rebuild is detached via `systemd-run --scope`, never a direct child of the
  agent process.
- A rollback timer is armed before any R3 change.
- Rescue layers that do not depend on the agent, the network, or the Nix config:
  provider console plus a known root password, drilled before first use.
- R4 changes are never applied by the agent.

## Consequences

Faster, more useful conversations. A real class of failure that the outside
architecture does not have.

If the compensating controls are skipped, this decision is straightforwardly bad. The
playbook is not optional flavour on top of the architecture; it is what makes the
architecture defensible.

Revisit if the failure rate turns out worse than expected. The measurable version:
count how many times a human has to open the provider console over three months. More
than once and the outside architecture wins.
