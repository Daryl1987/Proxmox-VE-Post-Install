#!/usr/bin/env bash
# Proxmox VE 9.x Post-Install Script (Debian 13 Trixie / deb822 format)

set -euo pipefail

# Colors for terminal output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

prompt_yes_no() {
    local prompt="$1"
    local reply
    read -r -p "$prompt [Y/n]: " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
}

# 1. Pre-flight checks
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
fi

if ! command -v pveversion >/dev/null 2>&1; then
    error "Proxmox VE is not installed on this system."
fi

PVE_VER=$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')
if [[ ! "$PVE_VER" =~ ^9\. ]]; then
    error "Detected Proxmox VE $PVE_VER. This script is designed for Proxmox VE 9.x."
fi

info "Detected Proxmox VE $PVE_VER"

# 2. Configure APT Repositories (deb822 format for Debian 13 Trixie)
if prompt_yes_no "Disable Enterprise repos and enable PVE No-Subscription repo?"; then
    # Disable PVE Enterprise repo if present
    if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
        cp /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.bak
        if grep -q "^Enabled:" /etc/apt/sources.list.d/pve-enterprise.sources; then
            sed -i 's/^Enabled:.*/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources
        else
            echo "Enabled: false" >> /etc/apt/sources.list.d/pve-enterprise.sources
        fi
        info "Disabled pve-enterprise.sources"
    fi

    # Disable Ceph Enterprise repo if present
    if [[ -f /etc/apt/sources.list.d/ceph.sources ]]; then
        cp /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.bak
        if grep -q "^Enabled:" /etc/apt/sources.list.d/ceph.sources; then
            sed -i 's/^Enabled:.*/Enabled: false/' /etc/apt/sources.list.d/ceph.sources
        else
            echo "Enabled: false" >> /etc/apt/sources.list.d/ceph.sources
        fi
        info "Disabled ceph.sources"
    fi

    # Create or overwrite Proxmox No-Subscription deb822 source
    cat << 'EOF' > /etc/apt/sources.list.d/proxmox.sources
Types: deb
URIs: http://proxmox.com
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
EOF
    info "Configured /etc/apt/sources.list.d/proxmox.sources"
fi

# 3. Remove Subscription Nag & Add Persistent APT Hook
if prompt_yes_no "Remove the 'No valid subscription' web UI pop-up?"; then
    JS_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
    if [[ -f "$JS_FILE" ]]; then
        cp "$JS_FILE" "${JS_FILE}.bak"
        sed -Ezi "s/(Ext\.Msg\.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$JS_FILE"
        
        # Add APT hook so updates to proxmox-widget-toolkit automatically re-apply the patch
        cat << 'EOF' > /etc/apt/apt.conf.d/no-nag-script
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$' && sed -Ezi 's/(Ext\.Msg\.show\(\{\s+title: gettext\('\''No valid sub)/void\(\{ \/\/\1/g' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || true"; };
EOF
        systemctl restart pveproxy.service
        info "Subscription pop-up removed and APT hook added (remember to hard-refresh your browser with Ctrl+Shift+R)."
    else
        warn "Could not find $JS_FILE; skipping nag removal."
    fi
fi

# 4. Disable High Availability (Single-Node Only)
if prompt_yes_no "Disable High Availability (HA) and Corosync services? (Choose 'n' if using a cluster)"; then
    systemctl disable --now pve-ha-lrm pve-ha-crm corosync 2>/dev/null || true
    info "Disabled pve-ha-lrm, pve-ha-crm, and corosync."
fi

# 5. Update and Upgrade System
if prompt_yes_no "Run 'apt update' and 'apt full-upgrade' now?"; then
    apt-get update
    apt-get full-upgrade -y
    info "System packages updated."
fi

info "Post-install setup complete!"

if prompt_yes_no "Would you like to reboot the node now?"; then
    reboot
fi
