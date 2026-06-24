{
  description = "minimalbase + explo service";
  inputs = {
    nixpkgs.follows = "minimalbase/nixpkgs";
    minimalbase.url = "github:nonrootdocker/minimalbase";
    explo-src = {
      url = "github:LumePart/Explo/v1.1.2";
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

    # Built from source, pinned to a release tag. The prebuilt release binary
    # ships an EMPTY embedded web UI (upstream's release workflow stubs it with
    # `touch src/web/dist/index.html`); only a source build with the Vite
    # frontend embedded serves a working UI.
    version = "1.1.2";

    # ----------------------------
    # Vite frontend. vite.config.js writes the build to ../dist (i.e.
    # src/web/dist), which the Go binary embeds via //go:embed dist/*.
    # ----------------------------
    explo-frontend = pkgs.buildNpmPackage {
      pname = "explo-frontend";
      inherit version;
      src = "${explo-src}/src/web/frontend";
      npmDepsHash = "sha256-N+i+VFHKJ9OxHyQKJ3vSw50N3tLjvFVPeG5aU0hLzqw=";
      VITE_VERSION = version;
      installPhase = ''
        runHook preInstall
        cp -r ../dist "$out"
        runHook postInstall
      '';
    };

    # ----------------------------
    # Explo binary, with the built frontend embedded.
    # ----------------------------
    explo = pkgs.buildGoModule {
      pname = "explo";
      inherit version;
      src = explo-src;
      vendorHash = "sha256-pa3WaVJU4WY/EyE3VttfEVOwwaxvkfxQj0wrwOmefYQ=";
      subPackages = [ "src/main" ];
      ldflags = [ "-s" "-w" "-X" "explo/src/config.Version=${version}" ];
      # Place the built frontend where //go:embed expects it before building.
      preBuild = ''
        mkdir -p src/web/dist
        cp -r ${explo-frontend}/. src/web/dist/
        [ -f src/web/sample.env ] || cp sample.env src/web/sample.env
      '';
      postInstall = ''
        mv "$out/bin/main" "$out/bin/explo"
      '';
    };

    # Version output for CI tagging.
    exploVersion = pkgs.writeText "explo-version" version;

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
          ExposedPorts = {
            "7288/tcp" = { };
          };
          Env = [
            "PATH=/bin"
            "TZ=UTC"
            "LANG=en_US.UTF-8"
            "WEB_UI=true"
            "WEB_ADDR=:7288"
            "WEB_DATA_PATH=/data/config"
          ];
        };
      };
    };
  };
}
