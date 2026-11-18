#!/bin/sh
# F021 3.5 · The owner's iPhone and iPad, once (How's 1a): on each connected device, in one
# sitting, the name bench (NameBench) and the old rules' measure (DetectionMeasureTests, 2.4),
# so each device's baseline is its own. Made-up cases only; nothing is sent, nothing is read from
# the owner's sources, nothing is installed for good: the bench's host app is removed at the end.
#
# The owner: connect the iPhone and the iPad by cable, unlock both, trust this Mac, keep them
# awake. Then, in the repository: scripts/bench-devices.sh   (about half an hour)
# The logs land in .build/bench-devices/; the lead reads them and fills bench.md and 6-test-report.md.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
team=${TEAM:-2F7QR8NL2D}   # the app's own team, as in App/Causabee.xcodeproj
out="$root/.build/bench-devices"
mkdir -p "$out"

"$root/NameBench/copy.sh" >/dev/null
[ -d "$root/NameBench/Tests/NameBenchTests/Cases/Model/NameNER.mlmodelc" ] ||
    echo "No model in NameBench/Model/: the Core ML candidate will print \"not available there\"."

# The connected iPhones and iPads, by devicectl: physical ones only (a paired simulator is listed
# too, as "simulated"), udid, then the model's name.
xcrun devicectl list devices --json-output "$out/devices.json" >/dev/null
/usr/bin/python3 -I - "$out/devices.json" > "$out/devices.txt" <<'PY'
import json, re, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if (hw.get("platform") == "iOS" and hw.get("reality") == "physical"
            and cp.get("pairingState") == "paired" and hw.get("udid")):
        print(hw["udid"], re.sub(r"[^A-Za-z0-9]+", "-", hw.get("marketingName", hw.get("productType", "device"))).strip("-"))
PY
if [ ! -s "$out/devices.txt" ]; then
    echo "No paired iPhone or iPad is connected. Connect, unlock, trust this Mac, and run again."
    exit 1
fi
cat "$out/devices.txt"

# A device runs tests only inside an app ("Tool-hosted testing is unavailable on device
# destinations"). The host is NameBench/Host/BenchHost.xcodeproj, de.chille.causabee.bench: for
# measuring only, never part of Causabee. Its two test bundles take the same files as the Mac:
# NameBenchTests, and from DisguiseTests the measure and the tier set.
# Built once for every device, then run on each.
host="$root/NameBench/Host/BenchHost.xcodeproj"
dd="$out/xc-host"
sign="-allowProvisioningUpdates DEVELOPMENT_TEAM=$team CODE_SIGN_STYLE=Automatic"
# Xcode has no account signed in on this Mac: sign with the App Store Connect API key, as
# scripts/testflight.sh does (the newest key in ~/.appstoreconnect/private_keys, its issuer beside it).
key=${CAUSABEE_ASC_KEY:-$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1)}
if [ -n "$key" ]; then
    issuer=${CAUSABEE_ASC_ISSUER:-$(tr -d '[:space:]' < "$HOME/.appstoreconnect/issuer_id" 2>/dev/null)}
    key_id=$(basename "$key" .p8); key_id=${key_id#AuthKey_}
    sign="$sign -authenticationKeyPath $key -authenticationKeyID $key_id -authenticationKeyIssuerID $issuer"
fi
echo "== building the host and its tests (a few minutes) …"
xcodebuild build-for-testing -project "$host" -scheme BenchHost -destination 'generic/platform=iOS' \
    -derivedDataPath "$dd" $sign > "$out/build.log" 2>&1 ||
    { echo "   the build failed: see $out/build.log"; exit 1; }
run=$(ls "$dd"/Build/Products/*.xctestrun | head -1)

while read -r udid name; do
    echo "== $name ($udid)"
    rm -rf "$out/bench-$name.xcresult" "$out/measure-$name.xcresult"
    if [ -z "${MEASURE_ONLY:-}" ]; then   # MEASURE_ONLY=1: the rules' measure only, without the models' bench
    echo "   the bench …"
    xcodebuild test-without-building -xctestrun "$run" -destination "id=$udid" \
        -only-testing:NameBenchTests -resultBundlePath "$out/bench-$name.xcresult" \
        > "$out/bench-$name.log" 2>&1 && echo "   passed" || echo "   failed: see $out/bench-$name.log"
    fi
    echo "   the old rules' measure and the tier set …"
    xcodebuild test-without-building -xctestrun "$run" -destination "id=$udid" \
        -only-testing:MatterCoreHostTests/DetectionMeasureTests -only-testing:MatterCoreHostTests/DetectionTierSetTests \
        -resultBundlePath "$out/measure-$name.xcresult" \
        > "$out/measure-$name.log" 2>&1 && echo "   passed" || echo "   failed: see $out/measure-$name.log"
    # What the tests printed, should xcodebuild not show a device's console.
    for r in bench measure; do
        xcrun xcresulttool get log --type console --path "$out/$r-$name.xcresult" > "$out/$r-$name.console.txt" 2>/dev/null || true
    done
    xcrun devicectl device uninstall app --device "$udid" de.chille.causabee.bench >/dev/null 2>&1 || true
done < "$out/devices.txt"
echo "Done. Logs: $out"
