#!/usr/bin/env bash
# The companion room's bundled character pack (whale-girl.zip). It is kept out
# of the repository on purpose (the model's terms, see docs/design/companion.md
# §3), so release builds take it from this machine: a copy already in the tree,
# else $DSH_COMPANION_PACK_FILE, default ~/keys/dshgo-companion-pack.zip.
# Every release APK/IPA must carry her — a release without the pack is exactly
# what shipped in 1.1.0 after the release machine lost its copy. Sourced by
# tooling/build-apk.sh and tooling/ios/release-testflight.sh.
#
#   companion_pack_source <app-dir>   print the pack's path, touch nothing
#   companion_pack_place <app-dir>    make <app-dir>/assets/companion/whale-girl.zip exist
#   companion_pack_verify <archive>   check a built APK/IPA actually carries it

companion_pack_name='whale-girl.zip'
# The one path tail both containers share: an APK entry is
# assets/flutter_assets/…, an ipa entry Payload/Runner.app/Frameworks/App.framework/….
companion_pack_match='flutter_assets/assets/companion/whale-girl.zip'

companion_pack_source() {
  local app_dir=$1
  local dest="$app_dir/assets/companion/$companion_pack_name"
  [[ -f $dest ]] && { printf '%s' "$dest"; return 0; }
  local stash=${DSH_COMPANION_PACK_FILE:-$HOME/keys/dshgo-companion-pack.zip}
  [[ -f $stash ]] && { printf '%s' "$stash"; return 0; }
  return 1
}

companion_pack_place() {
  local app_dir=$1
  local dest="$app_dir/assets/companion/$companion_pack_name"
  local from
  from=$(companion_pack_source "$app_dir") || {
    echo "companion pack: not found. Put the zip at ~/keys/dshgo-companion-pack.zip or point DSH_COMPANION_PACK_FILE at it. A release without her is how 1.1.0 shipped." >&2
    return 1
  }
  if [[ $from == "$dest" ]]; then
    echo "companion pack: using the copy already in the tree ($(du -h "$dest" | cut -f1))"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$from" "$dest"
    echo "companion pack: copied $from → $dest ($(du -h "$dest" | cut -f1))"
  fi
}

companion_pack_verify() {
  local archive=$1
  if ! python3 - "$archive" "$companion_pack_match" <<'PY'
import hashlib, sys, zipfile

archive, match = sys.argv[1], sys.argv[2]
try:
    z = zipfile.ZipFile(archive)
except Exception as exc:
    print(f"{archive}: not a readable archive ({exc})", file=sys.stderr)
    sys.exit(1)
hits = [n for n in z.namelist() if n.endswith(match)]
if not hits:
    print(f"{archive}: no {match} inside", file=sys.stderr)
    sys.exit(1)
data = z.read(hits[0])
print(f"companion pack in {archive}: {hits[0]} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:16]}…)")
PY
  then
    echo "companion pack: refusing to ship $archive without her" >&2
    return 1
  fi
}
