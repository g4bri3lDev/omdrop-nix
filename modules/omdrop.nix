{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.programs.omdrop;
in
{
  options.programs.omdrop = {
    enable = lib.mkEnableOption "omdrop, AirDrop with nearby Apple devices through the OWL radio backend";

    backendPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/omdrop-owl { };
      defaultText = lib.literalExpression "omdrop-owl from this flake";
      description = "The radio backend: OWL and the helper that makes this machine visible.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/omdrop { omdrop-owl = cfg.backendPackage; };
      defaultText = lib.literalExpression "omdrop from this flake, built against backendPackage";
      description = "The omdrop command and receiver.";
    };

    kde = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.services.desktopManager.plasma6.enable;
        defaultText = lib.literalExpression "config.services.desktopManager.plasma6.enable";
        description = ''
          Add "Send via AirDrop" to Dolphin's menu for files, and a launcher
          entry that receives for ten minutes.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ../pkgs/omdrop-kde { omdrop = cfg.package; };
        defaultText = lib.literalExpression "omdrop-kde from this flake, built against package";
        description = "The send window and the two desktop entries.";
      };
    };

    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wlp7s0";
      description = ''
        The Wi-Fi interface the backend runs AirDrop on, written to
        {file}`/etc/omdrop/infra-iface`. Left unset, the backend takes the
        first Wi-Fi interface it finds. On a machine with two cards, naming
        the one that isn't carrying the network keeps Wi-Fi up while a card
        in exclusive mode is visible.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open the receiver's port, TCP 8771, on the AWDL interface `awdl0`.
        No other interface is touched. Without it, senders find this machine
        but their transfers are dropped.
      '';
    };

    allowUntested = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let the backend run on a Wi-Fi card whose driver has no tested
        profile, by putting `1` in {file}`/etc/omdrop/allow-untested`.
      '';
    };

    extraProfiles = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        rtw88_8822be  untested  exclusive  station  no  no  Realtek RTL8822BE
      '';
      description = ''
        Lines for {file}`/etc/omdrop/owl-profiles`, which the backend reads
        before its packaged table: one line per kernel driver, in the format
        of the backend's own `owl-profiles`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.networkmanager.enable;
        message = "programs.omdrop needs networking.networkmanager.enable: the radio backend hands Wi-Fi over and takes it back through nmcli.";
      }
      {
        assertion = config.hardware.bluetooth.enable;
        message = "programs.omdrop needs hardware.bluetooth.enable: Apple devices are woken over Bluetooth before a transfer.";
      }
      {
        assertion = config.security.polkit.enable;
        message = "programs.omdrop needs security.polkit.enable: omdrop starts the radio backend through pkexec.";
      }
    ];

    # Also where polkit finds the backend's action.
    environment.systemPackages = [
      cfg.package
      cfg.backendPackage
    ]
    ++ lib.optional cfg.kde.enable cfg.kde.package;

    environment.pathsToLink = lib.mkIf cfg.kde.enable [ "/share/kio/servicemenus" ];

    # NixOS 26.11 made pkexec's setuid wrapper opt-in, and without it pkexec
    # refuses to run at all.
    security.polkit = lib.optionalAttrs (options.security.polkit ? enablePkexecWrapper) {
      enablePkexecWrapper = true;
    };

    # A managed awdl0 gets a randomised MAC and no IPv6 link-local, and
    # NetworkManager taking the monitor or ad-hoc interface for a Wi-Fi
    # device to configure has crashed iwlwifi's firmware.
    networking.networkmanager.unmanaged = [
      "interface-name:awdl0"
      "interface-name:mon0"
      "interface-name:awdlibss0"
    ];

    # NixOS restarts wpa_supplicant whenever a Wi-Fi interface appears or
    # goes, the backend's own two among them, and the restart disconnects
    # every card: on a machine with a second one, the network dropped for
    # some ten seconds at each start and stop. The rule lives with all other
    # extra rules in one file, so these two skip to its end.
    services.udev.extraRules = lib.mkMerge [
      (lib.mkBefore ''
        SUBSYSTEM=="net", KERNEL=="mon0|awdlibss0", GOTO="omdrop_owl_end"
      '')
      (lib.mkAfter ''
        LABEL="omdrop_owl_end"
      '')
    ];

    networking.firewall.interfaces.awdl0.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 8771 ];

    environment.etc = {
      "omdrop/infra-iface" = lib.mkIf (cfg.interface != null) { text = "${cfg.interface}\n"; };
      "omdrop/allow-untested" = lib.mkIf cfg.allowUntested { text = "1\n"; };
      "omdrop/owl-profiles" = lib.mkIf (cfg.extraProfiles != "") { text = cfg.extraProfiles; };
    };
  };
}
