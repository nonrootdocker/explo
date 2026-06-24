{
  description = "minimalbase + explo service";
  inputs = {
    nixpkgs.follows = "minimalbase/nixpkgs";
    minimalbase.url = "github:nonrootdocker/minimalbase";
    explo-src = {
      type = "file";
      url = "https://github.com/LumePart/Explo/releases/latest/download/explo-linux-amd64";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, minimalbase, explo-src }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    # ----------------------------
    # Python runtime with ytmusicapi — Explo shells out to it for YouTube Music
    # lookups (the binary-install method requires python3 + ytmusicapi on PATH).
    # ----------------------------
    exploPython = pkgs.python3.withPackages (ps: [ ps.ytmusicapi ]);

    # ----------------------------
    # Explo package (prebuilt release binary, frontend embedded upstream)
    # ----------------------------
    explo = pkgs.stdenv.mkDerivation {
      pname = "explo";
      version = "release";
      src = explo-src;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [ pkgs.stdenv.cc.cc.lib ];
      installPhase = ''
        mkdir -p $out/bin
        cp $src $out/bin/explo
        chmod +x $out/bin/explo
      '';
    };

    # ----------------------------
    # Explo version: read from the binary's own version output.
    # Exposed as the `version` output for CI tagging.
    # ----------------------------
    exploVersion = pkgs.runCommand "explo-version" { } ''
      ${explo}/bin/explo --version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d '\n' > $out
    '';

    # ----------------------------
    # User database configuration (/etc/passwd)
    # ----------------------------
    passwdFile = pkgs.writeTextDir "etc/passwd" ''
      root:x:0:0:root:/root:/bin/sh
      explo:x:1000:1000:explo:/data:/bin/sh
    '';

    # ----------------------------
    # ABI descriptor for container-init
    # ----------------------------
    exploAbi = pkgs.writeTextFile {
      name = "explo-abi.json";
      text = builtins.toJSON {
        version = 2;
        process = {
          exec = "${explo}/bin/explo";
          args = [ ];
          # explo reads its .env relative to the cwd and does not create its
          # own data dirs; run from /data and pre-create config/cache there.
          cwd = "/data";
          dirs = [ "/data/config" "/data/cache" ];
        };
      };
      destination = "/app/main";
    };

  in {
    packages.${system} = {
      default = self.packages.${system}.explo-image;
      version = exploVersion;
      explo-image = pkgs.dockerTools.buildImage {
        name = "explo";
        tag = "latest";
        fromImage = minimalbase.packages.${system}.base-image;
        copyToRoot = pkgs.buildEnv {
          name = "root";
          paths = [
            pkgs.coreutils
            pkgs.tzdata
            pkgs.cacert
            pkgs.ffmpeg
            pkgs.yt-dlp
            exploPython
            explo
            exploAbi
            passwdFile
          ];
        };
        config = {
          Entrypoint = [ "${minimalbase.packages.${system}.container-init}/bin/container-init" ];
          User = "1000:1000";
          Env = [
            "PATH=/bin"
            "TZ=UTC"
            "LANG=en_US.UTF-8"
            "WEB_ADDR=:7288"
            "WEB_DATA_PATH=/data/config"
          ];
        };
      };
    };
  };
}
