{
  lib,
  stdenvNoCC,
  bash,
  libnotify,
  makeWrapper,
  python3,
  qt6,
  omdrop,
}:

let
  pythonEnv = python3.withPackages (ps: [ ps.pyqt6 ]);
in
stdenvNoCC.mkDerivation {
  pname = "omdrop-kde";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    makeWrapper
    qt6.wrapQtAppsHook
  ];
  buildInputs = [
    qt6.qtbase
    qt6.qtwayland
  ];

  dontBuild = true;
  # The window is a Python script: it gets the Qt environment through the
  # wrapper made below.
  dontWrapQtApps = true;

  installPhase = ''
    runHook preInstall

    install -Dm644 omdrop_send.py "$out/share/omdrop-kde/omdrop_send.py"
    install -Dm644 omdrop-send.desktop "$out/share/kio/servicemenus/omdrop-send.desktop"
    install -Dm644 omdrop-receive.desktop "$out/share/applications/omdrop-receive.desktop"
    substituteInPlace "$out/share/kio/servicemenus/omdrop-send.desktop" \
      --replace-fail 'Exec=omdrop-send' "Exec=$out/bin/omdrop-send"
    substituteInPlace "$out/share/applications/omdrop-receive.desktop" \
      --replace-fail 'Exec=omdrop' 'Exec=${lib.getExe omdrop}'

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/omdrop-send" \
      --add-flags "$out/share/omdrop-kde/omdrop_send.py" \
      --set-default OMDROP ${lib.getExe omdrop} \
      --set-default OMDROP_NOTIFY_SEND ${libnotify}/bin/notify-send \
      "''${qtWrapperArgs[@]}"
  '';

  # The window, driven without a display against a stand-in for omdrop.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ bash ];
  installCheckPhase = ''
    runHook preInstallCheck

    export HOME=$TMPDIR XDG_CONFIG_HOME=$TMPDIR/config
    QT_QPA_PLATFORM=offscreen QT_PLUGIN_PATH=${qt6.qtbase}/${qt6.qtbase.qtPluginPrefix} \
      ${pythonEnv}/bin/python3 test_omdrop_send.py -v

    runHook postInstallCheck
  '';

  meta = {
    description = "Send via AirDrop from Dolphin, and a launcher entry to receive";
    homepage = "https://github.com/g4bri3lDev/omdrop-nix";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "omdrop-send";
  };
}
