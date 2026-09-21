{ config, lib, pkgs, ... }:

let
  cfg = config.services.aether;
  runtime = [ pkgs.nix pkgs.git pkgs.coreutils pkgs.python3 ];
  preflight = pkgs.writeText "aether-index-preflight.json" (builtins.toJSON {
    flake = cfg.flake;
    host = cfg.host;
    agent = cfg.agentUser;
    git = "${pkgs.git}/bin/git";
    path = lib.makeBinPath runtime;
  });
  index = pkgs.writeShellApplication {
    name = "aether-index";
    runtimeInputs = runtime;
    text = ''
      if (( $# != 0 )); then
        echo "aether: ERROR: aether-index takes no arguments; configure services.aether.flake and services.aether.host." >&2
        exit 1
      fi

      flake=${lib.escapeShellArg cfg.flake}
      host=${lib.escapeShellArg (if cfg.host == null then "" else cfg.host)}
      if [[ ! "$host" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "aether: ERROR: set services.aether.host to the nixosConfigurations key (letters, digits, underscores or hyphens), not the OS hostname." >&2
        exit 1
      fi
      if [[ "$flake" != /* || "$flake" == *'#'* || "$flake" == *'?'* || "$flake" == *$'\n'* || "$flake" == *$'\r'* ]]; then
        echo "aether: ERROR: services.aether.flake must be an absolute local directory without #, ? or line breaks." >&2
        exit 1
      fi
      if [[ ! -f "$flake/flake.nix" || ! -f "$flake/flake.lock" ]]; then
        echo "aether: ERROR: expected flake.nix and flake.lock in $flake; lock the host's inputs before generating its index." >&2
        exit 1
      fi
      ${lib.optionalString (cfg.agentUser != null) ''
        python3 -I ${./apply.py} ${preflight} index-preflight
      ''}

      status=0
      env -i PATH=${lib.escapeShellArg (lib.makeBinPath runtime)} HOME=/var/empty \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        NIX_USER_CONF_FILES=/dev/null \
        nix --extra-experimental-features 'nix-command flakes' --no-accept-flake-config build \
        --no-update-lock-file \
        "$flake#nixosConfigurations.\"$host\".config.system.build.manual.optionsJSON" \
        --out-link /var/lib/nixos-options || status=$?
      if (( status != 0 )); then
        echo "aether: ERROR: options build failed; the previous index was not replaced. Check the host key and keep documentation.enable and documentation.nixos.enable enabled for this attribute." >&2
        exit "$status"
      fi
      echo "aether: options index: /var/lib/nixos-options/share/doc/nixos/options.json"
    '';
  };
in
{
  options.services.aether = {
    flake = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = ''
        Absolute local directory containing the host's flake.nix and flake.lock.
        Spaces are allowed, but fragments, queries and line breaks are not.
        aether-index and aether-apply build from this lock without updating it.
      '';
    };

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "vps";
      description = ''
        Explicit nixosConfigurations key for the helpers, not networking.hostName.
        Use letters, digits, underscores or hyphens. Leaving it unset keeps the
        rollback helpers usable; aether-index reports a runtime error instead
        of guessing a host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ index ];
  };
}
