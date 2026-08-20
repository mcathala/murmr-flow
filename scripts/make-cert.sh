#!/usr/bin/env bash
#
# Create a persistent self-signed code signing certificate named "MurmrDev".
#
# ONLY NEEDED IF you have no Apple Development or Developer ID certificate. Check
# first:
#
#     security find-identity -v -p codesigning
#
# If that lists an "Apple Development: …" identity, you already have something
# better — build.sh will pick it up automatically and you can skip this script. A
# real Apple certificate carries a Team ID, which is what keeps TCC permissions
# stable; a self-signed cert has no Team ID and relies on the signature staying
# byte-stable instead.
#
# What this fixes: ad-hoc signing (`codesign -s -`) produces a new identity on every
# build, so macOS forgets your microphone and accessibility grants each time you
# rebuild. A persistent certificate stops that.
#
# This is for LOCAL DEVELOPMENT ONLY. The certificate is untrusted on every other
# machine, so it is not a distribution solution.

set -euo pipefail

CERT_NAME="MurmrDev"
DAYS=3650
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Bail out early if something better already exists
# ---------------------------------------------------------------------------
EXISTING="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -E "Developer ID Application|Apple Development" | head -1 || true)"
if [ -n "$EXISTING" ]; then
    bold "You already have a better certificate:"
    printf '  %s\n\n' "$(printf '%s' "$EXISTING" | sed -E 's/.*"(.*)".*/\1/')"
    printf 'It has a real Team ID, which is the most reliable way to keep TCC grants\n'
    printf 'stable. build.sh prefers it automatically — no need to run this script.\n\n'
    printf 'Continue anyway and create "%s"? [y/N] ' "$CERT_NAME"
    read -r reply
    case "$reply" in [yY]*) ;; *) printf 'Aborted.\n'; exit 0 ;; esac
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    bold "Certificate \"$CERT_NAME\" already exists — nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------
bold "Generating self-signed code signing certificate \"$CERT_NAME\"…"

# The codeSigning extended key usage is what makes this usable by `codesign`.
cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $CERT_NAME

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" \
    -out "$WORK/cert.pem" \
    -days "$DAYS" \
    -config "$WORK/openssl.cnf" 2>/dev/null

openssl pkcs12 -export \
    -inkey "$WORK/key.pem" \
    -in "$WORK/cert.pem" \
    -name "$CERT_NAME" \
    -out "$WORK/cert.p12" \
    -passout pass: 2>/dev/null

# ---------------------------------------------------------------------------
# Import into the login keychain
# ---------------------------------------------------------------------------
bold "Importing into your login keychain…"
security import "$WORK/cert.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# ---------------------------------------------------------------------------
# Trust it for code signing
# ---------------------------------------------------------------------------
echo
bold "Trusting it for code signing (needs your admin password)…"
warn "This runs: sudo security add-trusted-cert -d -r trustRoot -p codeSign …"
if sudo security add-trusted-cert -d -r trustRoot -p codeSign \
        -k /Library/Keychains/System.keychain "$WORK/cert.pem"; then
    printf '\033[32m  ✓ trusted\033[0m\n'
else
    echo
    warn "Automatic trust failed. Set it by hand:"
    warn "  1. Open Keychain Access"
    warn "  2. Find \"$CERT_NAME\" in the login keychain"
    warn "  3. Double-click it, expand Trust"
    warn "  4. Set \"Code Signing\" to \"Always Trust\""
fi

echo
bold "Done."
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo
printf 'build.sh will now find it automatically. Or force it explicitly:\n'
printf '  SIGNING_IDENTITY="%s" ./scripts/build.sh\n\n' "$CERT_NAME"
