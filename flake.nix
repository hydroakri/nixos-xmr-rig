{
  description = "Monero mining dev shell (xmrig, project-scoped, no system config changes)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems f;
    in {
      devShells = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
          # nixpkgs xmrig has no OpenCL toggle; the backend dlopen()s libOpenCL
          # at runtime (headers are bundled), so only the cmake flag is needed.
          xmrig = pkgs.xmrig.overrideAttrs (old: {
            cmakeFlags = old.cmakeFlags ++ [ (pkgs.lib.cmakeBool "WITH_OPENCL" true) ];
          });
        in {
          default = pkgs.mkShell {
            packages = [ xmrig pkgs.gamemode pkgs.clinfo ]
              # CUDA plugin is x86_64-only (no CUDA userspace on the aarch64 SBC hosts)
              ++ pkgs.lib.optional (system == "x86_64-linux") pkgs.xmrig-cuda;
          };
        }
      );
    };
}
