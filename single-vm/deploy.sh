#!/usr/bin/env bash
# deploy.sh — the whole single-VM deploy: render Gophish config, bring everything up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install it first: https://docs.docker.com/engine/install/"
    exit 1
fi

if [[ ! -f .env ]]; then
    if [[ ! -f .env.example ]]; then
        echo "ERROR: .env.example not found."
        exit 1
    fi

    echo "No .env found — running first-time setup."
    cp .env.example .env

    read -rp "Enter this VM's IP or domain (HOST_IP): " HOST_IP_INPUT
    if [[ -z "$HOST_IP_INPUT" ]]; then
        echo "ERROR: VM IP cannot be empty."
        rm -f .env
        exit 1
    fi

    gen_secret() {
        if command -v openssl &>/dev/null; then
            openssl rand -hex 32
        elif command -v xxd &>/dev/null; then
            head -c 32 /dev/urandom | xxd -p -c 256
        else
            head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
        fi
    }

    echo "Generating secrets..."
    JWT_SECRET_VAL=$(gen_secret)
    APPLICATION_SECRET_VAL=$(gen_secret)
    LICENSE_SECRET_VAL=$(gen_secret)
    GO_PHISH_TOKEN_VAL=$(gen_secret)
    GOPHISH_WEBHOOK_SECRET_VAL=$(gen_secret)

    sed -i \
        -e "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET_VAL}|" \
        -e "s|^APPLICATION_SECRET=.*|APPLICATION_SECRET=${APPLICATION_SECRET_VAL}|" \
        -e "s|^LICENSE_SECRET=.*|LICENSE_SECRET=${LICENSE_SECRET_VAL}|" \
        -e "s|^GO_PHISH_TOKEN=.*|GO_PHISH_TOKEN=${GO_PHISH_TOKEN_VAL}|" \
        -e "s|^GOPHISH_WEBHOOK_SECRET=.*|GOPHISH_WEBHOOK_SECRET=${GOPHISH_WEBHOOK_SECRET_VAL}|" \
        .env

    # Lands HOST_IP_INPUT into HOST_IP, MAIL_REGISTRATION_URL,
    # MAIL_FORGET_PASSWORD_URL, MAIL_LOGIN_URL, NEXT_PUBLIC_LANDING_PAGE_URL,
    # and LOCAL_URL in one pass — all share these two placeholders.
    # API_URL intentionally uses a different placeholder (cyberwise-user) and
    # is untouched by this substitution.
    sed -i \
        -e "s|192\.168\.1\.100|${HOST_IP_INPUT}|g" \
        -e "s|192\.168\.1\.y|${HOST_IP_INPUT}|g" \
        .env

    echo "✓ .env created — HOST_IP=${HOST_IP_INPUT}, 5 secrets generated."
    echo "  Review the remaining placeholders in .env before continuing if needed:"
    echo "  MySQL/MinIO/Gophish-admin passwords, SUPER_ADMIN_*, SMTP (MAIL_*) creds."
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
