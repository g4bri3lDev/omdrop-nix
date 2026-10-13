{
  description = "AirDrop for NixOS: omdrop with the OWL radio backend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      packagesFor = pkgs: rec {
        omdrop-owl = pkgs.callPackage ./pkgs/omdrop-owl { };
        omdrop = pkgs.callPackage ./pkgs/omdrop { inherit omdrop-owl; };
        omdrop-kde = pkgs.callPackage ./pkgs/omdrop-kde { inherit omdrop; };
      };
    in
    {
      packages = forAllSystems (pkgs: packagesFor pkgs // { default = (packagesFor pkgs).omdrop; });

      overlays.default = final: _prev: packagesFor final;

      nixosModules.default = ./modules/omdrop.nix;

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;

          # A NixOS configuration with the module on; `extra` overrides it.
          evalWith =
            extra:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "26.05";
                  networking.networkmanager.enable = true;
                  hardware.bluetooth.enable = true;
                  security.polkit.enable = true;
                  programs.omdrop.enable = true;
                }
                extra
              ];
            };
          toplevel = extra: (evalWith extra).config.system.build.toplevel.drvPath;
          rejected = extra: !(builtins.tryEval (toplevel extra)).success;

          good = evalWith {
            programs.omdrop = {
              allowUntested = true;
              interface = "wlp7s0";
              extraProfiles = "rtw88_8822be  untested  exclusive  station  no  no  Realtek RTL8822BE";
            };
          };

          plasma = evalWith { services.desktopManager.plasma6.enable = true; };
        in
        packagesFor pkgs
        // {
          # Evaluation only: nothing of the system is built.
          module =
            assert builtins.isString (toplevel { });
            assert good.config.networking.firewall.interfaces.awdl0.allowedTCPPorts == [ 8771 ];
            assert builtins.elem "interface-name:awdlibss0" good.config.networking.networkmanager.unmanaged;
            assert good.config.environment.etc."omdrop/allow-untested".text == "1\n";
            assert good.config.environment.etc."omdrop/infra-iface".text == "wlp7s0\n";
            assert !((evalWith { }).config.environment.etc ? "omdrop/infra-iface");
            assert
              !(good.options.security.polkit ? enablePkexecWrapper)
              || good.config.security.wrappers.pkexec.enable;
            assert
              !(builtins.elem good.config.programs.omdrop.kde.package good.config.environment.systemPackages);
            assert builtins.elem plasma.config.programs.omdrop.kde.package
              plasma.config.environment.systemPackages;
            assert rejected { networking.networkmanager.enable = nixpkgs.lib.mkForce false; };
            assert rejected { hardware.bluetooth.enable = nixpkgs.lib.mkForce false; };
            assert rejected { security.polkit.enable = nixpkgs.lib.mkForce false; };
            pkgs.runCommand "omdrop-module-eval" { } "touch $out";
        }
      );
    };
}
