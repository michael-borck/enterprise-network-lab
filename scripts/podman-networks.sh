#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create the enterprise-lab networks natively for Podman.
#
#   sudo bash scripts/podman-networks.sh
#
# Podman 6 / netavark 2 isolates bridge networks from each other by default.
# This lab routes *through* multi-homed FRR containers, so every network needs
# isolate=false. Do not rely on the compose front-end passing driver_opts
# through: podman-compose versions differ, and the Compose -> Podman socket
# path drops it. The Makefile marks these networks external in
# scripts/podman-networks.yml after this script creates them.
#
# Must run rootful: the routers need SYS_ADMIN/NET_ADMIN, tc and forwarding
# sysctls. The Makefile warns about this too.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="${CONTAINER_ENGINE:-podman}"
[ "$ENGINE" = "podman" ] || exit 0

command -v podman >/dev/null 2>&1 || { echo "podman is not installed."; exit 1; }
podman info >/dev/null 2>&1 || { echo "podman is not answering."; exit 1; }

if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
    echo "This lab needs rootful Podman (SYS_ADMIN, tc and forwarding sysctls)."
    echo "  macOS/Windows: podman machine set --rootful && podman machine stop && podman machine start"
    echo "  Linux:         run make with sudo, or use sudo podman ..."
    exit 1
fi

# name|subnet|gateway (empty gateway uses the provider default)
SPECS='
perth-users|10.10.10.0/24|
perth-servers|10.10.20.0/24|
perth-dmz|10.10.30.0/24|
london-users|10.20.10.0/24|
la-users|10.30.10.0/24|
pilbara-users|10.40.10.0/24|
wan-perth-london|172.16.1.0/24|172.16.1.200
wan-perth-la|172.16.2.0/24|172.16.2.200
wan-perth-pilbara|172.16.4.0/24|172.16.4.200
wan-london-la|172.16.3.0/24|172.16.3.200
'

# The lab is disposable; if a network has to be repaired, stop its containers
# first. Compose labels the project, so this does not touch other workloads.
remove_project_containers() {
    local ids
    ids="$(podman ps -aq --filter 'label=com.docker.compose.project=enterprise-network-lab' 2>/dev/null || true)"
    [ -n "$ids" ] || ids="$(podman ps -aq --filter 'name=enterprise-network-lab' 2>/dev/null || true)"
    # shellcheck disable=SC2086  # word splitting is intended here
    [ -n "$ids" ] && podman rm -f $ids >/dev/null 2>&1 || true
}

while IFS='|' read -r name subnet gateway; do
    [ -n "$name" ] || continue

    if podman network exists "$name" >/dev/null 2>&1; then
        opts="$(podman network inspect "$name" --format '{{json .Options}}' 2>/dev/null || echo '{}')"
        subnets="$(podman network inspect "$name" --format '{{range .Subnets}}{{.Subnet}} {{.Gateway}} {{end}}' 2>/dev/null || true)"
        ok=1
        printf '%s' "$opts" | grep -q '"isolate":"false"' || ok=0
        printf '%s' "$subnets" | grep -qw "$subnet" || ok=0
        if [ -n "$gateway" ]; then
            printf '%s' "$subnets" | grep -qw "$gateway" || ok=0
        fi
        [ "$ok" -eq 1 ] && continue

        echo "Repairing the Podman network $name (isolation, subnet or gateway was wrong)..."
        remove_project_containers
        if ! podman network rm "$name" >/dev/null 2>&1; then
            echo "!! Could not remove $name: another container is using it." >&2
            exit 1
        fi
    fi

    args=(network create --opt isolate=false --subnet "$subnet")
    [ -n "$gateway" ] && args+=(--gateway "$gateway")
    podman "${args[@]}" "$name" >/dev/null 2>&1 \
        || { echo "!! Could not create the Podman network $name." >&2; exit 1; }
    echo "network ready: $name"
done <<EOF
$SPECS
EOF
