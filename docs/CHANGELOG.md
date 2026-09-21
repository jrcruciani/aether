# Changelog

## 02: recover the repo after a failed R3 test

R3 modules are now committed only after the human confirms access from a second
SSH session and `aether-disarm` succeeds, before the final switch. Previously the
commit happened before the test, so a timer rollback left the bad module ready to
be reapplied. The prompt, playbook, README and rescue runbook now require completed
rollback, `aether-status` reporting `not armed`, removal of only the failed request's
module, and a fresh repository build whose resolved path equals `/run/current-system`.
A failed build or a different path stops recovery without a commit or activation.
Evidence: a manual walkthrough of the success and failure branches and a check of
every `git commit` example in the prompt and playbook. This is a documentation
change, not a VM test.
