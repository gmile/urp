{
  description = "Pure Elixir client for the UNO Remote Protocol";

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
      version = lib.trim (builtins.readFile ./VERSION);
      next =
        let
          bumped = part: toString (lib.toInt (part version) + 1);
        in
        {
          major = "${bumped lib.versions.major}.0.0";
          minor = "${lib.versions.major version}.${bumped lib.versions.minor}.0";
          patch = "${lib.versions.majorMinor version}.${bumped lib.versions.patch}";
        };
    in
    {
      packages = forAllSystems (
        { pkgs, beam }:
        {
          release = pkgs.writeShellApplication {
            name = "release";
            runtimeInputs = [
              pkgs.gawk
              pkgs.git
              pkgs.gnused
            ];
            runtimeEnv = next;
            text = ''
              case ''${1:-} in
                major | minor | patch) version=''${!1} ;;
                *) echo "usage: release major|minor|patch" >&2 && exit 1 ;;
              esac
              git fetch --quiet origin main
              if [ "$(git branch --show-current)" != main ] ||
                [ -n "$(git status --porcelain --untracked-files=no)" ] ||
                [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
                echo "release from a clean main that matches origin/main" >&2
                exit 1
              fi
              awk '/^## \[Unreleased\]/ { open = 1; next } /^## / { exit } open && NF { found = 1 } END { exit !found }' CHANGELOG.md ||
                { echo "CHANGELOG.md has nothing under [Unreleased]" >&2 && exit 1; }
              sed --in-place "s/^## \[Unreleased\]$/## [Unreleased]\n\n## [v$version] - $(date --utc +%F)/" CHANGELOG.md
              echo "$version" > VERSION
              git commit --quiet VERSION CHANGELOG.md --message "Release v$version"
              git push origin main
            '';
          };
          publish = pkgs.writeShellApplication {
            name = "publish";
            runtimeInputs = [
              beam.erlang
              beam.elixir_1_20
              pkgs.gh
              pkgs.git
            ];
            runtimeEnv = {
              ERL_LIBS = "${beam.hex}/lib/erlang/lib";
              MIX_REBAR3 = "${beam.rebar3}/bin/rebar3";
              VERSION = version;
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
                if pkgs.stdenv.hostPlatform.isDarwin then
                  "${pkgs.libreoffice-bin}/bin/soffice"
                else
                  "${pkgs.libreoffice.unwrapped}/lib/libreoffice/program/soffice"
              } --headless --norestore --nologo \
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
            mixEnv = "";
            hash = "sha256-wG1z4+BtT+UxoR8+5KF3Ec/fmeZix1j1G/IPXuc+kH0=";
          };
          mix =
            {
              name,
              env ? "test",
              inputs ? [ ],
              files ? [ ],
              setup ? "cp --recursive --no-preserve=mode ${compiled.${env}}/. .",
              command,
              output ? "touch $out",
            }:
            pkgs.stdenvNoCC.mkDerivation {
              inherit name;
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions (
                  [
                    ./mix.exs
                    ./mix.lock
                  ]
                  ++ files
                );
              };
              nativeBuildInputs = mixTools beam ++ inputs;
              MIX_ENV = env;
              MIX_REBAR3 = "${beam.rebar3}/bin/rebar3";
              HEX_OFFLINE = 1;
              buildPhase = ''
                export HOME=$TMPDIR MIX_DEPS_PATH=$PWD/deps
                echo 0.0.0 > VERSION
                ${setup}
              '';
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                ${command}
                runHook postCheck
              '';
              installPhase = output;
            };
          compiled = lib.genAttrs [ "dev" "test" ] (
            env:
            mix {
              name = "deps-${env}";
              inherit env;
              setup = "cp --recursive --no-preserve=mode ${deps} deps";
              command = "mix deps.compile --no-deps-check";
              output = ''
                mkdir $out
                cp --recursive deps _build $out
              '';
            }
          );
          sofficeTestHook = pkgs.makeSetupHook {
            name = "soffice-test-hook";
            substitutions.soffice = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.soffice;
          } ./nix/soffice-test-hook.sh;
          plt = mix {
            name = "plt";
            env = "dev";
            command = "mix dialyzer --plt";
            output = ''
              mkdir $out
              cp _build/plts/*.plt $out
            '';
          };
        in
        {
          test = mix {
            name = "test";
            inputs = [ sofficeTestHook ];
            files = [
              ./.formatter.exs
              ./lib
              ./test
            ];
            command = ''
              mix format --check-formatted
              mix compile --warnings-as-errors
              mix deps.unlock --check-unused
              mix xref graph --format cycles --label compile-connected --fail-above 0
              mix test --warnings-as-errors --include integration
            '';
          };
          docs = mix {
            name = "docs";
            env = "dev";
            files = [
              ./lib
              ./README.md
              ./PERFORMANCE.md
              ./CHANGELOG.md
              ./LICENSE
            ];
            command = "mix docs --warnings-as-errors";
          };
          dialyzer = mix {
            name = "dialyzer";
            env = "dev";
            files = [ ./lib ];
            command = ''
              mkdir _build/plts
              cp ${plt}/* _build/plts
              mix dialyzer --no-check
            '';
          };
          nixfmt =
            pkgs.runCommand "nixfmt"
              {
                nativeBuildInputs = [ pkgs.nixfmt ];
                src = lib.fileset.toSource {
                  root = ./.;
                  fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
                };
              }
              ''
                find $src -name '*.nix' -exec nixfmt --check {} +
                touch $out
              '';
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);

      devShells = forAllSystems (
        { pkgs, beam }:
        {
          default = pkgs.mkShell {
            packages = mixTools beam ++ [
              pkgs.fish
              pkgs.gh
              pkgs.uv
            ];

            shellHook = ''
              case $- in *i*) exec ${pkgs.fish}/bin/fish ;; esac
            '';
          };
        }
      );
    };
}
