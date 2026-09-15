set -eu
cd "${STATE_DIRECTORY:-/var/lib/grading-tls}"
umask 077

# Keep the CA stable across reboots and server-certificate renewals.
# Never silently replace a missing half of an existing CA identity.
if [ ! -e ca.key ] && [ ! -e ca.crt ]; then
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -subj '/CN=Grading Tango internal CA' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout ca.key -out ca.crt
fi
test -s ca.key
openssl x509 -in ca.crt -noout -checkend 2592000

if [ -s "$TANGO_PRIVATE_KEY" ] && [ -s "$TANGO_CERTIFICATE" ] &&
   openssl x509 -in "$TANGO_CERTIFICATE" -noout -checkend 2592000 &&
   openssl verify -CAfile ca.crt -verify_hostname "$TANGO_HOSTNAME" "$TANGO_CERTIFICATE"; then
  exit 0
fi

if [ ! -s "$TANGO_PRIVATE_KEY" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$TANGO_PRIVATE_KEY"
fi
openssl req -new -key "$TANGO_PRIVATE_KEY" -subj "/CN=$TANGO_HOSTNAME" -out server.csr
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth' \
  "subjectAltName=DNS:$TANGO_HOSTNAME" > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -set_serial "0x$(openssl rand -hex 16)" -days 90 -sha256 \
  -extfile server.ext -out "$TANGO_CERTIFICATE.new"
mv "$TANGO_CERTIFICATE.new" "$TANGO_CERTIFICATE"

# Nonblocking avoids a dependency cycle during nginx's initial start.
if systemctl is-active --quiet nginx.service; then
  systemctl reload --no-block nginx.service
fi
