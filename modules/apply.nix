{ config, lib, pkgs, ... }:

let
  cfg = config.services.aether;
  runtime = [
    pkgs.python3 pkgs.git pkgs.nix pkgs.nixos-rebuild pkgs.systemd
    pkgs.coreutils pkgs.util-linux
  ];
  settings = pkgs.writeText "aether-apply-config.json" (builtins.toJSON {
    flake = cfg.flake;
    host = cfg.host;
    agent = cfg.agentUser;
    unit = cfg.unitName;
    rollback = cfg.rollbackCommand;
    path = lib.makeBinPath runtime;
    git = "${pkgs.git}/bin/git";
    nix = "${pkgs.nix}/bin/nix";
    nix_store = "${pkgs.nix}/bin/nix-store";
    nix_env = "${pkgs.nix}/bin/nix-env";
    rebuild = "${pkgs.nixos-rebuild}/bin/nixos-rebuild";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    systemd_run = "${pkgs.systemd}/bin/systemd-run";
    python = "${pkgs.python3}/bin/python3";
    script = "${./apply.py}";
    arm = "/run/current-system/sw/bin/aether-arm";
    disarm = "/run/current-system/sw/bin/aether-disarm";
  });
  entry = name: operation: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = runtime;
    text = ''
      export PATH=${lib.escapeShellArg (lib.makeBinPath runtime)}
      exec python3 -I ${./apply.py} ${settings} ${operation} "$@"
    '';
  };
in
{
  options.services.aether.agentUser = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "aether-agent";
    description = ''
      Separate, non-root account proposing changes through aether-apply.
      This identifies the principal forbidden from confirming; it does not
      create accounts, grant sudo or secure your checkout. Follow HARDENING.md
      for the root-owned baseline, sticky proposal directory and additive sudo
      restrictions. Leaving it unset preserves timer/index-only installations.
      This is a cooperative-agent guardrail, not a sandbox for hostile Nix.
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (entry "aether-apply" "apply")
      (entry "aether-confirm" "confirm")
    ];
  };
}
