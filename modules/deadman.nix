# Aether: the deadman rollback timer as a NixOS module.
#
# The README calls this the piece worth keeping even if you throw the rest
# away. Until now it was a systemd-run line you were expected to paste
# correctly, from memory, in the one situation where you are least calm:
# about to change the firewall on a box you can only reach through that
# firewall.
#
# This turns it into two commands that are part of the system, and into a
# timeout you declare once in your config instead of retyping under pressure.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.aether;

  arm = pkgs.writeShellApplication {
    name = "aether-arm";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      timeout="''${1:-${cfg.rollbackTimeout}}"

      if systemctl is-active --quiet ${cfg.unitName}.timer; then
        echo "aether: ${cfg.unitName}.timer is already armed." >&2
        echo "Disarm it or let it fire before arming another one." >&2
        exit 1
      fi

      systemd-run \
        --collect \
        --unit=${cfg.unitName} \
        --on-active="$timeout" \
        ${cfg.rollbackCommand}

      echo "aether: armed. The system rolls back in $timeout unless disarmed."
      echo "aether: open a SECOND ssh session and confirm you can still log in,"
      echo "aether: keeping this one open. Then run: aether-disarm"
    '';
  };

  disarm = pkgs.writeShellApplication {
    name = "aether-disarm";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if ! systemctl is-active --quiet ${cfg.unitName}.timer; then
        echo "aether: nothing armed." >&2
        exit 1
      fi

      systemctl stop ${cfg.unitName}.timer
      echo "aether: disarmed. The change is yours to keep."
    '';
  };

  status = pkgs.writeShellApplication {
    name = "aether-status";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if systemctl is-active --quiet ${cfg.unitName}.timer; then
        echo "ARMED"
        systemctl list-timers --all '${cfg.unitName}.timer' --no-pager
      else
        echo "not armed"
      fi
    '';
  };
in
{
  options.services.aether = {
    enable = lib.mkEnableOption ''
      the Aether deadman rollback helpers.

      This installs aether-arm, aether-disarm and aether-status. It does not
      install an agent, does not run anything in the background, and does not
      touch your configuration on its own
    '';

    rollbackTimeout = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      example = "5min";
      description = ''
        How long you have to confirm you are still alive before the machine
        rolls itself back. Any systemd time span. Long enough to open a second
        session and try a few things, short enough that you are not stuck
        waiting when a change locks you out.
      '';
    };

    unitName = lib.mkOption {
      type = lib.types.str;
      default = "deadman-rollback";
      description = ''
        Name of the transient systemd unit. Changing it is only useful if
        something else on the box already owns that name.
      '';
    };

    rollbackCommand = lib.mkOption {
      type = lib.types.str;
      default = "${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch --rollback";
      description = ''
        What the timer runs when it fires. The default returns the system to
        the previous generation. An absolute store path on purpose: if the
        change you are testing breaks PATH, a bare command name is exactly
        the kind of thing that stops resolving.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ arm disarm status ];
  };
}
