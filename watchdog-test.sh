#!/bin/bash
# Watchdog test script for Pi-hole + Unbound stack
# Called by watchdog daemon every interval
# Exit 0 = healthy, non-zero = trigger reboot

# Check if Docker is responding
if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon not responding"
    exit 1
fi

# Check if Pi-hole container is running and healthy
PIHOLE_STATUS=$(docker inspect --format='{{.State.Health.Status}}' pihole 2>/dev/null)
if [ "$PIHOLE_STATUS" != "healthy" ]; then
    echo "Pi-hole container unhealthy: $PIHOLE_STATUS"
    exit 1
fi

# Check if Unbound container is running and healthy
UNBOUND_STATUS=$(docker inspect --format='{{.State.Health.Status}}' unbound 2>/dev/null)
if [ "$UNBOUND_STATUS" != "healthy" ]; then
    echo "Unbound container unhealthy: $UNBOUND_STATUS"
    exit 1
fi

# All checks passed
exit 0
