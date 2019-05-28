{ config, stdenv, callPackage,
  pkgs, androidenv, fetchurl, openjdk, nodejs, bash, git, gradle, perl, zlib,
  status-go }:

with stdenv;

let
  androidComposition = androidenv.composeAndroidPackages {
    toolsVersion = "26.1.1";
    platformToolsVersion = "28.0.2";
    buildToolsVersions = [ "28.0.3" ];
    includeEmulator = false;
    platformVersions = [ "28" ];
    includeSources = false;
    includeDocs = false;
    includeSystemImages = false;
    systemImageTypes = [ "default" ];
    abiVersions = [ "armeabi-v7a" ];
    lldbVersions = [ "2.0.2558144" ];
    cmakeVersions = [ "3.6.4111459" ];
    includeNDK = true;
    ndkVersion = "19.2.5345600";
    useGoogleAPIs = false;
    useGoogleTVAddOns = false;
    includeExtras = [ "extras;android;m2repository" "extras;google;m2repository" ];
  };
  licensedAndroidEnv = callPackage ./licensed-android-sdk.nix { inherit androidComposition; };
  src =
    let
      src = ./../..; # Import the root /android and /mobile_files folders clean of any build artifacts

      mkFilter = { dirsToInclude, dirsToExclude, filesToInclude, root }: path: type:
        let
          inherit (lib) elem elemAt splitString;
          baseName = baseNameOf (toString path);
          subpath = elemAt (splitString "${toString root}/" path) 1;
          spdir = elemAt (splitString "/" subpath) 0;

        in lib.cleanSourceFilter path type && ((type != "directory" && (elem spdir filesToInclude)) || ((elem spdir dirsToInclude) && ! (
          # Filter out version control software files/directories
          (type == "directory" && (elem baseName dirsToExclude)) ||
          # Filter out editor backup / swap files.
          lib.hasSuffix "~" baseName ||
          builtins.match "^\\.sw[a-z]$" baseName != null ||
          builtins.match "^\\..*\\.sw[a-z]$" baseName != null ||

          # Filter out generated files.
          lib.hasSuffix ".o" baseName ||
          lib.hasSuffix ".so" baseName ||
          # Filter out nix-build result symlinks
          (type == "symlink" && lib.hasPrefix "result" baseName)
        )));
      in builtins.filterSource
          (mkFilter {
            dirsToInclude = [ "android" "mobile_files" "packager" "resources" "scripts" ];
            dirsToExclude = [ ".git" ".svn" "CVS" ".hg" ".gradle" "build" "intermediates" ];
            filesToInclude = [ ".env" ];
            root = src;
          })
      src;
  node2nix = import ./node2nix { inherit pkgs nodejs; };
  nodePackage = node2nix.package.override(oldAttrs: {
    buildInputs = oldAttrs.buildInputs ++ [ pkgs.nodePackages.node-pre-gyp ];
    reconstructLock = true;
    preRebuild = ''
      # Do not attempt to do any http calls!
      substituteInPlace $out/lib/node_modules/${nodeProjectName}/node_modules/realm/scripts/download-realm.js \
        --replace "!shouldSkipAcquire(realmDir, requirements, options.force)" "false"
      mkdir -p ${realm-dest-dir}
      tar -xzf ${realm-core-src} -C ${realm-dest-dir}
    '';
  });
  nodeProjectName = "StatusIm";

  realm-core-version = "5.12.1";
  realm-version = "2.28.0";
  realm-patched-name = "realm-${realm-version}";
  # We download ${realm-core-src} to ${realm-dest-dir} in order to avoid having realm try to download these files on its own (which is disallowed by Nix)
  realm-core-src = pkgs.fetchurl (
    if builtins.currentSystem == "x86_64-darwin" then {
      url = "https://static.realm.io/downloads/core/realm-core-Release-v${realm-core-version}-Darwin-devel.tar.gz";
      sha256 = "05ji1zyskwjj8p6i01kcg7h1cxdjj62fcsp6haf2f65qshp6r44d";
    } else {
      url = "https://static.realm.io/downloads/core/realm-core-Release-v${realm-core-version}-Linux-devel.tar.gz";
      sha256 = "02pvi28qnvzdv7ghqzf79bxn8id9s7mpp3g2ambxg8jrcrkqfvr1";
    }
  );
  realm-dest-dir = if builtins.currentSystem == "x86_64-darwin" then
    "$out/lib/node_modules/${nodeProjectName}/node_modules/realm/compiled/node-v64_darwin_x64/realm.node" else
    "$out/lib/node_modules/${nodeProjectName}/node_modules/realm/compiled/node-v64_linux_x64/realm.node";

  mavenLocalRepos = callPackage ./gradle/maven-repo.nix { inherit stdenv; };
  fakeMavenRepoBuilder = callPackage ./gradle/maven-repo-builder.nix { inherit stdenv; };

  jsc-filename = "jsc-android-236355.1.1";
  react-native-deps = callPackage ./gradle/reactnative-android-native-deps.nix { inherit jsc-filename; };

  # fake build to pre-download deps into fixed-output derivation
  deps = stdenv.mkDerivation {
    name = "gradle-install-android-archives";
    inherit src;
    buildInputs = [ gradle bash git perl zlib ];
    unpackPhase = ''
      cp -R $src/* .
      chmod -R u+w android

      # Copy fresh RN maven dependencies and make them writable, otherwise Gradle copy fails
      cp -R ${react-native-deps}/deps ./deps
      chmod -R u+w ./deps

      # Copy fresh node_modules and adjust permissions
      rm -rf ./node_modules
      mkdir -p ./node_modules
      cp -R ${nodePackage}/lib/node_modules/${nodeProjectName}/node_modules .
      chmod u+w -R ./node_modules/react-native

      ln -s mobile_files/package.json
      ln -s mobile_files/.babelrc
      ln -s mobile_files/VERSION
      ln -s mobile_files/metro.config.js
    '';
    patchPhase = ''
      # Patch maven and google central repositories with our own local directories. This prevents the builder from downloading Maven artifacts
      substituteInPlace android/build.gradle \
        --replace "google()" "maven { url \"${mavenLocalRepos."StatusIm"}\" }" \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."StatusIm"}\" }" \
        --replace "\$rootDir/../node_modules/react-native/android" "${mavenLocalRepos."react-native-android"}"
      substituteInPlace node_modules/react-native-camera/android/build.gradle \
        --replace "jcenter()" "" \
        --replace "google()" "" \
        --replace "https://maven.google.com" "${mavenLocalRepos."react-native-camera"}" \
        --replace "\$rootDir/../node_modules/react-native/android" "${mavenLocalRepos."react-native-android"}"
      substituteInPlace node_modules/react-native-config/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."StatusIm"}\" }" \
        --replace "https://maven.google.com" "${mavenLocalRepos."react-native-config"}"
      substituteInPlace node_modules/react-native-dialogs/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-dialogs"}\" }" \
        --replace "https://jitpack.io" "${mavenLocalRepos."react-native-dialogs"}"
      substituteInPlace node_modules/react-native-firebase/android/build.gradle \
        --replace "google()" "" \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-firebase"}\" }" \
        --replace "https://maven.fabric.io/public" "${mavenLocalRepos."react-native-firebase"}"
      substituteInPlace node_modules/react-native-fs/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-fs"}\" }"
      substituteInPlace node_modules/react-native-http-bridge/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-http-bridge"}\" }"
      substituteInPlace node_modules/react-native-image-resizer/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-image-resizer"}\" }"
      substituteInPlace node_modules/react-native-keychain/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-keychain"}\" }"
      substituteInPlace node_modules/react-native-securerandom/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-securerandom"}\" }"
      substituteInPlace node_modules/react-native-status-keycard/android/build.gradle \
        --replace "google()" "maven { url \"${mavenLocalRepos."react-native-status-keycard"}\" }" \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-status-keycard"}\" }" \
        --replace "https://maven.google.com" "${mavenLocalRepos."react-native-status-keycard"}"
      substituteInPlace node_modules/react-native-svg/android/build.gradle \
        --replace "google()" "maven { url \"${mavenLocalRepos."react-native-svg"}\" }" \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-svg"}\" }"
      substituteInPlace node_modules/react-native-webview/android/build.gradle \
        --replace "google()" "maven { url \"${mavenLocalRepos."react-native-webview"}\" }" \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-webview"}\" }"
      substituteInPlace node_modules/react-native-webview-bridge/android/build.gradle \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."react-native-webview-bridge"}\" }"
      substituteInPlace node_modules/realm/android/build.gradle \
        --replace "google()" "maven { url \"${mavenLocalRepos."realm"}\" }" \
        --replace "jcenter()" "maven { url \"${mavenLocalRepos."realm"}\" }"

      # Patch prepareJSC so that it doesn't try to download from registry
      substituteInPlace node_modules/react-native/ReactAndroid/build.gradle \
        --replace "prepareJSC(dependsOn: downloadJSC)" "prepareJSC(dependsOn: createNativeDepsDirectories)" \
        --replace "def jscTar = tarTree(downloadJSC.dest)" "def jscTar = tarTree(new File(\"../../../deps/${jsc-filename}.tar.gz\"))"

      substituteInPlace scripts/build_no.sh \
        --replace "(git rev-parse --show-toplevel)" "STATUS_REACT_HOME"

      # TODO; figure out why we get `path may not be null or empty string. path='null'`
      substituteInPlace node_modules/react-native/ReactAndroid/release.gradle \
        --replace "classpath += files(project.getConfigurations().getByName(\"compile\").asList())" ""
    '';
    buildPhase = ''
      export JAVA_HOME="${openjdk}"
      export ANDROID_HOME="${licensedAndroidEnv}"
      export ANDROID_SDK_ROOT="$ANDROID_HOME"
      export ANDROID_NDK_ROOT="${androidComposition.androidsdk}/libexec/android-sdk/ndk-bundle"
      export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
      export ANDROID_NDK="$ANDROID_NDK_ROOT"
      export PATH="$ANDROID_HOME/bin:$ANDROID_HOME/tools:$ANDROID_HOME/tools/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools:$PATH"

      export REACT_NATIVE_DEPENDENCIES="$(pwd)/deps"

      ${status-go.shellHook}

      export GRADLE_USER_HOME=$(mktemp -d)
      ( cd android
        LD_LIBRARY_PATH=$LD_LIBRARY_PATH:${stdenv.lib.makeLibraryPath [ zlib ]} \
          gradle --no-daemon react-native-android:installArchives
      )
    '';
    installPhase = ''
      rm -rf $out
      mkdir -p $out
      cp -R node_modules/ $out

      # Patch prepareJSC so that it doesn't subsequently try to build NDK libs
      substituteInPlace $out/node_modules/react-native/ReactAndroid/build.gradle \
        --replace "packageReactNdkLibs(dependsOn: buildReactNdkLib, " "packageReactNdkLibs(" \
        --replace "../../../deps/${jsc-filename}.tar.gz" "${react-native-deps}/deps/${jsc-filename}.tar.gz" 

      # Generate Maven directory structure in node_modules/react-native/android from existing cache
      # perl code mavenizes pathes (com.squareup.okio/okio/1.13.0/a9283170b7305c8d92d25aff02a6ab7e45d06cbe/okio-1.13.0.jar -> com/squareup/okio/okio/1.13.0/okio-1.13.0.jar)
      find $GRADLE_USER_HOME/caches/modules* -type f -regex '.*\.\(jar\|pom\)' \
        | perl -pe 's#(.*/([^/]+)/([^/]+)/([^/]+)/[0-9a-f]{30,40}/([^/\s]+))$# ($x = $2) =~ tr|\.|/|; "install -Dm444 $1 \$out/node_modules/react-native/android/$x/$3/$4/$5" #e' \
        | sh
    '';
    dontPatchELF = true; # The ELF types are incompatible with the host platform, so let's not even try
    noAuditTmpdir = true;
    # TODO: see if this is actually needed to take src file hashes into account
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  };

in
  {
    inherit androidComposition;

    buildInputs = [ deps openjdk gradle ];
    shellHook = ''
      export JAVA_HOME="${openjdk}"
      export ANDROID_HOME="${licensedAndroidEnv}"
      export ANDROID_SDK_ROOT="$ANDROID_HOME"
      export ANDROID_NDK_ROOT="${androidComposition.androidsdk}/libexec/android-sdk/ndk-bundle"
      export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
      export ANDROID_NDK="$ANDROID_NDK_ROOT"
      export PATH="$ANDROID_HOME/bin:$ANDROID_HOME/tools:$ANDROID_HOME/tools/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools:$PATH"

      $STATUS_REACT_HOME/scripts/generate-keystore.sh
    '' +
    ''
      if [ -d ./node_modules ]; then
        chmod u+w -R ./node_modules
        rm -rf ./node_modules || exit
      fi
      echo "Copying node_modules from Nix store (${deps}/node_modules)..."
      # mkdir -p node_modules # node_modules/react-native/ReactAndroid
      time cp -HR --preserve=all ${deps}/node_modules .
      echo "Done"

      # This avoids RN trying to download dependencies. Maybe we need to wrap this in a special RN environment derivation
      export REACT_NATIVE_DEPENDENCIES="${react-native-deps}/deps"

      rndir='node_modules/react-native'
      rnabuild="$rndir/ReactAndroid/build"
      chmod 744 $rndir/scripts/.packager.env \
                $rndir/ReactAndroid/build.gradle \
                $rnabuild/outputs/logs/manifest-merger-release-report.txt \
                $rnabuild/intermediates/library_manifest/release/AndroidManifest.xml \
                $rnabuild/intermediates/aapt_friendly_merged_manifests/release/processReleaseManifest/aapt/AndroidManifest.xml \
                $rnabuild/intermediates/aapt_friendly_merged_manifests/release/processReleaseManifest/aapt/output.json \
                $rnabuild/intermediates/incremental/packageReleaseResources/compile-file-map.properties \
                $rnabuild/intermediates/incremental/packageReleaseResources/merger.xml \
                $rnabuild/intermediates/merged_manifests/release/output.json \
                $rnabuild/intermediates/symbols/release/R.txt \
                $rnabuild/intermediates/res/symbol-table-with-package/release/package-aware-r.txt
      chmod u+w -R $rnabuild

      export PATH="$PATH:${deps}/node_modules/.bin"
    '';
  }
