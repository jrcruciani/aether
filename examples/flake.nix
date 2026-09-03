{
  description = "Aether example host. Copy, rename, make it yours.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/vps/configuration.nix ];
    };
  };
}
