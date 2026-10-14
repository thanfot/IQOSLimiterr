#!/bin/bash
# Build + εγκατάσταση + εκκίνηση της iOS έκδοσης στο iPhone σου, με μία εντολή.
#
#   ./deploy-ios.sh            → πρώτη διαθέσιμη συσκευή
#   ./deploy-ios.sh Thanfot    → συγκεκριμένη συσκευή (case-insensitive)
#
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
DEVICE_NAME="${1:-}"

# ── 1. Βρες το iPhone ──
DEVICES=$(xcrun devicectl list devices 2>/dev/null | awk '$4=="available"||$4=="connected"{print $1"\t"$3}')
[ -z "$DEVICES" ] && { echo "❌ Κανένα iPhone συνδεδεμένο"; exit 1; }

if [ -n "$DEVICE_NAME" ]; then
    UUID=$(xcrun devicectl list devices 2>/dev/null \
        | awk -v n="$DEVICE_NAME" 'tolower($1)==tolower(n) && ($4=="available"||$4=="connected"){print $3; exit}')
    [ -z "$UUID" ] && { echo "❌ Δεν βρέθηκε συσκευή '$DEVICE_NAME'"; xcrun devicectl list devices; exit 1; }
else
    UUID=$(echo "$DEVICES" | cut -f2 | head -1)
fi
echo "▸ Συσκευή: $UUID"

# ── 2. Τυχαίο admin PIN ──
# Δημιουργείται μία φορά και μένει στο ~/.iqoslimiter-pin (εκτός repo). Στο app πάει μόνο το hash.
PIN_FILE="$HOME/.iqoslimiter-pin"
if [ ! -s "$PIN_FILE" ]; then
    (umask 077; LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 6 > "$PIN_FILE") || true
    echo "▸ Νέο τυχαίο PIN αποθηκεύτηκε στο $PIN_FILE"
fi
ADMIN_PIN_HASH=$(printf '%s' "iqoslimiter$(cat "$PIN_FILE")" | shasum -a 256 | cut -d' ' -f1)

# ── 3. Build ──
echo "▸ Build…"
cd "$PROJECT_DIR"
xcodebuild -project IQOSLimiter.xcodeproj -scheme IQOSLimiter-iOS -configuration Debug \
    -destination "id=$UUID" -allowProvisioningUpdates ADMIN_PIN_HASH="$ADMIN_PIN_HASH" build \
    | grep -E "error:|warning: .*[Pp]rovision|BUILD" || true

APP=$(find ~/Library/Developer/Xcode/DerivedData/IQOSLimiter-*/Build/Products/Debug-iphoneos \
      -maxdepth 1 -name "IQOSLimiter-iOS.app" | head -1)
[ -z "$APP" ] && { echo "❌ Δεν βρέθηκε το .app — μάλλον απέτυχε το build"; exit 1; }

# ── 4. Install ──
echo "▸ Εγκατάσταση…"
xcrun devicectl device install app --device "$UUID" "$APP" | grep -iE "installed|error"

# ── 5. Launch ──
BUNDLE="com.yourname.iqoslimiter.ios"
echo "▸ Εκκίνηση…"
xcrun devicectl device process launch --device "$UUID" --terminate-existing "$BUNDLE" \
    | grep -iE "launched|error|failed" || echo "  (ξεκίνησε — έλεγξε την οθόνη)"

echo "✅ Έτοιμο"