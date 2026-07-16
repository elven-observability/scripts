#!/bin/bash
# Dedicated Linux entrypoint: Node Exporter -> local OTel Collector -> remote OTel Collector (OTLP/HTTP)

set -e
set -o pipefail

BASE_INSTALLER_URL="https://raw.githubusercontent.com/elven-observability/scripts/main/linux/node_exporter/linux-instrumentation.sh"

if [ -n "${BASH_SOURCE[0]-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir=$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    local_installer="$script_dir/linux-instrumentation.sh"
    if [ -f "$local_installer" ]; then
        export ELVEN_METRICS_DESTINATION="collector"
        exec bash "$local_installer"
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download the Elven installer." >&2
    exit 1
fi

installer_file=$(mktemp /tmp/elven-linux-installer.XXXXXX)
cleanup() {
    rm -f "$installer_file"
}
trap cleanup EXIT HUP INT TERM

echo "Downloading the official Elven Linux instrumentation installer..."
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --output "$installer_file" \
    "$BASE_INSTALLER_URL"

if [ ! -s "$installer_file" ]; then
    echo "ERROR: downloaded installer is empty." >&2
    exit 1
fi

export ELVEN_METRICS_DESTINATION="collector"
bash "$installer_file"
