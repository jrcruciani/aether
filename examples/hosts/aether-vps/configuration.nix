{ modulesPath, lib, pkgs, ... }:

{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = false;
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.growPartition = true;

  networking.hostName = "nixos-experimento";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  time.timeZone = "Europe/Madrid";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    uv
    python3
    gcc
    gnumake
    tmux
  ];

  # Compatibilidad FHS para binarios genéricos de Linux (p.ej. instaladores
  # que no son paquetes Nix nativos, como el propio Hermes Agent).
  programs.nix-ld.enable = true;

  # Certificados CA para clientes HTTP genéricos (curl/python/node de Hermes)
  # que no saben localizar el store de Nix por defecto.
  environment.variables.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  environment.variables.NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # /usr/local/bin no está en el PATH por defecto en NixOS (gestiona rutas
  # estrictamente vía Nix). Hermes Agent se instaló ahí (FHS layout) — lo
  # añadimos explícitamente para poder usar 'hermes' sin ruta completa.
  environment.variables.PATH = [ "/usr/local/bin" "/usr/local/sbin" ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... hermes-nixos-experimento"
      "ssh-ed25519 AAAA... admin-laptop"
    ];
  };

  # USUARIO DE EMERGENCIA — NO TOCAR sin confirmación triple explícita del operador.
  # Clave privada fuera del VPS (guardada en /root/work/emergency_key en la
  # máquina de Hermes). Nunca gestionado por el flujo conversacional normal.
  users.users.rescate = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA... emergencia-nixos-experimento"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "25.05";
}
