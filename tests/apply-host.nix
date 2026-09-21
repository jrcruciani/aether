{ config, lib, pkgs, ... }:
{
  imports = [ ../modules/deadman.nix ];
  services.aether = {
    enable = true;
    host = "fixture";
    flake = "/etc/nixos";
    agentUser = "agent";
    rollbackTimeout = "30s";
  };
  networking.hostName = lib.mkForce "not-the-flake-key";
  services.openssh.enable = true;
  system.switch.enable = true;
  boot.loader.grub.enable = false;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = lib.mkForce [ ];
    trusted-users = [ "root" ];
  };
  users.groups.agent = { };
  users.users.agent = {
    isNormalUser = true;
    group = "agent";
    home = "/home/agent";
    createHome = true;
  };
  users.users.human = {
    isNormalUser = true;
    home = "/home/human";
    createHome = true;
  };
  security.sudo.extraRules = [
    {
      users = [ "agent" ];
      commands = map (name: {
        command = "/run/current-system/sw/bin/${name}";
        options = [ "NOPASSWD" "NOSETENV" ];
      }) [ "aether-apply" "aether-status" "aether-index" ];
    }
    {
      users = [ "human" ];
      commands = [{
        command = "/run/current-system/sw/bin/aether-confirm";
        options = [ "NOPASSWD" "NOSETENV" ];
      }];
    }
  ];
  environment.systemPackages = [ pkgs.git pkgs.python3 pkgs.jq pkgs.nixos-rebuild ];
  # Only the trusted test baseline contains failure injection, never a proposal.
  system.activationScripts.aether-fixture = lib.mkIf
    (builtins.elem 8443 config.networking.firewall.allowedTCPPorts) ''
      if [ -e /run/fail-candidate ]; then
        echo "fixture: deliberately failing candidate activation" >&2
        exit 1
      fi
      while [ -e /run/block-candidate ]; do
        sleep 1
      done
  '';
  virtualisation = {
    cores = 2;
    memorySize = 3072;
    diskSize = 8192;
    # Flake fetches must survive reboot, as they do in a real host's Nix store.
    writableStoreUseTmpfs = false;
  };
  system.stateVersion = "26.05";
}
