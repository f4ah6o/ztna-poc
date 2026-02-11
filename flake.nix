{
  description = "NetBird + Keycloak + midPoint portable IaC (compose + nix)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          mkApp = script: pkgs.writeShellApplication {
            name = script;
            runtimeInputs = [ pkgs.bash pkgs.docker ];
            text = ''
              set -euo pipefail
              exec bash ${./scripts}/${script}.sh "$@"
            '';
          };
        in
        {
          gen = mkApp "gen-env";
          up = mkApp "up";
          down = mkApp "down";
        });

      apps = forAllSystems (system: {
        gen = {
          type = "app";
          program = "${self.packages.${system}.gen}/bin/gen-env";
        };
        up = {
          type = "app";
          program = "${self.packages.${system}.up}/bin/up";
        };
        down = {
          type = "app";
          program = "${self.packages.${system}.down}/bin/down";
        };
      });
    };
}
