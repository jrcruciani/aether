# Read by the agent for context. Never rewritten by it.
# Everything the agent generates lands in ./modules/agent/ and is imported below.

{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./modules/agent          # the agent writes here, and only here
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "vps";

  services.aether = {
    enable = true;
    flake = "/etc/nixos";
    host = "vps"; # nixosConfigurations.vps, not a hostname lookup
  };

  # Keep at least a few generations in the boot menu. This is your rollback path,
  # so do not let garbage collection eat all of them.
  boot.loader.grub.configurationLimit = 10;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "prohibit-password";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... your-key-here"
    ];
  };

  # DO NOT TOUCH without triple explicit confirmation from the human.
  # This account exists so a bad change in modules/agent/ still leaves a way in.
  # Note its real limit: it lives in this same config, so it is convenience,
  # not insurance. The provider console plus a root password is the insurance.
  users.users.rescue = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... your-second-key-here"
    ];
  };

  # Set this at install time and store it in a password manager.
  # Without it, the provider console shows you a login prompt you cannot pass.
  users.users.root.hashedPassword = "$6$...";

  environment.systemPackages = with pkgs; [
    git
    tmux
    ripgrep
  ];

  system.stateVersion = "25.05";
}
