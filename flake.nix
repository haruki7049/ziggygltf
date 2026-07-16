{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    flake-compat.url = "github:edolstra/flake-compat";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          ZIG = pkgs.zig_0_16;
          ZLS = pkgs.zls_0_16;

          ziggygltf = pkgs.stdenv.mkDerivation {
            name = "ziggygltf";
            src = lib.cleanSource ./.;
            doCheck = true;

            nativeBuildInputs = [
              ZIG.hook
            ];

            postConfigure = ''
              ln -s ${pkgs.callPackage ./.deps.nix { }} zig-pkg

              # Remove NIX_CFLAGS_COMPILE because zig cannot understand it
              unset NIX_CFLAGS_COMPILE
            '';
          };
        in
        {
          treefmt = {
            projectRootFile = ".git/config";

            # Nix
            programs.nixfmt.enable = true;

            # Zig
            programs.zig.enable = true;
            programs.zig.package = ZIG;

            # GitHub Actions
            programs.actionlint.enable = true;

            # Markdown
            programs.mdformat.enable = true;

            # Shell Scripts
            programs.shfmt.enable = true;
            programs.shellcheck.enable = true;
          };

          packages = {
            inherit ziggygltf;
            default = ziggygltf;
          };

          checks = {
            inherit ziggygltf;
          };

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [
              ZIG # Zig Compiler
              ZLS # Zig LSP
              pkgs.nil # Nix LSP
              pkgs.zon2nix # zon2nix
            ];

            inputsFrom = [
              config.treefmt.build.devShell
            ];

            shellHook = ''
              # Remove NIX_CFLAGS_COMPILE because zig cannot understand it
              unset NIX_CFLAGS_COMPILE
            '';
          };
        };
    };
}
