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

`2026-09-03-postgres-localhost-only.nix.example` shows a slightly larger change and
the reasoning about which risk level it lands on. Drop the `.example` suffix to use
it.
