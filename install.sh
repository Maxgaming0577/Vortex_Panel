#!/bin/bash
# ============================================================
#  Vortex Panel — Interactive Installer
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()   { echo -e "${RED}[ERR]${RESET}   $*"; }
hdr()   { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}\n"; }

# ── Root check ──
if [ "$EUID" -ne 0 ]; then err "Run as root: sudo bash install.sh"; exit 1; fi

clear
echo -e "${BOLD}${CYAN}"
cat << 'LOGO'
 __   ____  ____  ____  ____  _  _ 
 \ \ / /  \/  _ \|  _ \|_  _|\ \/ /
  \ V /| |\/| | | | |_) | |   >  < 
   \_/ |_|  |_| |_|____/ |_|  /_/\_\
        PANEL  —  INSTALLER v1.0
LOGO
echo -e "${RESET}"

hdr "Step 1 — Owner Account Setup"
echo -e "These credentials will be used to log in as the panel owner.\n"

read -rp "  Owner username  : " OWNER_USER
while [[ -z "$OWNER_USER" ]]; do
  warn "Username cannot be empty."
  read -rp "  Owner username  : " OWNER_USER
done

read -rp "  Owner email     : " OWNER_EMAIL
while [[ -z "$OWNER_EMAIL" || ! "$OWNER_EMAIL" =~ @ ]]; do
  warn "Please enter a valid email address."
  read -rp "  Owner email     : " OWNER_EMAIL
done

while true; do
  read -rsp "  Owner password  : " OWNER_PASS; echo
  if [[ ${#OWNER_PASS} -lt 8 ]]; then warn "Password must be at least 8 characters."; continue; fi
  read -rsp "  Confirm password: " OWNER_PASS2; echo
  if [[ "$OWNER_PASS" != "$OWNER_PASS2" ]]; then warn "Passwords do not match."; continue; fi
  break
done

ok "Owner credentials saved."

hdr "Step 2 — Panel Configuration"

read -rp "  Panel port [default: 5000]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-5000}

read -rp "  Install dir [default: /opt/vortex]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/vortex}

hdr "Step 3 — System Dependencies"

info "Updating apt..."
apt-get update -qq
info "Installing system packages..."
apt-get install -y -qq python3 python3-pip git curl wget snapd iptables-persistent netfilter-persistent

info "Installing LXD via snap..."
snap install lxd 2>/dev/null || true
export PATH="$PATH:/snap/bin"

info "Enabling cgroup v2..."
if grep -q "systemd.unified_cgroup_hierarchy=1" /etc/default/grub 2>/dev/null; then
  ok "cgroup v2 already configured."
else
  sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
  update-grub 2>/dev/null || true
  warn "cgroup v2 configured — reboot required after install."
fi

info "Setting up IP forwarding..."
grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p -q

MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
iptables -t nat -C POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE
netfilter-persistent save -q 2>/dev/null || true

hdr "Step 4 — Installing Vortex Panel"

mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -r "$SCRIPT_DIR"/. "$INSTALL_DIR/"
cd "$INSTALL_DIR"

info "Installing Python dependencies..."
pip3 install -r requirements.txt --break-system-packages -q
pip3 install pymongo dnspython --break-system-packages -q

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(48))")

cat > "$INSTALL_DIR/.env" << ENV
PANEL_NAME=Vortex Panel
PANEL_VERSION=1.0
SECRET_KEY=${SECRET_KEY}
DATABASE_PATH=${INSTALL_DIR}/vortex.db
HOST=0.0.0.0
PORT=${PANEL_PORT}
MONGO_URI=mongodb+srv://maxgaming:maxgaming@cluster0.1v1jfsc.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0
OWNER_USERNAME=${OWNER_USER}
OWNER_EMAIL=${OWNER_EMAIL}
OWNER_PASSWORD=${OWNER_PASS}
DEBUG_MODE=False
ENV
chmod 600 "$INSTALL_DIR/.env"

info "Writing pre-configured owner credentials..."
python3 - << PYEOF
import sys, os
sys.path.insert(0, '$INSTALL_DIR')
os.chdir('$INSTALL_DIR')
os.environ.update({k.split('=')[0]: '='.join(k.split('=')[1:]) for k in open('.env').read().strip().splitlines() if '=' in k})

from werkzeug.security import generate_password_hash
import sqlite3, datetime, secrets, string

db_path = os.environ.get('DATABASE_PATH', 'vortex.db')
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row

# Run init_db-equivalent minimal setup
conn.executescript("""
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    is_admin INTEGER DEFAULT 0,
    is_main_admin INTEGER DEFAULT 0,
    created_at TEXT NOT NULL,
    last_login TEXT,
    api_key TEXT,
    preferences TEXT DEFAULT '{}',
    discord_id TEXT,
    discord_username TEXT,
    two_factor_enabled INTEGER DEFAULT 0,
    two_factor_secret TEXT,
    is_active INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS license (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    license_key TEXT UNIQUE NOT NULL,
    is_activated INTEGER DEFAULT 0,
    activated_at TEXT,
    activated_by TEXT,
    created_at TEXT NOT NULL
);
""")

username = '${OWNER_USER}'
email    = '${OWNER_EMAIL}'
password = '${OWNER_PASS}'
now      = datetime.datetime.now().isoformat()
pw_hash  = generate_password_hash(password)
api_key  = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(64))

cur = conn.cursor()
cur.execute('SELECT id FROM users WHERE is_main_admin=1 LIMIT 1')
row = cur.fetchone()
if row:
    cur.execute('UPDATE users SET username=?,email=?,password_hash=?,is_admin=1,is_main_admin=1 WHERE id=?',
                (username, email, pw_hash, row[0]))
else:
    cur.execute('''INSERT INTO users (username,email,password_hash,is_admin,is_main_admin,created_at,last_login,api_key,preferences)
                   VALUES (?,?,?,1,1,?,?,?,?)''',
                (username, email, pw_hash, now, now, api_key, '{}'))
conn.commit()
conn.close()
print('Owner account written to database.')
PYEOF

hdr "Step 5 — Systemd Service"

cat > /etc/systemd/system/vortex.service << SVC
[Unit]
Description=Vortex Panel
After=network.target snapd.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable vortex
systemctl start vortex

sleep 2
if systemctl is-active --quiet vortex; then
  ok "Vortex Panel service is running."
else
  warn "Service may need a moment to start. Check: journalctl -u vortex -n 30"
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

hdr "Installation Complete!"
echo -e "${GREEN}${BOLD}  Vortex Panel is installed and running.${RESET}\n"
echo -e "  URL        : ${CYAN}http://${SERVER_IP}:${PANEL_PORT}${RESET}"
echo -e "  Username   : ${BOLD}${OWNER_USER}${RESET}"
echo -e "  Email      : ${BOLD}${OWNER_EMAIL}${RESET}"
echo -e "  Password   : ${BOLD}(the one you entered)${RESET}\n"
echo -e "  ${YELLOW}NOTE: On first visit you will be asked to enter your license key.${RESET}"
echo -e "  ${YELLOW}Generate one with:  python3 ${INSTALL_DIR}/generate_license.py${RESET}\n"
if ! grep -q "cgroup2fs" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  echo -e "  ${RED}REBOOT REQUIRED for cgroup v2 (needed for accurate RAM limits).${RESET}"
  echo -e "  Run: ${BOLD}reboot${RESET}\n"
fi
