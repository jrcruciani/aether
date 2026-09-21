# Execution modes

## Mode A: agent on the managed box (today)

The agent runs as the target's restricted account, reads local state and proposes
modules in the protected configuration repo. Follow [HARDENING.md](HARDENING.md)
and the [playbook](PLAYBOOK.md): `aether-apply build|test|switch` owns the pipeline;
a different human confirms R3 from a fresh SSH session. Target activation must
survive the agent/session being restarted, which is why rule four matters.

## Mode B: agent on a workstation or separate VM

The agent works in a clone of the target's config repo. It can author proposals
and build supported changes locally without activating anything, provided the
builder supports the target's Linux architecture. Use the target's reviewed
`flake.lock` and trusted baseline, not a workstation configuration or unrelated
options index. Local build success is not deployment or human approval.

The local agent process can no longer be killed by restarting the target's
services, so rule four mostly stops mattering for that process. Target-side
activation still needs supervision independent of the SSH session; a persistent
workstation terminal alone does not provide that. Choose one of the flows below.
Neither adds a hostile-code sandbox: the guardrail remains cooperative.

### Guarded handoff: the agent path

Aether has no shipped clone receiver, remote deployment CLI or `--target-host`
support in `aether-apply`. Its `--host` only checks the configured local host key.
Clone-to-target synchronization is a **human procedure**, not a feature:

1. A human reviews the proposal against the target's current baseline and transfers
   only `hosts/vps/modules/agent/YYYY-MM-DD-topic.nix`. Do not copy the clone's
   `.git`, lock, loader or trusted configuration over `/etc/nixos`. Preserve the
   root-owned baseline/Git metadata and sticky proposal directory from hardening;
   the proposal is a regular agent-owned file. Stop on drift or another request.
2. The target's restricted agent runs `sudo aether-apply build --risk R3`, reviews
   the diff and, after the human's go-ahead, runs `sudo aether-apply test --risk R3`.
   Test automatically arms before activation. The workstation build is not reused
   as privileged authority.
3. A different human opens a fresh second SSH connection from the same workstation
   used to reach the target, keeping the first open, checks access and the candidate,
   then runs `sudo aether-confirm` there. Disable SSH connection multiplexing for
   this check. Only successful confirmation/disarming creates the root-only,
   single-use token; neither a chat reply nor manual `aether-disarm` does.
4. Only then does the target agent run `sudo aether-apply switch --risk R3`.
   The helper commits after successful activation. R1/R2 follow the playbook's
   build/review/switch path; R4 and unsupported changes remain human handoffs.

Never give either agent root SSH credentials, raw rebuild privileges, confirmation
or timer-control sudo grants. Keep human credentials and SSH agent sockets out of
the model's reach. The target helper remains the only agent activation interface.
Do not commit an R3 proposal in either repo before confirmation and successful
switch; a human reconciles the clone with the helper's committed target result.

### Manual remote deployment: HUMAN-OPERATED ONLY

This is a separate administrator procedure, **not an agent fallback** when apply
refuses a proposal. It does not use apply's frozen candidate, policy gate or token.
Do not mix it with an active/pending apply transaction. The human owns review,
supervision, exact-source consistency, recovery and the eventual commit.

Here `host` is the target's SSH name, `vps` is its `nixosConfigurations` key, and
commands run from the human's config-repo clone on a compatible Linux builder.
The human needs `nixos-rebuild` and working SSH to the `localhost` build host.
That build session also needs target access. Root SSH must already be
human-authorized; do not enable it for the agent. Have the rescue console ready
and keep an initial human SSH session open.
Before proceeding, verify that the installed rebuild implementation supervises
target activation independently of SSH, or arrange that supervision separately.
These commands alone do not establish it; Aether supplies no remote launcher.
The deadman cancels recorded apply workers, not arbitrary remote rebuilds: the
human must ensure no in-flight manual activation can race recovery.

Stage only the reviewed proposal so flakes can see it; do not commit yet. Keep
the source and lock unchanged throughout, with no concurrent deployment:

```bash
git add -- hosts/vps/modules/agent/YYYY-MM-DD-topic.nix
nix flake check --no-update-lock-file
nixos-rebuild build --flake .#vps --no-update-lock-file
```

This prebuild is local by default and creates `result`. Review its closure
against the target's running system before testing.
Prebuild to keep deployment within the rollback deadline. Run each step only if
the previous one succeeded; save the known-good path printed by arm:

```bash
ssh root@host aether-arm
nixos-rebuild test --flake .#vps --target-host root@host --build-host localhost --no-update-lock-file
```

After test completes, open a **new connection from that same workstation**, not
an existing multiplexed transport:

```bash
ssh -o ControlMaster=no -o ControlPath=none root@host
```

In this new human session, check access, the running candidate and expected
services. Only if those checks pass, disarm there and require success:

```bash
aether-disarm
```

That is disarming over SSH, not an `aether-confirm` token. Then, back in the
unchanged clone on the workstation:

```bash
nixos-rebuild switch --flake .#vps --target-host root@host --build-host localhost --no-update-lock-file
```

Verify final activation before the human commits only the reviewed proposal.
Unlike apply, these raw rebuilds can re-evaluate source; stop if anything changed
or the built/tested/switched store paths differ. Never let the model execute this
procedure or treat it as permission to bypass restricted sudo.

## Failure and rescue in either mode

If the second connection fails, do not disarm, commit, switch or reapply. Wait
for **completed** rollback or a known-good console reboot, not merely an inactive
timer. Require successful `aether-status` with an exact `not armed` line, quiescent
activation/recovery, and both running system and boot default equal to the captured
known-good path. A restored SSH service alone is insufficient.

Remove only the failed request's module from the clone and any target copy;
never leave it ready for a later sync or switch. The human also clears that file's
staged entry in the external clone. For guarded transactions follow the
[post-rollback checklist](RESCUE.md#post-rollback-checklist-for-a-failed-r3-test):
the target's fresh `aether-apply build` owns staging and must print
`repo matches running system`; the agent never edits protected Git metadata.
For manual remote deployment there is no apply transaction enforcing this check:
the human rebuilds the cleaned clone without activation and compares its resolved
`result` path with the target's `/run/current-system`. Build failure or unequal
paths means stop, no new request or commit; never switch to force agreement.
Reconcile any target source copy too. Equality completes recovery, not approval
to retry. If failure happens after disarm, use console recovery rather than
waiting for a timer that is no longer armed.

The [rescue hierarchy](RESCUE.md#you-are-locked-out) is more important in Mode B:
wait for the deadman, use the provider console, boot a known-good/older generation,
repair from the console, then restore a snapshot as a last resort. The outside
agent survives a broken target but cannot recover it from inside when SSH is gone.
An emergency SSH user is still in the same failure domain; practise independent
console/root access before either mode.
