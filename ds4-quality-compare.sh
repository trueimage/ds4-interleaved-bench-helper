#!/bin/bash
#
# ds4-quality-compare.sh -- quality comparison harness for ds4 on
# macOS / Apple Silicon.
#
# Measures how much two arms disagree about the next token, position by
# position, over a teacher-forced text.  The headline is the KL divergence of
# the two next-token distributions, with top-1 agreement, top-k overlap and
# each arm's own perplexity alongside.  Two kinds of comparison:
#
#   model mode   two GGUF files, one commit   (--model, --model-b, --ref)
#   branch mode  two commits, one GGUF file   (--branch, --base-ref)
#
# Model mode answers "did this requantization cost anything?".  Branch mode
# answers "did this kernel change alter the numerics?".  Either way arm A is
# the reference and arm B is the candidate, so KL is reported as KL(A||B).
#
# Optionally it also runs ds4's own official-continuation NLL scorer
# (gguf-tools/quality-testing/score_official) on both arms and includes the
# comparison, so one report carries both a distribution-level and a
# task-level view.
#
set -uo pipefail

readonly SELF=${0##*/}

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
note() { printf '%s: %s\n' "$SELF" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage:  model mode   $SELF --repo PATH --model FILE --model-b FILE [options]
        branch mode  $SELF --repo PATH --branch NAME --model FILE [options]

Model mode compares two GGUF files on one commit.  Branch mode compares two
commits on one GGUF file.  Arm A is the reference, arm B the candidate; the
report gives KL(A||B) at every scored position, plus agreement and perplexity.

Required (model mode):
  --repo PATH          Path to the ds4 git repository.
  --model FILE         Reference GGUF (arm A).  Relative paths resolve against --repo.
  --model-b FILE       Candidate GGUF (arm B).  Presence selects model mode.

Required (branch mode):
  --repo PATH          Path to the ds4 git repository.
  --branch NAME        Branch, tag or commit-ish under test (arm B).
  --model FILE         GGUF model used by both arms.

Options:
  --ref NAME           Model mode: the single commit to use.    Default: main
  --base-ref NAME      Branch mode: reference commit-ish.       Default: main
  --text FILE          Text to score, relative to --repo.
                       Default: speed-bench/promessi_sposi.txt
  --ctx N              Session context; scoring never exceeds it.  Default: 4096
  --tokens N           Score at most N positions.  Default: all that fit in --ctx
  --top-k K            Top-k overlap size.                       Default: 10
  --worst N            Worst positions listed in the report.     Default: 12
  --no-noise-floor     Skip the third pass that scores arm A against its own
                       logits.  That pass measures the run-to-run floor a
                       real difference must clear; omit it only to save time.
  --quality            Run both arms with the engine's --quality (exact kernels).
  --ssd-streaming      Run both arms with --ssd-streaming.
  --engine-arg ARG     Extra argument passed to ds4-kld (and score_official).
                       Repeatable; use for --ssd-streaming-cache-experts etc.
  --official MANIFEST  Also run gguf-tools/quality-testing/score_official on
                       both arms with this manifest (relative to the tree) and
                       include compare_scores.py output.  For GLM 5.3 Flash:
                       gguf-tools/quality-testing/data/glm53-flash-openrouter-zai-fp8-100/manifest.tsv
  --official-ctx N     Context for the official scorer.          Default: 4096
  --official-cases N   Score only the first N official cases.    Default: all
  --keep-logits        Keep the reference logits file (vocab x positions x 4 bytes).
  --out-dir DIR        Where the report is written.  Default: \$HOME/ds4-bench-results
  --cache-dir DIR      Worktree and build cache.     Default: \$HOME/.cache/ds4-bench
  --label-a TEXT       Override arm A's label.
  --label-b TEXT       Override arm B's label.
  --rebuild            Rebuild even if a cached worktree binary exists.
  -h, --help           This message.

Writes a timestamped Markdown report to --out-dir and prints its path.
USAGE
    exit 2
}

# ---------------------------------------------------------------- arguments

REPO="" BRANCH="" MODEL="" MODEL_B="" BASE_REF="main" REF=""
TEXT_REL="speed-bench/promessi_sposi.txt"
CTX=4096 TOKENS="" TOP_K=10 WORST=12
QUALITY=0 SSD=0 KEEP_LOGITS=0 REBUILD=0 NOISE_FLOOR=1
OFFICIAL="" OFFICIAL_CTX=4096 OFFICIAL_CASES=""
OUT_DIR="$HOME/ds4-bench-results"
CACHE_DIR="$HOME/.cache/ds4-bench"
LABEL_A="" LABEL_B=""
ENGINE_ARGS=()

[ $# -eq 0 ] && usage
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)           REPO=${2:?--repo needs a value}; shift 2 ;;
        --branch)         BRANCH=${2:?--branch needs a value}; shift 2 ;;
        --model)          MODEL=${2:?--model needs a value}; shift 2 ;;
        --model-b)        MODEL_B=${2:?--model-b needs a value}; shift 2 ;;
        --base-ref)       BASE_REF=${2:?--base-ref needs a value}; shift 2 ;;
        --ref)            REF=${2:?--ref needs a value}; shift 2 ;;
        --text)           TEXT_REL=${2:?--text needs a value}; shift 2 ;;
        --ctx)            CTX=${2:?--ctx needs a value}; shift 2 ;;
        --tokens)         TOKENS=${2:?--tokens needs a value}; shift 2 ;;
        --top-k)          TOP_K=${2:?--top-k needs a value}; shift 2 ;;
        --worst)          WORST=${2:?--worst needs a value}; shift 2 ;;
        --official)       OFFICIAL=${2:?--official needs a value}; shift 2 ;;
        --official-ctx)   OFFICIAL_CTX=${2:?--official-ctx needs a value}; shift 2 ;;
        --official-cases) OFFICIAL_CASES=${2:?--official-cases needs a value}; shift 2 ;;
        --out-dir)        OUT_DIR=${2:?--out-dir needs a value}; shift 2 ;;
        --cache-dir)      CACHE_DIR=${2:?--cache-dir needs a value}; shift 2 ;;
        --engine-arg)     ENGINE_ARGS+=("${2:?--engine-arg needs a value}"); shift 2 ;;
        --label-a)        LABEL_A=${2:?--label-a needs a value}; shift 2 ;;
        --label-b)        LABEL_B=${2:?--label-b needs a value}; shift 2 ;;
        --quality)        QUALITY=1; shift ;;
        --ssd-streaming)  SSD=1; shift ;;
        --keep-logits)    KEEP_LOGITS=1; shift ;;
        --no-noise-floor) NOISE_FLOOR=0; shift ;;
        --rebuild)        REBUILD=1; shift ;;
        -h|--help)        usage ;;
        *)                die "unrecognised argument '$1' (--help for usage)" ;;
    esac
done

[ -n "$REPO" ]  || die "--repo is required"
[ -n "$MODEL" ] || die "--model is required"

if [ -n "$MODEL_B" ]; then MODE=model; else MODE=branch; fi
[ "$MODE" = "branch" ] && [ -z "$BRANCH" ] && die "--branch is required in branch mode (or pass --model-b for model mode)"

case "$CTX" in ''|*[!0-9]*) die "--ctx must be a positive integer" ;; esac
[ "$CTX" -gt 32 ] || die "--ctx must be larger than the 32-token scoring prefix"
if [ -n "$TOKENS" ]; then
    case "$TOKENS" in ''|*[!0-9]*) die "--tokens must be a positive integer" ;; esac
fi
case "$TOP_K" in ''|*[!0-9]*) die "--top-k must be a positive integer" ;; esac
case "$WORST" in ''|*[!0-9]*) die "--worst must be a non-negative integer" ;; esac

# ------------------------------------------------------------ preconditions

[ "$(uname -s)" = "Darwin" ] || die "macOS only (uname -s = $(uname -s))"
[ "$(uname -m)" = "arm64" ]  || die "Apple Silicon only (uname -m = $(uname -m))"
command -v git >/dev/null     || die "git not found"
command -v make >/dev/null    || die "make not found"
command -v cc >/dev/null      || die "cc not found (install the Xcode Command Line Tools)"
command -v python3 >/dev/null || die "python3 not found (install the Xcode Command Line Tools)"

# The scorer source lives next to this script (follow a symlinked install).
self_path=$0
while [ -L "$self_path" ]; do
    link=$(readlink "$self_path")
    case "$link" in /*) self_path=$link ;; *) self_path=$(dirname "$self_path")/$link ;; esac
done
HELPER_DIR=$(cd "$(dirname "$self_path")" && pwd)
KLD_SRC="$HELPER_DIR/tools/ds4-kld.c"
KLD_MK="$HELPER_DIR/tools/ds4-kld.mk"
[ -f "$KLD_SRC" ] && [ -f "$KLD_MK" ] \
    || die "tools/ds4-kld.c and tools/ds4-kld.mk must sit next to this script (clone the repository)"

REPO=$(cd "$REPO" 2>/dev/null && pwd) || die "no such directory: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"

resolve() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$REPO" "$1" ;; esac; }
MODEL=$(resolve "$MODEL")
TEXT=$(resolve "$TEXT_REL")
[ -f "$MODEL" ] || die "model file not found: $MODEL"
[ -f "$TEXT" ]  || die "text file not found: $TEXT"
if [ "$MODE" = "model" ]; then
    MODEL_B=$(resolve "$MODEL_B")
    [ -f "$MODEL_B" ] || die "model file not found: $MODEL_B"
    [ "$MODEL" != "$MODEL_B" ] || die "--model and --model-b are the same file; nothing to compare"
fi

if [ "$MODE" = "branch" ]; then
    SHA_A=$(git -C "$REPO" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null) \
        || die "cannot resolve --base-ref '$BASE_REF'"
    SHA_B=$(git -C "$REPO" rev-parse --verify "${BRANCH}^{commit}" 2>/dev/null) \
        || die "cannot resolve --branch '$BRANCH'"
    [ "$SHA_A" != "$SHA_B" ] || die "--branch and --base-ref both resolve to ${SHA_A:0:12}; nothing to compare"
    REF_A=$BASE_REF; REF_B=$BRANCH
else
    [ -n "$REF" ] || REF=main
    SHA_A=$(git -C "$REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null) \
        || die "cannot resolve --ref '$REF'"
    SHA_B=$SHA_A
    REF_A=$REF; REF_B=$REF
fi

# ------------------------------------------------------------------- labels

if [ -z "$LABEL_A" ] || [ -z "$LABEL_B" ]; then
    if [ "$MODE" = "branch" ]; then
        auto_a="main"; auto_b="branch"
        [ "$BASE_REF" = "main" ] || auto_a="base"
    else
        # Strip the shared leading part of the two file names so the labels
        # say what actually differs (Q4_K vs Q4_K-kdaHeadQ8).
        ba=$(basename "$MODEL" .gguf); bb=$(basename "$MODEL_B" .gguf)
        i=0
        while [ $i -lt ${#ba} ] && [ $i -lt ${#bb} ] && [ "${ba:$i:1}" = "${bb:$i:1}" ]; do
            i=$((i + 1))
        done
        # Back up to a separator so a token is never cut in half.  Prefer a
        # dash or dot; an underscore only if there is nothing else, since
        # quant names like Q4_K contain one.
        cut=$i
        while [ $cut -gt 0 ]; do
            prev=$((cut - 1)); ch=${ba:$prev:1}
            case "$ch" in -|.) break ;; esac
            cut=$prev
        done
        if [ $cut -eq 0 ]; then
            cut=$i
            while [ $cut -gt 0 ]; do
                prev=$((cut - 1)); ch=${ba:$prev:1}
                case "$ch" in -|_|.) break ;; esac
                cut=$prev
            done
        fi
        auto_a=${ba:$cut}; auto_b=${bb:$cut}
        [ -n "$auto_a" ] || auto_a=$ba
        [ -n "$auto_b" ] || auto_b=$bb
    fi
    [ -n "$LABEL_A" ] || LABEL_A=$auto_a
    [ -n "$LABEL_B" ] || LABEL_B=$auto_b
fi

# ------------------------------------------------------------------ worktrees

ensure_worktree() {
    local sha=$1 dir=$2 label=$3
    if [ -e "$dir" ]; then
        local have
        have=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
        if [ "$have" = "$sha" ]; then
            note "reusing $label worktree $dir"
        else
            note "replacing stale $label worktree $dir"
            git -C "$REPO" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
        fi
    fi
    if [ ! -e "$dir" ]; then
        note "creating $label worktree $dir at ${sha:0:12}"
        git -C "$REPO" worktree add --detach "$dir" "$sha" >/dev/null \
            || die "git worktree add failed for $label at $sha"
    fi
}

NCPU=$(sysctl -n hw.ncpu)

build_kld() {
    local dir=$1 label=$2
    [ "$REBUILD" -eq 0 ] || rm -f "$dir/ds4-kld"
    # make rebuilds when the scorer source is newer than the cached binary.
    note "$label: building ds4-kld"
    ( cd "$dir" && make -f Makefile -f "$KLD_MK" ds4-kld -j"$NCPU" ) >"$dir/.build-kld.log" 2>&1 \
        || { tail -20 "$dir/.build-kld.log" >&2; die "$label: ds4-kld build failed (see $dir/.build-kld.log)"; }
    [ -x "$dir/ds4-kld" ] || die "$label: build produced no ds4-kld"
}

build_official() {
    local dir=$1 label=$2
    local target=gguf-tools/quality-testing/score_official
    [ "$REBUILD" -eq 0 ] || rm -f "$dir/$target"
    grep -q '^gguf-tools/quality-testing/score_official:' "$dir/Makefile" \
        || die "$label: this commit has no score_official make target; drop --official"
    note "$label: building score_official"
    ( cd "$dir" && make "$target" -j"$NCPU" ) >"$dir/.build-official.log" 2>&1 \
        || { tail -20 "$dir/.build-official.log" >&2; die "$label: score_official build failed (see $dir/.build-official.log)"; }
    [ -x "$dir/$target" ] || die "$label: build produced no score_official"
}

mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"
git -C "$REPO" worktree prune 2>/dev/null || true

TREE_A="$CACHE_DIR/wt-${SHA_A:0:12}"
ensure_worktree "$SHA_A" "$TREE_A" "arm A"
build_kld "$TREE_A" "arm A"
[ -z "$OFFICIAL" ] || build_official "$TREE_A" "arm A"
if [ "$SHA_B" = "$SHA_A" ]; then
    TREE_B=$TREE_A
else
    TREE_B="$CACHE_DIR/wt-${SHA_B:0:12}"
    ensure_worktree "$SHA_B" "$TREE_B" "arm B"
    build_kld "$TREE_B" "arm B"
    [ -z "$OFFICIAL" ] || build_official "$TREE_B" "arm B"
fi
MODEL_A=$MODEL
[ "$MODE" = "model" ] || MODEL_B=$MODEL

if [ -n "$OFFICIAL" ]; then
    # The manifest's own paths are relative to the tree root, so it must be
    # resolved against the tree, not the caller's repository.
    case "$OFFICIAL" in /*) MANIFEST_A=$OFFICIAL; MANIFEST_B=$OFFICIAL ;;
                        *)  MANIFEST_A="$TREE_A/$OFFICIAL"; MANIFEST_B="$TREE_B/$OFFICIAL" ;; esac
    [ -f "$MANIFEST_A" ] || die "official manifest not found: $MANIFEST_A"
    [ -f "$MANIFEST_B" ] || die "official manifest not found: $MANIFEST_B"
fi

# ------------------------------------------------------------------ the runs

STAMP=$(date +%Y%m%d-%H%M%S)
slug() { printf '%s' "$1" | tr -cs '[:alnum:]._-' '-' | sed 's/^-*//; s/-*$//'; }
if [ "$MODE" = "branch" ]; then
    RUN_NAME="ds4-quality-$(slug "$BRANCH")-$(slug "$(basename "$MODEL" .gguf)")-$STAMP"
else
    RUN_NAME="ds4-quality-models-$(slug "$LABEL_A")-vs-$(slug "$LABEL_B")-$STAMP"
fi
WORK="$CACHE_DIR/runs/$RUN_NAME"
mkdir -p "$WORK" "$OUT_DIR" || die "cannot create output directories"
REPORT="$OUT_DIR/$RUN_NAME.md"
LOGITS="$WORK/reference.logits"

KLD_ARGS=( --text "$TEXT" --ctx "$CTX" --top-k "$TOP_K" )
[ -z "$TOKENS" ] || KLD_ARGS+=( --tokens "$TOKENS" )
[ "$QUALITY" -eq 1 ] && KLD_ARGS+=( --quality )
[ "$SSD" -eq 1 ] && KLD_ARGS+=( --ssd-streaming )
[ ${#ENGINE_ARGS[@]} -gt 0 ] && KLD_ARGS+=("${ENGINE_ARGS[@]}")

note "mode $MODE; arms '$LABEL_A' (reference) vs '$LABEL_B' (candidate); ctx $CTX"

: >"$WORK/timeline.txt"
run_arm() {
    local arm=$1 tree=$2 model=$3; shift 3
    local started ended rc
    started=$(date +%H:%M:%S)
    note "arm $arm starting at $started"
    ( cd "$tree" && ./ds4-kld "$model" "$@" ) >"$WORK/$arm.stdout" 2>"$WORK/$arm.stderr"
    rc=$?
    ended=$(date +%H:%M:%S)
    printf '%s\t%s\t%s\t%d\n' "$arm" "$started" "$ended" "$rc" >>"$WORK/timeline.txt"
    if [ $rc -ne 0 ]; then
        tail -8 "$WORK/$arm.stderr" >&2
        [ "$KEEP_LOGITS" -eq 1 ] || rm -f "$LOGITS"
        die "arm $arm failed (rc=$rc); artifacts in $WORK"
    fi
    note "arm $arm done at $ended: $(tail -1 "$WORK/$arm.stdout")"
}

run_arm a "$TREE_A" "$MODEL_A" "${KLD_ARGS[@]}" --save-logits "$LOGITS" --tsv "$WORK/a.tsv"
run_arm b "$TREE_B" "$MODEL_B" "${KLD_ARGS[@]}" --load-logits "$LOGITS" --tsv "$WORK/b.tsv"
# A second pass of the reference against its own logits: any divergence here
# is run-to-run noise in the engine, the floor a real difference must clear.
[ "$NOISE_FLOOR" -eq 0 ] || run_arm a2 "$TREE_A" "$MODEL_A" "${KLD_ARGS[@]}" --load-logits "$LOGITS" --tsv "$WORK/a2.tsv"

hsize() {
    python3 -c "import os,sys; n=os.path.getsize(sys.argv[1]); print('%.1f GiB' % (n/1073741824) if n >= 1073741824 else '%.0f MiB' % (n/1048576))" "$1"
}
logits_size=$(hsize "$LOGITS")
if [ "$KEEP_LOGITS" -eq 1 ]; then
    note "reference logits kept at $LOGITS ($logits_size)"
else
    rm -f "$LOGITS"
fi

OFFICIAL_OK=0
if [ -n "$OFFICIAL" ]; then
    OFF_ARGS=( "$OFFICIAL_CTX" )
    [ "$QUALITY" -eq 1 ] && OFF_ARGS+=( --quality )
    [ "$SSD" -eq 1 ] && OFF_ARGS+=( --ssd-streaming )
    [ -z "$OFFICIAL_CASES" ] || OFF_ARGS+=( --max-cases "$OFFICIAL_CASES" )
    [ ${#ENGINE_ARGS[@]} -gt 0 ] && OFF_ARGS+=("${ENGINE_ARGS[@]}")
    OFFICIAL_OK=1
    for arm in a b; do
        if [ "$arm" = "a" ]; then tree=$TREE_A; model=$MODEL_A; manifest=$MANIFEST_A
        else                      tree=$TREE_B; model=$MODEL_B; manifest=$MANIFEST_B; fi
        started=$(date +%H:%M:%S)
        note "official scorer, arm $arm starting at $started"
        ( cd "$tree" && ./gguf-tools/quality-testing/score_official "$model" "$manifest" \
              "$WORK/official_$arm.tsv" "${OFF_ARGS[@]}" ) \
            >"$WORK/official_$arm.stdout" 2>"$WORK/official_$arm.stderr"
        rc=$?
        ended=$(date +%H:%M:%S)
        printf 'official_%s\t%s\t%s\t%d\n' "$arm" "$started" "$ended" "$rc" >>"$WORK/timeline.txt"
        if [ $rc -ne 0 ]; then
            tail -5 "$WORK/official_$arm.stderr" >&2
            note "official scorer, arm $arm FAILED rc=$rc; that section will be omitted"
            OFFICIAL_OK=0
            break
        fi
        note "official scorer, arm $arm done at $ended"
    done
    if [ "$OFFICIAL_OK" -eq 1 ]; then
        python3 "$TREE_A/gguf-tools/quality-testing/compare_scores.py" \
            "$WORK/official_a.tsv" "$WORK/official_b.tsv" >"$WORK/official_compare.txt" 2>&1 \
            || { note "compare_scores.py failed; official section omitted"; OFFICIAL_OK=0; }
    fi
fi

# ------------------------------------------------------ what differs on disk

# Reads only the GGUF headers, so this is quick even for 200 GB files.
python3 - "$MODEL_A" "$MODEL_B" "$LABEL_A" "$LABEL_B" >"$WORK/tensors.md" 2>"$WORK/tensors.err" <<'PY_EOF'
import hashlib, os, re, struct, sys
from collections import Counter, OrderedDict

path_a, path_b, label_a, label_b = sys.argv[1:5]

TYPES = {0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1", 8: "Q8_0",
         9: "Q8_1", 10: "Q2_K", 11: "Q3_K", 12: "Q4_K", 13: "Q5_K", 14: "Q6_K",
         15: "Q8_K", 16: "IQ2_XXS", 17: "IQ2_XS", 18: "IQ3_XXS", 19: "IQ1_S",
         20: "IQ4_NL", 21: "IQ3_S", 22: "IQ2_S", 23: "IQ4_XS", 24: "I8", 25: "I16",
         26: "I32", 27: "I64", 28: "F64", 29: "IQ1_M", 30: "BF16", 34: "TQ1_0",
         35: "TQ2_0", 39: "MXFP4"}
SCALAR = {0: ("<B", 1), 1: ("<b", 1), 2: ("<H", 2), 3: ("<h", 2), 4: ("<I", 4), 5: ("<i", 4),
          6: ("<f", 4), 7: ("<?", 1), 10: ("<Q", 8), 11: ("<q", 8), 12: ("<d", 8)}

def tname(t):
    return TYPES.get(t, "type%d" % t)

def read_gguf(path):
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise SystemExit("%s: not a GGUF file" % path)
        version = struct.unpack("<I", f.read(4))[0]
        n_tensors, n_kv = struct.unpack("<QQ", f.read(16))
        def rstr():
            n = struct.unpack("<Q", f.read(8))[0]
            return f.read(n)
        def rval(t):
            if t == 8:
                return rstr().decode("utf-8", "replace")
            if t == 9:
                et = struct.unpack("<I", f.read(4))[0]
                n = struct.unpack("<Q", f.read(8))[0]
                h = hashlib.sha256()
                if et == 8:
                    for _ in range(n):
                        h.update(rstr()); h.update(b"\0")
                else:
                    h.update(f.read(SCALAR[et][1] * n))
                return "array[%d] %s" % (n, h.hexdigest()[:12])
            fmt, size = SCALAR[t]
            return struct.unpack(fmt, f.read(size))[0]
        kv = OrderedDict()
        for _ in range(n_kv):
            k = rstr().decode("utf-8", "replace")
            t = struct.unpack("<I", f.read(4))[0]
            kv[k] = rval(t)
        tensors = OrderedDict()
        for _ in range(n_tensors):
            name = rstr().decode("utf-8", "replace")
            nd = struct.unpack("<I", f.read(4))[0]
            dims = struct.unpack("<%dQ" % nd, f.read(8 * nd))
            typ, off = struct.unpack("<IQ", f.read(12))
            tensors[name] = [dims, typ, off, 0]
        align = int(kv.get("general.alignment", 32))
        data_start = (f.tell() + align - 1) // align * align
    size = os.path.getsize(path)
    by_off = sorted(tensors.values(), key=lambda t: t[2])
    for i, t in enumerate(by_off):
        end = by_off[i + 1][2] if i + 1 < len(by_off) else size - data_start
        t[3] = max(0, end - t[2])
    return version, kv, tensors, size

def gib(n):
    return "%.1f GiB" % (n / 1073741824)

def ranges(nums):
    nums = sorted(set(nums))
    out, start, prev = [], None, None
    for n in nums + [None]:
        if start is None:
            start = prev = n
        elif n is not None and n == prev + 1:
            prev = n
        else:
            out.append("%d" % start if start == prev else "%d-%d" % (start, prev))
            start = prev = n
    return ", ".join(out)

va, kva, ta, sa = read_gguf(path_a)
vb, kvb, tb, sb = read_gguf(path_b)

print("| | %s | %s |" % (label_a, label_b))
print("|---|---:|---:|")
print("| file size | %s | %s |" % (gib(sa), gib(sb)))
print("| tensors | %d | %d |" % (len(ta), len(tb)))
ca = Counter(tname(t[1]) for t in ta.values())
cb = Counter(tname(t[1]) for t in tb.values())
ba = Counter(); bb = Counter()
for t in ta.values(): ba[tname(t[1])] += t[3]
for t in tb.values(): bb[tname(t[1])] += t[3]
for typ in sorted(set(ca) | set(cb), key=lambda k: (-(ba[k] + bb[k]), k)):
    print("| %s | %d (%s) | %d (%s) |" % (typ, ca[typ], gib(ba[typ]), cb[typ], gib(bb[typ])))
print()

kv_diff = [k for k in kva if k in kvb and kva[k] != kvb[k]]
kv_only = sorted((set(kva) | set(kvb)) - (set(kva) & set(kvb)))
if not kv_diff and not kv_only:
    print("Metadata is identical (%d keys), so both files carry the same tokenizer "
          "and architecture parameters." % len(kva))
else:
    print("Metadata differs:")
    print()
    for k in kv_diff:
        print("- `%s`: `%s` vs `%s`" % (k, str(kva[k])[:60], str(kvb[k])[:60]))
    for k in kv_only:
        print("- `%s` only in %s" % (k, label_a if k in kva else label_b))
print()

common = [n for n in ta if n in tb]
only_a = [n for n in ta if n not in tb]
only_b = [n for n in tb if n not in ta]
shape = [n for n in common if ta[n][0] != tb[n][0]]
typed = [n for n in common if ta[n][1] != tb[n][1]]

if not typed and not shape and not only_a and not only_b:
    print("Every tensor has the same name, shape and type in both files. Any "
          "difference below comes from the tensor *contents*, which this "
          "header comparison cannot see.")
else:
    bytes_a = sum(ta[n][3] for n in typed)
    bytes_b = sum(tb[n][3] for n in typed)
    print("%d tensor%s change type (%s to %s)%s%s%s."
          % (len(typed), "" if len(typed) == 1 else "s", gib(bytes_a), gib(bytes_b),
             "; %d change shape" % len(shape) if shape else "",
             "; %d only in %s" % (len(only_a), label_a) if only_a else "",
             "; %d only in %s" % (len(only_b), label_b) if only_b else ""))
    print()
    if typed:
        groups = OrderedDict()
        for n in typed:
            key = (re.sub(r"\bblk\.\d+\.", "blk.*.", n), tname(ta[n][1]), tname(tb[n][1]))
            m = re.search(r"\bblk\.(\d+)\.", n)
            groups.setdefault(key, []).append(int(m.group(1)) if m else None)
        print("| tensor | count | %s | %s | layers |" % (label_a, label_b))
        print("|---|---:|---|---|---|")
        for (pat, x, y), layers in groups.items():
            layer_txt = ranges([l for l in layers if l is not None]) if any(l is not None for l in layers) else ""
            print("| `%s` | %d | %s | %s | %s |" % (pat, len(layers), x, y, layer_txt))
        if shape or only_a or only_b:
            print()
    for n in shape[:20]:
        print("- `%s` shape %s vs %s" % (n, list(ta[n][0]), list(tb[n][0])))
    for n in only_a[:20]:
        print("- `%s` only in %s" % (n, label_a))
    for n in only_b[:20]:
        print("- `%s` only in %s" % (n, label_b))
PY_EOF

[ -s "$WORK/tensors.err" ] && note "header comparison failed (see $WORK/tensors.err); that section will say so"

# ------------------------------------------------------------------ results

python3 - "$WORK" "$LABEL_A" "$LABEL_B" "$WORST" "$TOP_K" >"$WORK/results.md" <<'PY_EOF'
import csv, math, os, sys

work, label_a, label_b, worst_n, top_k = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])

def unescape(s):
    """Undo ds4-kld's C-style escaping; the TSV was read with surrogateescape."""
    raw = s.encode("utf-8", "surrogateescape")
    out = bytearray()
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == 0x5c and i + 1 < len(raw):
            n = raw[i + 1]
            if n == 0x5c: out.append(0x5c); i += 2; continue
            if n == 0x74: out.append(0x09); i += 2; continue
            if n == 0x6e: out.append(0x0a); i += 2; continue
            if n == 0x72: out.append(0x0d); i += 2; continue
            if n == 0x78 and i + 3 < len(raw):
                try:
                    out.append(int(raw[i + 2:i + 4], 16)); i += 4; continue
                except ValueError:
                    pass
        out.append(c)
        i += 1
    return out.decode("utf-8", "replace")

def cell(s, limit=48):
    s = s.replace("\n", "⏎").replace("\r", "").replace("\t", "→").replace("|", "\\|").replace("`", "'")
    if len(s) > limit:
        s = "…" + s[-limit:]
    return "`" + s + "`" if s else ""

rows = []
with open(os.path.join(work, "b.tsv"), encoding="utf-8", errors="surrogateescape", newline="") as fh:
    for r in csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE):
        rows.append(r)
n = len(rows)
if n == 0:
    print("*The compare run produced no scored positions.*")
    sys.exit(0)

F = lambda key: [float(r[key]) for r in rows]
kld = F("kld_ab"); kld_rev = F("kld_ba"); jsd = F("jsd")
nll_a = F("nll_a"); nll_b = F("nll_b")
pa_t = F("p_a_target"); pb_t = F("p_b_target")
same = [int(r["top1_same"]) for r in rows]
overlap = F("topk_overlap")
pb_argmax_a = F("p_b_argmax_a")
ent_a = F("entropy_a")
hit_a = [int(r["argmax_a"] == r["token"]) for r in rows]
hit_b = [int(r["argmax_b"] == r["token"]) for r in rows]
pos = [int(r["pos"]) for r in rows]

def mean(v): return sum(v) / len(v)
def stderr(v):
    if len(v) < 2: return 0.0
    m = mean(v)
    return math.sqrt(sum((x - m) ** 2 for x in v) / (len(v) - 1) / len(v))
def quantile(v, q):
    s = sorted(v)
    return s[min(len(s) - 1, max(0, int(math.ceil(q * len(s))) - 1))]
def ppl(v): return math.exp(mean(v))

m_kld = mean(kld); se_kld = stderr(kld)
imax = max(range(n), key=lambda i: kld[i])

floor = None
floor_path = os.path.join(work, "a2.tsv")
if os.path.exists(floor_path):
    with open(floor_path, encoding="utf-8", errors="surrogateescape", newline="") as fh:
        frows = list(csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE))
    if frows:
        fk = [float(r["kld_ab"]) for r in frows]
        fs = [int(r["top1_same"]) for r in frows]
        floor = (mean(fk), max(fk), 100.0 * mean(fs), len(frows))
agree = sum(same); agree_pct = 100.0 * agree / n
ppl_a, ppl_b = ppl(nll_a), ppl(nll_b)
d_ppl = (ppl_b / ppl_a - 1.0) * 100.0

# ---- divergence -----------------------------------------------------------
print("#### Distribution divergence")
print()
print("KL(A‖B) at each scored position, in nats: how far the candidate's "
      "next-token distribution is from the reference's. Zero means identical. "
      "A = `%s`, B = `%s`." % (label_a, label_b))
print()
print("| statistic | KL(A‖B) |")
print("|---|---:|")
print("| mean | **%.6f** ± %.6f (standard error) |" % (m_kld, se_kld))
print("| median | %.6f |" % quantile(kld, 0.5))
print("| 90th percentile | %.6f |" % quantile(kld, 0.9))
print("| 99th percentile | %.6f |" % quantile(kld, 0.99))
print("| max | %.6f at position %d |" % (kld[imax], pos[imax]))
print("| reverse KL(B‖A), mean | %.6f |" % mean(kld_rev))
print("| Jensen–Shannon, mean | %.6f |" % mean(jsd))
if floor is not None:
    print("| noise floor: mean KL(A‖A′), A scored against a repeat run of itself | %.6f (max %.6f, top-1 same %.2f%%) |" % (floor[0], floor[1], floor[2]))
print()
if floor is not None:
    if floor[0] <= 0.0:
        print("The engine reproduced arm A bit for bit on the second pass, so every "
              "non-zero divergence above is attributable to the candidate.")
    elif m_kld > 0 and m_kld >= 10.0 * floor[0]:
        print("The mean divergence is %.0fx the noise floor, so it is a property of "
              "the candidate, not of run-to-run variation in the engine." % (m_kld / floor[0]))
    else:
        print("**The mean divergence is within about an order of magnitude of the "
              "noise floor**; the engine itself does not reproduce arm A more "
              "closely than this, so treat the difference between the arms as "
              "unresolved at this sample size.")
    print()
edges = [1e-4, 1e-3, 1e-2, 1e-1, 1.0]
labels = ["< 1e-4", "1e-4 to 1e-3", "1e-3 to 1e-2", "1e-2 to 0.1", "0.1 to 1", "≥ 1"]
counts = [0] * len(labels)
for x in kld:
    k = 0
    while k < len(edges) and x >= edges[k]:
        k += 1
    counts[k] += 1
print("Share of positions by KL(A‖B):")
print()
print("| " + " | ".join(labels) + " |")
print("|" + "---:|" * len(labels))
print("| " + " | ".join("%.1f%%" % (100.0 * c / n) for c in counts) + " |")
print()

# ---- agreement ------------------------------------------------------------
print("#### Next-token agreement")
print()
print("| | |")
print("|---|---:|")
print("| top-1 token identical | **%d of %d (%.2f%%)** |" % (agree, n, agree_pct))
print("| positions where greedy decoding would diverge | %d |" % (n - agree))
print("| mean top-%d overlap | %.1f%% |" % (top_k, 100.0 * mean(overlap)))
print("| mean p_B(A's top-1 token) | %.4f |" % mean(pb_argmax_a))
print("| mean \\|p_B − p_A\\| of the actual next token | %.4f |" % mean([abs(b - a) for a, b in zip(pa_t, pb_t)]))
print()
print("Greedy decoding picks the top-1 token, so the first row is the share of "
      "positions at which both arms would emit the same token given identical "
      "context. Sampling at temperature draws from the whole distribution, "
      "which the divergence table above describes.")
print()

# ---- fit to the text ------------------------------------------------------
print("#### Fit to the text (teacher-forced)")
print()
print("| | %s | %s | B vs A |" % (label_a, label_b))
print("|---|---:|---:|---:|")
print("| mean NLL (nats/token) | %.5f | %.5f | %+.5f |" % (mean(nll_a), mean(nll_b), mean(nll_b) - mean(nll_a)))
print("| perplexity | %.4f | %.4f | %+.2f%% |" % (ppl_a, ppl_b, d_ppl))
print("| greedy token is the actual next token | %.2f%% | %.2f%% | %+.2f pp |"
      % (100.0 * mean(hit_a), 100.0 * mean(hit_b), 100.0 * (mean(hit_b) - mean(hit_a))))
better = sum(1 for a, b in zip(nll_a, nll_b) if b < a - 1e-12)
worse = sum(1 for a, b in zip(nll_a, nll_b) if b > a + 1e-12)
print("| positions where B assigns the next token more / less probability | %d | %d | |" % (better, worse))
print()
print("Perplexity measures each arm's own fit to this text and can move either "
      "way; a lower value for B is not evidence that B is closer to the "
      "original weights. Divergence from A is the quantity to read for that.")
print()

# ---- by position ----------------------------------------------------------
nb = max(1, min(8, n // 16))
print("#### By position")
print()
print("Whether the gap grows with context. Recurrent state (KDA layers) and "
      "attention over a long window both accumulate error, so a candidate can "
      "look fine at the start of a context and drift later. Read the divergence "
      "against the reference's entropy in the same rows: where A is itself "
      "unsure, any perturbation moves more probability, so KL is naturally "
      "higher there.")
print()
print("| positions | mean KL(A‖B) | 99th pct | top-1 same | entropy %s | ppl %s | ppl %s |" % (label_a, label_a, label_b))
print("|---|---:|---:|---:|---:|---:|---:|")
for k in range(nb):
    lo, hi = k * n // nb, (k + 1) * n // nb
    if hi <= lo: continue
    seg = slice(lo, hi)
    print("| %d – %d | %.6f | %.6f | %.2f%% | %.3f | %.4f | %.4f |"
          % (pos[lo], pos[hi - 1], mean(kld[seg]), quantile(kld[seg], 0.99),
             100.0 * mean(same[seg]), mean(ent_a[seg]), ppl(nll_a[seg]), ppl(nll_b[seg])))
print()

# ---- worst positions ------------------------------------------------------
if worst_n > 0:
    print("#### Worst positions")
    print()
    print("The %d positions with the largest KL(A‖B). Context is the preceding "
          "scored text; probabilities are p_A / p_B." % min(worst_n, n))
    print()
    print("| pos | KL(A‖B) | context | next token (p_A / p_B) | %s top-1 (p) | %s top-1 (p) |" % (label_a, label_b))
    print("|---:|---:|---|---|---|---|")
    order = sorted(range(n), key=lambda i: -kld[i])[:worst_n]
    for i in order:
        r = rows[i]
        ctx = "".join(unescape(rows[j]["token_text"]) for j in range(max(0, i - 12), i))
        print("| %d | %.4f | %s | %s (%.3f / %.3f) | %s (%.3f) | %s (%.3f) |" % (
            pos[i], kld[i], cell(ctx),
            cell(unescape(r["token_text"]), 24), pa_t[i], pb_t[i],
            cell(unescape(r["argmax_a_text"]), 24), float(r["p_a_argmax_a"]),
            cell(unescape(r["argmax_b_text"]), 24), float(r["p_b_argmax_b"])))
    print()

with open(os.path.join(work, "summary.txt"), "w") as fh:
    fh.write("mean KL(A‖B) %.5f" % m_kld)
    if floor is not None:
        fh.write(" (noise floor %.5f)" % floor[0])
    fh.write(", top-1 agreement %.2f%%, perplexity %+.2f%%" % (agree_pct, d_ppl))
    fh.write("\n%d\n%d\n%d\n" % (n, pos[0], pos[-1]))
PY_EOF
[ $? -eq 0 ] && [ -s "$WORK/summary.txt" ] || die "result aggregation failed; per-position data is in $WORK"

# ------------------------------------------------------------------- machine

sp_gpu_cores=$(system_profiler SPDisplaysDataType 2>/dev/null \
                | awk -F': *' '/Total Number of Cores/ {print $2; exit}')
chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
hw_model=$(sysctl -n hw.model 2>/dev/null)
mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
pcores=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)
ecores=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || true)
ncpu=$(sysctl -n hw.physicalcpu 2>/dev/null)
os_ver=$(sw_vers -productVersion 2>/dev/null)
os_build=$(sw_vers -buildVersion 2>/dev/null)
cc_ver=$(cc --version 2>/dev/null | head -1)
cpu_desc="$ncpu cores"
[ -n "$pcores" ] && [ -n "$ecores" ] && cpu_desc="$ncpu cores (${pcores}P + ${ecores}E)"
mem_desc=$(python3 -c "print('%.0f GiB' % ($mem_bytes/1073741824))" 2>/dev/null || echo "$mem_bytes bytes")

# -------------------------------------------------------------------- report

fsize() { python3 -c "import os,sys; print('%.1f GiB' % (os.path.getsize(sys.argv[1])/1073741824))" "$1"; }
text_size=$(python3 -c "import os,sys; print('{:,} bytes'.format(os.path.getsize(sys.argv[1])))" "$TEXT")
n_scored=$(sed -n '2p' "$WORK/summary.txt")
pos_first=$(sed -n '3p' "$WORK/summary.txt")
pos_last=$(sed -n '4p' "$WORK/summary.txt")
summary_line=$(head -1 "$WORK/summary.txt")
kv() { sed -n "s/.*[[:space:]]$1=\([^[:space:]]*\).*/\1/p" "$2" | tail -1; }
rate_a=$(python3 -c "import sys; s,e=float(sys.argv[1]),float(sys.argv[2]); print('%.1f' % (s/e if e else 0))" "$n_scored" "$(kv elapsed_s "$WORK/a.stdout")")
rate_b=$(python3 -c "import sys; s,e=float(sys.argv[1]),float(sys.argv[2]); print('%.1f' % (s/e if e else 0))" "$n_scored" "$(kv elapsed_s "$WORK/b.stdout")")

{
if [ "$MODE" = "branch" ]; then
    printf '### ds4 quality comparison: `%s` vs `%s`\n\n' "$REF_B" "$REF_A"
else
    printf '### ds4 quality comparison: `%s` vs `%s`\n\n' "$LABEL_B" "$LABEL_A"
fi
printf '**%s** over %s teacher-forced positions of `%s`' "$summary_line" "$n_scored" "$(basename "$TEXT")"
if [ "$MODE" = "branch" ]; then
    printf ' with `%s`.\n\n' "$(basename "$MODEL_A")"
else
    printf '.\n\n'
fi
printf '<sub>%s · ctx %s · %s · generated by ' "$(date '+%Y-%m-%d %H:%M %Z')" "$CTX" \
    "$( [ "$QUALITY" -eq 1 ] && echo '--quality' || echo 'default kernels' )"
printf '[ds4-interleaved-bench-helper](https://github.com/trueimage/ds4-interleaved-bench-helper)</sub>\n\n'

printf '#### What was compared\n\n'
printf '| | |\n|---|---|\n'
printf '| mode | %s |\n' "$MODE"
if [ "$MODE" = "branch" ]; then
    printf '| arm A, reference (`%s`) | `%s` @ `%s` — %s |\n' "$LABEL_A" "$REF_A" "${SHA_A:0:12}" \
        "$(git -C "$REPO" log -1 --format=%s "$SHA_A")"
    printf '| arm B, candidate (`%s`) | `%s` @ `%s` — %s |\n' "$LABEL_B" "$REF_B" "${SHA_B:0:12}" \
        "$(git -C "$REPO" log -1 --format=%s "$SHA_B")"
    printf '| merge base | `%s` |\n' "$(git -C "$REPO" merge-base "$SHA_A" "$SHA_B" 2>/dev/null | cut -c1-12)"
    printf '| B vs A | %s commits ahead, %s behind |\n' \
        "$(git -C "$REPO" rev-list --count "$SHA_A..$SHA_B" 2>/dev/null || echo '?')" \
        "$(git -C "$REPO" rev-list --count "$SHA_B..$SHA_A" 2>/dev/null || echo '?')"
    printf '| model (both arms) | `%s` (%s) |\n' "$(basename "$MODEL_A")" "$(fsize "$MODEL_A")"
else
    printf '| commit (both arms) | `%s` @ `%s` — %s |\n' "$REF_A" "${SHA_A:0:12}" \
        "$(git -C "$REPO" log -1 --format=%s "$SHA_A")"
    printf '| arm A, reference (`%s`) | `%s` (%s) |\n' "$LABEL_A" "$(basename "$MODEL_A")" "$(fsize "$MODEL_A")"
    printf '| arm B, candidate (`%s`) | `%s` (%s) |\n' "$LABEL_B" "$(basename "$MODEL_B")" "$(fsize "$MODEL_B")"
fi
printf '| repository | `%s` |\n' "$REPO"
printf '\n'

if [ "$MODE" = "model" ]; then
    printf '#### What differs between the files\n\n'
    if [ -s "$WORK/tensors.err" ]; then
        printf '*The GGUF header comparison failed:*\n\n```\n'
        tail -3 "$WORK/tensors.err"
        printf '```\n'
    else
        cat "$WORK/tensors.md"
    fi
    printf '\n'
fi

printf '#### Method\n\n'
printf '| | |\n|---|---|\n'
printf '| text | `%s` (%s) |\n' "$(basename "$TEXT")" "$text_size"
printf '| scored positions | %s (token index %s to %s, after a 32-token prefix) |\n' "$n_scored" "$pos_first" "$pos_last"
printf '| context | %s |\n' "$CTX"
printf '| kernels | %s |\n' "$( [ "$QUALITY" -eq 1 ] && echo '`--quality` on both arms' || echo 'default (what `ds4` runs with)' )"
printf '| SSD streaming | %s |\n' "$( [ "$SSD" -eq 1 ] && echo 'on' || echo 'off' )"
printf '| scoring rate | %s tok/s (A), %s tok/s (B) |\n' "$rate_a" "$rate_b"
printf '| noise floor | %s |\n' "$( [ "$NOISE_FLOOR" -eq 1 ] && echo 'measured: arm A scored a second time against its own logits' || echo 'not measured (`--no-noise-floor`)' )"
printf '\n'
printf 'Both arms decode the same token stream one token at a time through the\n'
printf 'ordinary session path, the way generation does. Arm A records the full\n'
printf 'next-token logits at every position; arm B is scored against them. The\n'
printf 'token streams are checked to be identical, so a tokenizer difference\n'
printf 'between the files would abort the run rather than skew it.\n\n'
printf 'Arm A command:\n\n```\n./ds4-kld %s \\\n    %s--save-logits reference.logits --tsv a.tsv\n```\n\n' \
    "$MODEL_A" "$(printf '%s ' "${KLD_ARGS[@]}")"
if [ "$MODE" = "model" ]; then
    printf 'Arm B is the same command with `%s` and `--load-logits reference.logits`.\n\n' "$MODEL_B"
else
    printf 'Arm B is the same command with `--load-logits reference.logits`, run in the branch worktree.\n\n'
fi

printf '#### Machine\n\n'
printf '| | |\n|---|---|\n'
printf '| chip | %s |\n' "$chip"
printf '| model identifier | %s |\n' "$hw_model"
printf '| CPU | %s |\n' "$cpu_desc"
[ -n "$sp_gpu_cores" ] && printf '| GPU | %s cores |\n' "$sp_gpu_cores"
printf '| memory | %s |\n' "$mem_desc"
printf '| macOS | %s (%s) |\n' "$os_ver" "$os_build"
printf '| compiler | %s |\n' "$cc_ver"
printf '\n'

cat "$WORK/results.md"

if [ -n "$OFFICIAL" ]; then
    printf '#### Official-continuation NLL\n\n'
    if [ "$OFFICIAL_OK" -eq 1 ]; then
        printf "ds4's own quality gate: the negative log likelihood each arm assigns to\n"
        printf 'continuations collected from the hosted model, from `%s`. Lower is better.\n' "$OFFICIAL"
        printf 'This is a task-level view against an external reference, where the divergence\n'
        printf 'above is a distribution-level view against arm A.\n\n'
        python3 - "$WORK/official_compare.txt" "$LABEL_A" "$LABEL_B" <<'PY_EOF'
import sys
path, label_a, label_b = sys.argv[1:4]
kv = {}
for line in open(path, encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 2 and parts[0] and " " not in parts[0]:
        kv[parts[0]] = parts[1:]
def one(k, default="?"):
    return kv.get(k, [default])[0]
print("| | %s | %s | B vs A |" % (label_a, label_b))
print("|---|---:|---:|---:|")
print("| cases / target tokens | %s / %s | | |" % (one("cases"), one("tokens")))
try:
    a, b = float(one("old_avg_nll")), float(one("new_avg_nll"))
    print("| mean NLL per target token | %.5f | %.5f | %+.5f (%s) |" % (a, b, b - a, one("relative_nll_change")))
except ValueError:
    print("| mean NLL per target token | %s | %s | |" % (one("old_avg_nll"), one("new_avg_nll")))
w = kv.get("case_wins_new_old_ties", ["?", "?", "?"])
print("| cases won (lower NLL) | %s | %s | %s ties |" % (w[1], w[0], w[2] if len(w) > 2 else "?"))
f = kv.get("first_token_matches_old_new", ["?", "?"])
print("| first token matches the official one | %s | %s | |" % (f[0], f[1] if len(f) > 1 else "?"))
l = kv.get("avg_greedy_lcp_old_new", ["?", "?"])
print("| mean greedy common prefix (tokens) | %s | %s | |" % (l[0], l[1] if len(l) > 1 else "?"))
try:
    if float(one("old_api_target_tokens", "0")) > 0:
        for key, name in (("api_target_mae", "mean abs logprob delta vs API"),
                          ("api_top1_rate", "API top-1 equals local greedy"),
                          ("api_topn_recall", "API top-N recall"),
                          ("api_pair_rate", "pairwise ordering agreement")):
            print("| %s | %s | %s | |" % (name, one("old_" + key), one("new_" + key)))
except ValueError:
    pass
PY_EOF
        printf '\n<details>\n<summary>Full `compare_scores.py` output</summary>\n\n```\n'
        cat "$WORK/official_compare.txt"
        printf '```\n\n</details>\n\n'
    else
        printf '*The official scorer failed; see the artifacts directory.*\n\n'
    fi
fi

printf '<details>\n<summary>Raw data — run timeline, engine load, per-position TSV</summary>\n\n'
printf '**Run order**\n\n'
printf '| run | started | ended | exit |\n|---|---|---|---:|\n'
while IFS=$'\t' read -r label s e rc; do
    printf '| `%s` | %s | %s | %s |\n' "$label" "$s" "$e" "$rc"
done <"$WORK/timeline.txt"
printf '\n'
for arm in a b a2; do
    if [ -s "$WORK/$arm.stderr" ]; then
        printf '**Engine load, arm %s**\n\n```\n' "$arm"
        grep -E 'Metal device|memory:|resident model|GLM session|streaming|prefill chunk|ds4-kld:' \
            "$WORK/$arm.stderr" 2>/dev/null | tr '\r' '\n' | grep -v -e '^ds4-kld: [0-9]*/' -e '^$' | head -14
        printf '```\n\n'
    fi
done
printf 'Per-position results: `%s` (one row per scored position, with both\n' "$WORK/b.tsv"
printf "arms' NLL, top-1 tokens, top-k overlap and all three divergences).\n"
if [ "$KEEP_LOGITS" -eq 1 ]; then
    printf 'Reference logits: `%s` (%s); pass it to `ds4-kld --load-logits` to score\n' "$LOGITS" "$logits_size"
    printf 'another model against the same reference without re-running arm A.\n'
else
    printf 'The reference logits file (%s) was deleted; `--keep-logits` retains it.\n' "$logits_size"
fi
printf '\nArtifacts on disk: `%s`\n\n' "$WORK"
printf '</details>\n\n'
} >"$REPORT"

note "report written"
printf '%s\n' "$REPORT"
