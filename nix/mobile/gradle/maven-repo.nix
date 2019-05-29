{ stdenv, callPackage }:

let
  fakeMavenRepoBuilder = callPackage ./maven-repo-builder.nix { inherit stdenv; };
  makeFakeMavenRepo = srcName: source: fakeMavenRepoBuilder source "${srcName}-maven-deps";
  sources = {
    "StatusIm" = import ./StatusIm { };
    "react-native-android" = import ./react-native-android { };
    "react-native-camera" = import ./react-native-camera { };
    "react-native-config" = import ./react-native-config { };
    "react-native-dialogs" = import ./react-native-dialogs { };
    "react-native-firebase" = import ./react-native-firebase { };
    "react-native-fs" = import ./react-native-fs { };
    "react-native-http-bridge" = import ./react-native-http-bridge { };
    "react-native-image-resizer" = import ./react-native-image-resizer { };
    "react-native-keychain" = import ./react-native-keychain { };
    "react-native-securerandom" = import ./react-native-securerandom { };
    "react-native-status-keycard" = import ./react-native-status-keycard { };
    "react-native-svg" = import ./react-native-svg { };
    "react-native-webview" = import ./react-native-webview { };
    "react-native-webview-bridge" = import ./react-native-webview-bridge { };
    "realm" = import ./realm { };
  };

in stdenv.lib.mapAttrs makeFakeMavenRepo sources
