#!/usr/bin/env bash
# Build the FuzzCorp bundle for the Exponent Core crucible harness.
#
# Usage:
#   ./build-bundle.sh                  # full build, writes ./bundle
#   ./build-bundle.sh --manifest-only  # regenerate ./bundle/manifest.fc.json only
#
# targets.txt is the source of truth: one `svm <crate> <feature>` line per
# DISCOVERY lineage. Regression harnesses (regr_*) belong in a CI compile gate,
# never as a bundle lineage. The manifest is generated from it and never
# committed, so the two cannot drift.
#
# Four constraints here are load-bearing; each cost a failed remote campaign:
#
#  1. ARCH. Workers are linux/amd64 and the harness must be STATIC. A glibc build
#     uploads fine and then dies on the worker with a bare `status 1` (the host's
#     glibc is newer than the container's). Build with the musl target so the
#     binary carries no dynamic loader at all. Verify: `file` must say
#     "statically linked", not "dynamically linked".
#
#  2. --features. Without it the binary starts, selects no fuzz test, prints
#     "No fuzz test selected" and exits 0 -- a green run that fuzzed nothing.
#
#  3. TOOLS VERSION for the target program: --tools-version v1.51 is required.
#     The default toolchain leaves CollectInterest::try_accounts 16 bytes over
#     Solana's 4 KB stack frame, silently corrupting deserialized accounts and
#     manufacturing fake protocol bugs. (mock_sy is the opposite -- it must NOT
#     use v1.51, whose linker rejects edition2024 -- so it is built separately.)
#
#  4. SourcesOriginalPath must equal the DWARF comp_dir prefix of the SF: lines
#     in the coverage LCOV. Ours is "programs/", with bundle/srcs/ mirroring it
#     as srcs/<crate>/src/... A wrong prefix does NOT error the campaign -- it
#     silently yields lines_found: 0. Verify after upload with `fuzz list cover`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle="$here/bundle"
targets="$here/targets.txt"

# Two layouts must both work:
#   in-repo (the deliverable): fuzz/crucible/ -> repo root is $here/../..
#   dev checkout: the harness sits as a SIBLING of the client repo
# Pick whichever actually contains the program crate rather than assuming one.
for candidate in "$here/../.." "$here/../../exponent-core"; do
  if [[ -f "$candidate/programs/exponent_core/Cargo.toml" ]]; then
    repo="$(cd "$candidate" && pwd)"; break
  fi
done
[[ -n "${repo:-}" ]] || { echo "cannot locate programs/exponent_core from $here" >&2; exit 1; }

MODE="${1:-build}"

HARNESS_TARGET="x86_64-unknown-linux-musl"

# CI passes the commit being fuzzed (github.sha); locally fall back to repo HEAD.
commit="${FUZZ_REVISION:-$(git -C "$repo" rev-parse HEAD)}"
commit="${commit:0:7}"

# ---------------------------------------------------------------- manifest ---
# Generated from targets.txt so the two can never drift.
gen_manifest() {
  local commit_value="$1"
  python3 - "$targets" "$commit_value" <<'PY'
import json, sys
targets_path, commit = sys.argv[1], sys.argv[2]
lineages = []
for raw in open(targets_path, encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    kind, crate, feature = line.split()
    if kind != "svm":
        raise SystemExit(f"unsupported target kind {kind!r}")
    lineages.append({
        "name": f"{crate}__{feature}",
        # P-0003 and P-0011 are already-written-up confirmed findings (issue-02 and
        # issue-06). Left unmuted they fire thousands of times on the SAME known
        # defect and bury every other property's first finding.
        "env": {"SCOUT_CHECK_MUTE": "P-0003,P-0011"},
        "confs": [{
            "name": "explore",
            "driver": {"type": "crucible", "params": {
                "binary_path_in_bundle":    f"bin/{crate}/{feature}",
                # The harness opens its program via a CWD-relative path, so it must
                # run from bin/<crate>/ for programs/ and fixtures/ to resolve.
                "harness_run_dir_in_bundle": f"bin/{crate}",
                "symbols_path_in_bundle":   f"symbols/{crate}.debug.so",
                "sources_path_in_bundle":   "srcs",
                "sources_original_path":   "programs/",
            }},
            "architecture": {"name": "amd64", "extensions": []},
            "memory_kib": 2097152, "cores": 1,
            "stall_time_minutes": 0, "yield_time_minutes": 120,
        }],
    })
manifest = {
    "version": 3,
    "revision": {"commit": commit, "checkouts": {}},
    "lineages": lineages,
}
print(json.dumps(manifest, indent=2))
PY
}

# The manifest is always GENERATED from targets.txt, never committed, so the two
# cannot drift and there is nothing to keep in sync. bundle/ is gitignored.
if [[ "$MODE" == "--manifest-only" ]]; then
  mkdir -p "$bundle"
  gen_manifest "$commit" > "$bundle/manifest.fc.json"
  echo "[build-bundle] wrote $bundle/manifest.fc.json (commit $commit)"
  exit 0
fi

# ------------------------------------------------------------ 1. harness -----
rustup target add "$HARNESS_TARGET" >/dev/null 2>&1 || true

# Some transitive deps build C, and cc-rs looks for `x86_64-linux-musl-gcc`.
# Debian/Ubuntu's `musl-tools` installs it as plain `musl-gcc`, so without this
# the CI build dies with `failed to find tool "x86_64-linux-musl-gcc"`. Point
# both the C compiler and the linker at whichever name actually exists.
if ! command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
  if command -v musl-gcc >/dev/null 2>&1; then
    export CC_x86_64_unknown_linux_musl="${CC_x86_64_unknown_linux_musl:-musl-gcc}"
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="${CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER:-musl-gcc}"
    echo "[build-bundle] using musl-gcc for $HARNESS_TARGET"
  else
    echo "ERROR: no musl C toolchain found (need musl-gcc or x86_64-linux-musl-gcc)." >&2
    echo "       Debian/Ubuntu: apt-get install -y musl-tools" >&2
    echo "       macOS:         brew install FiloSottile/musl-cross/musl-cross" >&2
    exit 1
  fi
fi

while read -r raw; do
  line="${raw%%#*}"; line="$(echo "$line" | xargs || true)"
  [[ -z "$line" ]] && continue
  read -r kind crate feature <<<"$line"
  echo "[build-bundle] building $crate --features $feature ($HARNESS_TARGET)"
  ( cd "$here" && cargo build --release \
      --target "$HARNESS_TARGET" --features "$feature" )

  bin_src="$here/target/$HARNESS_TARGET/release/$feature"
  [[ -f "$bin_src" ]] || { echo "missing built binary $bin_src" >&2; exit 1; }

  # Constraint 1: refuse to ship a dynamically linked harness.
  # `file` says "statically linked" for a classic static ELF but "static-pie
  # linked" for a position-independent one -- and musl produces the PIE form.
  # Both are static; only "dynamically linked" is the failure. Matching the
  # literal "statically linked" rejected a perfectly good binary.
  if ! file "$bin_src" | grep -qE 'statically linked|static-pie linked'; then
    echo "ERROR: $bin_src is not statically linked -- it will die on the worker" >&2
    file "$bin_src" >&2
    exit 1
  fi

  mkdir -p "$bundle/bin/$crate"
  install -m 0755 "$bin_src" "$bundle/bin/$crate/$feature"
done < "$targets"

# ------------------------------------------------- 2. target program + DWARF -
# One invocation produces both artifacts so their PCs match: the stripped deploy
# .so is EXECUTED, the unstripped intermediate carries the DWARF. The unstripped
# one is NOT loadable ("Unknown symbol with index 38") -- never execute it.
echo "[build-bundle] building exponent_core.so (tools v1.51, debug=2, strip=none)"
sbf_log="$here/.build-sbf.log"
# Marker to prove the DWARF artifact came from THIS build. Do not compare it
# against target/deploy: build-sbf writes the unstripped intermediate FIRST and
# derives deploy/ from it, so deploy is always the newer of the two and a
# "not older than deploy" test can essentially never pass.
build_marker="$here/.build-start"
: > "$build_marker"
CARGO_PROFILE_RELEASE_DEBUG=2 CARGO_PROFILE_RELEASE_STRIP=none \
  cargo build-sbf --tools-version v1.51 \
    --manifest-path "$repo/programs/exponent_core/Cargo.toml" 2>&1 | tee "$sbf_log"

# `cargo build-sbf` prints this ON STDOUT WHILE EXITING 0. A binary with an
# overwritten stack frame null-derefs where the real program does not, so whole
# instruction families read as unreachable and any crash on an affected path is
# an artefact. Refuse to bundle one.
overwrites="$(grep -c 'overwrites values in the frame' "$sbf_log" || true)"
if [[ "$overwrites" -ne 0 ]]; then
  echo "ERROR: build-sbf reported $overwrites frame overwrites -- the .so is not trustworthy" >&2
  grep 'overwrites values in the frame' "$sbf_log" >&2
  exit 1
fi
echo "[build-bundle] frame-overwrite diagnostics: 0"

mkdir -p "$bundle/bin/exponent_core/programs" "$bundle/symbols"
exec_so="$repo/target/deploy/exponent_core.so"
install -m 0644 "$exec_so" "$bundle/bin/exponent_core/programs/exponent_core.so"

# The unstripped intermediate carrying the DWARF lives under a target-triple dir
# whose NAME DEPENDS ON THE TOOLCHAIN AND THE CLI. v1.51 alone ships
# sbf-solana-solana, sbpf-solana-solana AND sbpfv1..v4-solana-solana, and which
# one `cargo build-sbf` selects depends on the CLI driving it -- an agave 4.x CLI
# does not pick the same triple a 2.1.x CLI does. Enumerating a fixed list found
# NOTHING on CI. Glob instead, and pick the newest artifact that is not older
# than the executed .so, so the DWARF always belongs to the build being shipped.
symbols_so=""
while IFS= read -r cand; do
  [[ -f "$cand" ]] || continue
  # Accept on either of two proofs that this artifact belongs with the executed
  # .so: (a) it is newer than the marker, i.e. this build produced it; or (b) its
  # mtime is within a couple of minutes of deploy's, i.e. a fully CACHED build
  # rewrote neither and the two still come from the same compile. Requiring only
  # (a) false-fails a cache hit; requiring only "newer than deploy" can never pass,
  # because build-sbf derives deploy FROM the intermediate and so deploy is always
  # the newer of the two.
  if [[ "$cand" -nt "$build_marker" ]]; then symbols_so="$cand"; break; fi
  c_t=$(date -r "$cand" +%s 2>/dev/null || stat -c %Y "$cand" 2>/dev/null || echo 0)
  e_t=$(date -r "$exec_so" +%s 2>/dev/null || stat -c %Y "$exec_so" 2>/dev/null || echo 0)
  if [[ $(( c_t > e_t ? c_t - e_t : e_t - c_t )) -le 120 ]]; then
    symbols_so="$cand"
    echo "[build-bundle] cached build: symbols mtime within 120s of the executed .so"
    break
  fi
done < <(find "$repo/target" -name 'exponent_core.so' -not -path '*/deps/*' \
           -not -path '*/deploy/*' 2>/dev/null | xargs -r ls -t 2>/dev/null)
if [[ -z "$symbols_so" ]]; then
  echo "ERROR: no unstripped exponent_core.so was produced by this build." >&2
  echo "       DWARF symbols would come from a different build than the one being" >&2
  echo "       executed, which silently yields meaningless coverage." >&2
  echo "       Every exponent_core.so under target/ (marker: $(date -r "$build_marker" 2>/dev/null)):" >&2
  find "$repo/target" -name 'exponent_core.so' -not -path '*/deps/*' 2>/dev/null \
    | while IFS= read -r f; do echo "         $(date -r "$f" '+%H:%M:%S' 2>/dev/null)  $f" >&2; done
  exit 1
fi
rm -f "$build_marker"
echo "[build-bundle] DWARF symbols from ${symbols_so#$repo/}"
install -m 0644 "$symbols_so" "$bundle/symbols/exponent_core.debug.so"

# ------------------------------------------------------------ 3. fixtures ----
mkdir -p "$bundle/bin/exponent_core/fixtures"
for so in mock_sy mpl_token_metadata; do
  install -m 0644 "$here/fixtures/$so.so" \
                  "$bundle/bin/exponent_core/fixtures/$so.so"
done

# ------------------------------------------------------------ 4. sources -----
# Constraint 4: mirror the comp_dir prefix. SF: lines are programs/<crate>/src/...
# so SourcesOriginalPath is "programs/" and srcs/ holds <crate>/src/...
rm -rf "$bundle/srcs" "$bundle/libraries"
mkdir -p "$bundle/srcs"
for crate_dir in "$repo"/programs/*/; do
  crate_name="$(basename "$crate_dir")"
  [[ -d "$crate_dir/src" ]] || continue
  mkdir -p "$bundle/srcs/$crate_name"
  cp -R "$crate_dir/src" "$bundle/srcs/$crate_name/src"
done

# The program also compiles the workspace's `libraries/*` crates -- the fixed-point
# math (`precise_number`, `time_curve`, `sy_common`, `amount_value`) that the yield
# arithmetic actually runs through. Those LCOV records are emitted as
# `libraries/<crate>/src/...`, which does NOT start with SourcesOriginalPath.
#
# Per the driver (fuzzcorp lib/coverage/lcov/lcov.go:245-263, `Info.Replace`): a
# record whose key does not have the prefix is kept with its key UNCHANGED, and is
# then resolved relative to the BUNDLE ROOT -- not under SourcesPathInBundle. So
# these must be staged at bundle/libraries/, mirroring the repo layout. Without
# this the lines are measured and then silently dropped: 608 covered lines of the
# math crates rendered as nothing.
if [[ -d "$repo/libraries" ]]; then
  mkdir -p "$bundle/libraries"
  for lib_dir in "$repo"/libraries/*/; do
    lib_name="$(basename "$lib_dir")"
    [[ -d "$lib_dir/src" ]] || continue
    mkdir -p "$bundle/libraries/$lib_name"
    cp -R "$lib_dir/src" "$bundle/libraries/$lib_name/src"
  done
  echo "[build-bundle] staged $(find "$bundle/libraries" -name '*.rs' | wc -l | tr -d ' ') library source files at the bundle root"
fi

# ------------------------------------------- 4b. fail-closed sanity gates ----
# Both failure modes below are SILENT: the bundle validates, uploads and runs,
# and simply produces nothing. They are only observable days later as an empty
# dashboard, so they are checked here rather than trusted.

# GATE A -- the harness must actually have a fuzz test compiled in. Built without
# `--features <feature>` the binary starts, selects no test, prints "No fuzz test
# selected" and exits 0: a green campaign that fuzzed nothing.
_strings() { strings -a "$1" 2>/dev/null || grep -a -o '[[:print:]]\{4,\}' "$1" 2>/dev/null; }
while read -r raw; do
  line="${raw%%#*}"; line="$(echo "$line" | xargs || true)"
  [[ -z "$line" ]] && continue
  read -r kind crate feature <<<"$line"
  if ! _strings "$bundle/bin/$crate/$feature" | grep -q "$feature"; then
    echo "ERROR: '$feature' does not appear in bin/$crate/$feature." >&2
    echo "       The fuzz test is not registered -- the campaign would run and find" >&2
    echo "       nothing while reporting success. Was --features $feature passed?" >&2
    exit 1
  fi
done < "$targets"
echo "[build-bundle] fuzz test registered in every harness binary"

# GATE B -- source-level coverage must be able to resolve. Crucible keys each LCOV
# line on comp_dir + relative path, strips SourcesOriginalPath, and looks the rest
# up under SourcesPathInBundle. A wrong prefix or a missing srcs/ tree does not
# error: it yields lines_found: 0. Verify the mapping actually lands on real files.
missing=0; checked=0
while read -r src; do
  [[ -z "$src" ]] && continue
  if [[ "$src" == programs/* ]]; then
    # Prefixed records are rewritten to SourcesPathInBundle.
    dest="$bundle/srcs/${src#programs/}"
  else
    # Unprefixed records keep their key and resolve at the bundle root.
    dest="$bundle/$src"
  fi
  checked=$((checked+1))
  [[ -f "$dest" ]] || { missing=$((missing+1)); [[ $missing -le 5 ]] && echo "       missing: ${dest#$bundle/}" >&2; }
done < <(_strings "$bundle/symbols/exponent_core.debug.so" \
          | grep -oE '(programs|libraries)/[a-z_]+/src/[a-zA-Z0-9_/]+\.rs' | sort -u)
if [[ "$checked" -eq 0 ]]; then
  echo "ERROR: no 'programs|libraries/*/src/*.rs' paths found in the DWARF." >&2
  echo "       SourcesOriginalPath='programs/' cannot match anything -> zero coverage." >&2
  exit 1
fi
if [[ "$missing" -gt 0 ]]; then
  echo "ERROR: $missing of $checked DWARF source paths are absent from the bundle." >&2
  echo "       Those lines are measured and then silently dropped from coverage." >&2
  exit 1
fi
echo "[build-bundle] coverage sources resolve: $checked/$checked DWARF paths present in the bundle"

# ------------------------------------------------------------ 5. manifest ----
gen_manifest "$commit" > "$bundle/manifest.fc.json"

echo
echo "[build-bundle] bundle ready at $bundle (commit $commit)"
file "$bundle/bin/exponent_core/invariant_test"
du -sh "$bundle"
echo
echo "Upload with:   fuzz config use exponent && fuzz upload bundle $bundle"
echo "Then VERIFY:   fuzz list errors   (no SourcesOriginalPath message)"
echo "               fuzz list cover    (lines_found > 0 once cover has run)"
