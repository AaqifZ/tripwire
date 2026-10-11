#!/bin/sh
# Create a local code-signing certificate "tripwire-local" in the login keychain (one time per Mac).
# Why: macOS ties Input Monitoring access to the binary's signature. An ad-hoc signature
# changes on every build, so each reinstall loses the permission. A fixed certificate keeps it.
set -e
security find-identity -p codesigning | grep -q tripwire-local && { echo "tripwire-local exists"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cs.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=tripwire-local
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$tmp/k" -out "$tmp/c" -config "$tmp/cs.cnf" 2>/dev/null
# OpenSSL 3 needs -legacy so the macOS keychain can read the file. LibreSSL (in macOS) has no such flag.
legacy=""; openssl pkcs12 -help 2>&1 | grep -q -- -legacy && legacy=-legacy
openssl pkcs12 -export $legacy -inkey "$tmp/k" -in "$tmp/c" -name tripwire-local -out "$tmp/p12" -passout pass:tw
security import "$tmp/p12" -k ~/Library/Keychains/login.keychain-db -P tw -T /usr/bin/codesign
echo "tripwire-local created"
