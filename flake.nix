{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShell = with pkgs;
          stdenv.mkDerivation {
            name = "dev-shell";
            version = "1.0.0";
            nativeBuildInputs = [
              llvmPackages_14.bintools
            ];
            buildInput = [
              zig
            ];
          };
      });
}
