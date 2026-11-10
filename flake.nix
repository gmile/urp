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
      mixScript =
        pkgs: beam: name: text:
        pkgs.writeShellApplication {
          inherit name text;
          runtimeInputs = mixTools beam ++ [
            pkgs.gh
            pkgs.git
          ];
          runtimeEnv = {
            VERSION = lib.trim (builtins.readFile ./VERSION);
            MIX_REBAR3 = "${beam.rebar3}/bin/rebar3";
          };
        };
    in
    {
      packages = forAllSystems (
        { pkgs, beam }:
        {
          release = mixScript pkgs beam "release" ''
            grep --fixed-strings --quiet "## [v$VERSION]" CHANGELOG.md
            mix deps.get
            mix hex.publish --yes
            gh release create "v$VERSION" --target "$(git rev-parse HEAD)" --generate-notes
          '';
          audit = mixScript pkgs beam "audit" ''
            mix deps.get
            mix hex.audit
          '';
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
            name: env: command:
            pkgs.stdenvNoCC.mkDerivation {
              inherit name;
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./.formatter.exs
                  ./mix.exs
                  ./mix.lock
                  ./lib
                  ./test
                  ./README.md
                  ./PERFORMANCE.md
                  ./CHANGELOG.md
                  ./LICENSE
                ];
              };
              nativeBuildInputs = mixTools beam;
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
          plt = (mix "plt" "dev" "mix dialyzer --plt").overrideAttrs {
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./mix.exs
                ./mix.lock
              ];
            };
            installPhase = "mkdir $out && cp priv/plts/*.plt $out";
          };
        in
        {
          test = mix "test" "test" ''
            mix format --check-formatted
            mix compile --warnings-as-errors
            mix deps.unlock --check-unused
            mix xref graph --format cycles --fail-above 0
            mix test
          '';
          docs = mix "docs" "dev" "mix docs --warnings-as-errors";
          dialyzer = mix "dialyzer" "dev" ''
            mkdir -p priv/plts
            cp ${plt}/* priv/plts
            mix dialyzer --no-check
          '';
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          integration =
            (mix "integration" "test" ''
              soffice --headless --norestore --nologo \
                -env:UserInstallation=file://$TMPDIR/soffice \
                "--accept=socket,host=127.0.0.1,port=2002,tcpNoDelay=1;urp;" &
              for _ in $(seq 120); do
                (exec 3<>/dev/tcp/127.0.0.1/2002) 2>/dev/null && break
                sleep 1
              done
              mix test --include integration
              kill %1
            '').overrideAttrs
              (old: {
                nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.libreoffice ];
                FONTCONFIG_FILE = pkgs.makeFontsConf {
                  fontDirectories = [
                    pkgs.liberation_ttf
                    pkgs.carlito
                  ];
                };
              });
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
