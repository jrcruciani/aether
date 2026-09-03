# 1. Record architecture decisions

Date: 2026-09-03

## Status

Accepted

## Context

An agent-managed system accumulates choices fast. Which reverse proxy, which port,
why the firewall allows that one CIDR, why we rejected the obvious option. Three
months later the config line is still there and the reason is gone.

Agent memory is the tempting place to put this. It is also the wrong place: it is not
auditable, it does not survive changing tools or models, it cannot be reviewed in a
pull request, and it is invisible to anyone else who touches the machine.

## Decision

Every non-trivial decision gets a numbered file in `docs/adr/`, committed alongside
the change it describes.

Format, kept deliberately small:

```
# N. Title

Date: YYYY-MM-DD

## Status
Proposed | Accepted | Superseded by ADR-M

## Context
What situation forced a choice.

## Decision
What we chose, in the active voice.

## Consequences
What this makes easier, what it makes harder, what we gave up.
```

Superseding rather than editing. Old ADRs stay, marked superseded, because the
reasoning that was wrong is often more useful than the reasoning that was right.

## Consequences

Slightly more friction per change. Considerably less archaeology later.

The agent is instructed to write these, which means their quality depends on the
agent. Review them like you would review code. A bad ADR is worse than none because
it looks like a record.
