# Changelog

## 01: pin the rollback target

I changed the timer to return to the system that was running when it was armed.
Stepping back a generation was wrong after `test`, because the profile was still
pointing at the known-good system. The helper now records that path, restores the
profile and activates it directly; a missing or invalid pin warns and uses the
boot default instead. Status shows the pin, and disarming removes it. I added a
disposable NixOS VM check for pinned recovery and the missing-pin fallback, using
a prebuilt specialisation that stops sshd. The Linux CI run is still pending; I
have not tested the timer on a live host for this change.

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
