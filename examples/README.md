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
from `default.nix`. That is what makes a change reviewable at a glance and reversible
with `rm`.

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
