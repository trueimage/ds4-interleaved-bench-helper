#!/bin/bash
#
# ds4-interleaved-bench.sh -- interleaved benchmark harness for ds4 on
# macOS / Apple Silicon.
#
# Compares two arms with ds4-bench, running them in an interleaved order so
# that machine drift lands on both arms alike instead of on one.  Two kinds of
# comparison:
#
#   branch mode  two commits, one model   (--branch, --base-ref)
#   model mode   two models, one commit   (--model, --model-b, --ref)
#
# The interleave order is a string of A/B (or M/B) positions.  The default,
# ABBA, cancels linear drift exactly: each arm's mean position in the session
# is identical, so a steady warm-up or slow-down biases neither.  See --help
# and the README for which longer orders are worth the machine time.
#
set -uo pipefail

readonly SELF=${0##*/}

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
note() { printf '%s: %s\n' "$SELF" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage:  branch mode  $SELF --repo PATH --branch NAME --model FILE [options]
        model mode   $SELF --repo PATH --model FILE --model-b FILE [options]

Branch mode compares two commits on one model.  Model mode compares two model
files on one commit -- use it to compare quantizations for speed.

Required (branch mode):
  --repo PATH          Path to the ds4 git repository.
  --branch NAME        Branch, tag or commit-ish under test.
  --model FILE         GGUF model.  Relative paths resolve against --repo.

Required (model mode):
  --repo PATH          Path to the ds4 git repository.
  --model FILE         First GGUF model (arm A).
  --model-b FILE       Second GGUF model (arm B).  Presence selects model mode.

Options:
  --base-ref NAME      Branch mode: baseline commit-ish.      Default: main
  --ref NAME           Model mode: the single commit to use.  Default: main
  --order SPEC         Interleave order.                      Default: ABBA
                       A (or M) = arm A, B = arm B.  Presets:
                         abba / mbbm      A B B A            (4 runs)
                         baab / bmmb      B A A B            (4 runs)
                         tm8              A B B A B A A B    (8 runs)
                         tm16             Thue-Morse         (16 runs)
                       Or any literal string, e.g. --order ABBABAAB.
                       ABBA cancels linear drift; tm8 also cancels quadratic.
                       The report grades whatever order you choose.
  --prompt-file FILE   Benchmark text, relative to --repo.
                       Default: speed-bench/promessi_sposi.txt
  --ctx-start N        First measured frontier.               Default: 2048
  --ctx-max N          Last measured frontier.                Default: 16384
  --step-mul F         Multiplicative frontier step.          Default: 2
  --gen-tokens N       Greedy decode tokens per frontier.     Default: 128
  --ssd-streaming      Run both arms with --ssd-streaming.  Implies --warmup
                       unless --no-warmup is given, because streaming reads
                       from disk and a cold page cache would penalise run 1.
  --warmup             Do one short discarded run per distinct arm first.
  --no-warmup          Suppress the warmup --ssd-streaming would imply.
  --out-dir DIR        Where the report is written.  Default: \$HOME/ds4-bench-results
  --cache-dir DIR      Worktree and build cache.     Default: \$HOME/.cache/ds4-bench
  --bench-arg ARG      Extra argument passed to ds4-bench.  Repeatable.
  --label-a TEXT       Override arm A's column label.
  --label-b TEXT       Override arm B's column label.
  --rebuild            Rebuild even if a cached worktree binary exists.
  --keep-going         Do not abort the sweep if one run fails.
  -h, --help           This message.

Writes a timestamped Markdown report to --out-dir and prints its path.
USAGE
    exit 2
}

# ---------------------------------------------------------------- arguments

REPO="" BRANCH="" MODEL="" MODEL_B="" BASE_REF="main" REF="" ORDER="ABBA"
PROMPT_REL="speed-bench/promessi_sposi.txt"
CTX_START=2048 CTX_MAX=16384 STEP_MUL=2 GEN_TOKENS=128
OUT_DIR="$HOME/ds4-bench-results"
CACHE_DIR="$HOME/.cache/ds4-bench"
REBUILD=0 KEEP_GOING=0 SSD=0 WARMUP=-1
LABEL_A="" LABEL_B=""
EXTRA_ARGS=()

[ $# -eq 0 ] && usage
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)          REPO=${2:?--repo needs a value}; shift 2 ;;
        --branch)        BRANCH=${2:?--branch needs a value}; shift 2 ;;
        --model)         MODEL=${2:?--model needs a value}; shift 2 ;;
        --model-b)       MODEL_B=${2:?--model-b needs a value}; shift 2 ;;
        --base-ref)      BASE_REF=${2:?--base-ref needs a value}; shift 2 ;;
        --ref)           REF=${2:?--ref needs a value}; shift 2 ;;
        --order)         ORDER=${2:?--order needs a value}; shift 2 ;;
        --prompt-file)   PROMPT_REL=${2:?--prompt-file needs a value}; shift 2 ;;
        --ctx-start)     CTX_START=${2:?--ctx-start needs a value}; shift 2 ;;
        --ctx-max)       CTX_MAX=${2:?--ctx-max needs a value}; shift 2 ;;
        --step-mul)      STEP_MUL=${2:?--step-mul needs a value}; shift 2 ;;
        --gen-tokens)    GEN_TOKENS=${2:?--gen-tokens needs a value}; shift 2 ;;
        --out-dir)       OUT_DIR=${2:?--out-dir needs a value}; shift 2 ;;
        --cache-dir)     CACHE_DIR=${2:?--cache-dir needs a value}; shift 2 ;;
        --bench-arg)     EXTRA_ARGS+=("${2:?--bench-arg needs a value}"); shift 2 ;;
        --label-a)       LABEL_A=${2:?--label-a needs a value}; shift 2 ;;
        --label-b)       LABEL_B=${2:?--label-b needs a value}; shift 2 ;;
        --ssd-streaming) SSD=1; shift ;;
        --warmup)        WARMUP=1; shift ;;
        --no-warmup)     WARMUP=0; shift ;;
        --rebuild)       REBUILD=1; shift ;;
        --keep-going)    KEEP_GOING=1; shift ;;
        -h|--help)       usage ;;
        *)               die "unrecognised argument '$1' (--help for usage)" ;;
    esac
done

[ -n "$REPO" ]  || die "--repo is required"
[ -n "$MODEL" ] || die "--model is required"

if [ -n "$MODEL_B" ]; then MODE=model; else MODE=branch; fi
[ "$MODE" = "branch" ] && [ -z "$BRANCH" ] && die "--branch is required in branch mode (or pass --model-b for model mode)"

# --ssd-streaming implies a warmup unless the user said otherwise.
[ "$SSD" -eq 1 ] && [ "$WARMUP" -eq -1 ] && WARMUP=1
[ "$WARMUP" -eq -1 ] && WARMUP=0

# ------------------------------------------------------------- order parsing

ORDER_UP=$(printf '%s' "$ORDER" | tr '[:lower:]' '[:upper:]')
case "$ORDER_UP" in
    ABBA|MBBM)          SEQ_STR="ABBA" ;;
    BAAB|BMMB)          SEQ_STR="BAAB" ;;
    TM8|THUE-MORSE|TM)  SEQ_STR="ABBABAAB" ;;
    TM16)               SEQ_STR="ABBABAABBAABABBA" ;;
    *)                  SEQ_STR=$(printf '%s' "$ORDER_UP" | tr 'M' 'A') ;;
esac
case "$SEQ_STR" in
    *[!AB]*) die "--order must be a preset or a string of A/M and B only (got '$ORDER')" ;;
esac
N_RUNS=${#SEQ_STR}
[ "$N_RUNS" -ge 2 ] || die "--order needs at least two runs"
[ "$N_RUNS" -le 32 ] || die "--order is limited to 32 runs"
case "$SEQ_STR" in *A*) ;; *) die "--order contains no arm-A run" ;; esac
case "$SEQ_STR" in *B*) ;; *) die "--order contains no arm-B run" ;; esac

# ------------------------------------------------------------ preconditions

[ "$(uname -s)" = "Darwin" ] || die "macOS only (uname -s = $(uname -s))"
[ "$(uname -m)" = "arm64" ]  || die "Apple Silicon only (uname -m = $(uname -m))"
command -v git >/dev/null     || die "git not found"
command -v make >/dev/null    || die "make not found"
command -v python3 >/dev/null || die "python3 not found (install the Xcode Command Line Tools)"

REPO=$(cd "$REPO" 2>/dev/null && pwd) || die "no such directory: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"

resolve() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$REPO" "$1" ;; esac; }
MODEL=$(resolve "$MODEL")
PROMPT=$(resolve "$PROMPT_REL")
[ -f "$MODEL" ]  || die "model file not found: $MODEL"
[ -f "$PROMPT" ] || die "prompt file not found: $PROMPT"
if [ "$MODE" = "model" ]; then
    MODEL_B=$(resolve "$MODEL_B")
    [ -f "$MODEL_B" ] || die "model file not found: $MODEL_B"
    [ "$MODEL" != "$MODEL_B" ] && : || die "--model and --model-b are the same file; nothing to compare"
fi

# Resolve the commit(s) each arm runs at.
if [ "$MODE" = "branch" ]; then
    SHA_A=$(git -C "$REPO" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null) \
        || die "cannot resolve --base-ref '$BASE_REF'"
    SHA_B=$(git -C "$REPO" rev-parse --verify "${BRANCH}^{commit}" 2>/dev/null) \
        || die "cannot resolve --branch '$BRANCH'"
    if [ "$SHA_A" = "$SHA_B" ]; then
        die "--branch and --base-ref both resolve to ${SHA_A:0:12}; nothing to compare"
    fi
    REF_A=$BASE_REF; REF_B=$BRANCH
else
    [ -n "$REF" ] || REF=${BRANCH:-$BASE_REF}
    SHA_A=$(git -C "$REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null) \
        || die "cannot resolve --ref '$REF'"
    SHA_B=$SHA_A
    REF_A=$REF; REF_B=$REF
fi

# ------------------------------------------------------------- column labels

if [ -z "$LABEL_A" ] || [ -z "$LABEL_B" ]; then
    if [ "$MODE" = "branch" ]; then
        # Branch mode reads best with the familiar names.
        auto_a="main"; auto_b="branch"
        [ "$BASE_REF" = "main" ] || auto_a="base"
    else
        # Model mode: strip the shared leading part of the two file names so
        # the columns say what actually differs (Q2 vs Q4_K-kdaHeadQ8).
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

build_tree() {
    local dir=$1 label=$2
    if [ "$REBUILD" -eq 0 ] && [ -x "$dir/ds4-bench" ]; then
        note "$label: ds4-bench already built"; return 0
    fi
    note "$label: building ds4-bench"
    ( cd "$dir" && make ds4-bench -j"$(sysctl -n hw.ncpu)" ) >"$dir/.build.log" 2>&1 \
        || { tail -20 "$dir/.build.log" >&2; die "$label: build failed (see $dir/.build.log)"; }
    [ -x "$dir/ds4-bench" ] || die "$label: build produced no ds4-bench"
}

mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"
git -C "$REPO" worktree prune 2>/dev/null || true

TREE_A="$CACHE_DIR/wt-${SHA_A:0:12}"
ensure_worktree "$SHA_A" "$TREE_A" "arm A"
build_tree "$TREE_A" "arm A"
if [ "$SHA_B" = "$SHA_A" ]; then
    TREE_B=$TREE_A            # model mode: one commit, one build
else
    TREE_B="$CACHE_DIR/wt-${SHA_B:0:12}"
    ensure_worktree "$SHA_B" "$TREE_B" "arm B"
    build_tree "$TREE_B" "arm B"
fi
MODEL_A=$MODEL
[ "$MODE" = "model" ] || MODEL_B=$MODEL

# --------------------------------------------------------------- run the sweep

STAMP=$(date +%Y%m%d-%H%M%S)
slug() { printf '%s' "$1" | tr -cs '[:alnum:]._-' '-' | sed 's/^-*//; s/-*$//'; }
if [ "$MODE" = "branch" ]; then
    RUN_NAME="ds4-bench-$(slug "$BRANCH")-$(slug "$(basename "$MODEL" .gguf)")-$SEQ_STR-$STAMP"
else
    RUN_NAME="ds4-bench-models-$(slug "$LABEL_A")-vs-$(slug "$LABEL_B")-$SEQ_STR-$STAMP"
fi
WORK="$CACHE_DIR/runs/$RUN_NAME"
mkdir -p "$WORK" "$OUT_DIR" || die "cannot create output directories"
REPORT="$OUT_DIR/$RUN_NAME.md"

BENCH_ARGS=( --prompt-file "$PROMPT"
             --ctx-start "$CTX_START" --ctx-max "$CTX_MAX"
             --step-mul "$STEP_MUL" --gen-tokens "$GEN_TOKENS" )
[ "$SSD" -eq 1 ] && BENCH_ARGS+=( --ssd-streaming )
[ ${#EXTRA_ARGS[@]} -gt 0 ] && BENCH_ARGS+=("${EXTRA_ARGS[@]}")

arm_tree()  { case "$1" in A) printf '%s' "$TREE_A" ;; B) printf '%s' "$TREE_B" ;; esac; }
arm_model() { case "$1" in A) printf '%s' "$MODEL_A" ;; B) printf '%s' "$MODEL_B" ;; esac; }

note "mode $MODE; order $SEQ_STR ($N_RUNS runs); arms '$LABEL_A' vs '$LABEL_B'"

if [ "$WARMUP" -eq 1 ]; then
    for arm in A B; do
        note "warmup: arm $arm (discarded)"
        ( cd "$(arm_tree "$arm")" && ./ds4-bench -m "$(arm_model "$arm")" \
              --prompt-file "$PROMPT" --ctx-start "$CTX_START" --ctx-max "$CTX_START" \
              --gen-tokens 8 $( [ "$SSD" -eq 1 ] && printf '%s' --ssd-streaming ) ) \
            >"$WORK/warmup_$arm.stdout" 2>"$WORK/warmup_$arm.stderr" \
            || note "warmup: arm $arm returned nonzero (continuing)"
    done
fi

: >"$WORK/timeline.txt"
FAILED=0
count_a=0; count_b=0
i=0
while [ $i -lt "$N_RUNS" ]; do
    arm=${SEQ_STR:$i:1}
    i=$((i + 1))
    if [ "$arm" = "A" ]; then count_a=$((count_a + 1)); nth=$count_a
    else                      count_b=$((count_b + 1)); nth=$count_b
    fi
    label=$(printf '%s_%d' "$(printf '%s' "$arm" | tr 'AB' 'ab')" "$nth")
    started=$(date +%H:%M:%S)
    note "[$i/$N_RUNS] $label starting at $started"
    ( cd "$(arm_tree "$arm")" && ./ds4-bench -m "$(arm_model "$arm")" \
          "${BENCH_ARGS[@]}" --csv "$WORK/$label.csv" ) \
        >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    rc=$?
    ended=$(date +%H:%M:%S)
    printf '%d\t%s\t%s\t%s\t%s\t%d\n' "$i" "$label" "$arm" "$started" "$ended" "$rc" \
        >>"$WORK/timeline.txt"
    if [ $rc -ne 0 ]; then
        FAILED=1
        note "[$i/$N_RUNS] $label FAILED rc=$rc"
        tail -5 "$WORK/$label.stderr" >&2
        [ "$KEEP_GOING" -eq 1 ] || die "aborting after a failed run (--keep-going to continue); artifacts in $WORK"
    else
        note "[$i/$N_RUNS] $label done at $ended"
    fi
done
[ $FAILED -eq 0 ] || note "one or more runs failed; the report will be incomplete"

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

python3 - "$WORK" "$SEQ_STR" "$LABEL_A" "$LABEL_B" >"$WORK/results.md" <<'PY_EOF'
import csv, os, sys

work, seq, label_a, label_b = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def load(label):
    path = os.path.join(work, label + ".csv")
    if not os.path.exists(path):
        return None
    rows = {}
    with open(path) as fh:
        for row in csv.DictReader(fh):
            rows[int(row["ctx_tokens"])] = row
    return rows or None

n_a = seq.count("A")
n_b = seq.count("B")
labels_a = ["a_%d" % k for k in range(1, n_a + 1)]
labels_b = ["b_%d" % k for k in range(1, n_b + 1)]

runs = {}
for lb in labels_a + labels_b:
    r = load(lb)
    if r is not None:
        runs[lb] = r

expected = n_a + n_b
if len(runs) < expected:
    print("*Incomplete: only %d of %d runs produced a CSV (%s).*"
          % (len(runs), expected, ", ".join(sorted(runs)) or "none"))
    sys.exit(0)

frontiers = sorted(set.intersection(*(set(r) for r in runs.values())))
if not frontiers:
    print("*No frontier is common to all runs.*")
    sys.exit(0)

def series(labels, ctx, col):
    return [float(runs[lb][ctx][col]) for lb in labels]

def mean(v):
    return sum(v) / len(v)

def cell(v, fmt="%.2f"):
    return " / ".join(fmt % x for x in v)

def delta(b, a):
    return (mean(b) - mean(a)) / mean(a) * 100.0

# ---- design grading -------------------------------------------------------
# Interleaving works by making the arm variable orthogonal to time.  If both
# arms have the same mean position in the session, a linear drift adds the
# same amount to each and cancels.  Matching the mean of squared positions
# additionally cancels curvature, which is what thermal saturation looks like.
pos_a = [i + 1 for i, c in enumerate(seq) if c == "A"]
pos_b = [i + 1 for i, c in enumerate(seq) if c == "B"]
m1 = (mean(pos_a), mean(pos_b))
m2 = (mean([p * p for p in pos_a]), mean([p * p for p in pos_b]))
lin_ok = abs(m1[0] - m1[1]) < 1e-9
quad_ok = abs(m2[0] - m2[1]) < 1e-9

print("#### Interleave design")
print()
print("Order `%s` — %d runs (%d x %s, %d x %s)."
      % (seq, len(seq), n_a, label_a, n_b, label_b))
print()
print("| drift cancelled | | mean position |")
print("|---|---|---|")
print("| linear (steady warm-up or slow-down) | %s | %.3f vs %.3f |"
      % ("**yes**" if lin_ok else "**NO**", m1[0], m1[1]))
print("| quadratic (thermal saturation) | %s | %.2f vs %.2f |"
      % ("**yes**" if quad_ok else "no", m2[0], m2[1]))
print()
if not lin_ok:
    print("> **This order does not cancel linear drift.** The two arms sit at "
          "different average points in the session, so a machine that steadily "
          "warms or cools biases the comparison. Prefer `ABBA`, or `tm8`.")
    print()
elif not quad_ok:
    print("Linear drift cancels exactly. Curvature does not; if the effect "
          "below is small relative to the spread, re-run with `--order tm8`.")
    print()
else:
    print("Both linear and quadratic drift cancel exactly.")
    print()

# ---- main table -----------------------------------------------------------
print("#### Throughput")
print()
print("| frontier | %s prefill | %s prefill | prefill | %s decode | %s decode | decode |"
      % (label_a, label_b, label_a, label_b))
print("|---:|---:|---:|---:|---:|---:|---:|")
for ctx in frontiers:
    pa, pb = series(labels_a, ctx, "prefill_tps"), series(labels_b, ctx, "prefill_tps")
    da, db = series(labels_a, ctx, "gen_tps"),     series(labels_b, ctx, "gen_tps")
    print("| %d | %s | %s | %+.2f%% | %s | %s | **%+.2f%%** |" % (
        ctx, cell(pa), cell(pb), delta(pb, pa), cell(da), cell(db), delta(db, da)))

print()
print("Each cell lists that arm's runs in the order they ran; the delta "
      "compares the arms' means. Decode is `gen_tps` over the full generation "
      "at each frontier.")

print()
print("#### Time to first token (`gen_first_ms`, lower is better)")
print()
print("| frontier | %s | %s | delta |" % (label_a, label_b))
print("|---:|---:|---:|---:|")
for ctx in frontiers:
    a, b = series(labels_a, ctx, "gen_first_ms"), series(labels_b, ctx, "gen_first_ms")
    print("| %d | %s | %s | %+.2f%% |" % (ctx, cell(a), cell(b), delta(b, a)))

# ---- repeatability --------------------------------------------------------
def spread(v):
    return (max(v) - min(v)) / mean(v) * 100.0

worst, worst_where = 0.0, ""
for ctx in frontiers:
    for labels, shown in ((labels_a, label_a), (labels_b, label_b)):
        for col in ("prefill_tps", "gen_tps"):
            s = spread(series(labels, ctx, col))
            if s > worst:
                worst, worst_where = s, "%s %s at ctx %d" % (shown, col, ctx)

print()
print("#### Repeatability")
print()
print("Worst spread within a single arm's own runs: **%.2f%%** (%s). "
      "A delta is only meaningful well above this." % (worst, worst_where))
print()
print("| frontier | %s prefill | %s prefill | %s decode | %s decode |"
      % (label_a, label_b, label_a, label_b))
print("|---:|---:|---:|---:|---:|")
for ctx in frontiers:
    cells = []
    for col in ("prefill_tps", "gen_tps"):
        for labels in (labels_a, labels_b):
            cells.append("%.2f%%" % spread(series(labels, ctx, col)))
    print("| %d | %s | %s | %s | %s |" % (ctx, cells[0], cells[1], cells[2], cells[3]))

# ---- one-line summary, written aside for the report header ----------------
d_dec = mean([delta(series(labels_b, c, "gen_tps"),      series(labels_a, c, "gen_tps"))      for c in frontiers])
d_pre = mean([delta(series(labels_b, c, "prefill_tps"),  series(labels_a, c, "prefill_tps"))  for c in frontiers])
d_ttft = mean([delta(series(labels_b, c, "gen_first_ms"), series(labels_a, c, "gen_first_ms")) for c in frontiers])
with open(os.path.join(work, "summary.txt"), "w") as fh:
    fh.write("%+.1f%% generation, %+.1f%% prefill, %.1f%% %s TTFT"
             % (d_dec, d_pre, abs(d_ttft), "faster" if d_ttft < 0 else "slower"))
    fh.write("\n%d\n" % len(frontiers))
PY_EOF

fsize() { python3 -c "import os,sys; print('%.1f GiB' % (os.path.getsize(sys.argv[1])/1073741824))" "$1"; }
prompt_size=$(python3 -c "import os,sys; print('{:,} bytes'.format(os.path.getsize(sys.argv[1])))" "$PROMPT")

{
if [ "$MODE" = "branch" ]; then
    printf '### ds4 interleaved benchmark: `%s` vs `%s`\n\n' "$REF_B" "$REF_A"
else
    printf '### ds4 model comparison: `%s` vs `%s`\n\n' "$LABEL_B" "$LABEL_A"
fi
if [ -s "$WORK/summary.txt" ]; then
    summary_line=$(head -1 "$WORK/summary.txt")
    n_frontiers=$(sed -n '2p' "$WORK/summary.txt")
    printf '**%s** — mean across %s frontier' "$summary_line" "$n_frontiers"
    [ "$n_frontiers" = "1" ] || printf 's'
    printf ' (ctx %s' "$CTX_START"
    [ "$CTX_START" = "$CTX_MAX" ] || printf '–%s' "$CTX_MAX"
    if [ "$MODE" = "branch" ]; then
        printf ') on `%s`.\n\n' "$(basename "$MODEL_A")"
    else
        printf ').\n\n'
    fi
fi
printf '<sub>%s · order `%s` · %d runs · generated by ' \
    "$(date '+%Y-%m-%d %H:%M %Z')" "$SEQ_STR" "$N_RUNS"
printf '[ds4-interleaved-bench-helper](https://github.com/trueimage/ds4-interleaved-bench-helper)</sub>\n\n'

printf '#### What was compared\n\n'
printf '| | |\n|---|---|\n'
printf '| mode | %s |\n' "$MODE"
if [ "$MODE" = "branch" ]; then
    printf '| arm A (`%s`) | `%s` @ `%s` — %s |\n' "$LABEL_A" "$REF_A" "${SHA_A:0:12}" \
        "$(git -C "$REPO" log -1 --format=%s "$SHA_A")"
    printf '| arm B (`%s`) | `%s` @ `%s` — %s |\n' "$LABEL_B" "$REF_B" "${SHA_B:0:12}" \
        "$(git -C "$REPO" log -1 --format=%s "$SHA_B")"
    printf '| merge base | `%s` |\n' "$(git -C "$REPO" merge-base "$SHA_A" "$SHA_B" 2>/dev/null | cut -c1-12)"
    printf '| B vs A | %s commits ahead, %s behind |\n' \
        "$(git -C "$REPO" rev-list --count "$SHA_A..$SHA_B" 2>/dev/null || echo '?')" \
        "$(git -C "$REPO" rev-list --count "$SHA_B..$SHA_A" 2>/dev/null || echo '?')"
    printf '| model (both arms) | `%s` (%s) |\n' "$(basename "$MODEL_A")" "$(fsize "$MODEL_A")"
else
    printf '| commit (both arms) | `%s` @ `%s` — %s |\n' "$REF_A" "${SHA_A:0:12}" \
        "$(git -C "$REPO" log -1 --format=%s "$SHA_A")"
    printf '| arm A (`%s`) | `%s` (%s) |\n' "$LABEL_A" "$(basename "$MODEL_A")" "$(fsize "$MODEL_A")"
    printf '| arm B (`%s`) | `%s` (%s) |\n' "$LABEL_B" "$(basename "$MODEL_B")" "$(fsize "$MODEL_B")"
fi
printf '| repository | `%s` |\n' "$REPO"
printf '\n'

printf '#### Benchmark\n\n'
printf '| | |\n|---|---|\n'
printf '| prompt | `%s` (%s) |\n' "$(basename "$PROMPT")" "$prompt_size"
printf '| frontiers | %s to %s, step x%s |\n' "$CTX_START" "$CTX_MAX" "$STEP_MUL"
printf '| decode | %s greedy tokens per frontier |\n' "$GEN_TOKENS"
printf '| SSD streaming | %s |\n' "$( [ "$SSD" -eq 1 ] && echo 'on' || echo 'off' )"
printf '| warmup | %s |\n' "$( [ "$WARMUP" -eq 1 ] && echo 'one short discarded run per arm' || echo 'none' )"
printf '\n'
printf 'Arm A command:\n\n```\n./ds4-bench -m %s \\\n    %s\n```\n\n' \
    "$MODEL_A" "$(printf '%s ' "${BENCH_ARGS[@]}")"
if [ "$MODE" = "model" ]; then
    printf 'Arm B is the same command with `-m %s`.\n\n' "$MODEL_B"
else
    printf 'Arm B is the same command, run in the branch worktree.\n\n'
fi
if [ "$MODE" = "branch" ]; then
    printf 'Each arm is built and run in its own detached worktree, because the Metal\n'
    printf 'shaders are loaded from the `metal/` directory of the tree the binary runs\n'
    printf 'in, so a binary built at one commit but run in another tree would measure\n'
    printf 'the wrong shaders. Nothing is checked out while a run is in flight.\n\n'
else
    printf 'Both arms are the same build, run from one detached worktree at the commit\n'
    printf 'above, so the engine is held fixed and only the model file varies.\n\n'
fi
if [ "$SSD" -eq 1 ] && [ "$WARMUP" -ne 1 ]; then
    printf '> **Note:** SSD streaming was on with no warmup, so the first run of the\n'
    printf '> session read from a cold page cache and is likely understated.\n\n'
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
printf '\n'

printf '<details>\n<summary>Raw data — run timeline, engine load, per-run CSV</summary>\n\n'

printf '**Run order**\n\n'
printf '| # | run | arm | started | ended | exit |\n|---:|---|---|---|---|---:|\n'
while IFS=$'\t' read -r n label arm s e rc; do
    case "$arm" in A) shown=$LABEL_A ;; B) shown=$LABEL_B ;; esac
    printf '| %s | `%s` | %s | %s | %s | %s |\n' "$n" "$label" "$shown" "$s" "$e" "$rc"
done <"$WORK/timeline.txt"
printf '\n'
printf 'The first run of a session pays the model load from disk, so its wall time '
printf 'is not comparable to the others. Throughput is measured inside the run and '
printf 'is unaffected.\n\n'

first_label=$(head -1 "$WORK/timeline.txt" | cut -f2)
if [ -s "$WORK/$first_label.stderr" ]; then
    printf '**Engine load** (from `%s`)\n\n```\n' "$first_label"
    grep -E 'Metal device|memory:|resident model|GLM session|streaming|prefill chunk' \
        "$WORK/$first_label.stderr" 2>/dev/null | head -12
    printf '```\n\n'
fi

printf '**Per-run CSV**\n\n'
for f in "$WORK"/a_*.csv "$WORK"/b_*.csv; do
    [ -f "$f" ] || continue
    printf '`%s`\n```\n' "$(basename "$f" .csv)"
    cat "$f"
    printf '```\n\n'
done

printf 'Artifacts on disk: `%s`\n\n' "$WORK"
printf '</details>\n\n'

} >"$REPORT"

note "report written"
printf '%s\n' "$REPORT"
