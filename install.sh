#!/bin/bash
# klipper-macos: run Klipper + Moonraker + Mainsail natively on macOS.
#
#   ./install.sh                 install everything and start the services
#   ./install.sh --no-services   install the files only: no launchd services,
#                                no klipper-mac command in your PATH
#
# Optional environment variables:
#   PREFIX=~           where klipper/, moonraker/, mainsail/ and the venvs go
#   DATA=~/printer_data
#   MOONRAKER_PORT=7125  MAINSAIL_PORT=7130
#   KLIPPER_REF / MOONRAKER_REF / MAINSAIL_VERSION   (default: the versions this was tested with)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME}"
DATA="${DATA:-$PREFIX/printer_data}"
MOONRAKER_PORT="${MOONRAKER_PORT:-7125}"
MAINSAIL_PORT="${MAINSAIL_PORT:-7130}"
LABEL="com.klipper-macos"

# Upstream versions the patches were tested with. Use "master" to try the latest.
KLIPPER_REF="${KLIPPER_REF:-461c4e3722c3a897fba1c6b3f0780a5315043842}"
MOONRAKER_REF="${MOONRAKER_REF:-9e676eba6b02661a4dfa3ec6e7ac3f3504498e6d}"
MAINSAIL_CONFIG_REF="${MAINSAIL_CONFIG_REF:-ff3869a621db17ce3ef660adbbd3fa321995ac42}"
MAINSAIL_VERSION="${MAINSAIL_VERSION:-v2.19.0}"

SERVICES=1
for arg in "$@"; do
  case "$arg" in
    --no-services) SERVICES=0 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- checks ---------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "this installer is for macOS only"
command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"
for sock in "$DATA/comms/klippy.sock" "$DATA/comms/moonraker.sock"; do
  # macOS limits Unix socket paths to 103 characters
  [ "${#sock}" -lt 104 ] || die "DATA path too long for a Unix socket on macOS: $sock (use a shorter DATA=...)"
done
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools are required: run  xcode-select --install"
if [ "$SERVICES" = 1 ]; then
  for port in "$MOONRAKER_PORT" "$MAINSAIL_PORT"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
       && ! launchctl print "gui/$UID/$LABEL.moonraker" >/dev/null 2>&1; then
      die "port $port is already in use. Pick another one, e.g. MOONRAKER_PORT=7126 MAINSAIL_PORT=7131 ./install.sh"
    fi
  done
fi

say "Homebrew packages: python@3.12, libsodium"
brew install --quiet python@3.12 libsodium
PY="$(brew --prefix python@3.12)/bin/python3.12"
[ -x "$PY" ] || die "python3.12 not found at $PY"

mkdir -p "$PREFIX"

# --- sources --------------------------------------------------------------
clone_at() { # url dir ref
  if [ -d "$2/.git" ]; then
    say "$(basename "$2"): already there, keeping the current checkout"
  else
    say "Downloading $(basename "$2")"
    git clone --quiet "$1" "$2"
    # stay on a named branch: Moonraker cannot detect its version on a detached HEAD
    git -C "$2" checkout --quiet -B "$(git -C "$2" rev-parse --abbrev-ref HEAD)" "$3"
  fi
}

apply_patch() { # repo patchfile
  local name; name="$(basename "$2")"
  if git -C "$1" apply --reverse --check "$2" 2>/dev/null; then
    say "$name: already applied"
  elif git -C "$1" apply --check "$2" 2>/dev/null; then
    git -C "$1" apply "$2"
    say "$name: applied"
  else
    die "$name does not apply to $1 (upstream changed). Use the tested versions: unset KLIPPER_REF / MOONRAKER_REF"
  fi
}

clone_at https://github.com/Klipper3d/klipper.git "$PREFIX/klipper" "$KLIPPER_REF"
clone_at https://github.com/Arksine/moonraker.git "$PREFIX/moonraker" "$MOONRAKER_REF"
clone_at https://github.com/mainsail-crew/mainsail-config.git "$PREFIX/mainsail-config" "$MAINSAIL_CONFIG_REF"
apply_patch "$PREFIX/klipper" "$HERE/patches/klipper-macos.patch"
apply_patch "$PREFIX/moonraker" "$HERE/patches/moonraker-macos.patch"

# --- python environments -------------------------------------------------
say "Python environment for Klipper"
[ -x "$PREFIX/klippy-env/bin/python" ] || "$PY" -m venv "$PREFIX/klippy-env"
"$PREFIX/klippy-env/bin/pip" install --quiet --upgrade pip
"$PREFIX/klippy-env/bin/pip" install --quiet -r "$PREFIX/klipper/scripts/klippy-requirements.txt"

say "Compiling Klipper's C helper"
build_log="$(mktemp)"
if ! (cd "$PREFIX/klipper/klippy" && "$PREFIX/klippy-env/bin/python" -c "import chelper; chelper.get_ffi()") >"$build_log" 2>&1; then
  tail -30 "$build_log"; die "the C helper did not compile (full log: $build_log)"
fi
rm -f "$build_log"

say "Python environment for Moonraker"
[ -x "$PREFIX/moonraker-env/bin/python" ] || "$PY" -m venv "$PREFIX/moonraker-env"
"$PREFIX/moonraker-env/bin/pip" install --quiet --upgrade pip
# run from scripts/ so the relative --find-links in the requirements file resolves
(cd "$PREFIX/moonraker/scripts" && "$PREFIX/moonraker-env/bin/pip" install --quiet -r moonraker-requirements.txt)

# --- mainsail -------------------------------------------------------------
if [ ! -f "$PREFIX/mainsail/index.html" ]; then
  say "Downloading Mainsail $MAINSAIL_VERSION"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/mainsail.zip" \
    "https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_VERSION/mainsail.zip"
  mkdir -p "$PREFIX/mainsail"
  unzip -q -o "$tmp/mainsail.zip" -d "$PREFIX/mainsail"
  rm -rf "$tmp"
fi
cat > "$PREFIX/mainsail/config.json" <<EOF
{
    "defaultMode": "dark",
    "hostname": null,
    "port": $MOONRAKER_PORT,
    "path": null,
    "instancesDB": "moonraker",
    "instances": []
}
EOF

# --- printer_data ---------------------------------------------------------
say "Data folder: $DATA"
mkdir -p "$DATA"/{config,logs,gcodes,comms,database,bin}

render() { # template destination
  sed -e "s|@DATA@|$DATA|g" -e "s|@LABEL@|$LABEL|g" \
      -e "s|@MOONRAKER_PORT@|$MOONRAKER_PORT|g" -e "s|@MAINSAIL_PORT@|$MAINSAIL_PORT|g" "$1" > "$2"
}

[ -e "$DATA/config/moonraker.conf" ] || render "$HERE/templates/moonraker.conf" "$DATA/config/moonraker.conf"
[ -e "$DATA/config/printer.cfg" ] || cp "$HERE/templates/printer.cfg" "$DATA/config/printer.cfg"
ln -sfn "$PREFIX/mainsail-config/client.cfg" "$DATA/config/mainsail.cfg"

cp "$HERE/bin/ip" "$HERE/bin/klipper-mac-helper.py" "$DATA/bin/"
render "$HERE/templates/klipper-mac" "$DATA/bin/klipper-mac"
chmod +x "$DATA/bin/ip" "$DATA/bin/klipper-mac-helper.py" "$DATA/bin/klipper-mac"

# --- launchd services -----------------------------------------------------
AGENTS="$HOME/Library/LaunchAgents"
SVC_PATH="$DATA/bin:$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"

write_plist() { # name program [args...]
  local name="$1"; shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$LABEL.$name</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo '  <key>EnvironmentVariables</key><dict>'
    echo "    <key>PATH</key><string>$SVC_PATH</string>"
    echo "    <key>MOONRAKER_URL</key><string>http://127.0.0.1:$MOONRAKER_PORT</string>"
    echo "    <key>GCODES_DIR</key><string>$DATA/gcodes</string>"
    echo '  </dict>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    # Interactive = macOS does not throttle it like a background job (Klipper is timing sensitive)
    echo '  <key>ProcessType</key><string>Interactive</string>'
    echo "  <key>StandardErrorPath</key><string>$DATA/logs/$name.err</string>"
    echo '</dict></plist>'
  } > "$AGENTS/$LABEL.$name.plist"
}

if [ "$SERVICES" = 1 ]; then
  say "Creating launchd services ($LABEL.*)"
  mkdir -p "$AGENTS"
  write_plist klipper "$PREFIX/klippy-env/bin/python" "$PREFIX/klipper/klippy/klippy.py" \
    "$DATA/config/printer.cfg" -I "$DATA/comms/klippy.serial" -a "$DATA/comms/klippy.sock" \
    -l "$DATA/logs/klippy.log"
  write_plist moonraker "$PREFIX/moonraker-env/bin/python" "$PREFIX/moonraker/moonraker/moonraker.py" \
    -d "$DATA" -l "$DATA/logs/moonraker.log"
  write_plist mainsail "$PY" -m http.server "$MAINSAIL_PORT" --bind 127.0.0.1 -d "$PREFIX/mainsail"
  write_plist helper "$PY" "$DATA/bin/klipper-mac-helper.py"
  for s in klipper moonraker mainsail helper; do
    launchctl bootout "gui/$UID/$LABEL.$s" 2>/dev/null || true
    # bootout is asynchronous: wait until the old instance is gone before loading the new one
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      launchctl print "gui/$UID/$LABEL.$s" >/dev/null 2>&1 || break
      sleep 0.5
    done
    launchctl bootstrap "gui/$UID" "$AGENTS/$LABEL.$s.plist" 2>/dev/null \
      || { sleep 2; launchctl bootstrap "gui/$UID" "$AGENTS/$LABEL.$s.plist"; } \
      || die "could not start $LABEL.$s"
  done
  ln -sf "$DATA/bin/klipper-mac" "$(brew --prefix)/bin/klipper-mac"
fi

cat <<EOF

Done.

  Web UI:        http://127.0.0.1:$MAINSAIL_PORT      (klipper-mac open)
  Printer config $DATA/config/printer.cfg
  G-code folder  $DATA/gcodes
  Control:       klipper-mac start | stop | restart | status | open | log

Next steps:
  1. Flash Klipper to your printer board (see README, "Flash the firmware").
  2. Put your printer config in printer.cfg (serial port: ls /dev/cu.*).
  3. klipper-mac restart
EOF
[ "$SERVICES" = 1 ] || warn "services not installed (--no-services): nothing was started"
