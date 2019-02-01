#!/usr/bin/env bash

function download_url() {
  if program_exists "aria2c"; then
    aria2c --max-connection-per-server=16 --split=16 --dir="$1" -o "$2" "$3"
  else
    wget --show-progress --output-document="$1/$2" "$3"
  fi
}

function install_nix() {
  if ! program_exists nix; then
    touch -a "${HOME}/.bash_profile"

    local required_version=$(toolversion nix)
    bash <(curl https://nixos.org/releases/nix/nix-${required_version}/install) --no-daemon
    if [ $? -eq 0 ]; then
      echo -e "${YELLOW}**********************************************************************************************************"
      echo "The Nix package manager was successfully installed. Please enter the following commands into the terminal:"
      echo "  - . ~/.nix-profile/etc/profile.d/nix.sh"
      echo "  - make shell"
      echo "If this doesn't work, you might have to sign out and back in, in order for the environment to be reloaded."
      echo -e "**********************************************************************************************************${NC}"

      if is_linux && [ -f ~/.bashrc ]; then
        # For some reason, new terminals are not started as login shells, so .profile and .bash_profile are not sourced.
        # To get around it, we add Nix initialization to .bashrc as well, if it exists
        echo "if [ -e ${HOME}/.nix-profile/etc/profile.d/nix.sh ]; then . ${HOME}/.nix-profile/etc/profile.d/nix.sh; fi # added by `make setup` Status script" > ~/.bashrc
      fi
    else
      echo "Please see https://nixos.org/nix/manual/#chap-installation"
    fi
    exit
  fi
}

function install_nsis() {
  # NSIS (Nullsoft Scriptable Install System) is a professional open source system to create Windows installers. It is designed to be as small and flexible as possible and is therefore very suitable for internet distribution.
  linux_install nsis
}

function install_android_sdk() {
  if [ -d "$ANDROID_SDK_ROOT" ]; then
    cecho "@green[[Android SDK already installed.]]"
  else
    local required_version=$(toolversion android-sdk)
    mkdir -p $ANDROID_SDK_ROOT
    cecho "@cyan[[Downloading Android SDK.]]"

    local PLATFORM=$(echo "$OS" | tr '[:upper:]' '[:lower:]')
    download_url . sdk-tools-${PLATFORM}.zip https://dl.google.com/android/repository/sdk-tools-${PLATFORM}-${required_version}.zip && \
      cecho "@cyan[[Extracting Android SDK to $ANDROID_SDK_ROOT.]]" && \
      unzip -q -o ./sdk-tools-${PLATFORM}.zip -d "$ANDROID_SDK_ROOT" && \
      rm -f ./sdk-tools-${PLATFORM}.zip && \
      cecho "@blue[[Android SDK installation completed in $ANDROID_SDK_ROOT.]]" || \
      exit $?
  fi

  [ $? -eq 0 ] && use_android_sdk

  return 0
}

function dependency_setup() {
  cecho "@b@blue[[\$ $@]]"
  echo

  cd "$(repo_path)"
  eval "$@" || (cecho "@b@red[[Error running dependency install '$@']]" && exit 1)

  echo
  echo "  + done"
  echo
}

function use_android_sdk() {
  if [ -d "$ANDROID_SDK_ROOT" ]; then
    local ANDROID_BUILD_TOOLS_VERSION=$(toolversion android-sdk-build-tools)
    local ANDROID_PLATFORM_VERSION=$(toolversion android-sdk-platform)
    touch ~/.android/repositories.cfg
    echo y | sdkmanager "platform-tools" "build-tools;$ANDROID_BUILD_TOOLS_VERSION" "platforms;$ANDROID_PLATFORM_VERSION"
    yes | sdkmanager --licenses
  else
    local _docUrl="https://status.im/build_status/"
    cecho "@yellow[[ANDROID_SDK_ROOT environment variable not defined, please install the Android SDK.]]"
    cecho "@yellow[[(see $_docUrl).]]"

    echo

    exit 1
  fi

  scripts/generate-keystore.sh
}

function install_android_ndk() {
  if [ -d "$ANDROID_NDK_ROOT" ]; then
    cecho "@green[[Android NDK already installed.]]"
  else
    local ANDROID_NDK_VERSION=$(toolversion android-ndk)
    local _ndkParentDir=$(dirname $ANDROID_NDK_ROOT)
    mkdir -p $_ndkParentDir
    cecho "@cyan[[Downloading Android NDK.]]"

    local PLATFORM=$(echo "$OS" | tr '[:upper:]' '[:lower:]')

    download_url . android-ndk.zip https://dl.google.com/android/repository/android-ndk-$ANDROID_NDK_VERSION-$PLATFORM-x86_64.zip && \
      cecho "@cyan[[Extracting Android NDK to $_ndkParentDir.]]" && \
      unzip -q -o ./android-ndk.zip -d "$_ndkParentDir" && \
      rm -f ./android-ndk.zip && \
      _ndkTargetDir="$_ndkParentDir/$(ls $_ndkParentDir | grep ndk)" && \
      cecho "@blue[[Android NDK installation completed in $_ndkTargetDir.]]"
  fi
}
