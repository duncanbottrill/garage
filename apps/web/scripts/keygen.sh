#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="${HOME}/.garage"; mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
PRIV="$OUT_DIR/private-key.pem"; PUB="$(dirname "$0")/../public/.well-known/appspecific/com.tesla.3p.public-key.pem"
if [ -f "$PRIV" ]; then echo "private key already exists at $PRIV — refusing to overwrite"; exit 1; fi
openssl ecparam -name prime256v1 -genkey -noout -out "$PRIV"; chmod 600 "$PRIV"
openssl ec -in "$PRIV" -pubout -out "$PUB"
echo "private key: $PRIV (back this up to your password manager)"; echo "public key:  $PUB (commit this)"
