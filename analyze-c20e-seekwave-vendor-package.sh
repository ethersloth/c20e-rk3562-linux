#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-$PWD}"
ZIP="$REPO/wifi/new/SWT6621S_H26.6.2.1_F26.3.3.1.zip"
ACTIVE="$REPO/src/kernel/drivers/net/wireless/ea6621q"
OVERLAY="$REPO/overlay/drivers/net/wireless/ea6621q"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO/c20e-analysis/c20e-seekwave-vendor-audit-$STAMP"
EXTRACT="$REPORT/vendor-extracted"
LOG="$REPORT/full.log"

mkdir -p "$REPORT" "$EXTRACT"
exec > >(tee -a "$LOG") 2>&1

die(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo "[$(date -Is)] EXIT rc=$rc"; exit $rc' EXIT

echo "C20e Seekwave vendor-package audit: $(date -Is)"
echo "Repo:   $REPO"
echo "Vendor: $ZIP"
echo "Active: $ACTIVE"

[[ -f "$ZIP" ]] || die "vendor ZIP not found: $ZIP"
[[ -d "$ACTIVE" ]] || die "active Seekwave driver not found: $ACTIVE"
command -v unzip >/dev/null || die "unzip is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

echo
echo "===== 1/9 vendor package identity ====="
ls -lh "$ZIP" | tee "$REPORT/vendor-zip-ls.txt"
sha256sum "$ZIP" | tee "$REPORT/vendor-zip.sha256"
unzip -Z1 "$ZIP" > "$REPORT/vendor-file-list.txt"
printf 'Files in ZIP: '
wc -l < "$REPORT/vendor-file-list.txt"
sed -n '1,160p' "$REPORT/vendor-file-list.txt"

echo
echo "===== 2/9 extract vendor package read-only for analysis ====="
unzip -q "$ZIP" -d "$EXTRACT"
find "$EXTRACT" -type f -printf '%s\t%P\n' | sort -k2 > "$REPORT/vendor-files.txt"
du -sh "$EXTRACT" | tee "$REPORT/vendor-extracted-size.txt"

echo
echo "===== 3/9 identify driver trees ====="
find "$EXTRACT" -type d \( -name 'seekwaveplatform*' -o -name 'skwifi' -o -name 'swtbt4l' -o -name 'ea6621q' -o -name 'ea6x21q' \) -print | sort | tee "$REPORT/vendor-driver-dirs.txt"

echo
echo "===== 4/9 chip / compatible / firmware evidence ====="
grep -RInaE --include='*.c' --include='*.h' --include='Kconfig' --include='Makefile' \
    'SV6160LITE|SV6160|SWT6621S|SWT6621|EA6621|EA6521|seekwave,|CHIP_DEV_NAME|local_chip_id|check_chipid|IRAM|DRAM|nvbin|NV_' \
    "$EXTRACT" > "$REPORT/vendor-chip-evidence.txt" 2>/dev/null || true
sed -n '1,260p' "$REPORT/vendor-chip-evidence.txt"

echo
echo "===== 5/9 GPIO / SDIO / DMA evidence ====="
grep -RInaE --include='*.c' --include='*.h' \
    'gpio_host_wake|gpio_chip_wake|gpio_chip_en|HOST_WAKE|CHIP_WAKE|CHIP_EN|EBUSY|dma_map_sg|dma_unmap_sg|mmc_wait_for_req|sdio_register_driver|sdio_claim_host|sdio-pwrseq|pwrseq' \
    "$EXTRACT" > "$REPORT/vendor-sdio-gpio-dma-evidence.txt" 2>/dev/null || true
sed -n '1,320p' "$REPORT/vendor-sdio-gpio-dma-evidence.txt"

echo
echo "===== 6/9 version / build metadata ====="
grep -RInaE --include='*.c' --include='*.h' --include='Makefile' --include='Kconfig' --include='*.mk' \
    'VERSION|version|H26\.|F26\.|202[0-9]-|LINUX_VERSION_CODE|KERNEL_VERSION\(6|CONFIG_SKW|CONFIG_SEEKWAVE' \
    "$EXTRACT" > "$REPORT/vendor-version-evidence.txt" 2>/dev/null || true
sed -n '1,260p' "$REPORT/vendor-version-evidence.txt"

echo
echo "===== 7/9 firmware inventory and hashes ====="
find "$EXTRACT" -type f \( -iname '*.bin' -o -iname '*.nvbin' -o -iname '*.fw' \) -print0 \
    | sort -z \
    | xargs -0 -r sha256sum > "$REPORT/vendor-firmware.sha256"
cat "$REPORT/vendor-firmware.sha256"

{
    echo "=== Current repo firmware ==="
    find "$REPO/wifi" "$REPO/overlay/firmware" "$OVERLAY/swtbt4l" -maxdepth 3 -type f \
        \( -iname '*.bin' -o -iname '*.nvbin' -o -iname '*.fw' \) -print0 2>/dev/null \
        | sort -z | xargs -0 -r sha256sum
} > "$REPORT/current-firmware.sha256"
cat "$REPORT/current-firmware.sha256"

echo
echo "===== 8/9 compare vendor source with current active driver ====="
find "$ACTIVE" -type f -printf '%P\n' | sort > "$REPORT/active-driver-file-list.txt"

python3 - "$EXTRACT" "$ACTIVE" "$REPORT" <<'PY'
from pathlib import Path
import hashlib, sys

vendor_root = Path(sys.argv[1])
active = Path(sys.argv[2])
report = Path(sys.argv[3])

vendor_files = list(vendor_root.rglob("*"))
vendor_files = [p for p in vendor_files if p.is_file()]

def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

active_by_name = {}
for p in active.rglob("*"):
    if p.is_file():
        active_by_name.setdefault(p.name, []).append(p)

rows = []
same = changed = unique = 0
for vp in vendor_files:
    candidates = active_by_name.get(vp.name, [])
    if not candidates:
        unique += 1
        rows.append(("VENDOR_ONLY", str(vp.relative_to(vendor_root)), "", sha(vp)))
        continue

    vsha = sha(vp)
    exact = next((ap for ap in candidates if sha(ap) == vsha), None)
    if exact:
        same += 1
        rows.append(("IDENTICAL", str(vp.relative_to(vendor_root)), str(exact.relative_to(active)), vsha))
    else:
        changed += 1
        ap = candidates[0]
        rows.append(("DIFFERENT", str(vp.relative_to(vendor_root)), str(ap.relative_to(active)), vsha))

with (report / "vendor-vs-active.tsv").open("w") as f:
    f.write("status\tvendor_path\tactive_path\tvendor_sha256\n")
    for row in rows:
        f.write("\t".join(row) + "\n")

with (report / "vendor-vs-active-summary.txt").open("w") as f:
    f.write(f"vendor files examined: {len(vendor_files)}\n")
    f.write(f"identical basename+content matches: {same}\n")
    f.write(f"same basename but different content: {changed}\n")
    f.write(f"vendor-only basenames: {unique}\n")

print((report / "vendor-vs-active-summary.txt").read_text())
PY

echo
echo "--- Different source files ---"
awk -F'\t' '$1=="DIFFERENT"{print $2 "  <->  " $3}' "$REPORT/vendor-vs-active.tsv" | tee "$REPORT/vendor-different-files.txt" | sed -n '1,240p'

echo
echo "--- Vendor-only source/files ---"
awk -F'\t' '$1=="VENDOR_ONLY"{print $2}' "$REPORT/vendor-vs-active.tsv" | tee "$REPORT/vendor-only-files.txt" | sed -n '1,240p'

echo
echo "===== 9/9 package report ====="
tar -C "$REPO/c20e-analysis" -czf "$REPORT.tar.gz" "$(basename "$REPORT")"
sha256sum "$REPORT.tar.gz" | tee "$REPORT.tar.gz.sha256"

echo
echo "PASS: Seekwave vendor-package audit complete."
echo "No kernel, SD card, DTS, or driver source files were modified."
echo "Report archive: $REPORT.tar.gz"
echo "Report SHA256:  $REPORT.tar.gz.sha256"
