{
  description = "Aether: safety rails for reconfiguring NixOS by conversation";

  # No inputs on purpose. The module is plain NixOS and follows whatever
  # nixpkgs your own flake already pins, so adding Aether cannot move your
  # package set underneath you.

  outputs = { self }: {
    nixosModules.aether = import ./modules/deadman.nix;
    nixosModules.default = self.nixosModules.aether;
  };
}
