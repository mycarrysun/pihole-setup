# Pi-hole + Unbound Docker Setup

A reliable, self-contained DNS setup with ad blocking and recursive resolution.

## Why This Setup?

- **Pi-hole**: Blocks ads and trackers at the DNS level for your whole network
- **Unbound**: Recursive DNS resolver - no forwarding to Google/Cloudflare, queries root servers directly
- **Docker**: Auto-restart on failure, easy updates, clean separation
- **Healthchecks**: Automatic recovery if either service becomes unhealthy

## Prerequisites

1. **Raspberry Pi 4** with Raspberry Pi OS (64-bit recommended)
2. **Docker and Docker Compose** installed
3. **Static IP** configured on the Pi
4. **SSD boot** (recommended) - SD cards die, SSDs don't

### Install Docker (if needed)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in for group membership to take effect
```

## Quick Start

```bash
# Clone or copy these files to your Pi
cd pihole-setup

# Run the setup script (requires sudo)
chmod +x setup.sh
sudo ./setup.sh
```

The setup script handles everything interactively:
- Prompts for Pi-hole web password
- Auto-detects timezone, Pi IP, and router IP (with confirmation)
- Prompts for local DNS records (NAT loopback) with wildcard subdomain support
- Installs Docker if needed
- Configures hardware watchdog with network ping monitoring
- Downloads DNS root hints and sets up monthly updates
- Starts the containers automatically

## NAT Loopback / Hairpin NAT Fix

The setup script prompts you to add local DNS records for NAT loopback. These are stored in `etc-dnsmasq.d/02-custom-dns.conf`.

To add more records later:
1. Open Pi-hole admin: `http://your-pi-ip:6161/admin`
2. Go to **Local DNS → DNS Records**
3. Add entries for your internal services

For wildcard subdomains (e.g., `*.example.com`), edit `etc-dnsmasq.d/02-custom-dns.conf` directly:
```
address=/example.com/192.168.1.x
```
Then restart Pi-hole: `docker restart pihole`

## Hardware Watchdog

The setup script configures the Pi 4's hardware watchdog with:
- **Hardware timeout**: Reboots if system locks up (14 second timeout)
- **Network ping**: Reboots if router becomes unreachable

The watchdog config is at `/etc/watchdog.conf`.

To verify the watchdog is running:

```bash
# Check watchdog status
systemctl status watchdog

# View watchdog details
wdctl
```

To test the watchdog (this WILL reboot your Pi):

```bash
# Method 1: Fork bomb (triggers high load reboot)
:(){ :|:& };:

# Method 2: Direct watchdog trigger (forces reboot in ~14 seconds)
sudo bash -c 'echo 1 > /dev/watchdog'
```

## Router Configuration

1. Log into your router's admin page
2. Find DHCP settings
3. Set DNS server to your Pi's IP address
4. (Optional) Set a secondary DNS as backup: `1.1.1.1` or `9.9.9.9`

**Note**: Setting a secondary public DNS means some queries will bypass Pi-hole.
For maximum blocking, only use the Pi-hole IP. The reliability of this setup
should make that safe.

## Maintenance

### Update Containers

```bash
docker-compose pull
docker-compose up -d
```

### Update Root Hints

Root hints are automatically updated monthly via cron job (set up by setup.sh).

To manually update:

```bash
curl -s -o /path/to/pihole-setup/unbound/root.hints https://www.internic.net/domain/named.root
docker restart unbound
```

### View Logs

```bash
# Pi-hole logs
docker logs pihole

# Unbound logs
docker logs unbound

# Follow logs live
docker logs -f pihole
```

### Check Health Status

```bash
docker ps
# Look for (healthy) status next to container names
```

## Troubleshooting

### DNS not resolving

1. Check containers are running: `docker ps`
2. Check Pi-hole logs: `docker logs pihole`
3. Test Unbound directly: `dig @your-pi-ip -p 5335 google.com`
4. Test Pi-hole directly: `dig @your-pi-ip google.com`

### Container keeps restarting

```bash
# Check what's happening
docker logs --tail 50 pihole
docker logs --tail 50 unbound
```

### Web interface not loading

- Check port 80 isn't used by something else: `sudo lsof -i :80`
- Try accessing via IP directly: `http://your-pi-ip/admin`

## File Structure

```
pihole-setup/
├── docker-compose.yml    # Main config (uses .env variables)
├── setup.sh              # Interactive setup script
├── .env                  # Configuration (created by setup.sh)
├── unbound/
│   ├── unbound.conf      # Unbound configuration
│   ├── root.hints        # Root DNS servers (created by setup.sh)
│   └── root.key          # DNSSEC trust anchor (auto-managed)
├── etc-pihole/           # Pi-hole data (created on first run)
└── etc-dnsmasq.d/
    └── 02-custom-dns.conf  # Local DNS records (created by setup.sh)
```

## Useful Commands

```bash
# Restart everything
docker-compose restart

# Stop everything
docker-compose down

# Full rebuild
docker-compose down && docker-compose up -d --force-recreate

# Update Pi-hole gravity (blocklists)
docker exec pihole pihole -g

# Check Pi-hole stats
docker exec pihole pihole -c -e
```