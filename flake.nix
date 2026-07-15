{
  description = "Grumble: local, on-device dictation for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      # Pinned to the latest release; CI rewrites this file on every tag
      # (see the appcast commit step in .github/workflows/release.yml).
      release = builtins.fromJSON (builtins.readFile ./nix/version.json);
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkGrumble = pkgs: pkgs.stdenvNoCC.mkDerivation {
        pname = "grumble";
        inherit (release) version;

        src = pkgs.fetchurl {
          url = "https://github.com/fcjr/grumble/releases/download/v${release.version}/Grumble-${release.version}.zip";
          hash = release.sha256;
        };

        nativeBuildInputs = [ pkgs.unzip ];
        sourceRoot = ".";

        installPhase = ''
          mkdir -p $out/Applications
          cp -R Grumble.app $out/Applications/
        '';

        # The bundle is signed and notarized; any patching would break the
        # signature, so skip fixup entirely.
        dontFixup = true;

        meta = with nixpkgs.lib; {
          description = "Local, on-device dictation for macOS";
          homepage = "https://grumble.computer";
          license = licenses.asl20;
          platforms = systems;
          sourceProvenance = [ sourceTypes.binaryNativeCode ];
        };
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        grumble = mkGrumble pkgs;
        default = grumble;
      });

      overlays.default = final: prev: {
        grumble = mkGrumble final;
      };
    };
}
