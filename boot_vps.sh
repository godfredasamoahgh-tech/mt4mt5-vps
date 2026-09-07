#!/usr/bin/env bash
# MT4+MT5 self-healing VPS — one boot = fresh install + user state overlay + GUI up + tunnel
# Design: fresh binary install every boot (nothing to corrupt) + state overlay from git.
set -u
export DEBIAN_FRONTEND=noninteractive

echo "[vps] 1/8 deps"
sudo dpkg --add-architecture i386
sudo apt-get update -qq
sudo apt-get install -y -qq wine64 wine32:i386 xvfb x11vnc novnc websockify jq >/dev/null 2>&1

echo "[vps] 2/8 display + wine prefix (fresh)"
export DISPLAY=:99
export WINEPREFIX="$HOME/.wine"
export WINEARCH=win64
export WINEDEBUG=-all
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null
Xvfb :99 -screen 0 1280x800x24 -ac &
sleep 2
wineboot --init >/dev/null 2>&1
sleep 5

echo "[vps] 3/8 fresh MT4 install"
wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt4/mt4setup.exe" -O /tmp/mt4setup.exe
# installers may open a GUI wizard (no reliable /auto) — cap at 150s; if it doesn't finish,
# check if terminal.exe landed anyway; else extract via portable zip fallback (below)
timeout 150 wine /tmp/mt4setup.exe /auto >/dev/null 2>&1 || true
pkill -f mt4setup.exe 2>/dev/null || true
sleep 3

echo "[vps] 4/8 fresh MT5 install"
wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" -O /tmp/mt5setup.exe
timeout 150 wine /tmp/mt5setup.exe /auto >/dev/null 2>&1 || true
pkill -f mt5setup.exe 2>/dev/null || true
sleep 3

# PORTABLE FALLBACK: if installers didn't produce terminals, use MetaQuotes' portable zips
MT4DIR="$WINEPREFIX/drive_c/Program Files (x86)/MetaTrader 4"
MT5DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
if [ ! -f "$MT4DIR/terminal.exe" ]; then
  echo "[vps] MT4 installer failed → portable zip"
  wget -q "https://files.metaquotes.net/metaquotes.software.corp/mt4/mt4.zip" -O /tmp/mt4.zip || true
  if [ -s /tmp/mt4.zip ]; then mkdir -p "$MT4DIR" && cd "$MT4DIR" && unzip -oq /tmp/mt4.zip; cd - >/dev/null; fi
fi
if [ ! -f "$MT5DIR/terminal64.exe" ]; then
  echo "[vps] MT5 installer failed → portable zip"
  wget -q "https://files.metaquotes.net/metaquotes.software.corp/mt5/mt5.zip" -O /tmp/mt5.zip || true
  if [ -s /tmp/mt5.zip ]; then mkdir -p "$MT5DIR" && cd "$MT5DIR" && unzip -oq /tmp/mt5.zip; cd - >/dev/null; fi
fi

echo "[vps] 5/8 overlay user state (EAs, charts, logins) from git"
# vps-state mirrors INTO the wine prefix: vps-state/mt4/... → MT4 dir, vps-state/mt5/... → MT5 dir
mkdir -p "$MT4DIR" "$MT5DIR" "$HOME/vps-state"
python3 vps_state.py restore
if [ -d "$HOME/vps-state/mt4" ]; then
  cp -r "$HOME/vps-state/mt4/." "$MT4DIR/" 2>/dev/null || true
fi
if [ -d "$HOME/vps-state/mt5" ]; then
  cp -r "$HOME/vps-state/mt5/." "$MT5DIR/" 2>/dev/null || true
fi
# force autotrading ON + no first-run wizard
mkdir -p "$MT4DIR/config" "$MT5DIR/config"
grep -q "AutoTrading" "$MT4DIR/config/common.ini" 2>/dev/null || echo "AutoTrading=true" >> "$MT4DIR/config/common.ini"
grep -q "AutoTrading" "$MT5DIR/config/common.ini" 2>/dev/null || echo "AutoTrading=true" >> "$MT5DIR/config/common.ini"

echo "[vps] 6/8 launch terminals"
cd "$MT4DIR" && nohup wine terminal.exe /portable >/dev/null 2>&1 &
sleep 12
cd "$MT5DIR" && nohup wine terminal64.exe /portable >/dev/null 2>&1 &
sleep 12

echo "[vps] 7/8 GUI: VNC + noVNC + password"
DISPLAY=:99 x11vnc -display :99 -passwd "$VNC_PASSWORD" -forever -shared -xkb -rfbport 5999 -bg -o /tmp/x11vnc.log
websockify --web /usr/share/novnc 8080 localhost:5999 >/dev/null 2>&1 &
sleep 2

echo "[vps] 8/8 tunnel"
wget -q -O /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
chmod +x /tmp/cloudflared
nohup /tmp/cloudflared tunnel --url http://localhost:8080 --no-autoupdate > "$HOME/tunnel.log" 2>&1 &
sleep 8
VPS_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$HOME/tunnel.log" | head -1)
echo "[vps] URL: ${VPS_URL:-not-yet}/vnc.html  (password: from VNC_PASSWORD secret)"

# health receipt
{
  echo "=== $(date -u +%FT%TZ) boot receipt ==="
  for p in terminal.exe terminal64.exe Xvfb x11vnc websockify cloudflared; do
    pgrep -f "$p" >/dev/null && echo "OK  $p" || echo "DEAD $p"
  done
  echo "URL: ${VPS_URL:-none}"
} > "$HOME/vps-state/boot_receipt.txt" 2>&1
mkdir -p "$HOME/vps-state"
cat "$HOME/vps-state/boot_receipt.txt"

echo "[vps] boot complete — window: ${RUN_MINUTES:-267}m"
timeout "${RUN_MINUTES:-267}m" sleep infinity &
WATCH=$!
# state pusher in background
python3 vps_state.py push &
PUSHER=$!
# keepalive loop: if a terminal dies mid-shift, relaunch it (self-healing)
while kill -0 $WATCH 2>/dev/null; do
  pgrep -f "MetaTrader 4/terminal.exe" >/dev/null || (cd "$MT4DIR" && nohup wine terminal.exe /portable >/dev/null 2>&1 & echo "[heal] MT4 relaunched $(date -u +%T)")
  pgrep -f "MetaTrader 5/terminal64.exe" >/dev/null || (cd "$MT5DIR" && nohup wine terminal64.exe /portable >/dev/null 2>&1 & echo "[heal] MT5 relaunched $(date -u +%T)")
  sleep 60
done
wait $WATCH
