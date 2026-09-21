# Changelog

## 01: pin the rollback target

I changed the timer to return to the system that was running when it was armed.
Stepping back a generation was wrong after `test`, because the profile was still
pointing at the known-good system. The helper now records that path, restores the
profile and activates it directly; a missing or invalid pin warns and uses the
boot default instead. Status shows the pin, and disarming removes it. Arm and
disarm share a lock so a competing arm cannot steal a live timer's pin. The
[Linux VM run](https://github.com/jrcruciani/aether/actions/runs/35610109795)
passed against the locked NixOS 26.05 test input: it test-activated a prebuilt
specialisation that stops sshd, then waited for the timer and checked that both
the running path and system profile returned to the pinned base and sshd listened
again. The same checks passed after deleting the pin, with the fallback warning
in the journal. Concurrent arming, status and pin removal on disarm also passed.
This is a disposable, direct-boot VM, not a bootloader test or a live-host field
note; no timer was tested on a live host for this change.

## 02: recover the repo after a failed R3 test

R3 modules are now committed only after the human confirms access from a second
SSH session and `aether-disarm` succeeds, before the final switch. Previously the
commit happened before the test, so a timer rollback left the bad module ready to
be reapplied. The prompt, playbook, README and rescue runbook now require completed
rollback, a successful `aether-status` with an exact `not armed` line, removal of only
the failed request's module, and a fresh repository build whose resolved path equals
`/run/current-system`.
A failed build or a different path stops recovery without a commit or activation.
Evidence: a manual walkthrough of the success and failure branches and a check of
every `git commit` example in the prompt and playbook. Shell-gate checks cover both
one-line status output and multiline output with the rollback target, plus rejection
of armed or failed status checks. This is a documentation change, not a VM test.

## 03: build the options index from the host's lock

Rule seven was building from a channel, not the host's `flake.lock`, so its index
could confidently describe the wrong options. `services.aether.enable` now also
installs `aether-index`, with an explicit configuration key in `services.aether.host`
and a local `services.aether.flake` directory, defaulting to `/etc/nixos`. It requires
a lock, refuses to update it, and leaves the old symlink alone on build failure;
timer-only installs still work without a host key. The README, playbook, prompt and
examples agree on setup and the unchanged `share/doc/nixos/options.json` layout.
The [Linux evidence run](https://github.com/jrcruciani/aether/actions/runs/35613584766)
built that exact manual attribute from a disposable copy of the example host:
22,116 options at NixOS 25.05 revision `ac62194c3917d5f474c1a844b6fd6da2db95077d`,
then 23,290 after changing the same fixture lock to NixOS 25.11 revision
`b6018f87da91d19d0ab4cf979885689b469cdd41`. The helper produced the same output as
the direct build with an empty caller PATH, a space in the flake directory, and
an OS hostname different from the configuration key. On both pins, disabling
`documentation.nixos.enable` or `documentation.enable` removed `system.build.manual`;
the failed helper preserved the old index. Disabling only `documentation.doc.enable`
still built the JSON. Invalid inputs, missing locks and unknown hosts also failed
without replacing it. All eight deadman VM subtests passed, including a timer-only
install's missing-host error. The option counts come from the host pins, not the
root test-only input; the disposable KVM guest still uses its own locked input.
No timer was tested on a live host.

## 04: exercise the deadman in a disposable VM

I extended the existing VM harness rather than adding a second build, and exposed
it as `checks.x86_64-linux.deadman`. Recovery now has to restore the running path,
profile and SSH even when the boot default differs from the pin; missing and
invalid pins must warn before falling back. Separate subtests disarm and wait
past the deadline plus systemd's timer accuracy, reject a second arm with its
message, and keep the concurrent-arm pin check. Finished transient units must
disappear, and fresh journal cursors stop an earlier rollback from contaminating
the next scenario. The [Linux VM run](https://github.com/jrcruciani/aether/actions/runs/35611400808)
passed all seven subtests with
`nix flake check --no-update-lock-file --print-build-logs` against the locked
NixOS 26.05 input, including the full 70-second disarm wait. The runtime helpers
did not change. This is still a direct-boot KVM guest, not a bootloader test or a
timer experiment on a live host.

## 05: apply through a single guarded entry point

I added the single-entry-point ADR, `aether-apply build|test|switch` and a separate
human `aether-confirm`. Apply uses the configured flake/host, scans a deliberately
bounded static syntax, stages and builds an exact root-owned snapshot, prints the
closure diff and activates only that built store path in a detached scope. Tool
floors cannot be lowered by `--risk`; R4 and unsupported proposals show a bounded
source diff without mutation, and kernel/initrd/hardware activation is a manual
handoff. R3 test auto-arms, confirmation requires a different principal and
successful disarm, and commits follow successful final activation rather than
preceding a risky test. Approval is candidate-bound and single-use; recovery
cancels a blocked worker without waiting on its apply lock, and a durable pending
gate requires a safe running/boot-default pair plus a fresh repository build equal
to the running system. The prompt, playbook, README and hardening/rescue
instructions now agree on that account and ownership contract. The
[Linux evidence run](https://github.com/jrcruciani/aether/actions/runs/35635585546)
at code SHA `b30cb4406dbe293867c2a0bf0db209959c333cce` passed 17
policy/identity/state tests and all 13 restricted-account VM scenarios, including
real ripgrep 15.1.0/fd 10.4.2 installation, separate-human SSH confirmation, sudo
denials, unchanged R4 state, stale/foreign approval, arm/disarm failure, blocked
and failed activation, an actual failed profile update that still attempted
recovery activation, and a real reboot followed by mismatch refusal and successful
cleanup/build equality. All eight existing deadman subtests and both real
25.05/25.11 options-index builds also passed. These are disposable direct-boot
guests with exact preloaded fixture closures and a persistent writable Nix store,
not bootloader or hostile-code-sandbox evidence; no timer was tested on a live host.

## 06: document external execution modes

I added [execution modes](MODES.md) and linked it from the README, playbook's Known
limits and prompt. It separates today's on-box agent from an outside agent working
in a config clone: proposal-only transfer is a human procedure, while target
activation still uses guarded apply and a separate human confirmation. The
explicit human-only remote rebuild example keeps arm before test, a fresh SSH
connection and successful disarm before switch, with no early R3 commit or stale
failed proposal left for reapplication. This avoids implying that local-only
apply ships a remote receiver or that root SSH is an agent workaround. Evidence:
a documentation command/flow walkthrough against the current helper and account
contract, including supervision, success, rollback cleanup and repo/running
equality, plus local link checks. No remote deployment, live-host test or VM rerun
was performed for this documentation-only change.

## 07: use the deadman timer without an agent

I split the exports, not the recovery promise. `nixosModules.deadman` now installs
only arm, disarm and status, without agent settings, Python apply hooks or policy
state. `aether` and `default` still compose the timer, index and apply pieces,
preserving cancellation, token invalidation and bounded recovery independent of
the apply lock. Existing enable/timeout settings and full-bundle helper ordering
remain intact. ADR 0003 records the boundary; the README's human-only walkthrough
gates a scoped firewall test on successful arming, checks a fresh SSH session and
never treats manual disarm as apply confirmation. The
[Linux evidence run](https://github.com/jrcruciani/aether/actions/runs/35639932541)
at code SHA `aa1f5bf299ce5235be670791b0c300a06cd1589d` passed all 11 deadman
subtests, including standalone closed-PATH commands, configured-timeout recovery
of the running system/profile/SSH without policy state, and full-bundle recovery
despite failing state hooks with explicit journal errors. All 17 policy tests,
13 actual restricted-account apply scenarios and both real host-pinned index
builds passed too: 22,116 options on 25.05 and 23,290 on 25.11. The apply check kept
the exact fixture/preload layout, persistent writable store and reboot coverage.
This is disposable direct-boot VM evidence, not a live-host timer experiment or
bootloader test. The final change after that run only adds this evidence entry.

## 08: reject unsafe timer edge cases early

Arm now checks the effective UID and parses the timeout with systemd before
creating state or units, preserving an existing pin and timer on invalid input.
Disarm checks rollback activity, transitions, queued jobs and the full bundle's
recovery marker before stopping the timer or revoking approval, and retains a
post-stop check.
It refuses with `rollback in progress, do not interrupt` and never stops the
rollback service; the checks are not an atomic barrier against concurrent
recovery. The prompt explicitly stops on a pre-existing `ARMED` status, current
proposal paths agree on `hosts/<host>/modules/agent/`, and module contributions
now require a passing NixOS VM check or a real field note.
