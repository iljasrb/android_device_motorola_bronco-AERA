#!/usr/bin/env bash
# Publish the current recovery build to the download mirror.
#
#   scripts/publish.sh --dry-run     # default: print, change nothing
#   scripts/publish.sh --yes         # upload, latest/ replaced, previous in archive/
#   scripts/publish.sh --yes --purge # drop older builds
#
# Uploads into a staging directory and swaps it into latest/ only after every
# file landed at the expected size, so an interrupted upload leaves the
# published build untouched.
#
# Target comes from .env.publish (gitignored) or the environment:
#   PUBLISH_HOST  ssh alias/host                                    (required)
#   PUBLISH_ROOT  directory served below the base url               (required)
#   PUBLISH_URL   public base url (default https://rom.flac.moe/bronco/recovery/AERA)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/out

if [ -f "$root/.env.publish" ]; then
    while IFS='=' read -r k v; do
        case $k in PUBLISH_*) [ -n "${!k:-}" ] || export "$k=$v" ;; esac
    done < <(grep -v '^#' "$root/.env.publish")
fi
host=${PUBLISH_HOST:?publish: set PUBLISH_HOST (see .env.publish)}
site=${PUBLISH_ROOT:?publish: set PUBLISH_ROOT (see .env.publish)}
baseurl=${PUBLISH_URL:-https://rom.flac.moe/bronco/recovery/AERA}
stage=$site/_staging

dry=1 purge=0
for a in "$@"; do
    case $a in
        --dry-run) dry=1 ;;
        --yes|-y) dry=0 ;;
        --purge) purge=1 ;;
        *) echo "usage: $0 [--yes] [--purge] [--dry-run]" >&2; exit 2 ;;
    esac
done

run() { if [ "$dry" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }
rsh() { if [ "$dry" = 1 ]; then printf '  would: ssh %s bash -lc %s\n' "$host" "$*";
        else ssh "$host" "bash -lc \"$*\""; fi; }

img=$(ls -t "$out"/AERA-bronco-#*.img 2>/dev/null | head -1)
zip=$(ls -t "$out"/AERA-bronco-#*.zip 2>/dev/null | head -1)
[ -n "$img" ] || { echo "no AERA-bronco-#*.img in $out" >&2; exit 1; }
img_name=$(basename "$img")
zip_name=$(basename "$zip")
build=${img_name#AERA-bronco-}; build=${build%%-*}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
files=("$img")
[ -n "$zip" ] && files+=("$zip")
( cd "$out" && md5sum "${img_name}" ${zip:+$zip_name} >"$tmp/MD5SUMS" )
( cd "$out" && sha256sum "${img_name}" ${zip:+$zip_name} >"$tmp/SHA256SUMS" )

python3 - "$tmp/latest.json" "$baseurl" "$build" "$img" "${zip:-}" <<'PY'
import json, sys, hashlib, os, datetime
dst, base, build, img, zip_path = sys.argv[1:6]
def entry(path):
    sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    return {"url": f"{base}/latest/{os.path.basename(path)}",
            "size": os.path.getsize(path), "sha256": sha}
doc = {"build": build, "published": datetime.date.today().isoformat(),
       "image": entry(img)}
if zip_path:
    doc["installer"] = entry(zip_path)
json.dump(doc, open(dst, 'w'), indent=2)
open(dst, 'a').write("\n")
PY

echo "publishing $img_name${zip:+ + $zip_name} as $build"
if [ "$dry" = 1 ]; then
    echo "  target $host:$site"
fi
run rsh "mkdir -p $stage"

rsync_opts=(-ah --partial)
[ -t 1 ] && rsync_opts+=(--info=progress2)
run rsync "${rsync_opts[@]}" "${files[@]}" \
    "$tmp/MD5SUMS" "$tmp/SHA256SUMS" "$tmp/latest.json" "$host:$stage/"

for f in "${files[@]}"; do
    local_size=$(stat -c %s "$f")
    if [ "$dry" = 1 ]; then
        printf '  would: check %s is %s bytes on the server\n' "$(basename "$f")" "$local_size"
        continue
    fi
    remote_size=$(ssh "$host" "bash -lc \"stat -c %s $stage/$(basename "$f")\"" 2>/dev/null || echo 0)
    [ "$remote_size" = "$local_size" ] ||
        { echo "upload incomplete: $(basename "$f") $remote_size of $local_size bytes; latest/ untouched" >&2; exit 1; }
    echo "  ok $(basename "$f") ($local_size bytes)"
done

if [ "$purge" = 1 ]; then
    rsh "rm -rf $site/archive && mv $stage $site/latest"
else
    rsh "mkdir -p $site/archive && rm -rf $site/archive/$build &&
         { [ -d $site/latest ] && mv $site/latest $site/archive/$build || true; } &&
         mv $stage $site/latest"
fi

if [ "$dry" = 0 ]; then
    want=$(stat -c %s "$img"); url=$baseurl/latest/$img_name
    got=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
    [ "$got" = "$want" ] || { echo "verify FAILED: $url serves $got bytes, want $want" >&2; exit 1; }
    echo "verified: $url ($got bytes)"
else
    echo "  would: curl -sIL $baseurl/latest/$img_name"
fi
