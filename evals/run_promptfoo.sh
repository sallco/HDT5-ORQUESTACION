#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Ambos proveedores Python cargan .env mediante python-dotenv, que admite
# CRLF. No se ejecuta el contenido de .env como código de shell.

exec npx promptfoo "$@"
