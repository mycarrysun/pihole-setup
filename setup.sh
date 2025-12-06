#!/bin/bash

# Pi-hole + Unbound Setup Script
# Run this once to configure and start the Pi-hole stack
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
echo -e "${YELLOW}[1/8] Checking for Docker...${NC}"
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
# Collect User Input
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[2/8] Collecting configuration...${NC}"
echo ""

# --- Pi-hole Web Password ---
echo -e "${GREEN}Pi-hole Web Password${NC}"
echo -n "Enter password for Pi-hole web interface: "
read -s WEBPASSWORD
echo ""
if [ -z "$WEBPASSWORD" ]; then
    echo -e "${RED}Password cannot be empty.${NC}"
    exit 1
fi

# --- Timezone ---
echo ""
echo -e "${GREEN}Timezone${NC}"
DETECTED_TZ=""
if [ -f /etc/timezone ]; then
    DETECTED_TZ=$(cat /etc/timezone)
elif command -v timedatectl &> /dev/null; then
    DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
fi

if [ -n "$DETECTED_TZ" ]; then
    echo "Detected timezone: $DETECTED_TZ"
    echo -n "Is this correct? [Y/n]: "
    read TZ_CONFIRM
    if [ "$TZ_CONFIRM" = "n" ] || [ "$TZ_CONFIRM" = "N" ]; then
        echo -n "Enter timezone (e.g., America/Chicago): "
        read TZ
    else
        TZ="$DETECTED_TZ"
    fi
else
    echo -n "Enter timezone (e.g., America/New_York): "
    read TZ
fi

if [ -z "$TZ" ]; then
    echo -e "${RED}Timezone cannot be empty.${NC}"
    exit 1
fi

# --- Pi's Static IP ---
echo ""
echo -e "${GREEN}Pi's Static IP Address${NC}"
DETECTED_IP=$(hostname -I | awk '{print $1}')

if [ -n "$DETECTED_IP" ]; then
    echo "Detected IP: $DETECTED_IP"
    echo -n "Is this correct? [Y/n]: "
    read IP_CONFIRM
    if [ "$IP_CONFIRM" = "n" ] || [ "$IP_CONFIRM" = "N" ]; then
        echo -n "Enter Pi's static IP address: "
        read PIHOLE_LOCAL_IP
    else
        PIHOLE_LOCAL_IP="$DETECTED_IP"
    fi
else
    echo -n "Enter Pi's static IP address: "
    read PIHOLE_LOCAL_IP
fi

if [ -z "$PIHOLE_LOCAL_IP" ]; then
    echo -e "${RED}IP address cannot be empty.${NC}"
    exit 1
fi

# --- Router/Gateway IP ---
echo ""
echo -e "${GREEN}Router/Gateway IP (for network watchdog)${NC}"
DETECTED_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)

if [ -n "$DETECTED_GATEWAY" ]; then
    echo "Detected gateway: $DETECTED_GATEWAY"
    echo -n "Is this correct? [Y/n]: "
    read GW_CONFIRM
    if [ "$GW_CONFIRM" = "n" ] || [ "$GW_CONFIRM" = "N" ]; then
        echo -n "Enter router/gateway IP address: "
        read ROUTER_IP
    else
        ROUTER_IP="$DETECTED_GATEWAY"
    fi
else
    echo -n "Enter router/gateway IP address: "
    read ROUTER_IP
fi

if [ -z "$ROUTER_IP" ]; then
    echo -e "${RED}Router IP cannot be empty.${NC}"
    exit 1
fi

# --- NAT Loopback DNS Records ---
echo ""
echo -e "${GREEN}=== Local DNS Records (NAT Loopback) ===${NC}"
echo "Add DNS records for internal services that need to resolve locally."
echo ""
echo -n "Add DNS records? [y/N]: "
read ADD_DNS

DNS_RECORDS=""
if [ "$ADD_DNS" = "y" ] || [ "$ADD_DNS" = "Y" ]; then
    ENTRY_NUM=1
    while true; do
        echo ""
        echo -e "${YELLOW}Entry $ENTRY_NUM:${NC}"
        echo -n "  Domain: "
        read DNS_DOMAIN

        if [ -z "$DNS_DOMAIN" ]; then
            echo -e "${RED}  Domain cannot be empty. Skipping.${NC}"
            break
        fi

        echo -n "  IP address: "
        read DNS_IP

        if [ -z "$DNS_IP" ]; then
            echo -e "${RED}  IP cannot be empty. Skipping.${NC}"
            break
        fi

        echo -n "  Include all subdomains (*.$DNS_DOMAIN)? [Y/n]: "
        read WILDCARD

        if [ "$WILDCARD" = "n" ] || [ "$WILDCARD" = "N" ]; then
            # Exact match only
            DNS_RECORDS="${DNS_RECORDS}host-record=${DNS_DOMAIN},${DNS_IP}\n"
            echo -e "  ${GREEN}Added: $DNS_DOMAIN -> $DNS_IP${NC}"
        else
            # Wildcard (domain + all subdomains)
            DNS_RECORDS="${DNS_RECORDS}address=/${DNS_DOMAIN}/${DNS_IP}\n"
            echo -e "  ${GREEN}Added: $DNS_DOMAIN (+ subdomains) -> $DNS_IP${NC}"
        fi

        echo ""
        echo -n "Add another? [y/N]: "
        read ADD_ANOTHER

        if [ "$ADD_ANOTHER" != "y" ] && [ "$ADD_ANOTHER" != "Y" ]; then
            break
        fi

        ENTRY_NUM=$((ENTRY_NUM + 1))
    done
fi

# -------------------------------------------------------------------
# Write Configuration Files
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[3/8] Writing configuration files...${NC}"

cd "$SCRIPT_DIR"

# Write .env file
cat > .env << EOF
# Pi-hole configuration - generated by setup.sh
WEBPASSWORD=${WEBPASSWORD}
TZ=${TZ}
PIHOLE_LOCAL_IP=${PIHOLE_LOCAL_IP}
EOF

chmod 600 .env
chown "$ACTUAL_USER":"$ACTUAL_USER" .env
echo -e "${GREEN}.env file created.${NC}"

# Write DNS records if any were added
if [ -n "$DNS_RECORDS" ]; then
    mkdir -p etc-dnsmasq.d
    echo -e "# Custom local DNS records for NAT loopback\n# Generated by setup.sh\n${DNS_RECORDS}" > etc-dnsmasq.d/02-custom-dns.conf
    chown -R "$ACTUAL_USER":"$ACTUAL_USER" etc-dnsmasq.d
    echo -e "${GREEN}DNS records written to etc-dnsmasq.d/02-custom-dns.conf${NC}"
fi

# -------------------------------------------------------------------
# Create Pi-hole directories
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[4/8] Creating Pi-hole directories...${NC}"

mkdir -p etc-pihole etc-dnsmasq.d
chown -R "$ACTUAL_USER":"$ACTUAL_USER" etc-pihole etc-dnsmasq.d

# -------------------------------------------------------------------
# Download root hints for Unbound
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[5/8] Downloading DNS root hints...${NC}"

curl -s -o unbound/root.hints https://www.internic.net/domain/named.root
chown "$ACTUAL_USER":"$ACTUAL_USER" unbound/root.hints

echo -e "${GREEN}Root hints downloaded.${NC}"

# -------------------------------------------------------------------
# Set up monthly cron job to update root hints
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[6/8] Setting up monthly root hints update...${NC}"

CRON_CMD="0 4 1 * * curl -s -o $SCRIPT_DIR/unbound/root.hints https://www.internic.net/domain/named.root && docker restart unbound 2>/dev/null || true"

# Check if cron job already exists (add to actual user's crontab, not root's)
if ! crontab -u "$ACTUAL_USER" -l 2>/dev/null | grep -q "root.hints"; then
    (crontab -u "$ACTUAL_USER" -l 2>/dev/null; echo "$CRON_CMD") | crontab -u "$ACTUAL_USER" -
    echo -e "${GREEN}Monthly cron job added to $ACTUAL_USER's crontab.${NC}"
else
    echo -e "${GREEN}Root hints cron job already exists.${NC}"
fi

# -------------------------------------------------------------------
# Set up hardware watchdog with network ping
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[7/8] Setting up hardware watchdog...${NC}"

# Install watchdog package
apt-get update -qq
apt-get install -y -qq watchdog

# Configure watchdog
cat > /etc/watchdog.conf << EOF
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

# Network connectivity check - reboot if router unreachable
ping = ${ROUTER_IP}
ping-count = 3

# Realtime scheduling for watchdog daemon
realtime = yes
priority = 1

# Verbose logging (set to no for production)
verbose = no
EOF

# Enable watchdog service
systemctl enable watchdog
systemctl start watchdog

echo -e "${GREEN}Hardware watchdog configured with network ping to ${ROUTER_IP}.${NC}"

# -------------------------------------------------------------------
# Configure Docker to start on boot
# -------------------------------------------------------------------
echo ""
echo -e "${YELLOW}[8/8] Configuring Docker and starting containers...${NC}"

systemctl enable docker

# Start the containers
cd "$SCRIPT_DIR"
docker compose up -d

echo -e "${GREEN}Containers started.${NC}"

# Wait a moment for containers to initialize
sleep 5

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "Pi-hole admin interface: ${YELLOW}http://${PIHOLE_LOCAL_IP}:6161/admin${NC}"
echo ""
echo -e "${YELLOW}Container status:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update your router's DHCP settings to use ${PIHOLE_LOCAL_IP} as the DNS server"
echo "2. (Optional) Add more local DNS records in Pi-hole Admin -> Local DNS -> DNS Records"
echo ""
echo -e "${GREEN}Watchdog status:${NC}"
systemctl status watchdog --no-pager | head -5
echo ""
