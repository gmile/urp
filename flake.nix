{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          beamPackages = pkgs.beam.packages.erlang_29;
          # CI/release tasks are headless; avoid the full wx and systemd closure.
          ciBeamPackages = pkgs.beamMinimal29Packages;
        in
        {
          default = pkgs.mkShell {
            packages = [
              beamPackages.erlang
              beamPackages.elixir_1_20
              beamPackages.hex
              beamPackages.rebar3
              pkgs.git
              pkgs.uv
            ];
          };

          ci = pkgs.mkShell {
            packages = [
              ciBeamPackages.erlang
              ciBeamPackages.elixir_1_20
              ciBeamPackages.hex
              ciBeamPackages.rebar3
            ];
          };
        }
      );
    };
}
