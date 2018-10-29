#!/bin/bash

function createTProxyChain {
    ${IPTABLES} -t nat -N TPROXYHTTP
    ${IPTABLES} -t nat -A TPROXYHTTP -o lo -j RETURN
    ${IPTABLES} -t nat -A TPROXYHTTP -d 127.0.0.0/8 -j RETURN
    ${IPTABLES} -t nat -A TPROXYHTTP -d 192.168.0.0/16 -j RETURN
    ${IPTABLES} -t nat -A TPROXYHTTP -d 10.0.0.0/8 -j RETURN
    ${IPTABLES} -t nat -A TPROXYHTTP -d 172.16.0.0/12 -j RETURN

    for machineIp in $(hostname -i); do
        if [ "${machineIp}" = "${HTTP_PROXY_HOST}" ]; then
            # The parent proxy is managed by this host: exclude the proxy container from the TPROXYHTTP chain
            for containerIp in $(iptables -t nat -S DOCKER | grep " DNAT " | grep -- " --dport ${HTTP_PROXY_PORT} " | sed -nr "s|.+--to-destination ([^:]+):.+|\1|p"); do
                echo "Excluding the Proxy container bind on ${containerIp} from the TPROXYHTTP chain"
                ${IPTABLES} -t nat -A TPROXYHTTP -s "${containerIp}" -j RETURN
            done
        fi
        if [ "${machineIp}" = "${HTTPS_PROXY_HOST}" ]; then
            # The parent proxy is managed by this host: exclude the proxy container from the TPROXYHTTP chain
            for containerIp in $(iptables -t nat -S DOCKER | grep " DNAT " | grep -- " --dport ${HTTPS_PROXY_PORT} " | sed -nr "s|.+--to-destination ([^:]+):.+|\1|p"); do
                echo "Excluding the Proxy container bind on ${containerIp} from the TPROXYHTTP chain"
                ${IPTABLES} -t nat -A TPROXYHTTP -s "${containerIp}" -j RETURN
            done
        fi
    done
}

function deleteTProxyChain {
    ${IPTABLES} -t nat -F TPROXYHTTP
    ${IPTABLES} -t nat -X TPROXYHTTP
}

function addIPTableRedirectionRules {
    local REDIRECTED_PORT=$1
    local DOCKER_PROXY_CONTAINER_PORT=$2

    ${IPTABLES} -t nat -A TPROXYHTTP -p tcp --dport ${REDIRECTED_PORT} -j REDIRECT --to-port ${DOCKER_PROXY_CONTAINER_PORT}

    # For the container traffic
    ${IPTABLES} -t nat -I PREROUTING -p tcp --dport ${REDIRECTED_PORT} -j TPROXYHTTP
    # For the boot2docker VM traffic itself
    ${IPTABLES} -t nat -I OUTPUT -p tcp --dport ${REDIRECTED_PORT} -j TPROXYHTTP
}

function deleteIPTableRedirectionRules {
    local REDIRECTED_PORT=$1
    local DOCKER_PROXY_CONTAINER_PORT=$2

    # For the container traffic
    ${IPTABLES} -t nat -D PREROUTING -p tcp --dport ${REDIRECTED_PORT} -j TPROXYHTTP
    # For the boot2docker VM traffic itself
    ${IPTABLES} -t nat -D OUTPUT -p tcp --dport ${REDIRECTED_PORT} -j TPROXYHTTP
}

function HTTPProxyPortsListening {
    test "$($SS -lnt '( sport = :3128 )' | grep -v ^State | wc -l)" -eq 1
    return $?
}

function HTTPSProxyPortsListening {
    test "$($SS -lnt '( sport = :3129 )' | grep -v ^State | wc -l)" -eq 1
    return $?
}

function shutdown {
    echo "Received SIGTERM"

    echo "Shutting down HTTP transparent proxy..."
    if [ "${HTTP_PROXY_PID}" -ne 0 ]; then
        kill -SIGTERM "${HTTP_PROXY_PID}"
        wait "${HTTP_PROXY_PID}"
    fi
    if [ "${HTTP_TAIL_PID}" -ne 0 ]; then
        kill -SIGTERM "${HTTP_TAIL_PID}"
        wait "${HTTP_TAIL_PID}"
    fi

    echo "Shutting down HTTPS transparent proxy..."
    if [ "${HTTPS_PROXY_PID}" -ne 0 ]; then
        kill -SIGTERM "${HTTPS_PROXY_PID}"
        wait "${HTTPS_PROXY_PID}"
    fi
    if [ "${HTTPS_TAIL_PID}" -ne 0 ]; then
        kill -SIGTERM "${HTTPS_TAIL_PID}"
        wait "${HTTPS_TAIL_PID}"
    fi

    echo 'Removing iptables redirections to transparent proxies...'
    deleteIPTableRedirectionRules 80   3128
    deleteIPTableRedirectionRules 8080 3128
    deleteIPTableRedirectionRules 443  3129
    deleteIPTableRedirectionRules 8443 3129
    deleteTProxyChain

    exit 143; # 128 + 15 -- SIGTERM
}

trap 'shutdown' SIGINT SIGTERM

IPTABLES="/sbin/iptables"
SS="/sbin/ss"

[ -z ${http_proxy} ] && { echo "http_proxy variable is undefined"; exit 1; }
read HTTP_PROXY_HOST HTTP_PROXY_PORT <<< $(echo "$http_proxy" | sed -nr 's|^http://([^:]+):([0-9]+)$|\1 \2|p')
[ -z ${HTTP_PROXY_HOST} ] && { echo "http_proxy variable is malformed"; exit 1; }
HTTP_PROXY_ADDR="${HTTP_PROXY_HOST}:${HTTP_PROXY_PORT}"
HTTP_PROXY_LOG="/tmp/http-proxy.log"
HTTP_PROXY_PID=0
HTTP_TAIL_PID=0

[ -z ${https_proxy} ] && { echo "https_proxy variable is undefined"; exit 1; }
read HTTPS_PROXY_HOST HTTPS_PROXY_PORT <<< $(echo "$https_proxy" | sed -nr 's|^http://([^:]+):([0-9]+)$|\1 \2|p')
[ -z ${HTTPS_PROXY_HOST} ] && { echo "https_proxy variable is malformed"; exit 1; }
HTTPS_PROXY_ADDR="${HTTPS_PROXY_HOST}:${HTTPS_PROXY_PORT}"
HTTPS_PROXY_LOG="/tmp/https-proxy.log"
HTTPS_PROXY_PID=0
HTTPS_TAIL_PID=0

echo "Starting any_proxy as HTTP transparent proxy (parent proxy: ${HTTP_PROXY_ADDR})..."
/tmp/any_proxy -l :3128 -p "${HTTP_PROXY_ADDR}" -f "${HTTP_PROXY_LOG}" &
HTTP_PROXY_PID="$!"
while [ "${HTTP_TAIL_PID}" -eq 0 ]; do
    if [ -f "${HTTP_PROXY_LOG}" ]; then
        tail -f "${HTTP_PROXY_LOG}" &
        HTTP_TAIL_PID=${!}
    fi
    sleep 1;
done

echo "Waiting for HTTP transparent proxy to listen..."
while ! $(HTTPProxyPortsListening); do
    sleep 1
done

echo "Starting any_proxy as HTTPS transparent proxy (parent proxy: ${HTTPS_PROXY_ADDR})..."
/tmp/any_proxy -l :3129 -p "${HTTPS_PROXY_ADDR}" -f "${HTTPS_PROXY_LOG}" &
HTTPS_PROXY_PID="$!"
while [ "${HTTPS_TAIL_PID}" -eq 0 ]; do
    if [ -f "${HTTPS_PROXY_LOG}" ]; then
        tail -f "${HTTPS_PROXY_LOG}" &
        HTTPS_TAIL_PID=${!}
    fi
    sleep 1;
done

echo "Waiting for HTTPS transparent proxy to listen..."
while ! $(HTTPSProxyPortsListening); do
    sleep 1
done

echo "Adding iptables redirections to transparent proxies..."
createTProxyChain
addIPTableRedirectionRules 80   3128
addIPTableRedirectionRules 8080 3128
addIPTableRedirectionRules 443  3129
addIPTableRedirectionRules 8443 3129

echo "Waiting for SIGTERM..."
while true; do
    sleep 2
done
