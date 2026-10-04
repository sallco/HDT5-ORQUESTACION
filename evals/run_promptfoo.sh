#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Promptfoo usa OPENAI_API_KEY para sus graders, mientras que la aplicación
# usa NVIDIA_API_KEY. Ambas variables contienen la misma clave NVIDIA y solo
# se aliasan para el cliente OpenAI-compatible de Promptfoo.
if [[ -f .env ]]; then
  clean_env="$(mktemp)"
  trap 'rm -f "$clean_env"' EXIT
  sed 's/\r$//' .env > "$clean_env"
  set -a
  # shellcheck disable=SC1090
  source "$clean_env"
  set +a
fi

export OPENAI_API_KEY="${OPENAI_API_KEY:-${NVIDIA_API_KEY:-}}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://integrate.api.nvidia.com/v1}"

exec npx promptfoo "$@"
