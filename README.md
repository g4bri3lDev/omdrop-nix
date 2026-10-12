# omdrop-nix

AirDrop between iPhones and NixOS machines: Nix packages and a NixOS module
for [omdrop](https://github.com/brentkearney/omdrop-plugin) with the
[omdrop-owl](https://github.com/t4t5/omdrop-owl) radio backend, which runs
AWDL in userspace on Wi-Fi cards that aren't Apple's.

Status: experimental. Sending and receiving with an iPhone work on an Intel
AX200 (`iwlwifi`, exclusive mode) under NixOS 26.05 with Plasma 6. Other cards
are untried here.

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

## Options

| Option | Default | |
|---|---|---|
| `programs.omdrop.enable` | `false` | Install omdrop and the backend, and configure the system for them. |
| `programs.omdrop.openFirewall` | `true` | Open TCP 8771 on `awdl0` only. |
| `programs.omdrop.allowUntested` | `false` | Run on a Wi-Fi card whose driver has no tested profile. |
| `programs.omdrop.extraProfiles` | `""` | Lines for `/etc/omdrop/owl-profiles`, read before the packaged table. |
| `programs.omdrop.package`, `backendPackage` | this flake's | The two packages. |

The module needs NetworkManager, Bluetooth and polkit, and says so at
evaluation when one is off. It keeps NetworkManager away from `awdl0`, `mon0`
and `awdlibss0`.

## What to expect

- Which cards work, and how, is the backend's business: see its hardware
  table. Intel cards run in exclusive mode, so Wi-Fi is off while the machine
  is visible and comes back on `omdrop off`.
- `omdrop send --pick` and the bar panel belong to another desktop and aren't
  packaged. `omdrop send FILE` works anywhere.
- Keeping the identity in 1Password is untested here.

## Development

```sh
nix build .#omdrop-owl .#omdrop
nix flake check
```

The revisions of OWL and omdrop-awdl in `pkgs/omdrop-owl` have to match the
`pins` file of the omdrop-owl revision; the build fails when they don't.
