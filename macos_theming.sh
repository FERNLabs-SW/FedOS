#!/usr/bin/env bash
# macosify-fedora.sh
# Fedora GNOME → modern macOS-like environment
# - Reliable dock bounce on launch (GNOME 49 + Dash-to-Dock aware)
# - macOS-like GDM login theme (best effort, safe fallback)
# - Wayland trackpad scroll “weakened” (event drop + time-gated throttle), X11 imwheel
# - Night Light ≈25% that sticks (two-phase apply + daemon restart)
# - Inter + font aliases + smoothing (+ portal hardening)
# - iTerm2-like Terminal palette, JetBrains Mono Bold 13, 5px padding
# - Dynamic day/night wallpapers (auto-repair corrupt images), systemd day/night switcher
# - Quick Settings: GPU toggle (Intel vs NVIDIA offload), Caffeine, Audio device chooser, BT quick connect, GSConnect
# - Dash-to-Dock tuned, panel CSS polish, clipboard + spell infra

set -euo pipefail
IFS=$'\n\t'

LOG_PREFIX="[macosify]"
log(){ printf "%s %s\n" "$LOG_PREFIX" "$*"; }
ensure_dir(){ mkdir -p "$1"; }

# ---------------- Tunables ----------------
# Night Light: 25 feels gently warm; change to 20 or 30 to taste.
NIGHT_LIGHT_PERCENT=25   # 0..100
# Wayland scroll throttle: pass 1 of N events (3 = ~1/3 kept) + time minimum between scroll events.
SCROLL_THROTTLE_N=3
SCROLL_MIN_INTERVAL_MS=18
# Dock bounce
DOCK_BOUNCE_CYCLES=2
DOCK_BOUNCE_SCALE=1.24
DOCK_BOUNCE_DURATION=170
# Dock look
DOCK_ICON_SIZE=48
DOCK_OPACITY=0.22
DOCK_SHRINK=true
# UI look
WINDOW_RADIUS=14
PANEL_HEIGHT=28
# Terminal
TERMINAL_MONO_FONT="JetBrains Mono Bold 13"
TERMINAL_PADDING=5
TERMINAL_PROFILE_BG="#181A1F"
TERMINAL_PROFILE_FG="#E5E5E7"
TERMINAL_CURSOR_COLOR="#FFFFFF"
TERMINAL_PALETTE=(
  "#000000" "#FF3B30" "#34C759" "#FF9500"
  "#007AFF" "#AF52DE" "#5AC8FA" "#C7C7CC"
  "#3A3A3C" "#FF453A" "#30D158" "#FF9F0A"
  "#0A84FF" "#BF5AF2" "#64D2FF" "#FFFFFF"
)
# Dynamic wallpapers
DYNAMIC_WALLPAPER_DIR="$HOME/Pictures/DynamicWallpapers"
DAY_WALLPAPER="day.jpg"
NIGHT_WALLPAPER="night.jpg"
DAY_START_HOUR=7
NIGHT_START_HOUR=19
# GDM Theming
ENABLE_GDM_THEME=1

# ---------------- Env/paths ----------------
WORKDIR="/tmp/macosify_work"
BACKUP_DIR="$HOME/.macosify_backups_$(date +%s)"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
mkdir -p "$WORKDIR" "$BACKUP_DIR" "$EXT_DIR"
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true
sudo -v || true
IS_WAYLAND=0; [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && IS_WAYLAND=1

schema_exists(){ gsettings list-schemas | grep -qx "$1"; }
key_writable(){ gsettings writable "$1" "$2" >/dev/null 2>&1; }
gset_try(){ local s="$1" k="$2"; shift 2; schema_exists "$s" && key_writable "$s" "$k" && gsettings set "$s" "$k" "$@" >/dev/null 2>&1 || true; }

download_zipball(){ # repo -> dest
  local repo="$1" dest="$2" owner_repo base srcdir
  owner_repo="$(echo "$repo" | sed -E 's#https?://github.com/([^/]+/[^.]+)(\.git)?#\1#')"
  base="$(basename "$owner_repo")"
  for br in main master; do
    local url="https://github.com/$owner_repo/archive/refs/heads/$br.zip"
    log "ZIP fetch: $url"
    if curl -fsSL "$url" -o "$WORKDIR/$base-$br.zip"; then
      rm -rf "$dest"; unzip -q "$WORKDIR/$base-$br.zip" -d "$WORKDIR"
      srcdir="$WORKDIR/$base-$br"; [ -d "$srcdir" ] && mv "$srcdir" "$dest" && return 0
    fi
  done
  return 1
}
fetch_repo(){ local repo="$1" dest="$2"; rm -rf "$dest"; log "Clone: $repo -> $dest"
  if command -v git >/dev/null 2>&1 && git clone --depth 1 "$repo" "$dest" >/dev/null 2>&1; then return 0; fi
  log "git clone failed; trying ZIP fallback..."; download_zipball "$repo" "$dest"
}

# ---------------- Packages ----------------
log "Installing/updating needed packages..."
sudo dnf makecache --refresh -y || true
sudo dnf install -y \
  gcc make sassc glib2-devel unzip curl wget fontconfig \
  gnome-tweaks gnome-extensions-app \
  gnome-shell-extension-user-theme \
  gnome-shell-extension-appindicator \
  gnome-shell-extension-dash-to-dock \
  gnome-shell-extension-caffeine \
  gnome-shell-extension-sound-output-device-chooser \
  gnome-shell-extension-gsconnect \
  gnome-shell-extension-bluetooth-quick-connect \
  switcheroo-control \
  hunspell-en hunspell-en-US hunspell-en-GB enchant gspell \
  ibus ibus-libpinyin ibus-gtk3 ibus-gtk4 \
  python3 geoclue2 gnome-terminal \
  jetbrains-mono-fonts ibm-plex-mono-fonts ibm-plex-sans-fonts \
  copyq imagemagick \
  || true
sudo dnf install -y imwheel || true
sudo dnf install -y ibus-hunspell || true
sudo systemctl enable --now switcheroo-control || true

# ---------------- Fonts: Inter + aliases + smoothing + portal hardening ----------------
log "Installing Inter (repo or fallback) + fontconfig aliases/smoothing..."
install_inter(){
  local candidates=(inter-fonts inter-vf-fonts rsms-inter-fonts)
  for pkg in "${candidates[@]}"; do
    if sudo dnf install -y "$pkg" >/dev/null 2>&1; then log "Inter via package: $pkg"; return; fi
  done
  ensure_dir "$HOME/.local/share/fonts"
  if curl -fsSL -o "$WORKDIR/Inter.zip" "https://github.com/rsms/inter/releases/latest/download/Inter.zip"; then
    unzip -q -o "$WORKDIR/Inter.zip" -d "$WORKDIR/inter"
    find "$WORKDIR/inter" -type f -iname "*.ttf" -exec cp -f "{}" "$HOME/.local/share/fonts/" \; || true
  else
    curl -fsSL -o "$HOME/.local/share/fonts/InterVariable.ttf" \
      "https://github.com/rsms/inter/releases/latest/download/InterVariable.ttf" || true
    curl -fsSL -o "$HOME/.local/share/fonts/InterVariable-Italic.ttf" \
      "https://github.com/rsms/inter/releases/latest/download/InterVariable-Italic.ttf" || true
  fi
}
install_inter
ensure_dir "$HOME/.config/fontconfig/conf.d"
cat > "$HOME/.config/fontconfig/conf.d/62-sfpro-alias.conf" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias><family>SF Pro Display</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>SF Pro Text</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>SF Pro</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>San Francisco</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>Helvetica</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>Helvetica Neue</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>Arial</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>system-ui</family><prefer><family>Inter</family></prefer></alias>
  <alias><family>sans-serif</family><prefer><family>Inter</family></prefer></alias>
</fontconfig>
XML
cat > "$HOME/.config/fontconfig/conf.d/64-font-smoothing.conf" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
XML
rm -rf "$HOME/.cache/fontconfig" "$HOME/.fontconfig" 2>/dev/null || true
fc-cache -f -v || true
gsettings set org.gnome.desktop.interface font-name "Inter 11" || true
gsettings set org.gnome.desktop.interface document-font-name "Inter 11" || true
gsettings set org.gnome.desktop.interface monospace-font-name "$TERMINAL_MONO_FONT" || true
gsettings set org.gnome.desktop.interface text-scaling-factor 1.0 || true
systemctl --user restart xdg-desktop-portal xdg-desktop-portal-gtk || true

# ---------------- Themes & assets (WhiteSur) ----------------
GTK_REPO="https://github.com/vinceliuice/WhiteSur-gtk-theme.git"
ICON_REPO="https://github.com/vinceliuice/WhiteSur-icon-theme.git"
CURSOR_REPO="https://github.com/vinceliuice/WhiteSur-cursors.git"
WALLS_REPO="https://github.com/vinceliuice/WhiteSur-wallpapers.git"

log "Installing WhiteSur GTK/Shell, icons, cursors, wallpapers..."
GTK_DIR="$WORKDIR/WhiteSur-gtk-theme"; fetch_repo "$GTK_REPO" "$GTK_DIR" && (cd "$GTK_DIR" && ./install.sh || true)
ICON_DIR="$WORKDIR/WhiteSur-icon-theme"; fetch_repo "$ICON_REPO" "$ICON_DIR" && (cd "$ICON_DIR" && ./install.sh || true)
CUR_DIR="$WORKDIR/WhiteSur-cursors"; fetch_repo "$CURSOR_REPO" "$CUR_DIR" && (cd "$CUR_DIR" && ./install.sh || true)
for base in "$HOME/.icons" "$HOME/.local/share/icons" "/usr/share/icons"; do
  if [ -d "$base/WhiteSur-cursors/cursors" ]; then
    ( cd "$base/WhiteSur-cursors/cursors" && ln -sf left_ptr wait && ln -sf left_ptr progress && ln -sf left_ptr watch ) || true
  fi
done
WALL_DIR="$WORKDIR/WhiteSur-wallpapers"; fetch_repo "$WALLS_REPO" "$WALL_DIR" && { ensure_dir "$HOME/Pictures/Wallpapers"; cp -r "$WALL_DIR"/* "$HOME/Pictures/Wallpapers"/ || true; }

# ---------------- Dynamic wallpapers: validate/repair ----------------
ensure_dir "$DYNAMIC_WALLPAPER_DIR"
pick_wp(){ find "$HOME/Pictures/Wallpapers" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | shuf | head -n1; }
is_img_ok(){
  local f="$1"; [ -f "$f" ] || return 1
  if command -v magick >/dev/null 2>&1; then magick identify -quiet -ping "$f" >/dev/null 2>&1
  elif command -v identify >/dev/null 2>&1; then identify -quiet -ping "$f" >/dev/null 2>&1
  else [ -s "$f" ] && file -b --mime-type "$f" | grep -Eiq 'image/(jpeg|png)'; fi
}
DAYP="$DYNAMIC_WALLPAPER_DIR/$DAY_WALLPAPER"; NIGHTP="$DYNAMIC_WALLPAPER_DIR/$NIGHT_WALLPAPER"
if ! is_img_ok "$DAYP"; then src="$(pick_wp || true)"; [ -n "${src:-}" ] && cp -f "$src" "$DAYP" || true; fi
if ! is_img_ok "$NIGHTP"; then src2="$(pick_wp || true)"; [ -n "${src2:-}" ] && cp -f "$src2" "$NIGHTP" || cp -f "$DAYP" "$NIGHTP" || true; fi
# Set wallpaper immediately
if [ -f "$DAYP" ]; then
  URI="file://$DAYP"
  gset_try org.gnome.desktop.background picture-uri "'$URI'"
  gset_try org.gnome.desktop.background picture-uri-dark "'$URI'"
  gset_try org.gnome.desktop.background picture-options "'zoom'"
fi

# ---------------- Day/Night theme + wallpaper switcher (systemd) ----------------
log "Configuring day/night theme & wallpaper switcher..."
ensure_dir "$HOME/.local/bin"
cat > "$HOME/.local/bin/macos-daynight.py" <<'PY'
#!/usr/bin/env python3
import os, datetime, subprocess
DAY_H=int(os.environ.get("DAY_H","7")); NIGHT_H=int(os.environ.get("NIGHT_H","19"))
DAY_WP=os.environ.get("DAY_WP"); NIGHT_WP=os.environ.get("NIGHT_WP"); WP_DIR=os.environ.get("WP_DIR")
GTK_LIGHT="WhiteSur-Light"; GTK_DARK="WhiteSur-Dark"
now=datetime.datetime.now()
day=now.replace(hour=DAY_H,minute=0,second=0,microsecond=0)
night=now.replace(hour=NIGHT_H,minute=0,second=0,microsecond=0)
use_day = day<=now<night if NIGHT_H>DAY_H else not (night<=now<day)
def gset(s,k,v): subprocess.run(["gsettings","set",s,k,v],stderr=subprocess.DEVNULL)
if use_day:
  gset("org.gnome.desktop.interface","gtk-theme",f"'{GTK_LIGHT}'")
  gset("org.gnome.shell.extensions.user-theme","name",f"'{GTK_LIGHT}'")
  gset("org.gnome.desktop.interface","color-scheme","'prefer-light'")
  if WP_DIR and DAY_WP:
    p=os.path.join(WP_DIR,DAY_WP)
    if os.path.isfile(p):
      u=f"file://{p}"
      gset("org.gnome.desktop.background","picture-uri",f"'{u}'")
      gset("org.gnome.desktop.background","picture-uri-dark",f"'{u}'")
else:
  gset("org.gnome.desktop.interface","gtk-theme",f"'{GTK_DARK}'")
  gset("org.gnome.shell.extensions.user-theme","name",f"'{GTK_DARK}'")
  gset("org.gnome.desktop.interface","color-scheme","'prefer-dark'")
  if WP_DIR and NIGHT_WP:
    p=os.path.join(WP_DIR,NIGHT_WP)
    if os.path.isfile(p):
      u=f"file://{p}"
      gset("org.gnome.desktop.background","picture-uri",f"'{u}'")
      gset("org.gnome.desktop.background","picture-uri-dark",f"'{u}'")
PY
chmod +x "$HOME/.local/bin/macos-daynight.py"
ensure_dir "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/macos-daynight.service" <<EOF
[Unit]
Description=macOS-like day/night theme & wallpaper switcher
[Service]
Type=oneshot
Environment=DAY_H="$DAY_START_HOUR"
Environment=NIGHT_H="$NIGHT_START_HOUR"
Environment=DAY_WP="$DAY_WALLPAPER"
Environment=NIGHT_WP="$NIGHT_WALLPAPER"
Environment=WP_DIR="$DYNAMIC_WALLPAPER_DIR"
ExecStart=$HOME/.local/bin/macos-daynight.py
EOF
cat > "$HOME/.config/systemd/user/macos-daynight.timer" <<'EOF'
[Unit]
Description=Run day/night switch every 10 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
Unit=macos-daynight.service
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload || true
systemctl --user enable --now macos-daynight.timer || true

# ---------------- Night Light: enforce and make it stick ----------------
percent_to_temp(){ local p="$1"; [ "$p" -lt 0 ] && p=0; [ "$p" -gt 100 ] && p=100; local d=$((6500-2000)); echo $((6500 - (p*d)/100)); }
percent_to_frac(){ local p="$1"; [ "$p" -le 0 ] && { echo "0.00"; return; }; [ "$p" -ge 100 ] && { echo "1.00"; return; }; printf "0.%02d" "$p"; }
NL_TEMP="$(percent_to_temp "$NIGHT_LIGHT_PERCENT")"; NL_STRENGTH="$(percent_to_frac "$NIGHT_LIGHT_PERCENT")"
log "Applying Night Light ≈${NIGHT_LIGHT_PERCENT}% (temp ${NL_TEMP}K) and reasserting..."
gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true || true
# Force-active window to take effect immediately
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic false || true
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-from 0.0 || true
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-to 24.0 || true
gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature "$NL_TEMP" || true
if gsettings list-keys org.gnome.settings-daemon.plugins.color | grep -q night-light-strength; then
  gsettings set org.gnome.settings-daemon.plugins.color night-light-strength "$NL_STRENGTH" || true
fi
# Restart color daemon then restore automatic
systemctl --user restart org.gnome.SettingsDaemon.Color.service 2>/dev/null || true
sleep 1
gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true || true
# Reassert temperature if GNOME bumped it
CUR_TEMP="$(gsettings get org.gnome.settings-daemon.plugins.color night-light-temperature 2>/dev/null || echo 6500)"
if echo "$CUR_TEMP" | grep -q 6500; then gsettings set org.gnome.settings-daemon.plugins.color night-light-temperature "$NL_TEMP" || true; fi

# ---------------- Trackpad: weaker scrolling ----------------
log "Setting gentler trackpad & mouse..."
gset_try org.gnome.desktop.peripherals.touchpad speed 0.03
gset_try org.gnome.desktop.peripherals.touchpad tap-to-click true
gset_try org.gnome.desktop.peripherals.touchpad natural-scroll true
gset_try org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
gset_try org.gnome.desktop.peripherals.touchpad click-method "'fingers'"
gset_try org.gnome.desktop.peripherals.mouse speed 0.0
gset_try org.gnome.desktop.peripherals.mouse natural-scroll true

if [ $IS_WAYLAND -eq 1 ]; then
  log "Installing scroll-throttle extension (Wayland)..."
  ST_UUID="scroll-throttle@local.macosify"
  ST_DIR="$EXT_DIR/$ST_UUID"; rm -rf "$ST_DIR"; mkdir -p "$ST_DIR"
  cat > "$ST_DIR/metadata.json" <<JSON
{"uuid":"$ST_UUID","name":"Scroll Throttle","description":"Slow smooth scrolling by event drop + time gating","version":2,"shell-version":["49","50"],"url":"https://local.macosify"}
JSON
  cat > "$ST_DIR/extension.js" <<JS
'use strict';
const { Clutter, GLib } = imports.gi;
let handler = null;
let counter = 0;
const N = parseInt(GLib.getenv('SCROLL_THROTTLE_N') || '${SCROLL_THROTTLE_N}');
const MIN_MS = parseInt(GLib.getenv('SCROLL_MIN_INTERVAL_MS') || '${SCROLL_MIN_INTERVAL_MS}');
let lastTime = 0;
function enable() {
  const stage = global.stage;
  if (!stage) return;
  handler = stage.connect('event', (_actor, event) => {
    if (event.type() === Clutter.EventType.SCROLL) {
      const now = GLib.get_monotonic_time() / 1000; // microseconds→ms
      if (now - lastTime < MIN_MS) return Clutter.EVENT_STOP;
      counter = (counter + 1) % N;
      if (counter !== 0) return Clutter.EVENT_STOP;
      lastTime = now;
    }
    return Clutter.EVENT_PROPAGATE;
  });
}
function disable() {
  if (handler) { global.stage.disconnect(handler); handler = null; }
  counter = 0; lastTime = 0;
}
function init() {}
JS
  # Export throttle parameters into session
  for kv in "SCROLL_THROTTLE_N=${SCROLL_THROTTLE_N}" "SCROLL_MIN_INTERVAL_MS=${SCROLL_MIN_INTERVAL_MS}"; do
    grep -q "${kv%%=*}=" "$HOME/.profile" 2>/dev/null || echo "export $kv" >> "$HOME/.profile"
  done
  command -v gnome-extensions >/dev/null 2>&1 && gnome-extensions enable "$ST_UUID" >/dev/null 2>&1 || true
else
  log "Configuring imwheel (X11 gentle steps)..."
  cat > "$HOME/.imwheelrc" <<'IMW'
".*"
None,Up,Button4,1
None,Down,Button5,1
Shift_L,Up,Button4,1
Shift_L,Down,Button5,1
Control_L,Up,Button4,1
Control_L,Down,Button5,1
IMW
  ensure_dir "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/imwheel.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=imwheel
Exec=sh -c '[ "${XDG_SESSION_TYPE}" = "x11" ] && imwheel -b "4 5" -d'
X-GNOME-Autostart-enabled=true
DESK
fi

# ---------------- Dock bounce (robust) ----------------
log "Installing dock-bounce extension..."
DB_UUID="dock-bounce@local.macosify"
DB_DIR="$EXT_DIR/$DB_UUID"; rm -rf "$DB_DIR"; mkdir -p "$DB_DIR"
cat > "$DB_DIR/metadata.json" <<JSON
{"uuid":"$DB_UUID","name":"Dock Bounce","description":"mac-like double-bounce on app launch","version":5,"shell-version":["49","50"],"url":"https://local.macosify"}
JSON
cat > "$DB_DIR/extension.js" <<JS
'use strict';
const { Clutter, GLib } = imports.gi;
const Shell = imports.gi.Shell;
const Main = imports.ui.main;

let signals = [];
let bouncing = new WeakSet();
const SCALE = ${DOCK_BOUNCE_SCALE};
const DURATION = ${DOCK_BOUNCE_DURATION};
const CYCLES = ${DOCK_BOUNCE_CYCLES};

function oneBounce(actor, done) {
  actor.set_scale(1.0, 1.0);
  actor.ease({
    scale_x: SCALE, scale_y: SCALE, duration: DURATION,
    mode: Clutter.AnimationMode.EASE_OUT_BACK,
    onComplete: () => actor.ease({
      scale_x: 1.0, scale_y: 1.0, duration: DURATION,
      mode: Clutter.AnimationMode.EASE_OUT_BACK,
      onComplete: done,
    }),
  });
}
function doBounces(actor) {
  if (!actor || bouncing.has(actor)) return;
  bouncing.add(actor);
  let i = 0;
  const next = () => {
    i++; if (i < CYCLES) oneBounce(actor, next); else bouncing.delete(actor);
  };
  oneBounce(actor, next);
}
function findIconForApp(app) {
  for (const ext of Main.extensionManager._extensions.values()) {
    const dock = ext?.stateObj?.dock;
    const icons = dock?._appIcons;
    if (icons && Array.isArray(icons)) {
      for (const icon of icons) {
        if (icon.app === app) return icon.iconActor || icon.actor || icon;
      }
    }
  }
  const dash = Main.overview?.dash;
  const list = dash?._appIcons;
  if (list && Array.isArray(list)) {
    for (const icon of list) {
      if (icon.app === app) return icon.iconActor || icon.actor || icon;
    }
  }
  return null;
}
function enable() {
  const appSys = Shell.AppSystem.get_default();
  signals.push(appSys.connect('app-state-changed', (_sys, app) => {
    if (app.state === Shell.AppState.STARTING) {
      let actor = findIconForApp(app);
      if (actor) doBounces(actor);
      // Retry shortly after to catch icon appearance lag
      GLib.timeout_add(GLib.PRIORITY_DEFAULT, 120, () => {
        actor = findIconForApp(app); if (actor) doBounces(actor); return GLib.SOURCE_REMOVE;
      });
    }
  }));
}
function disable() {
  const appSys = Shell.AppSystem.get_default();
  signals.forEach(s => appSys.disconnect(s));
  signals = [];
}
function init() {}
JS
command -v gnome-extensions >/dev/null 2>&1 && gnome-extensions enable "$DB_UUID" >/dev/null 2>&1 || true

# ---------------- Dash-to-Dock and Quick Settings tiles ----------------
log "Configuring Dash-to-Dock and tiles..."
if command -v gnome-extensions >/dev/null 2>&1; then
  gnome-extensions enable dash-to-dock@micxgx.gmail.com >/dev/null 2>&1 || true
  gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com >/dev/null 2>&1 || true
  gnome-extensions enable user-theme@gnome-shell-extensions.gcampax.github.com >/dev/null 2>&1 || true
  gnome-extensions enable caffeine@patapon.info >/dev/null 2>&1 || true
  gnome-extensions enable sound-output-device-chooser@kgshank.net >/dev/null 2>&1 || true
  gnome-extensions enable gsconnect@andyholmes.github.io >/dev/null 2>&1 || true
  gnome-extensions enable bluetooth-quick-connect@bjarosze.gmail.com >/dev/null 2>&1 || true
fi
gset_try org.gnome.shell.extensions.dash-to-dock dock-position "'BOTTOM'"
gset_try org.gnome.shell.extensions.dash-to-dock dash-max-icon-size "$DOCK_ICON_SIZE"
gset_try org.gnome.shell.extensions.dash-to-dock dock-fixed true
gset_try org.gnome.shell.extensions.dash-to-dock autohide false
gset_try org.gnome.shell.extensions.dash-to-dock intellihide false
gset_try org.gnome.shell.extensions.dash-to-dock show-trash true
gset_try org.gnome.shell.extensions.dash-to-dock show-mounts false
gset_try org.gnome.shell.extensions.dash-to-dock background-opacity "$DOCK_OPACITY"
gset_try org.gnome.shell.extensions.dash-to-dock transparency-mode "'FIXED'"
gset_try org.gnome.shell.extensions.dash-to-dock apply-custom-theme true
$DOCK_SHRINK && gset_try org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true || true

# ---------------- Quick Settings GPU toggle (Intel vs NVIDIA offload) ----------------
log "Installing Quick Settings GPU toggle..."
GPU_UUID="gpu-switch@local.macosify"
GPU_DIR="$EXT_DIR/$GPU_UUID"; rm -rf "$GPU_DIR"; mkdir -p "$GPU_DIR"
cat > "$GPU_DIR/metadata.json" <<'JSON'
{"uuid":"gpu-switch@local.macosify","name":"Hybrid GPU Switch","description":"Toggle Intel default vs NVIDIA offload (logout to apply)","version":2,"shell-version":["49","50"],"url":"https://local.macosify"}
JSON
cat > "$GPU_DIR/extension.js" <<'JS'
'use strict';
const { Gio, GLib } = imports.gi;
const Main = imports.ui.main;
const QuickSettings = imports.ui.quickSettings;
let indicator, tile;
const ENV_DIR = GLib.build_filenamev([GLib.get_home_dir(), '.config', 'environment.d']);
const ENV_FILE = GLib.build_filenamev([ENV_DIR, '50-nvidia-offload.conf']);
function exists(p){ return GLib.file_test(p, GLib.FileTest.EXISTS); }
function readOn(){
  if (!exists(ENV_FILE)) return false;
  try { let [ok, buf] = GLib.file_get_contents(ENV_FILE); if (!ok) return false;
        let t = imports.byteArray.toString(buf); return /__NV_PRIME_RENDER_OFFLOAD=1/.test(t); } catch(e){ return false; }
}
function writeOn(on){
  GLib.mkdir_with_parents(ENV_DIR, 0o755);
  if (on){
    const data = '__NV_PRIME_RENDER_OFFLOAD=1\n__GLX_VENDOR_LIBRARY_NAME=nvidia\n__VK_LAYER_NV_optimus=NVIDIA_only\n';
    GLib.file_set_contents(ENV_FILE, data);
  } else if (exists(ENV_FILE)) GLib.unlink(ENV_FILE);
}
class GpuTile extends QuickSettings.QuickMenuToggle {
  constructor(){
    super({ title: 'Hybrid GPU', subtitle: 'Intel', iconName: 'video-display-symbolic', toggleMode: true });
    this.connect('clicked', () => this._toggle());
    this._sync();
  }
  _toggle(){
    writeOn(!this.checked);
    this._sync();
    Main.notify('Hybrid GPU', this.checked ? 'NVIDIA offload default set. Log out/in to apply.' : 'Intel-only default set. Log out/in to apply.');
  }
  _sync(){
    const on = readOn();
    this.checked = on; this.subtitle = on ? 'NVIDIA (default)' : 'Intel';
  }
}
function enable(){ indicator = new QuickSettings.SystemIndicator(); tile = new GpuTile(); indicator.quickSettingsItems.push(tile); Main.panel.addToQuickSettings(indicator); }
function disable(){ if (indicator){ indicator.destroy(); indicator=null; tile=null; } }
function init(){}
JS
command -v gnome-extensions >/dev/null 2>&1 && gnome-extensions enable "$GPU_UUID" >/dev/null 2>&1 || true

# ---------------- Apply interface/ICON/cursor, CSS polish ----------------
gset_try org.gnome.desktop.interface gtk-theme "'WhiteSur-Light'"
gset_try org.gnome.desktop.interface icon-theme "'WhiteSur'"
gset_try org.gnome.desktop.interface cursor-theme "'WhiteSur-cursors'"
gset_try org.gnome.desktop.interface cursor-size 24
gset_try org.gnome.shell.extensions.user-theme name "'WhiteSur-Light'"
gset_try org.gnome.desktop.wm.preferences button-layout "'close,minimize,maximize:'"
gset_try org.gnome.mutter center-new-windows true
gset_try org.gnome.desktop.interface color-scheme "'prefer-light'"

THEME_DIR="$HOME/.themes/WhiteSur-Light"
if [ -d "$THEME_DIR/gnome-shell/gnome-shell.css" ]; then
  cp -a "$THEME_DIR/gnome-shell/gnome-shell.css" "$BACKUP_DIR/gnome-shell.css.bak" || true
  cat >> "$THEME_DIR/gnome-shell/gnome-shell.css" <<EOF

/* macosify panel + dock */
.panel { background-color: rgba(32,32,32,0.50) !important; backdrop-filter: blur(18px);
  height: ${PANEL_HEIGHT}px; border: none !important; box-shadow: 0 2px 8px rgba(0,0,0,0.35); }
.panel .panel-button { border-radius: 8px !important; padding: 0 6px !important; transition: background-color 160ms ease; }
.panel .panel-button:hover { background-color: rgba(255,255,255,0.12) !important; }
#dash, .dock { background-color: rgba(24,24,24,0.45) !important; backdrop-filter: blur(16px);
  border-radius: 18px !important; padding: 4px 8px !important; margin-bottom: 6px !important; }
EOF
fi

# ---------------- Terminal polish ----------------
ensure_dir "$HOME/.config/gtk-4.0" "$HOME/.config/gtk-3.0"
cat > "$HOME/.config/gtk-4.0/gtk.css" <<EOF
.vte-terminal, .terminal-screen { padding: ${TERMINAL_PADDING}px ${TERMINAL_PADDING}px !important; }
window, .background, decoration, .dialog { border-radius: ${WINDOW_RADIUS}px !important; }
EOF
cat > "$HOME/.config/gtk-3.0/gtk.css" <<EOF
.vte-terminal, .terminal-screen { padding: ${TERMINAL_PADDING}px ${TERMINAL_PADDING}px !important; }
.window, .background, decoration, .dialog { border-radius: ${WINDOW_RADIUS}px !important; }
EOF
PROFILES=$(dconf list /org/gnome/terminal/legacy/profiles:/ | tr -d '/')
if [ -z "$PROFILES" ]; then (gnome-terminal --hide-menubar &>/dev/null &) || true; sleep 2; PROFILES=$(dconf list /org/gnome/terminal/legacy/profiles:/ | tr -d '/'); fi
PALETTE_STR="["; for i in "${!TERMINAL_PALETTE[@]}"; do PALETTE_STR="${PALETTE_STR}'${TERMINAL_PALETTE[$i]}'"; [ "$i" -lt $((${#TERMINAL_PALETTE[@]}-1)) ] && PALETTE_STR="${PALETTE_STR}, "; done; PALETTE_STR="${PALETTE_STR}]"
for p in $PROFILES; do
  base="/org/gnome/terminal/legacy/profiles:/:$p"
  dconf write "$base/use-system-font" "false"
  dconf write "$base/font" "'$TERMINAL_MONO_FONT'"
  dconf write "$base/use-theme-colors" "false"
  dconf write "$base/background-color" "'$TERMINAL_PROFILE_BG'"
  dconf write "$base/foreground-color" "'$TERMINAL_PROFILE_FG'"
  dconf write "$base/palette" "$PALETTE_STR"
  dconf write "$base/bold-color-same-as-fg" "true"
  dconf write "$base/cursor-colors-set" "true"
  dconf write "$base/cursor-background-color" "'$TERMINAL_CURSOR_COLOR'"
  dconf write "$base/cursor-foreground-color" "'$TERMINAL_PROFILE_BG'"
  dconf write "$base/scrollback-unlimited" "true"
  dconf write "$base/audible-bell" "false"
  dconf write "$base/login-shell" "true"
  dconf write "$base/scrollbar-policy" "'never'"
done

# ---------------- macOS-like GDM (safe best effort) ----------------
attempt_whitesur_gdm() {
  local GTK_DIR="$WORKDIR/WhiteSur-gtk-theme"
  [ -d "$GTK_DIR" ] || return 1
  (cd "$GTK_DIR" && sudo ./install.sh --gdm >/dev/null 2>&1) && return 0
  (cd "$GTK_DIR" && sudo ./install.sh -g   >/dev/null 2>&1) && return 0
  [ -x "$GTK_DIR/tools/install.sh" ] && (cd "$GTK_DIR/tools" && sudo ./install.sh --gdm >/dev/null 2>&1) && return 0
  return 1
}
attempt_gdmtools_set() {
  if command -v gdm-tools >/dev/null 2>&1; then sudo gdm-tools set -s WhiteSur-Light >/dev/null 2>&1 && return 0; fi
  local UBASE="$(python3 -m site --user-base 2>/dev/null || echo "$HOME/.local")"
  local GDMTOOL="$UBASE/bin/gdm-tools"
  [ -x "$GDMTOOL" ] && sudo "$GDMTOOL" set -s WhiteSur-Light >/dev/null 2>&1 && return 0
  return 1
}
if [ "$ENABLE_GDM_THEME" -eq 1 ]; then
  log "Applying macOS-like GDM theme (best effort)..."
  python3 -m pip install --user --upgrade gdm-tools >/dev/null 2>&1 || true
  attempt_whitesur_gdm || attempt_gdmtools_set || log "GDM theming skipped (no supported method found)."
else
  log "Skipping GDM theming (disabled)."
fi

# ---------------- Favorites ----------------
CANDS=(org.gnome.Nautilus.desktop firefox.desktop org.gnome.Terminal.desktop org.gnome.Settings.desktop org.gnome.Software.desktop)
ACTUAL=(); for f in "${CANDS[@]}"; do [ -f "/usr/share/applications/$f" ] || [ -f "$HOME/.local/share/applications/$f" ] && ACTUAL+=("$f"); done
if [ "${#ACTUAL[@]}" -gt 0 ]; then
  fav="["; for i in "${!ACTUAL[@]}"; do fav="${fav}'${ACTUAL[$i]}'"; [ "$i" -lt $((${#ACTUAL[@]}-1)) ] && fav="${fav}, "; done; fav="${fav}]"
  gset_try org.gnome.shell favorite-apps "$fav"
fi

# ---------------- Summary ----------------
cat <<EOF

$LOG_PREFIX Applied:
- Dock: double-bounce on app launch (GNOME 49 + Dash-to-Dock aware)
- Login Screen: macOS-like theme (best effort, safe), reboot recommended to see it
- Trackpad: weaker scrolling (Wayland throttle N=${SCROLL_THROTTLE_N}, min ${SCROLL_MIN_INTERVAL_MS}ms); X11 imwheel
- Night Light: ~${NIGHT_LIGHT_PERCENT}% (temperature ${NL_TEMP}K) with reassert
- Terminal: JetBrains Mono Bold 13, iTerm2 palette, padding ${TERMINAL_PADDING}px
- Inter + font aliases/smoothing; portals restarted to avoid font cache crashes
- Dynamic day/night wallpapers with auto-repair; day/night timer enabled (10m cadence)
- Quick Settings: GPU toggle, Caffeine, Audio chooser, BT quick connect, GSConnect
- Dash-to-Dock polished; panel CSS; favorites updated

Notes:
- Adjust throttle: edit SCROLL_THROTTLE_N or SCROLL_MIN_INTERVAL_MS at the top and rerun.
- Adjust Night Light: edit NIGHT_LIGHT_PERCENT (e.g., 20 or 30) and rerun.
- For GDM visuals, reboot once.
EOF

# Reboot countdown
COUNTDOWN=10; echo -n "$LOG_PREFIX Reboot in $COUNTDOWN sec (Ctrl+C to cancel)... "
while [ $COUNTDOWN -gt 0 ]; do echo -n "$COUNTDOWN "; sleep 1; COUNTDOWN=$((COUNTDOWN-1)); done
echo; systemctl reboot
