{
  inputs.nixpkgs.url = "nixpkgs";
  inputs.aether.url = "github:jrcruciani/aether";
  inputs.aether.inputs.nixpkgs-test.follows = "nixpkgs";

  outputs = { nixpkgs, aether, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      evaluation = (import (nixpkgs + "/nixos/lib") {}).evalTest {
        hostPkgs = pkgs;
        name = "aether-apply-fixture";
        nodes.machine.imports = [
          (aether + "/tests/apply-host.nix")
          ./hosts/fixture/modules/agent
        ];
        testScript = "";
      };
    in {
      nixosConfigurations.fixture = {
        config = evaluation.config.nodes.machine;
        inherit pkgs;
      };
    };
}
