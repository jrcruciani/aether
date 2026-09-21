{
  description = "Aether: safety rails for reconfiguring NixOS by conversation";

  # Only the VM check uses this input. The module still takes pkgs from the
  # importing NixOS configuration; it cannot move a consumer's package set.
  inputs.nixpkgs-test.url = "github:NixOS/nixpkgs/6d663c0533ff269008fb84e45930151e37c99db9";

  outputs = { self, nixpkgs-test }: {
    nixosModules.aether = import ./modules/deadman.nix;
    nixosModules.default = self.nixosModules.aether;

    checks.x86_64-linux.deadman =
      nixpkgs-test.legacyPackages.x86_64-linux.testers.runNixOSTest
        (import ./tests/rollback.nix);
  };
}
