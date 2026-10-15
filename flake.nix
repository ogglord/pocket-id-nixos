{
  description = "Declarative OIDC clients and app config for Pocket-ID (NixOS module)";

  # nixpkgs is only used for this repo's checks and dev shell; the module
  # itself uses the importing system's pkgs. Consumers should add
  #   pocket-id-nixos.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        pocket-id-auth = ./module.nix;
        default = self.nixosModules.pocket-id-auth;
      };

      checks = forAllSystems (pkgs: {
        vm = pkgs.testers.runNixOSTest (import ./test.nix { inherit self; });
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            curl
            jq
            python3
          ];
        };
      });
    };
}
