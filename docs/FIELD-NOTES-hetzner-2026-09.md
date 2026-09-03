# Field notes: getting NixOS running on real Hetzner Cloud

This is a log of what actually broke while provisioning a live Hetzner
Cloud VPS with `nixos-anywhere`, told in the order it happened. The playbook
in this repo is the theory. This is the practice, warts included. Every
failure below cost real wall-clock time before the fix landed.

## The VNC console is a trap, not a fallback

I started by mounting Hetzner's NixOS ISO and installing manually through
the web console. No copy-paste, foreign keyboard layout, one typo away
from `mkfs.ext4: invalid blocks 'nixos' on device '-L'` because a stray
character ate an argument. Forty minutes in, still fighting the keyboard,
it clicked that this was a solved problem: Hetzner has a real Cloud API. I
switched to `enable_rescue` (API call, gives you a normal Debian box with
real SSH) plus `nixos-anywhere` (installs NixOS remotely from a flake, no
console typing required). What had been a slog for most of an hour took
about five minutes once I stopped fighting the terminal and started using
the API. If a task has a console-only path and a programmatic path, and the
console has any friction at all, check for the API first. Don't wait until
someone points out you're doing it the hard way.

## Hetzner Cloud boots BIOS, not UEFI

First real install: `boot.loader.systemd-boot.enable = true`, because
that's the modern NixOS default everyone reaches for. `nixos-anywhere`
reported success, installed the loader, rebooted. The machine never came
back. Not a crash, not an error. It just sat at "Booting from hard disk"
forever, because systemd-boot requires UEFI and Hetzner Cloud boots BIOS
by default. No warning fired during install; the only tell was one throwaway
line in the log, "Not booted with EFI, skipping EFI variable setup," easy to
miss between hundreds of `copying path` lines.

The fix: `boot.loader.grub.enable = true` with `efiSupport = false`, and a
disk layout with a small BIOS-boot partition (`EF02` in GPT) instead of an
EFI system partition. Once that changed, the reboot came back clean.

## disko already knows where GRUB goes

Second attempt after switching to GRUB: `boot.loader.grub.devices = [
"/dev/sda" ];` in the config, alongside a disko layout that also declares
the disk. Evaluation failed with `You cannot have duplicated devices in
mirroredBoots` — disko's GRUB module was already inferring the device from
the partition table, and my explicit line collided with it. Deleting the
manual line fixed it. Worth remembering: disko modules aren't just disk
formatting, they set NixOS options too, and they'll silently do more than
you asked if you let them.

## Installing anything non-Nix costs you three things

Once the base system was up, I installed a second Hermes Agent instance
directly on the box for local administration — using its normal
`curl | bash` installer, same as on any other Linux machine. It failed
three times, each in a different way:

1. **No dynamic linker.** NixOS doesn't ship the standard FHS paths, so a
   downloaded `uv` binary refused to even start: "NixOS cannot run
   dynamically linked executables intended for generic linux environments."
   Fixed with `programs.nix-ld.enable = true`.
2. **No CA bundle.** With nix-ld sorted, the installer's own HTTPS calls
   started failing TLS verification. NixOS doesn't populate `/etc/ssl/certs`
   the way most distros do, so any non-Nix HTTP client can't find a trust
   store. Fixed with `SSL_CERT_FILE` and `NIX_SSL_CERT_FILE` pointed at
   `pkgs.cacert`.
3. **No compiler.** Once the installer could actually download things, it
   hit a step that compiles a native Node module and had no `gcc` to do it
   with. Added `gcc` and `gnumake` to system packages.

None of these are NixOS bugs. They're consequences of NixOS deliberately not
having a general-purpose FHS environment, which is the same property that
makes the rest of this playbook work. But it means: budget for friction the
first time you install anything that assumes a normal Linux filesystem
layout, and check for these three specifically before concluding the
software is incompatible.

## PATH is not a courtesy, it's a config decision

Hermes installed cleanly into `/usr/local/bin` — a convention every other
distro treats as part of the default PATH. NixOS doesn't; it manages PATH
strictly through Nix profiles, so `/usr/local/bin` was invisible to any new
shell even though the binary was right there. Fixed with an explicit
`environment.variables.PATH` addition. If software installs itself outside
`/nix/store` and doesn't show up on the PATH, this is almost always why.

## The panel of models called it before I built it

Before touching the VPS, I ran the choice of admin agent past five
different models (Claude, GPT, Gemini, Grok, Mistral) with the same
brief. Three independent votes landed on the same architecture I ended up
using: run the agent from outside the managed host, not inside it, so a
broken firewall rule doesn't also take down your only way to fix it. I
still installed a second Hermes instance inside the VPS afterward, for
local work — but the box has an out-of-band emergency user with its own
key, sudo without a password, and an explicit "do not touch" comment in the
config, precisely because the panel's reasoning held up.
