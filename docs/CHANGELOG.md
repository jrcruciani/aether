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
