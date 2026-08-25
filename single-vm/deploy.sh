#!/usr/bin/env bash
# deploy.sh — the whole single-VM deploy: render Gophish config, bring everything up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install it first: https://docs.docker.com/engine/install/"
    exit 1
fi

if [[ ! -f .env ]]; then
    echo "ERROR: .env not found."
    echo "  cp .env.example .env"
    echo "  nano .env   # fill in real values"
    echo "  ./deploy.sh"
    exit 1
fi

if ! command -v envsubst &>/dev/null; then
    echo "ERROR: envsubst not found (part of gettext)."
    echo "  Debian/Ubuntu: sudo apt-get install -y gettext-base"
    exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

echo "Rendering phish/config.json..."
envsubst < phish/config.json.tpl > phish/config.json
echo "✓ phish/config.json rendered"

if [[ -n "${DOCKER_HUB_USER:-}" && -n "${DOCKER_HUB_PASS:-}" ]]; then
    echo "Logging into Docker Hub..."
    echo "${DOCKER_HUB_PASS}" | docker login -u "${DOCKER_HUB_USER}" --password-stdin
fi

echo ""
echo "Starting all services..."
docker compose up -d

echo ""
echo "=== Deployment started ==="
echo "  Web App:        http://${HOST_IP:-localhost}:3000"
echo "  Gophish Phish:  http://${HOST_IP:-localhost}:3000/landing"
echo "  User API:       http://${HOST_IP:-localhost}:10081"
echo "  User Metrics:   http://${HOST_IP:-localhost}:10091/actuator/prometheus"
echo "  LMS gRPC:       ${HOST_IP:-localhost}:10082"
echo "  Gophish Admin:  http://${HOST_IP:-localhost}:3331"
echo ""
echo "Check status:  docker compose ps"
echo "Check logs:    docker compose logs -f <service>   (mysql, minio, nginx, user, lms, web, phish)"
