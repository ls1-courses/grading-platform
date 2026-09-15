#!/usr/bin/env bash
set -euo pipefail
script_directory=$(cd -- "$(dirname -- "$0")" && pwd)
export STATE_DIRECTORY
STATE_DIRECTORY=$(mktemp -d)
export TANGO_HOSTNAME=astrid.dos.cit.tum.de
export TANGO_CERTIFICATE="$STATE_DIRECTORY/server.crt"
export TANGO_PRIVATE_KEY="$STATE_DIRECTORY/server.key"
# Do not access the host service manager during this isolated test.
systemctl() { return 1; }
export -f systemctl

bash "$script_directory/tango-tls.sh"
openssl verify -CAfile "$STATE_DIRECTORY/ca.crt" -purpose sslserver \
  -verify_hostname "$TANGO_HOSTNAME" "$TANGO_CERTIFICATE"
if openssl verify -CAfile "$STATE_DIRECTORY/ca.crt" \
  -verify_hostname other.invalid "$TANGO_CERTIFICATE"; then
  echo 'Incorrect hostname was accepted' >&2
  exit 1
fi
if openssl verify -no-CAfile -no-CApath -no-CAstore "$TANGO_CERTIFICATE"; then
  echo 'Untrusted certificate was accepted' >&2
  exit 1
fi
before=$(sha256sum "$STATE_DIRECTORY/ca.crt" "$TANGO_CERTIFICATE")
bash "$script_directory/tango-tls.sh"
test "$before" = "$(sha256sum "$STATE_DIRECTORY/ca.crt" "$TANGO_CERTIFICATE")"
test "$(stat -c %a "$STATE_DIRECTORY/ca.key")" = 600
test "$(stat -c %a "$TANGO_PRIVATE_KEY")" = 600

# Force the renewal branch and ensure Autolab's trust anchor stays stable.
ca_before=$(sha256sum "$STATE_DIRECTORY/ca.crt")
openssl x509 -req -in "$STATE_DIRECTORY/server.csr" \
  -CA "$STATE_DIRECTORY/ca.crt" -CAkey "$STATE_DIRECTORY/ca.key" \
  -set_serial 42 -days 1 -extfile "$STATE_DIRECTORY/server.ext" \
  -out "$TANGO_CERTIFICATE"
bash "$script_directory/tango-tls.sh"
test "$ca_before" = "$(sha256sum "$STATE_DIRECTORY/ca.crt")"
openssl x509 -in "$TANGO_CERTIFICATE" -noout -checkend 2592000
openssl verify -CAfile "$STATE_DIRECTORY/ca.crt" \
  -verify_hostname "$TANGO_HOSTNAME" "$TANGO_CERTIFICATE"
printf 'TLS issuance, rejection, idempotence, permissions and renewal passed. Test files: %s\n' "$STATE_DIRECTORY"
