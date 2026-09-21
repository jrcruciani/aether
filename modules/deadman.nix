# Aether: the deadman rollback timer as a NixOS module.
#
# The README calls this the piece worth keeping even if you throw the rest
# away. Until now it was a systemd-run line you were expected to paste
# correctly, from memory, in the one situation where you are least calm:
# about to change the firewall on a box you can only reach through that
# firewall.
#
# Arm before activation: it pins the running system, not the generation before
# the boot default. A `test` activation leaves that default alone, so stepping
# back one generation would recover the wrong system.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.aether;

  validateTarget = ''
    valid_target() {
      [[ "$1" =~ ^/nix/store/[^/[:space:]]+$ ]] &&
        [[ -d "$1" && -x "$1/bin/switch-to-configuration" ]] &&
        [[ "$(readlink -f -- "$1")" == "$1" ]]
    }
  '';

  # Recovery only uses a system already built on disk. No rebuild or flake
  # evaluation belongs in the path that runs after we have lost SSH.
  rollbackScript = pkgs.writeShellApplication {
    name = "aether-rollback";
    runtimeInputs = [ pkgs.nix pkgs.coreutils ];
    text = ''
      profile=/nix/var/nix/profiles/system
      pin=/run/aether/rollback-target
      ${validateTarget}

      target=
      if [[ ! -f "$pin" ]] || ! target=$(cat "$pin") || ! valid_target "$target"; then
        echo "aether: WARNING: missing or invalid rollback target in $pin; falling back to boot-default profile $profile." >&2
        if ! target=$(readlink -f "$profile") || ! valid_target "$target"; then
          echo "aether: ERROR: boot-default profile is not an activatable system; cannot recover." >&2
          exit 1
        fi
      fi

      echo "aether: rolling back to $target"
      profile_status=0
      nix-env --profile "$profile" --set "$target" || {
        profile_status=$?
        echo "aether: ERROR: failed to set system profile to $target; attempting recovery activation anyway." >&2
      }

      if ! "$target"/bin/switch-to-configuration switch; then
        echo "aether: ERROR: recovery activation of $target failed; inspect the journal and use the rescue console." >&2
        exit 1
      fi

      if (( profile_status != 0 )); then
        echo "aether: ERROR: recovery activation finished, but the system profile update failed; check the boot default." >&2
      fi
      exit "$profile_status"
    '';
  };

  arm = pkgs.writeShellApplication {
    name = "aether-arm";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.util-linux ];
    text = ''
      timeout="''${1:-${cfg.rollbackTimeout}}"
      pin=/run/aether/rollback-target
      ${validateTarget}

      # Keep a competing arm or disarm from replacing a live timer's pin.
      install -d -m 0700 /run/aether
      exec 9>/run/aether/lock
      flock -x 9

      if systemctl is-active --quiet ${cfg.unitName}.timer; then
        echo "aether: ${cfg.unitName}.timer is already armed." >&2
        echo "Disarm it or let it fire before arming another one." >&2
        exit 1
      fi

      if ! target=$(readlink -f /run/current-system) || ! valid_target "$target"; then
        echo "aether: ERROR: /run/current-system is not an activatable system; timer not armed." >&2
        exit 1
      fi

      pending_pin=$(mktemp /run/aether/rollback-target.XXXXXX)
      trap 'rm -f "$pending_pin"' EXIT
      printf '%s\n' "$target" > "$pending_pin"
      mv -f "$pending_pin" "$pin"

      if ! systemd-run \
        --collect \
        --unit=${cfg.unitName} \
        --on-active="$timeout" \
        ${cfg.rollbackCommand}; then
        rm -f "$pin"
        echo "aether: ERROR: could not arm the rollback timer; pin removed. Do not activate the change." >&2
        exit 1
      fi

      echo "aether: pinned $target"
      echo "aether: armed. The system rolls back in $timeout unless disarmed."
      echo "aether: open a SECOND ssh session and confirm you can still log in,"
      echo "aether: keeping this one open. Then run: aether-disarm"
    '';
  };

  disarm = pkgs.writeShellApplication {
    name = "aether-disarm";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.util-linux ];
    text = ''
      install -d -m 0700 /run/aether
      exec 9>/run/aether/lock
      flock -x 9

      if ! systemctl is-active --quiet ${cfg.unitName}.timer; then
        echo "aether: nothing armed." >&2
        exit 1
      fi

      systemctl stop ${cfg.unitName}.timer
      rm -f /run/aether/rollback-target
      echo "aether: disarmed. The change is yours to keep."
    '';
  };

  status = pkgs.writeShellApplication {
    name = "aether-status";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils ];
    text = ''
      if [[ -f /run/aether/rollback-target ]]; then
        printf 'rollback target: '
        cat /run/aether/rollback-target
      else
        echo "rollback target: not pinned"
      fi

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
      default = "${rollbackScript}/bin/aether-rollback";
      description = ''
        What the timer runs when it fires. Before activation, aether-arm
        records the running system in /run/aether/rollback-target. The
        default sets the system profile to that pinned path and activates
        it directly, without rebuilding or evaluating your flake. A test
        activation leaves the profile unchanged, so going back one
        generation would skip the system you meant to recover.

        If the pin is missing or invalid, it warns and activates the
        current boot-default profile instead. It never steps back a
        generation. A failed profile update is reported, but does not
        prevent an attempt to activate the recovery system. The service
        still fails so that a boot-default problem is not hidden.

        An override replaces this recovery behavior, not the pin lifecycle:
        aether-arm still writes the pin and aether-disarm removes it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ arm disarm status ];
  };
}
