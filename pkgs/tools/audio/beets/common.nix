{ stdenv
, bashInteractive
, diffPlugins
, glibcLocales
, gobject-introspection
, gst_all_1
, lib
, python3Packages
, runtimeShell
, writeScript

  # plugin deps
, aacgain
, essentia-extractor
, ffmpeg
, flac
, imagemagick
, keyfinder-cli
, mp3gain
, mp3val

, src
, version
, pluginOverrides ? { }
, disableAllPlugins ? false
}@inputs:
let
  inherit (lib) attrNames attrValues concatMap;

  builtinPlugins = import ./builtin-plugins.nix inputs;

  mkPlugin = { enable ? !disableAllPlugins, propagatedBuildInputs ? [ ], testPaths ? [ ], wrapperBins ? [ ] }: {
    inherit enable propagatedBuildInputs testPaths wrapperBins;
  };

  allPlugins = lib.mapAttrs (_: mkPlugin) (lib.recursiveUpdate builtinPlugins pluginOverrides);
  enabledPlugins = lib.filterAttrs (_: p: p.enable) allPlugins;
  disabledPlugins = lib.filterAttrs (_: p: !p.enable) allPlugins;

  pluginWrapperBins = concatMap (p: p.wrapperBins) (attrValues enabledPlugins);
in
python3Packages.buildPythonApplication rec {
  pname = "beets";
  inherit src version;

  patches = [
    # Bash completion fix for Nix
    ./patches/bash-completion-always-print.patch
  ];

  propagatedBuildInputs = with python3Packages; [
    confuse
    gobject-introspection
    gst-python
    jellyfish
    mediafile
    munkres
    musicbrainzngs
    mutagen
    pygobject3
    pyyaml
    reflink
    unidecode
  ] ++ (concatMap (p: p.propagatedBuildInputs) (attrValues enabledPlugins));

  buildInputs = [
  ] ++ (with gst_all_1; [
    gst-plugins-base
    gst-plugins-good
    gst-plugins-ugly
  ]);

  postInstall = ''
    mkdir -p $out/share/zsh/site-functions
    cp extra/_beet $out/share/zsh/site-functions/
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    tmphome="$(mktemp -d)"

    EDITOR="${writeScript "beetconfig.sh" ''
      #!${runtimeShell}
      cat > "$1" <<CFG
      plugins: ${lib.concatStringsSep " " (attrNames enabledPlugins)}
      CFG
    ''}" HOME="$tmphome" "$out/bin/beet" config -e
    EDITOR=true HOME="$tmphome" "$out/bin/beet" config -e

    runHook postInstallCheck
  '';

  makeWrapperArgs = [
    "--set GI_TYPELIB_PATH \"$GI_TYPELIB_PATH\""
    "--set GST_PLUGIN_SYSTEM_PATH_1_0 \"$GST_PLUGIN_SYSTEM_PATH_1_0\""
    "--prefix PATH : ${lib.makeBinPath pluginWrapperBins}"
  ];

  checkInputs = with python3Packages; [
    pytest
    mock
    rarfile
    responses
  ] ++ pluginWrapperBins;

  disabledTestPaths = lib.flatten (attrValues (lib.mapAttrs (n: v: v.testPaths ++ [ "test/test_${n}.py" ]) disabledPlugins));

  checkPhase = ''
    runHook preCheck

    # Check for undefined plugins
    find beetsplug -mindepth 1 \
      \! -path 'beetsplug/__init__.py' -a \
      \( -name '*.py' -o -path 'beetsplug/*/__init__.py' \) -print \
      | sed -n -re 's|^beetsplug/([^/.]+).*|\1|p' \
      | sort -u > plugins_available
    ${diffPlugins (attrNames allPlugins) "plugins_available"}

    export BEETS_TEST_SHELL="${bashInteractive}/bin/bash --norc"
    export HOME="$(mktemp -d)"

    args=" -m pytest -r fEs"
    eval "disabledTestPaths=($disabledTestPaths)"
    for path in ''${disabledTestPaths[@]}; do
      if [ -e "$path" ]; then
        args+=" --ignore $path"
      else
        echo "Skipping non-existent test path '$path'"
      fi
    done

    python $args

    runHook postCheck
  '';

  meta = with lib; {
    description = "Music tagger and library organizer";
    homepage = "https://beets.io";
    license = licenses.mit;
    maintainers = with maintainers; [ aszlig doronbehar lovesegfault pjones ];
    platforms = platforms.linux;
  };
}
