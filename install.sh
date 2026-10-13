#!/usr/bin/env bash
set -euo pipefail

plugin_source=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_id=io.github.manateelazycat.desktop-clock
config_root=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy
plugin_target=$config_root/plugins/$plugin_id
backup_root=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/desktop-clock/backups
enable_plugin=true
if [[ ${1:-} == --no-enable ]]; then
  enable_plugin=false
elif [[ $# -gt 0 ]]; then
  printf 'Usage: bash install.sh [--no-enable]\n' >&2
  exit 2
fi

omarchy plugin validate "$plugin_source"
install -d -m 700 -- "$backup_root"
if [[ -f $config_root/shell.json ]]; then
  (umask 077; cp -- "$config_root/shell.json" "$backup_root/shell-$(date +%Y%m%d-%H%M%S-%N).json")
fi
if [[ $(realpath -m -- "$plugin_source") != $(realpath -m -- "$plugin_target") ]]; then
  mkdir -p -- "$plugin_target"
  for file in manifest.json Service.qml hyprland.lua README.md README.zh-CN.md PERFORMANCE.md LICENSE; do
    install -m 644 -- "$plugin_source/$file" "$plugin_target/$file"
  done
  install -d -- "$plugin_target/renderer"
  for file in Worker.qml DesktopState.qml Visibility.js ClockController.qml ClockSurface.qml ClockFace.qml Position.js MinimizeMark.qml MinimizedTab.qml; do
    install -m 644 -- "$plugin_source/renderer/$file" "$plugin_target/renderer/$file"
  done
  install -d -- "$plugin_target/assets"
  install -m 644 -- "$plugin_source/assets/preview.png" "$plugin_target/assets/preview.png"
  # Remove the obsolete renderer files installed by 0.1.x.
  rm -f -- "$plugin_target/ClockSurface.qml" "$plugin_target/ClockFace.qml" "$plugin_target/Position.js"
fi

# This clock requires immediate layer geometry and no fading snapshots.
# Keep the rule in the plugin and add a guarded, idempotent Lua include.
hypr_config=${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua
if [[ -f $hypr_config ]]; then
  python3 - "$hypr_config" "$backup_root" <<'PY'
from datetime import datetime
from pathlib import Path
import os
import shutil
import sys
import tempfile

config = Path(sys.argv[1])
marker = '-- >>> omarchy-desktop-clock >>>'
text = config.read_text()
if marker not in text:
    backup = Path(sys.argv[2])
    # mkstemp creates an exclusive 0600 file before any config bytes are copied.
    # Keep backups private even when the source configuration is world-readable.
    fd, backup_path = tempfile.mkstemp(
        prefix='hyprland-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '-',
        suffix='.lua', dir=backup)
    try:
        with os.fdopen(fd, 'wb') as destination, config.open('rb') as source:
            shutil.copyfileobj(source, destination)
    except BaseException:
        Path(backup_path).unlink()
        raise
    config.write_text(text.rstrip() + '''

-- >>> omarchy-desktop-clock >>>
do
  local path = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
    .. "/omarchy/plugins/io.github.manateelazycat.desktop-clock/hyprland.lua"
  local file = io.open(path, "r")
  if file then file:close(); dofile(path) end
end
-- <<< omarchy-desktop-clock <<<
''')
PY
  hyprctl reload >/dev/null
  config_errors=$(hyprctl configerrors)
  if [[ -n ${config_errors//[[:space:]]/} ]]; then
    printf 'Hyprland config errors after loading clock rules:\n%s\n' "$config_errors" >&2
    exit 1
  fi
else
  printf 'Hyprland Lua config is required to install the clock animation rule.\n' >&2
  exit 1
fi
omarchy-shell shell rescanPlugins
# Discovery is asynchronous; wait for the manifest before asking the host to
# enable it. This also works on a busy shell during automatic hot-reload.
plugin_discovered=false
for attempt in {1..50}; do
  if omarchy plugin list --json | jq -e --arg id "$plugin_id" 'any(.[]; .id == $id)' >/dev/null; then
    plugin_discovered=true
    break
  fi
  sleep 0.1
done
if [[ $plugin_discovered != true ]]; then
  printf 'Plugin discovery timed out. Check that omarchy-shell is running.\n' >&2
  exit 1
fi
if [[ $enable_plugin == true ]]; then
  omarchy plugin enable "$plugin_id"
  printf 'Desktop Clock installed and enabled: %s\n' "$plugin_target"
else
  printf 'Desktop Clock installed; activation unchanged: %s\n' "$plugin_target"
fi
