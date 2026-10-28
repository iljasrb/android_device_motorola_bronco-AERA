#!/usr/bin/env bash
# Publish the current recovery build to the download mirror and update the
# in-recovery update catalog.
#
#   scripts/publish.sh --dry-run     # default: print, change nothing
#   scripts/publish.sh --yes         # upload, latest/ replaced, previous in archive/
#
# Publishes the newest out/AERA-bronco-*.img and .zip plus catalog.json, the
# feed the in-recovery updater reads (schema 1).
#   scripts/publish.sh --yes --purge # drop older builds
#
# Files are uploaded into a staging directory and swapped into latest/ only after
# every one landed at the expected size, so an interrupted upload leaves the
# published build untouched.
#
# Target comes from .env.publish (gitignored) or the environment:
#   PUBLISH_HOST  ssh alias/host                                    (required)
#   PUBLISH_ROOT  directory served below the base url               (required)
#   PUBLISH_URL   public base url (default https://rom.flac.moe/bronco/recovery/aera)
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
baseurl=${PUBLISH_URL:-https://rom.flac.moe/bronco/recovery/aera}
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

# The ROM feed owns the site root (latest/, archive/). Refuse to publish there.
case $site in
    */recovery/aera) ;;
    *) echo "publish: PUBLISH_ROOT must end in /recovery/aera (got $site)" >&2; exit 2 ;;
esac
if [ "$dry" = 0 ] &&
   ssh "$host" "bash -lc \"ls $site/latest/Project_Infinity-* 2>/dev/null\"" | grep -q .; then
    echo "publish: $site/latest holds ROM builds, refusing to replace it" >&2
    exit 2
fi

run() { if [ "$dry" = 1 ]; then printf '  would: %s\n' "$*"; else "$@"; fi; }
rsh() { if [ "$dry" = 1 ]; then printf '  would: ssh %s bash -lc %s\n' "$host" "$*";
        else ssh "$host" "bash -lc \"$*\""; fi; }

img=$(ls -t "$out"/AERA-bronco-*.img 2>/dev/null | head -1)
zip=$(ls -t "$out"/AERA-bronco-*.zip 2>/dev/null | head -1)
[ -n "$img" ] || { echo "no AERA-bronco-*.img in $out" >&2; exit 1; }
[ -n "$zip" ] || { echo "no AERA-bronco-*.zip in $out (the updater installs the zip)" >&2; exit 1; }
img_name=$(basename "$img")
zip_name=$(basename "$zip")
build=${img_name#AERA-bronco-}; build=${build%%-*}

# The updater installs the referenced package as a zip and compares build_time
# with the value the installed image reports.
props=$(unzip -p "$zip" META-INF/debug/default.prop)
vars=$(unzip -p "$zip" META-INF/debug/fox_build_vars.txt)
build_time=$(sed -n 's/^ro\.build\.date\.utc_aera=//p' <<<"$props" | head -1)
build_type=$(sed -n 's/^AERA_BUILD_TYPE="\(.*\)"/\1/p' <<<"$vars")
version=$(sed -n 's/^AERA_INTERNAL_RELEASE="\(.*\)"/\1/p' <<<"$vars")
[ -n "$build_time" ] || { echo "no ro.build.date.utc_aera in $zip_name" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
( cd "$out" && md5sum "$img_name" "$zip_name" >"$tmp/MD5SUMS" )
( cd "$out" && sha256sum "$img_name" "$zip_name" >"$tmp/SHA256SUMS" )
sha_zip=$(awk -v f="$zip_name" '$2 == f { print $1 }' "$tmp/SHA256SUMS")

catalog=catalog.json
[ "$build_type" = Nightly ] && catalog=catalog-nightly.json
python3 - "$tmp/$catalog" "$baseurl" "$version" "$build_type" "$build_time" \
         "$zip_name" "$zip" "$sha_zip" <<'PY'
import json, os, sys
dst, base, version, build_type, build_time, name, path, sha = sys.argv[1:9]
doc = {"schema": 1,
       "devices": {"bronco": {
           "version": version,
           "build_type": build_type,
           "build_time": int(build_time),
           "filename": name,
           "size": os.path.getsize(path),
           "sha256": sha,
           "ota_url": f"{base}/latest/{name}"}}}
json.dump(doc, open(dst, 'w'), indent=2)
open(dst, 'a').write("\n")
PY

python3 - "$tmp/latest.json" "$baseurl" "$build" "$img" "$zip" <<'PY'
import datetime, hashlib, json, os, sys
dst, base, build, img, zpath = sys.argv[1:6]
def entry(path):
    return {"url": f"{base}/latest/{os.path.basename(path)}",
            "size": os.path.getsize(path),
            "sha256": hashlib.sha256(open(path, 'rb').read()).hexdigest()}
doc = {"build": build, "published": datetime.date.today().isoformat(),
       "image": entry(img), "installer": entry(zpath)}
json.dump(doc, open(dst, 'w'), indent=2)
open(dst, 'a').write("\n")
PY

echo "publishing $img_name + $zip_name as $build ($build_type $version, $build_time)"
[ "$dry" = 1 ] && echo "  target $host:$site"
run rsh "mkdir -p $stage"

rsync_opts=(-ah --partial)
[ -t 1 ] && rsync_opts+=(--info=progress2)
run rsync "${rsync_opts[@]}" "$img" "$zip" \
    "$tmp/MD5SUMS" "$tmp/SHA256SUMS" "$tmp/latest.json" "$tmp/$catalog" "$host:$stage/"

for f in "$img_name" "$zip_name"; do
    local_size=$(stat -c %s "$out/$f")
    if [ "$dry" = 1 ]; then
        printf '  would: check %s is %s bytes on the server\n' "$f" "$local_size"
        continue
    fi
    remote_size=$(ssh "$host" "bash -lc \"stat -c %s $stage/$f\"" 2>/dev/null || echo 0)
    [ "$remote_size" = "$local_size" ] ||
        { echo "upload incomplete: $f $remote_size of $local_size bytes; latest/ untouched" >&2; exit 1; }
    echo "  ok $f ($local_size bytes)"
done

if [ "$purge" = 1 ]; then
    rsh "rm -rf $site/archive && mv $stage/$catalog $site/$catalog && mv $stage $site/latest"
else
    rsh "mkdir -p $site/archive && rm -rf $site/archive/$build &&
         mv $stage/$catalog $site/$catalog &&
         { [ -d $site/latest ] && mv $site/latest $site/archive/$build || true; } &&
         mv $stage $site/latest"
fi

if [ "$dry" = 1 ]; then
    echo "  would: curl -sIL $baseurl/latest/$zip_name"
    echo "  would: curl -sf $baseurl/$catalog"
    exit 0
fi

want=$(stat -c %s "$out/$zip_name"); url=$baseurl/latest/$zip_name
got=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
[ "$got" = "$want" ] || { echo "verify FAILED: $url serves $got bytes, want $want" >&2; exit 1; }
echo "verified: $url ($got bytes)"
curl -sf "$baseurl/$catalog" >/dev/null || { echo "catalog not served: $baseurl/$catalog" >&2; exit 1; }
echo "verified: $baseurl/$catalog"
