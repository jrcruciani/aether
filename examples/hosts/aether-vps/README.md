# aether-vps — a real Hetzner Cloud install, warts included

This is the actual `flake.nix`/`configuration.nix`/`disko.nix` from a live
Hetzner Cloud CX33 instance provisioned with `nixos-anywhere`, kept here as a
worked example of the problems you'll actually hit on that specific provider
— as opposed to `examples/hosts/vps/`, which is the clean, provider-agnostic
teaching example in the main playbook.

Public SSH keys have been replaced with `AAAA...` placeholders. Nothing else
was redacted — there is nothing else to redact. NixOS configuration is not a
secrets store; keys, tokens, and passwords never belong in this file (see
`sops-nix`/`agenix` in the main playbook).

## The one thing that will bite you on Hetzner Cloud

Hetzner Cloud boots in **BIOS/legacy mode by default**, not UEFI. The
"obvious" NixOS choice — `boot.loader.systemd-boot.enable = true;` — requires
UEFI and will install silently without error, then hang forever at "Booting
from hard disk" on the real reboot. There is no error message pointing at
this; you just get a machine that never comes back.

The fix is `boot.loader.grub.enable = true;` with `efiSupport = false;`, and
a GPT disk layout with a small `EF02` (BIOS-boot) partition instead of an ESP.
See `disko.nix` for the exact partition table.

## Installing non-Nix software inside NixOS

This host also runs a second, independent instance of [Hermes
Agent](https://github.com/NousResearch/hermes-agent) for local administration
— installed via its upstream `curl | bash` script, which is not
NixOS-aware. Three declarative additions were needed before it would run at
all:

1. `programs.nix-ld.enable = true;` — NixOS has no standard dynamic linker
   path, so generic Linux binaries (a downloaded `uv`, Node.js, etc.) refuse
   to execute at all without this.
2. `environment.variables.SSL_CERT_FILE` / `NIX_SSL_CERT_FILE` pointing at
   `pkgs.cacert` — without it, any non-Nix HTTP client (curl, Python, Node)
   fails TLS verification with `CERTIFICATE_VERIFY_FAILED`, because NixOS
   doesn't populate the usual `/etc/ssl/certs` path those tools expect.
3. `environment.variables.PATH` extended with `/usr/local/bin` —
   FHS-layout installers (anything using `/usr/local/bin` as a
   convention) land outside the NixOS-managed PATH by default.

If you're bringing any `curl | bash` installer onto a NixOS box, expect to
need at least the first two of these before it will even start.

## Emergency user

`users.users.rescate` exists purely as an out-of-band access path,
independent of the keys the agent manages day to day, with `sudo` requiring
no password. Its own comment block says not to touch it without explicit
triple confirmation — worth stealing verbatim into your own configs.
