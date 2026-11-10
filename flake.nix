{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems =
        f:
        lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          f {
            inherit pkgs;
            beam = pkgs.beam_minimal.packages.erlang_29;
          }
        );
      mixTools = beam: [
        beam.erlang
        beam.elixir_1_20
        beam.hex
        beam.rebar3
      ];
    in
    {
      packages = forAllSystems (
        { pkgs, beam }:
        {
          publish = pkgs.writeShellApplication {
            name = "publish";
            runtimeInputs = mixTools beam ++ [
              pkgs.gh
              pkgs.git
            ];
            runtimeEnv = {
              VERSION = lib.trim (builtins.readFile ./VERSION);
              MIX_REBAR3 = "${beam.rebar3}/bin/rebar3";
            };
            text = ''
              grep --fixed-strings --quiet "## [v$VERSION]" CHANGELOG.md
              mix deps.get
              mix hex.audit
              mix hex.publish --yes
              gh release create "v$VERSION" --target "$(git rev-parse HEAD)" --generate-notes
            '';
          };
          soffice = pkgs.writeShellApplication {
            name = "soffice";
            runtimeEnv.FONTCONFIG_FILE = pkgs.makeFontsConf {
              fontDirectories = [
                pkgs.liberation_ttf
                pkgs.carlito
              ];
            };
            text = ''
              exec ${
                if pkgs.stdenv.hostPlatform.isDarwin then pkgs.libreoffice-bin else pkgs.libreoffice
              }/bin/soffice --headless --norestore --nologo \
                "-env:UserInstallation=file://''${TMPDIR:-/tmp}/urp-soffice" \
                "--accept=socket,host=127.0.0.1,port=''${PORT:-2002},tcpNoDelay=1;urp;"
            '';
          };
        }
      );

      checks = forAllSystems (
        { pkgs, beam }:
        let
          deps = beam.fetchMixDeps {
            pname = "urp-deps";
            version = "locked";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./mix.exs
                ./mix.lock
                ./VERSION
              ];
            };
            mixEnv = "dev";
            hash = "sha256-wG1z4+BtT+UxoR8+5KF3Ec/fmeZix1j1G/IPXuc+kH0=";
          };
          mix =
            {
              name,
              env ? "test",
              inputs ? [ ],
              files ? [
                ./.formatter.exs
                ./mix.exs
                ./mix.lock
                ./lib
                ./test
                ./README.md
                ./PERFORMANCE.md
                ./CHANGELOG.md
                ./LICENSE
              ],
              command,
            }:
            pkgs.stdenvNoCC.mkDerivation {
              inherit name;
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions files;
              };
              nativeBuildInputs = mixTools beam ++ inputs;
              MIX_ENV = env;
              MIX_REBAR3 = "${beam.rebar3}/bin/rebar3";
              HEX_OFFLINE = 1;
              buildPhase = ''
                export HOME=$TMPDIR MIX_DEPS_PATH=$PWD/deps
                echo 0.0.0 > VERSION
                cp --recursive --no-preserve=mode ${deps} deps
                mix deps.compile --no-deps-check
                ${command}
              '';
              installPhase = "touch $out";
            };
          plt = mix {
            name = "plt";
            env = "dev";
            files = [
              ./mix.exs
              ./mix.lock
            ];
            command = ''
              mix dialyzer --plt
              mkdir $out
              cp priv/plts/*.plt $out
            '';
          };
        in
        {
          test = mix {
            name = "test";
            command = ''
              mix format --check-formatted
              mix compile --warnings-as-errors
              mix deps.unlock --check-unused
              mix xref graph --format cycles --fail-above 0
              mix test
            '';
          };
          docs = mix {
            name = "docs";
            env = "dev";
            command = "mix docs --warnings-as-errors";
          };
          dialyzer = mix {
            name = "dialyzer";
            env = "dev";
            command = ''
              mkdir -p priv/plts
              cp ${plt}/* priv/plts
              mix dialyzer --no-check
            '';
          };
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          integration = mix {
            name = "integration";
            inputs = [ self.packages.${pkgs.stdenv.hostPlatform.system}.soffice ];
            command = ''
              soffice &> soffice.log &
              timeout 60 bash -c 'until (exec 3<>/dev/tcp/127.0.0.1/2002) 2>/dev/null; do sleep 1; done' ||
                { cat soffice.log; exit 1; }
              mix test --include integration
              kill %1
            '';
          };
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = mixTools pkgs.beam.packages.erlang_29 ++ [
              pkgs.git
              pkgs.uv
            ];
          };
        }
      );
    };
}
