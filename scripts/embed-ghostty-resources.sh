#!/usr/bin/env bash
set -euo pipefail

destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
ghostty_source="${SRCROOT}/.build/ghostty/share/ghostty"
terminfo_source="${SRCROOT}/.build/ghostty/share/terminfo"
ghostty_destination="${destination_root}/ghostty"
terminfo_destination="${destination_root}/terminfo"

rm -rf "${ghostty_destination}" "${terminfo_destination}"
mkdir -p "${ghostty_destination}" "${terminfo_destination}"
rsync -a --delete "${ghostty_source}/" "${ghostty_destination}/"
rsync -a --delete "${terminfo_source}/" "${terminfo_destination}/"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install ghostty CLI shim in the MacOS executable folder for shell integrations.
# Ghostty shell integrations call "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache to manage
# the remote terminfo cache. Symlinking 'ghostty' to 'supacode' (the GUI app) was
# harmful because invoking 'ghostty' launched a whole new GUI instance of Supacode.
if [ -n "${EXECUTABLE_FOLDER_PATH:-}" ]; then
  mkdir -p "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
  clang -O2 -Wall -Wextra -Werror "${script_dir}/ghostty-shim.c" -o "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/ghostty"
fi

