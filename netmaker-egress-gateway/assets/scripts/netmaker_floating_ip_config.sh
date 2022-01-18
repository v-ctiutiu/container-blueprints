#!/usr/bin/env bash

set -eu -o pipefail

CADDYFILE="/root/Caddyfile"
DOCKER_COMPOSE_FILE="/root/docker-compose.yml"

function stop_netmaker_server() {
    echo "[INFO] Stopping Netmaker server..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" down
}

function start_netmaker_server() {
    echo "[INFO] Starting Netmaker server..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" up -d
}

function restart_netmaker_server() {
    stop_netmaker_server
    start_netmaker_server
}

function set_anchor_ip_default_gw() {
    local SERVER_NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
    local PUBLIC_INTERFACE_GW_IP_ADDRESS="$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/gateway)"
    local SERVER_ANCHOR_IP_GW=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/gateway)

    if [[ "${SERVER_ANCHOR_IP_GW}null" == "null" ]]; then
        echo "[ERROR] Server anchor IP gateway address cannnot be empty!"
        exit 1
    fi

    ip route replace default via "$SERVER_ANCHOR_IP_GW" dev eth0

    # Persist settings across machine reboots
    if [[ -f "$SERVER_NETPLAN_FILE" ]]; then
        if grep "$SERVER_ANCHOR_IP_GW" "$SERVER_NETPLAN_FILE" &> /dev/null; then
            echo "[WARNING] Netplan file: $SERVER_NETPLAN_FILE already contains a Floating IP GW configuration for this server, skipping!"
            return 0
        fi

        echo "[INFO] Backing up $SERVER_NETPLAN_FILE to ${SERVER_NETPLAN_FILE}.bk"
        cp "$SERVER_NETPLAN_FILE" "${SERVER_NETPLAN_FILE}.bk"
        echo "[INFO] Setting persistent settings for default gw: ${SERVER_ANCHOR_IP_GW}..."
        sed -i "s/gateway4:.*$PUBLIC_INTERFACE_GW_IP_ADDRESS/gateway4: $SERVER_ANCHOR_IP_GW/g" "$SERVER_NETPLAN_FILE"
        netplan apply -debug
    else
        echo "[WARNING] Could not find server netplan configuration file: $SERVER_NETPLAN_FILE!"
        echo "[WARNING] Default GW settings won't be persisted if machine reboots!"
    fi
}

function netmaker_floating_ip_config() {
    local DROPLET_PUBLIC_IP_ADDRESS="$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)"
    local DROPLET_FLOATING_IP_ADDRESS="$(curl -s http://169.254.169.254/metadata/v1/floating_ip/ipv4/ip_address)"
    
    local OLD_NETMAKER_BASE_DOMAIN="nm.$(echo $DROPLET_PUBLIC_IP_ADDRESS | tr . -).nip.io"
    local OLD_SERVER_PUBLIC_IP="$DROPLET_PUBLIC_IP_ADDRESS"

    local FLOATING_IP_NETMAKER_BASE_DOMAIN="nm.$(echo $DROPLET_FLOATING_IP_ADDRESS | tr . -).nip.io"
    local FLOATING_IP_COREDNS=$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')
    local NEED_SERVER_RESTART="false"

    if grep "$FLOATING_IP_NETMAKER_BASE_DOMAIN" "$CADDYFILE" &> /dev/null; then
        echo "[WARNING] Netmaker Caddy configuration file: ${CADDYFILE} already contains a Floating IP configuration for: ${DROPLET_FLOATING_IP_ADDRESS}, skipping!"
    else
        echo "[INFO] Backing up Netmaker server Caddy file to: ${CADDYFILE}.bk..."
        cp "$CADDYFILE" "${CADDYFILE}.bk"
        echo "[INFO] Setting up Netmaker server Caddy configuration file to use Floating IP address: ${DROPLET_FLOATING_IP_ADDRESS}..."
        sed -i "s/$OLD_NETMAKER_BASE_DOMAIN/$FLOATING_IP_NETMAKER_BASE_DOMAIN/g" "$CADDYFILE"
        NEED_SERVER_RESTART="true"
    fi

    if grep "$FLOATING_IP_NETMAKER_BASE_DOMAIN" "$DOCKER_COMPOSE_FILE" &> /dev/null; then
        echo "[WARNING] Caddyfile already contains Floating IP configuration for: ${DROPLET_FLOATING_IP_ADDRESS}, skipping!"
    else
        echo "[INFO] Backing up Netmaker server docker compose file to: ${DOCKER_COMPOSE_FILE}.bk..."
        cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bk"
        echo "[INFO] Setting up Netmaker server docker-compose file to use Floating IP address: ${DROPLET_FLOATING_IP_ADDRESS}..."
        sed -i "s/$OLD_NETMAKER_BASE_DOMAIN/$FLOATING_IP_NETMAKER_BASE_DOMAIN/g" "$DOCKER_COMPOSE_FILE"
        # Replace all occurences, except coredns
        sed -i "/${OLD_SERVER_PUBLIC_IP}:53/ ! s/$OLD_SERVER_PUBLIC_IP/$DROPLET_FLOATING_IP_ADDRESS/g" "$DOCKER_COMPOSE_FILE"
        # Replace coredns entries now
        sed -i "s/${OLD_SERVER_PUBLIC_IP}:53/${FLOATING_IP_COREDNS}:53/g" "$DOCKER_COMPOSE_FILE"
        NEED_SERVER_RESTART="true"
    fi

    if [[ "$NEED_SERVER_RESTART" == "true" ]]; then
        echo "[INFO] Restarting Netmaker server for changes to take effect..."
        restart_netmaker_server
    fi

    echo -e "\n[INFO] To access the dashboard, please visit: https://dashboard.$FLOATING_IP_NETMAKER_BASE_DOMAIN"
}

function check_script_prerequisites() {
    local SCRIPT_REQUIRES="cp grep ip docker-compose netplan sed"

    for CMD in $SCRIPT_REQUIRES; do
        echo -ne "[INFO] Checking if command '$CMD' is available... "
        command -v "$CMD" &> /dev/null || {
            echo "FAIL!"
            exit 1
        }
        echo "PASS."
    done
}

function main() {
    check_script_prerequisites
    set_anchor_ip_default_gw
    netmaker_floating_ip_config
}

main "$@"
