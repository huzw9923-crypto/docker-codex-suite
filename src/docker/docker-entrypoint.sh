#!/usr/bin/env bash
set -euo pipefail

CODEX_USER="${CODEX_USER:-codex}"
CODEX_HOME_DIR="/home/${CODEX_USER}/.codex"
CODEX_LOCAL_BIN="/home/${CODEX_USER}/.local/bin"

mkdir -p /run/sshd "${CODEX_HOME_DIR}" "${CODEX_HOME_DIR}/app-server-control" "${CODEX_LOCAL_BIN}"

if [ -d /opt/codex/packages/standalone/releases ] && [ -e /opt/codex/packages/standalone/current ]; then
  mkdir -p "${CODEX_HOME_DIR}/packages/standalone/releases"
  cp -a /opt/codex/packages/standalone/releases/. "${CODEX_HOME_DIR}/packages/standalone/releases/"
  rm -f "${CODEX_HOME_DIR}/packages/standalone/current"
  cp -a /opt/codex/packages/standalone/current "${CODEX_HOME_DIR}/packages/standalone/current"
fi

if [ -e "${CODEX_HOME_DIR}/packages/standalone/current/bin/codex" ]; then
  ln -sfn "${CODEX_HOME_DIR}/packages/standalone/current/bin/codex" "${CODEX_LOCAL_BIN}/codex"
fi

{
  printf 'CODEX_HOME=%s\n' "${CODEX_HOME_DIR}"
  printf 'PATH=%s:%s\n' "${CODEX_LOCAL_BIN}" "/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [ -n "${DOCKER_CODEX_API_KEY:-}" ]; then
    printf 'DOCKER_CODEX_API_KEY=%s\n' "${DOCKER_CODEX_API_KEY}"
  fi
} >"/home/${CODEX_USER}/.ssh/environment"
chmod 600 "/home/${CODEX_USER}/.ssh/environment"

rm -f "${CODEX_HOME_DIR}"/app-server-control/*.sock
rm -f "${CODEX_HOME_DIR}/app-server-control/app-server-startup.lock"

chown -R "${CODEX_USER}:${CODEX_USER}" "${CODEX_HOME_DIR}" "/home/${CODEX_USER}/.local" "/home/${CODEX_USER}/.ssh"

exec "$@"

