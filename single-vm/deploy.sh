#!/usr/bin/env bash
# deploy.sh — the whole single-VM deploy: render Gophish config, bring everything up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker not found. Install it first: https://docs.docker.com/engine/install/"
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

gen_alnum() {
    # head closes the pipe as soon as it has $1 bytes, so tr gets SIGPIPE
    # (exit 141) — harmless, but pipefail+set -e would otherwise abort
    # the script on it. Scoped to a subshell so pipefail stays on globally.
    local len="$1"
    ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len" )
}

gen_password() {
    gen_alnum 10
}

if [[ ! -f .env ]]; then
    if [[ ! -f .env.example ]]; then
        echo "ERROR: .env.example not found."
        exit 1
    fi

    echo "No .env found — running first-time setup."
    cp .env.example .env

    read -rp "Enter this VM's IP or domain: " HOST_IP_INPUT
    if [[ -z "$HOST_IP_INPUT" ]]; then
        echo "ERROR: VM IP cannot be empty."
        rm -f .env
        exit 1
    fi

    echo "Generating secrets..."
    JWT_SECRET_VAL=$(gen_secret)
    LICENSE_SECRET_VAL=$(gen_secret)
    GO_PHISH_TOKEN_VAL=$(gen_secret)
    GOPHISH_WEBHOOK_SECRET_VAL=$(gen_secret)

    echo "Generating passwords..."
    MYSQL_ROOT_PASSWORD_VAL=$(gen_password)
    MYSQL_PASSWORD_VAL=$(gen_password)
    MINIO_ROOT_PASSWORD_VAL=$(gen_password)
    SUPER_ADMIN_PASSWORD_VAL=$(gen_password)
    GOPHISH_ADMIN_PASSWORD_VAL=$(gen_password)

    sed -i \
        -e "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET_VAL}|" \
        -e "s|^LICENSE_SECRET=.*|LICENSE_SECRET=${LICENSE_SECRET_VAL}|" \
        -e "s|^GO_PHISH_TOKEN=.*|GO_PHISH_TOKEN=${GO_PHISH_TOKEN_VAL}|" \
        -e "s|^GOPHISH_WEBHOOK_SECRET=.*|GOPHISH_WEBHOOK_SECRET=${GOPHISH_WEBHOOK_SECRET_VAL}|" \
        -e "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD_VAL}|" \
        -e "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=${MYSQL_PASSWORD_VAL}|" \
        -e "s|^DATABASE_PASSWORD=.*|DATABASE_PASSWORD=${MYSQL_PASSWORD_VAL}|" \
        -e "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD_VAL}|" \
        -e "s|^SUPER_ADMIN_PASSWORD=.*|SUPER_ADMIN_PASSWORD=${SUPER_ADMIN_PASSWORD_VAL}|" \
        -e "s|^GOPHISH_ADMIN_PASSWORD=.*|GOPHISH_ADMIN_PASSWORD=${GOPHISH_ADMIN_PASSWORD_VAL}|" \
        .env

    # Lands HOST_IP_INPUT into MAIL_FORGET_PASSWORD_URL, MAIL_LOGIN_URL, and
    # NEXT_PUBLIC_LANDING_PAGE_URL in one pass — all share this placeholder.
    # API_URL intentionally uses a different placeholder (cyberwise-user)
    # and is untouched by this substitution.
    sed -i \
        -e "s|192\.168\.1\.100|${HOST_IP_INPUT}|g" \
        .env

    SUPER_ADMIN_EMAIL_VAL=$(grep '^SUPER_ADMIN_EMAIL=' .env | cut -d= -f2-)

    echo "✓ .env created — VM IP set to ${HOST_IP_INPUT}, 4 secrets + 5 passwords generated."
    echo "  Super Admin login:  ${SUPER_ADMIN_EMAIL_VAL} / ${SUPER_ADMIN_PASSWORD_VAL}"
    echo "  Gophish admin login: admin / ${GOPHISH_ADMIN_PASSWORD_VAL}"
    echo "  Review the remaining placeholders in .env before continuing if needed:"
    echo "  SMTP (MAIL_*) creds."
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
echo "Starting database and object storage..."
docker compose up -d mysql minio

echo "Waiting for MinIO to become healthy..."
tries=0
until [[ "$(docker inspect -f '{{.State.Health.Status}}' cyberwise-minio 2>/dev/null)" == "healthy" ]]; do
    tries=$((tries + 1))
    if (( tries > 60 )); then
        echo "ERROR: MinIO did not become healthy in time."
        exit 1
    fi
    sleep 2
done

if [[ "${MINIO_ACCESS_KEY}" == "your_access_key" ]]; then
    echo "Provisioning MinIO access credentials..."
    MC_IMAGE="minio/mc:RELEASE.2025-08-13T08-35-41Z"
    MC_NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' cyberwise-minio)

    MC_OUTPUT=""
    if docker image inspect "${MC_IMAGE}" &>/dev/null || { echo "Pulling ${MC_IMAGE} (one-time)..."; timeout 120 docker pull "${MC_IMAGE}"; }; then
        MC_OUTPUT=$(docker run --rm --network "${MC_NET}" --entrypoint sh "${MC_IMAGE}" -c "
            mc alias set local http://cyberwise-minio:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' >/dev/null &&
            mc admin user svcacct add local '${MINIO_ROOT_USER}'
        " 2>&1) || true
    else
        echo "⚠ Could not pull ${MC_IMAGE} (no registry access?) — skipping to fallback."
    fi

    if [[ -n "$MC_OUTPUT" ]] && echo "$MC_OUTPUT" | grep -q "Access Key"; then
        MINIO_ACCESS_KEY_VAL=$(echo "$MC_OUTPUT" | grep "Access Key" | awk '{print $3}')
        MINIO_SECRET_KEY_VAL=$(echo "$MC_OUTPUT" | grep "Secret Key" | awk '{print $3}')
        sed -i \
            -e "s|^MINIO_ACCESS_KEY=.*|MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY_VAL}|" \
            -e "s|^MINIO_SECRET_KEY=.*|MINIO_SECRET_KEY=${MINIO_SECRET_KEY_VAL}|" \
            .env
        echo "✓ MinIO access credentials generated"
    else
        echo "⚠ Could not create a MinIO service account — falling back to root credentials."
        [[ -n "$MC_OUTPUT" ]] && echo "$MC_OUTPUT"
        sed -i \
            -e "s|^MINIO_ACCESS_KEY=.*|MINIO_ACCESS_KEY=${MINIO_ROOT_USER}|" \
            -e "s|^MINIO_SECRET_KEY=.*|MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD}|" \
            .env
    fi
fi

echo ""
echo "Starting all services..."
docker compose up -d

# No standalone HOST_IP var — pull the display IP out of a URL that already
# has it baked in from the first-run setup above.
DISPLAY_HOST=$(printf '%s' "${NEXT_PUBLIC_LANDING_PAGE_URL:-}" | sed -E 's#^https?://([^:/]+).*#\1#')

echo ""
echo "=== Deployment started ==="
echo "  Web App:        http://${DISPLAY_HOST:-localhost}:3000/auth/login"
echo ""
echo "Check status:  docker compose ps"
echo "Check logs:    docker compose logs -f <service>   (mysql, minio, nginx, user, lms, web, phish)"
