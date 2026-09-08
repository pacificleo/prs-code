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

# Create a symlink named 'ghostty' pointing to 'supacode' in the MacOS executable folder.
# Ghostty's shell integrations hardcode "$GHOSTTY_BIN_DIR/ghostty" for features like ssh-cache.
# Without this symlink, the shell integrations fail to find the binary.
if [ -n "${EXECUTABLE_NAME:-}" ] && [ -n "${EXECUTABLE_FOLDER_PATH:-}" ]; then
  mkdir -p "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
  ln -sf "${EXECUTABLE_NAME}" "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/ghostty"
fi
