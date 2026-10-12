{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bash,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  iproute2,
  keyutils,
  libnotify,
  openssl,
  python3,
  runtimeShell,
  wl-clipboard,
  writeShellScriptBin,
  xdg-utils,
  omdrop-owl,
}:

let
  pythonEnv = python3.withPackages (ps: [ ps.libarchive-c ]);

  # omdrop sends its desktop notifications through this command when it
  # exists. Same arguments, delivered with notify-send.
  notificationSend = writeShellScriptBin "omarchy-notification-send" ''
    args=()
    run=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) args+=(-t "$2"); shift 2 ;;
        --image) args+=(-i "$2"); shift 2 ;;
        --exec) shift; run=("$@"); break ;;
        *) args+=("$1"); shift ;;
      esac
    done
    if [ ''${#run[@]} -eq 0 ]; then
      exec ${libnotify}/bin/notify-send -a Omdrop "''${args[@]}"
    fi
    # Clicking the notification runs the command. notify-send waits for the
    # click, so it goes to the background.
    (
      [ "$(${libnotify}/bin/notify-send -a Omdrop -A default=Open "''${args[@]}")" = default ] \
        && exec "''${run[@]}"
    ) > /dev/null 2>&1 &
  '';

  launchBrowser = writeShellScriptBin "omarchy-launch-browser" ''
    exec ${xdg-utils}/bin/xdg-open "$@"
  '';

  # pacman's version comparison, which omdrop uses on the backend's contract.
  vercmp = writeShellScriptBin "vercmp" ''
    if [ "$1" = "$2" ]; then
      echo 0
    elif [ "$(printf '%s\n%s\n' "$1" "$2" | ${coreutils}/bin/sort -V | ${coreutils}/bin/head -n 1)" = "$1" ]; then
      echo -1
    else
      echo 1
    fi
  '';

  runtimePath = lib.makeBinPath [
    bash
    coreutils
    gawk
    gnugrep
    gnused
    iproute2
    keyutils
    launchBrowser
    notificationSend
    openssl
    pythonEnv
    vercmp
    wl-clipboard
    xdg-utils
  ];

  # What the receiving service's shell snippets and the receiver itself call.
  unitPath = lib.makeBinPath [
    coreutils
    gnugrep
    iproute2
  ];
in
stdenvNoCC.mkDerivation {
  pname = "omdrop";
  version = "0.16.1";

  src = fetchFromGitHub {
    owner = "brentkearney";
    repo = "omdrop-plugin";
    rev = "b2f9a537b150c26402c5daad8125fb7e61c214ec";
    hash = "sha256-VXIpUAmABTPUaiYRcJR71upvlH2SCoYkLO1pubUoooo=";
  };

  buildInputs = [
    bash
    pythonEnv
  ];

  postPatch = ''
    # The command carries its own environment, so it works however it is
    # started: from a shell, a desktop entry or one of its own systemd units.
    # pkexec is the setuid wrapper, systemctl the system's.
    sed -i '1a \
    export PATH=${runtimePath}''${PATH:+:$PATH}:/run/wrappers/bin:/run/current-system/sw/bin\
    export OMDROP_DISCOVERABLE=''${OMDROP_DISCOVERABLE:-${omdrop-owl}/lib/omdrop/omdrop-discoverable}\
    export OMDROP_SENDER=''${OMDROP_SENDER:-${omdrop-owl}/lib/omdrop/send-to-peer}' bin/omdrop

    substituteInPlace bin/omdrop \
      --replace-fail '[[ -e /usr/lib/libkeyutils.so.1 ]]' \
                     '[[ -e ${keyutils.lib}/lib/libkeyutils.so.1 ]]' \
      --replace-fail 'if [[ -z "$current" || "$current" == */plugins/*/bin/omdrop ]]; then' \
                     'if false; then' \
      --replace-fail 'elif [[ "$current" != "$plugin/bin/omdrop" ]]; then' \
                     'elif false; then'

    substituteInPlace bin/identity.py \
      --replace-fail "ctypes.CDLL('libkeyutils.so.1'" \
                     "ctypes.CDLL('${keyutils.lib}/lib/libkeyutils.so.1'"

    substituteInPlace share/airdrop-receiver.service \
      --replace-fail /usr/bin/python3 ${pythonEnv}/bin/python3 \
      --replace-fail /bin/sh ${runtimeShell}
    sed -i '/^\[Service\]$/a Environment=PATH=${unitPath}' share/airdrop-receiver.service
  '';

  dontBuild = true;

  # omdrop finds its own files from the directory that holds manifest.json,
  # so the layout of the source tree is kept.
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/omdrop" "$out/bin"
    cp -r bin share manifest.json LICENSE README.md "$out/share/omdrop/"
    chmod 755 "$out/share/omdrop/bin/omdrop"
    ln -s ../share/omdrop/bin/omdrop "$out/bin/omdrop"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    HOME=$TMPDIR "$out/bin/omdrop" version | grep -F 0.16.1
    ! grep -n '/usr/bin/python3\|ExecStartPre=/bin/sh' "$out/share/omdrop/share/airdrop-receiver.service"

    runHook postInstallCheck
  '';

  meta = {
    description = "Send and receive files with nearby Apple devices over AirDrop";
    homepage = "https://github.com/brentkearney/omdrop-plugin";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "omdrop";
  };
}
