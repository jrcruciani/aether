# Example layout

A minimal skeleton showing where things go. It will not build unmodified: the
hardware configuration is a placeholder and the SSH keys are fake. Generate your own
with `nixos-generate-config` and paste your real keys.

```
flake.nix
hosts/vps/
  configuration.nix              read by the agent, never rewritten
  hardware-configuration.nix     yours, generated at install
  modules/agent/
    default.nix                  imports every generated module
    2026-09-03-ripgrep-and-fd.nix
```

The shape that matters is `modules/agent/`. One file per request, dated, imported
automatically in sorted order by the human-owned `default.nix`. Do not edit the
loader when adding a proposal. A root-owned sticky directory protects it from
unlink/replacement while allowing the agent to create its own `.nix` files.
Follow [HARDENING.md](../docs/HARDENING.md) before enabling apply for an account.

Two things about wiring it up, both of which fail quietly rather than loudly:

The host directory is called `vps` here, but the name is yours. Whatever you call it,
the flake and the agent have to agree, because `nixos-rebuild --flake .#vps` takes the
name from `nixosConfigurations`, not from the directory.

More important: `modules/agent` has to be in the flake's `modules` list, as it is in
`flake.nix` here. Miss it and the agent writes a module, `nix flake check` passes,
`nixos-rebuild` reports success, and absolutely nothing happens, because the file was
never part of the configuration. There is no error to read. `nix store diff-closures`
catches this one immediately: it prints nothing at all.

`2026-09-03-postgres-localhost-only.nix.example` shows a slightly larger change and
the reasoning about which risk level it lands on. Drop the `.example` suffix to use
it.

## Installing the helpers and the options index

`flake.nix` imports `aether.nixosModules.aether`; the host sets
`services.aether.enable = true`, `services.aether.flake = "/etc/nixos"` and
`services.aether.host = "vps"`. The last value is the `nixosConfigurations` key,
not the OS hostname. The separate Hetzner example deliberately has different
names; its [setup note](hosts/aether-vps/README.md#adding-the-current-options-helper)
uses `vps`, not `nixos-experimento`.

There is no lock file in this skeleton. In your copied host repo, run
`nix flake lock`, review and commit `flake.lock`, then install the configuration
through the normal reviewed flow. As root, run:

```bash
aether-index
```

It builds the equivalent of
`nix build /etc/nixos#nixosConfigurations.vps.config.system.build.manual.optionsJSON -o /var/lib/nixos-options`,
with `--no-update-lock-file`. The JSON is at
`/var/lib/nixos-options/share/doc/nixos/options.json`, not at the symlink itself.
Regenerate after lock or module changes. The helper accepts an absolute local
flake directory (including spaces) and a host key made of letters, digits,
underscores or hyphens. It refuses a missing lock and never guesses the hostname.
Existing timer-only installs can leave `host` unset; index/apply report setup
errors instead of guessing.

For apply, additionally configure `services.aether.agentUser`, the protected
checkout and separate agent/human sudo grants described in the hardening guide.
The example intentionally does not grant a root-capable account to an agent.
Enabling the module does not provision those permissions for you.

The R1 ripgrep/fd example goes through `sudo aether-apply build --risk R1`, review
of the closure diff, then `sudo aether-apply switch --risk R1`. The helper stages,
activates the exact build and commits only after success. R3 instead uses test,
a different human's `sudo aether-confirm`, then switch. Never grant the agent
direct rebuild, activation, confirm or disarm sudo access.

On the tested NixOS 25.05 and 25.11 pins, both `documentation.enable` and
`documentation.nixos.enable` must be true for this build attribute to exist.
`documentation.doc.enable = false` skips installing the HTML manual without
removing the attribute. The default index covers nixpkgs' base modules; for
options declared by imported modules, enable
`documentation.nixos.includeAllModules` or query the host's `.options` directly
as shown in [rule seven](../docs/PLAYBOOK.md#rule-seven-ground-the-model-in-real-options).

`tests/index-pins.sh` copies this skeleton into a disposable directory in Linux
CI, creates its lock at a fixed 25.05 revision, builds the index, then changes
only that lock to a fixed 25.11 revision and builds again. It checks the real JSON
layout, different option counts, the configured helper, and disabled-documentation
failure without booting the placeholder hardware configuration. This networked
evidence job is separate from the locked, offline deadman VM check.
