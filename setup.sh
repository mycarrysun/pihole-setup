#!/bin/bash

# Pi-hole + Unbound Setup Script
# Run this once before starting docker-compose
# This script must be run with sudo

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Pi-hole + Unbound Setup ===${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script with sudo${NC}"
    echo "Usage: sudo ./setup.sh"
    exit 1
fi

# Get the actual user (not root) for setting ownership
ACTUAL_USER=${SUDO_USER:-$USER}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------------------------------------------------
# Check for Docker
# -------------------------------------------------------------------
echo -e "${YELLOW}[1/7] Checking for Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed.${NC}"
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$ACTUAL_USER"
    echo -e "${GREEN}Docker installed. You may need to log out and back in for group membership.${NC}"
else
    echo -e "${GREEN}Docker is installed.${NC}"
fi

# Check for docker-compose
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "Installing docker-compose plugin..."
    apt-get update
    apt-get install -y docker-compose-plugin
fi

# -------------------------------------------------------------------
# Set up hardware watchdog
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[3/7] Setting up hardware watchdog...${NC}"

# Install watchdog package
apt-get update
apt-get install -y watchdog

# Configure watchdog
cat > /etc/watchdog.conf << 'EOF'
# Hardware watchdog configuration for Raspberry Pi
# The Pi's hardware watchdog has a maximum timeout of 15 seconds
# We use 14 to stay safely under the limit

# Watchdog device
watchdog-device = /dev/watchdog

# Timeout (must be < 15 seconds on Raspberry Pi)
watchdog-timeout = 14

# Interval to reset the watchdog timer
interval = 10

# Load thresholds - reboot if 1-minute load exceeds this
max-load-1 = 24

# Memory thresholds - reboot if free pages drops below this
# Commented out by default, uncomment if needed
# min-memory = 1

# Ping test - ensure network is reachable (optional)
# Uncomment to enable network watchdog
# ping = 192.168.1.1

# File to check - reboot if file not updated
# Uncomment to monitor a specific service heartbeat file
# file = /var/run/pihole-heartbeat
# change = 300

# Realtime scheduling for watchdog daemon
realtime = yes
priority = 1

# Verbose logging (set to no for production)
verbose = no
EOF

# Enable watchdog service
systemctl enable watchdog
systemctl start watchdog

echo -e "${GREEN}Hardware watchdog configured and enabled.${NC}"

# -------------------------------------------------------------------
# Create Pi-hole directories
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[4/7] Creating Pi-hole directories...${NC}"

cd "$SCRIPT_DIR"
mkdir -p etc-pihole etc-dnsmasq.d unbound

# -------------------------------------------------------------------
# Download root hints for Unbound
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[5/7] Downloading DNS root hints...${NC}"

curl -s -o unbound/root.hints https://www.internic.net/domain/named.root

# Create empty root.key file (will be populated by Unbound on first run)
touch unbound/root.key

# Set permissions
chmod -R 755 unbound
chown -R "$ACTUAL_USER":"$ACTUAL_USER" etc-pihole etc-dnsmasq.d unbound

echo -e "${GREEN}Root hints downloaded.${NC}"

# -------------------------------------------------------------------
# Set up monthly cron job to update root hints
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[6/7] Setting up monthly root hints update...${NC}"

CRON_CMD="0 4 1 * * curl -s -o $SCRIPT_DIR/unbound/root.hints https://www.internic.net/domain/named.root && docker restart unbound 2>/dev/null || true"

# Check if cron job already exists
if ! crontab -l 2>/dev/null | grep -q "root.hints"; then
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    echo -e "${GREEN}Monthly cron job added to update root hints.${NC}"
else
    echo -e "${GREEN}Root hints cron job already exists.${NC}"
fi

# -------------------------------------------------------------------
# Set up Docker restart policy via systemd (belt and suspenders)
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[7/7] Configuring Docker to start on boot...${NC}"

systemctl enable docker
echo -e "${GREEN}Docker configured to start on boot.${NC}"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Before running 'docker-compose up -d', make sure to:"
echo ""
echo -e "${YELLOW}1. Edit docker-compose.yml and set:${NC}"
echo "   - TZ: Your timezone (e.g., 'America/Chicago')"
echo "   - WEBPASSWORD: A secure password for the web interface"
echo "   - FTLCONF_LOCAL_IPV4: Your Pi's static IP address"
echo ""
echo -e "${YELLOW}2. Ensure your Pi has a static IP configured${NC}"
echo "   Edit /etc/dhcpcd.conf or use your router's DHCP reservation"
echo ""
echo -e "${YELLOW}3. Start the stack:${NC}"
echo "   cd $SCRIPT_DIR"
echo "   docker-compose up -d"
echo ""
echo -e "${YELLOW}4. Update your router's DHCP to hand out your Pi's IP as DNS${NC}"
echo ""
echo -e "${YELLOW}5. (Optional) Add local DNS records in Pi-hole for NAT loopback:${NC}"
echo "   Pi-hole Admin -> Local DNS -> DNS Records"
echo "   Add your internal services (e.g., nas.yourdomain.com -> 192.168.1.x)"
echo ""
echo -e "${GREEN}Watchdog status:${NC}"
systemctl status watchdog --no-pager | head -5
echo ""
echo -e "${GREEN}To verify watchdog is working later, you can run:${NC}"
echo "   wdctl"
echo ""
