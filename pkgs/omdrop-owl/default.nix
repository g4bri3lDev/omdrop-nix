{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  bash,
  coreutils,
  gawk,
  gnugrep,
  iproute2,
  iputils,
  iw,
  libev,
  libnl,
  libpcap,
  networkmanager,
  procps,
  python3,
  util-linux,
}:

let
  # Keep in step with the `pins` file of `src`; postPatch checks.
  owlRev = "832d70f815c3d4a06a02117bf0fc5e868daa1ff0";
  omdropAwdlRev = "534f91a525337951ca19c311e53d333bd6d55100";

  owl = fetchFromGitHub {
    owner = "jedbillyb";
    repo = "owl";
    rev = owlRev;
    fetchSubmodules = true;
    hash = "sha256-wke+tR6E4mfmzlGw1tgXiYOkSxeIRvaOmOYNWXIUVR8=";
  };

  omdropAwdl = fetchFromGitHub {
    owner = "brentkearney";
    repo = "omdrop-awdl";
    rev = omdropAwdlRev;
    hash = "sha256-GqxaM/5Qnj458AQPdHp1Jyfa6HK7tdybO6xDBbKUWc4=";
  };

  # omdrop-awdl's radio-independent tools, installed unmodified beside the
  # helper: they find each other as siblings.
  awdlTools = [
    "send-to-peer"
    "airdrop-send.py"
    "awdl-af-parse.py"
    "awdl_identity.py"
    "awdl_debug.py"
    "ble-airdrop-adv.py"
    "awdl-airdrop-adv.py"
    "awdl-mdns-respond.py"
  ];

  pythonEnv = python3.withPackages (
    ps: with ps; [
      dbus-python
      ifaddr
      libarchive-c
      pillow
      pygobject3
      zeroconf
    ]
  );

  # The helper runs as root through pkexec, which drops the environment, so
  # it carries its own PATH.
  helperPath = lib.makeBinPath [
    bash
    coreutils
    gawk
    gnugrep
    iproute2
    iputils
    iw
    networkmanager
    procps
    pythonEnv
    util-linux
  ];
in
stdenv.mkDerivation {
  pname = "omdrop-owl";
  version = "0.1.0-unstable-2026-10-12";

  src = fetchFromGitHub {
    owner = "t4t5";
    repo = "omdrop-owl";
    rev = "02de5ce63f04b2ff628e6ed805dd190a728266ff";
    hash = "sha256-IA8YeKhTCmC4IBbcxv/7ZAiV89tSw0D41yqTh1u8ozU=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
  ];

  buildInputs = [
    bash
    libev
    libnl
    libpcap
    pythonEnv
  ];

  postUnpack = ''
    cp -r ${owl} "$sourceRoot/owl"
    chmod -R u+w "$sourceRoot/owl"
  '';

  postPatch = ''
    . ./pins
    if [ "$OWL_COMMIT" != "${owlRev}" ] || [ "$OMDROP_AWDL_COMMIT" != "${omdropAwdlRev}" ]; then
      echo "the pinned OWL and omdrop-awdl revisions differ from ./pins" >&2
      exit 1
    fi

    for p in patches/owl-*.patch; do
      echo "applying $p"
      patch -d owl -p1 < "$p"
    done

    sed -i '1a export PATH=${helperPath}' userspace/omdrop-discoverable

    substituteInPlace packaging/omdrop-owl.policy \
      --replace-fail /usr/lib/omdrop/omdrop-discoverable "$out/lib/omdrop/omdrop-discoverable"
  '';

  cmakeDir = "../owl";
  # For the bundled googletest, whose cmake_minimum_required predates 3.5.
  cmakeFlags = [ "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" ];
  # Only OWL itself: googletest doesn't build under current GCC and isn't needed.
  buildFlags = [ "owl" ];

  installPhase = ''
    runHook preInstall

    lib=$out/lib/omdrop
    install -Dm755 daemon/owl "$lib/owl"
    cd "$NIX_BUILD_TOP/$sourceRoot"
    install -Dm755 userspace/omdrop-discoverable "$lib/omdrop-discoverable"
    install -Dm644 userspace/owl-profiles "$lib/owl-profiles"
    for f in ${lib.escapeShellArgs awdlTools}; do
      install -Dm755 "${omdropAwdl}/userspace/$f" "$lib/$f"
    done
    install -Dm644 packaging/omdrop-owl.policy \
      "$out/share/polkit-1/actions/io.github.t4t5.omdrop-owl.policy"
    install -Dm644 README.md "$out/share/doc/omdrop-owl/README.md"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    case "$("$out/lib/omdrop/owl" -S intersect -R 12 -m 02:00:00:00:00:01 -F -E -h 2>&1 || true)" in
      *"invalid option"* | *"-R takes"* | *"-m takes"*)
        echo "owl lacks -S, -R, -m, -F or -E: the patches did not apply" >&2
        exit 1
        ;;
    esac
    "$out/lib/omdrop/omdrop-discoverable" probe --json | grep -q '"backend": "owl"'

    runHook postInstallCheck
  '';

  meta = {
    description = "AirDrop radio backend for omdrop: AWDL in userspace through OWL";
    homepage = "https://github.com/t4t5/omdrop-owl";
    license = with lib.licenses; [
      gpl3Plus
      gpl2Only
      isc
    ];
    platforms = lib.platforms.linux;
  };
}
