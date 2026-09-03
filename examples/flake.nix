{
  description = "Aether example host. Copy, rename, make it yours.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/vps/configuration.nix
        # Without this line the agent writes modules that are never loaded,
        # every build succeeds, and nothing it does takes effect.
        ./hosts/vps/modules/agent
      ];
    };
  };
}
