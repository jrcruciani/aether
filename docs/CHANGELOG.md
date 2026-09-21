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
