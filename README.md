# omdrop-nix

AirDrop between iPhones and NixOS machines: Nix packages and a NixOS module
for [omdrop](https://github.com/brentkearney/omdrop-plugin) with the
[omdrop-owl](https://github.com/t4t5/omdrop-owl) radio backend, which runs
AWDL in userspace on Wi-Fi cards that aren't Apple's.

Status: experimental. Sending and receiving with an iPhone work on an Intel
AX200 (`iwlwifi`, exclusive mode) with Plasma 6, under NixOS 26.05 (kernel
6.19) and 26.11 as of October 2026 (kernel 7.2). Other cards are untried here.

## Use

```nix
{
  inputs.omdrop-nix = {
    url = "github:g4bri3lDev/omdrop-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # in a nixosSystem's modules:
  #   inputs.omdrop-nix.nixosModules.default
  #   { programs.omdrop.enable = true; }
}
```

Then, with an iPhone nearby set to receive from Everyone:

```sh
omdrop on            # become visible for ten minutes; sets itself up on first use
omdrop send FILE     # send to a nearby device
omdrop off
omdrop doctor        # what, if anything, is in the way
```

Received files land in `~/Downloads`.

### Plasma

With Plasma 6 enabled, files in Dolphin get a "Send via AirDrop" entry in
their context menu. It opens a window that lists nearby devices by name as
they answer, which takes up to twenty seconds, and sends to the one you
choose. The window turns omdrop on when it is off, after asking, and off
again when it closes. The launcher gets "AirDrop: Receive for 10 Minutes".

## Options

| Option | Default | |
|---|---|---|
| `programs.omdrop.enable` | `false` | Install omdrop and the backend, and configure the system for them. |
| `programs.omdrop.kde.enable` | Plasma 6 enabled | The Dolphin entry, its window and the launcher entry. |
| `programs.omdrop.interface` | first Wi-Fi interface | The interface AirDrop runs on. With two cards, name the one not carrying the network and Wi-Fi stays up. |
| `programs.omdrop.openFirewall` | `true` | Open TCP 8771 on `awdl0` only. |
| `programs.omdrop.allowUntested` | `false` | Run on a Wi-Fi card whose driver has no tested profile. |
| `programs.omdrop.extraProfiles` | `""` | Lines for `/etc/omdrop/owl-profiles`, read before the packaged table. |
| `programs.omdrop.package`, `backendPackage`, `kde.package` | this flake's | The packages. |

The module needs NetworkManager, Bluetooth and polkit, and says so at
evaluation when one is off. It keeps NetworkManager away from `awdl0`, `mon0`
and `awdlibss0`, and turns on pkexec's setuid wrapper where NixOS has made
that a choice (26.11).

## What to expect

- Which cards work, and how, is the backend's business: see its hardware
  table. Intel cards run in exclusive mode, so Wi-Fi is off while the machine
  is visible and comes back on `omdrop off`.
- `omdrop send --pick` and the bar panel belong to another desktop and aren't
  packaged. `omdrop send FILE` works anywhere.
- Keeping the identity in 1Password is untested here.

## Development

```sh
nix build .#omdrop-owl .#omdrop .#omdrop-kde
nix flake check
```

The revisions of OWL and omdrop-awdl in `pkgs/omdrop-owl` have to match the
`pins` file of the omdrop-owl revision; the build fails when they don't.
