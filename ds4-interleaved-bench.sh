#!/bin/bash
#
# ds4-interleaved-bench.sh -- interleaved A/B/B/A ds4-bench comparison of a
# branch against a base ref, on macOS / Apple Silicon.
#
# Why interleaved: a single main-then-branch pair cannot separate a real change
# from thermal or machine drift.  Running MBBM (or BMMB) puts one run of each
# arm in each half of the session, so any monotonic drift lands on both arms
# alike and shows up as spread between an arm's two runs.
#
# Both arms are built and run in their own detached worktrees, because the
# Metal shaders are loaded from the `metal/` directory of the tree the binary
# runs in -- a binary built from one commit but run in another tree measures
# the wrong shaders.  Worktrees also mean no commit is ever checked out while a
# run is in flight.  Only one model process runs at a time.
#
# Usage:
#   ds4-interleaved-bench.sh --repo PATH --branch NAME --model FILE [options]
#
set -uo pipefail

readonly SELF=${0##*/}

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
note() { printf '%s: %s\n' "$SELF" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage: $SELF --repo PATH --branch NAME --model FILE [options]

Required:
  --repo PATH          Path to the ds4 git repository.
  --branch NAME        Branch (or any commit-ish) under test.
  --model FILE         GGUF model file.  Relative paths resolve against --repo.

Options:
  --base-ref NAME      Baseline to compare against.        Default: main
  --order MBBM|BMMB    Interleave order.                   Default: MBBM
                       MBBM = base, branch, branch, base
                       BMMB = branch, base, base, branch
  --prompt-file FILE   Benchmark text.  Relative to --repo.
                       Default: speed-bench/promessi_sposi.txt
  --ctx-start N        First measured frontier.            Default: 2048
  --ctx-max N          Last measured frontier.             Default: 16384
  --step-mul F         Multiplicative frontier step.       Default: 2
  --gen-tokens N       Greedy decode tokens per frontier.  Default: 128
  --out-dir DIR        Where the report is written.        Default: \$HOME/ds4-bench-results
  --cache-dir DIR      Worktree/build cache.               Default: \$HOME/.cache/ds4-bench
  --bench-arg ARG      Extra argument passed through to ds4-bench.  Repeatable.
  --rebuild            Force a rebuild even if a cached worktree binary exists.
  --keep-going         Do not abort the sweep if one run fails.
  -h, --help           This message.

Writes a timestamped Markdown report to --out-dir and prints its path.
USAGE
    exit 2
}

# ---------------------------------------------------------------- arguments

REPO="" BRANCH="" MODEL="" BASE_REF="main" ORDER="MBBM"
PROMPT_REL="speed-bench/promessi_sposi.txt"
CTX_START=2048 CTX_MAX=16384 STEP_MUL=2 GEN_TOKENS=128
OUT_DIR="$HOME/ds4-bench-results"
CACHE_DIR="$HOME/.cache/ds4-bench"
REBUILD=0 KEEP_GOING=0
EXTRA_ARGS=()

[ $# -eq 0 ] && usage
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)         REPO=${2:?--repo needs a value}; shift 2 ;;
        --branch)       BRANCH=${2:?--branch needs a value}; shift 2 ;;
        --model)        MODEL=${2:?--model needs a value}; shift 2 ;;
        --base-ref)     BASE_REF=${2:?--base-ref needs a value}; shift 2 ;;
        --order)        ORDER=${2:?--order needs a value}; shift 2 ;;
        --prompt-file)  PROMPT_REL=${2:?--prompt-file needs a value}; shift 2 ;;
        --ctx-start)    CTX_START=${2:?--ctx-start needs a value}; shift 2 ;;
        --ctx-max)      CTX_MAX=${2:?--ctx-max needs a value}; shift 2 ;;
        --step-mul)     STEP_MUL=${2:?--step-mul needs a value}; shift 2 ;;
        --gen-tokens)   GEN_TOKENS=${2:?--gen-tokens needs a value}; shift 2 ;;
        --out-dir)      OUT_DIR=${2:?--out-dir needs a value}; shift 2 ;;
        --cache-dir)    CACHE_DIR=${2:?--cache-dir needs a value}; shift 2 ;;
        --bench-arg)    EXTRA_ARGS+=("${2:?--bench-arg needs a value}"); shift 2 ;;
        --rebuild)      REBUILD=1; shift ;;
        --keep-going)   KEEP_GOING=1; shift ;;
        -h|--help)      usage ;;
        *)              die "unrecognised argument '$1' (--help for usage)" ;;
    esac
done

[ -n "$REPO" ]   || die "--repo is required"
[ -n "$BRANCH" ] || die "--branch is required"
[ -n "$MODEL" ]  || die "--model is required"

ORDER=$(printf '%s' "$ORDER" | tr '[:lower:]' '[:upper:]')
case "$ORDER" in MBBM|BMMB) ;; *) die "--order must be MBBM or BMMB" ;; esac

# ------------------------------------------------------------ preconditions

[ "$(uname -s)" = "Darwin" ] || die "macOS only (uname -s = $(uname -s))"
[ "$(uname -m)" = "arm64" ]  || die "Apple Silicon only (uname -m = $(uname -m))"
command -v git >/dev/null     || die "git not found"
command -v make >/dev/null    || die "make not found"
command -v python3 >/dev/null || die "python3 not found (install the Xcode Command Line Tools)"

REPO=$(cd "$REPO" 2>/dev/null && pwd) || die "no such directory: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"

# Resolve the model and prompt to absolute paths; a relative path is taken
# against the repo, which is where gguf/ and speed-bench/ live.
resolve() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$REPO" "$1" ;;
    esac
}
MODEL=$(resolve "$MODEL")
PROMPT=$(resolve "$PROMPT_REL")
[ -f "$MODEL" ]  || die "model file not found: $MODEL"
[ -f "$PROMPT" ] || die "prompt file not found: $PROMPT"

BASE_SHA=$(git -C "$REPO" rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null) \
    || die "cannot resolve --base-ref '$BASE_REF' in $REPO"
BRANCH_SHA=$(git -C "$REPO" rev-parse --verify "${BRANCH}^{commit}" 2>/dev/null) \
    || die "cannot resolve --branch '$BRANCH' in $REPO"
if [ "$BASE_SHA" = "$BRANCH_SHA" ]; then
    die "--branch and --base-ref both resolve to ${BASE_SHA:0:12}; nothing to compare"
fi

# ------------------------------------------------------------------ worktrees

# Cached per commit, so a repeat run at the same pair of commits reuses the
# build.  Detached, so a branch already checked out elsewhere is not a conflict.
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
        note "$label: ds4-bench already built"
        return 0
    fi
    note "$label: building ds4-bench"
    ( cd "$dir" && make ds4-bench -j"$(sysctl -n hw.ncpu)" ) >"$dir/.build.log" 2>&1 \
        || { tail -20 "$dir/.build.log" >&2; die "$label: build failed (see $dir/.build.log)"; }
    [ -x "$dir/ds4-bench" ] || die "$label: build produced no ds4-bench"
}

mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"
git -C "$REPO" worktree prune 2>/dev/null || true

BASE_TREE="$CACHE_DIR/wt-${BASE_SHA:0:12}"
BRANCH_TREE="$CACHE_DIR/wt-${BRANCH_SHA:0:12}"
ensure_worktree "$BASE_SHA"   "$BASE_TREE"   "base"
ensure_worktree "$BRANCH_SHA" "$BRANCH_TREE" "branch"
build_tree "$BASE_TREE"   "base"
build_tree "$BRANCH_TREE" "branch"

# --------------------------------------------------------------- run the sweep

STAMP=$(date +%Y%m%d-%H%M%S)
slug() { printf '%s' "$1" | tr -cs '[:alnum:]._-' '-' | sed 's/^-*//; s/-*$//'; }
RUN_NAME="ds4-bench-$(slug "$BRANCH")-$(slug "$(basename "$MODEL" .gguf)")-$ORDER-$STAMP"
WORK="$CACHE_DIR/runs/$RUN_NAME"
mkdir -p "$WORK" "$OUT_DIR" || die "cannot create output directories"
REPORT="$OUT_DIR/$RUN_NAME.md"

if [ "$ORDER" = "MBBM" ]; then
    SEQ=(base:1 branch:1 branch:2 base:2)
else
    SEQ=(branch:1 base:1 base:2 branch:2)
fi

BENCH_ARGS=( --prompt-file "$PROMPT"
             --ctx-start "$CTX_START" --ctx-max "$CTX_MAX"
             --step-mul "$STEP_MUL" --gen-tokens "$GEN_TOKENS" )
[ ${#EXTRA_ARGS[@]} -gt 0 ] && BENCH_ARGS+=("${EXTRA_ARGS[@]}")

note "order $ORDER; model $(basename "$MODEL"); frontiers $CTX_START..$CTX_MAX x$STEP_MUL"
: >"$WORK/timeline.txt"
FAILED=0
step=0
for item in "${SEQ[@]}"; do
    arm=${item%%:*}; nth=${item##*:}
    label="${arm}_${nth}"
    step=$((step + 1))
    case "$arm" in
        base)   tree=$BASE_TREE ;;
        branch) tree=$BRANCH_TREE ;;
    esac
    started=$(date +%H:%M:%S)
    note "[$step/4] $label starting at $started"
    ( cd "$tree" && ./ds4-bench -m "$MODEL" "${BENCH_ARGS[@]}" --csv "$WORK/$label.csv" ) \
        >"$WORK/$label.stdout" 2>"$WORK/$label.stderr"
    rc=$?
    ended=$(date +%H:%M:%S)
    printf '%d\t%s\t%s\t%s\t%s\t%d\n' "$step" "$label" "$arm" "$started" "$ended" "$rc" \
        >>"$WORK/timeline.txt"
    if [ $rc -ne 0 ]; then
        FAILED=1
        note "[$step/4] $label FAILED rc=$rc"
        tail -5 "$WORK/$label.stderr" >&2
        [ "$KEEP_GOING" -eq 1 ] || die "aborting after a failed run (--keep-going to continue); artifacts in $WORK"
    else
        note "[$step/4] $label done at $ended"
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

# ------------------------------------------------------------------- report

export BENCH_WORK="$WORK" BENCH_ORDER="$ORDER"
python3 - "$WORK" "$ORDER" >"$WORK/results.md" <<'PY_EOF'
import csv, os, sys

work, order = sys.argv[1], sys.argv[2]
arms = [("base", "main"), ("branch", "branch")]

def load(label):
    path = os.path.join(work, label + ".csv")
    if not os.path.exists(path):
        return None
    rows = {}
    with open(path) as fh:
        for row in csv.DictReader(fh):
            rows[int(row["ctx_tokens"])] = row
    return rows or None

runs = {}
for arm, _ in arms:
    for n in (1, 2):
        label = "%s_%d" % (arm, n)
        r = load(label)
        if r is not None:
            runs[label] = r

if len(runs) < 4:
    print("*Incomplete: only %d of 4 runs produced a CSV (%s).*"
          % (len(runs), ", ".join(sorted(runs)) or "none"))
    sys.exit(0)

frontiers = sorted(set.intersection(*(set(r) for r in runs.values())))
if not frontiers:
    print("*No frontier is common to all four runs.*")
    sys.exit(0)

def pair(arm, ctx, col):
    return [float(runs["%s_%d" % (arm, n)][ctx][col]) for n in (1, 2)]

def mean(v):
    return sum(v) / len(v)

def cell(v, fmt):
    return " / ".join(fmt % x for x in v)

def delta(b, m):
    return (mean(b) - mean(m)) / mean(m) * 100.0

print("| frontier | main prefill | branch prefill | prefill | main decode | branch decode | decode |")
print("|---:|---:|---:|---:|---:|---:|---:|")
for ctx in frontiers:
    mp, bp = pair("base", ctx, "prefill_tps"), pair("branch", ctx, "prefill_tps")
    md, bd = pair("base", ctx, "gen_tps"),     pair("branch", ctx, "gen_tps")
    print("| %d | %s | %s | %+.2f%% | %s | %s | **%+.2f%%** |" % (
        ctx, cell(mp, "%.2f"), cell(bp, "%.2f"), delta(bp, mp),
        cell(md, "%.2f"), cell(bd, "%.2f"), delta(bd, md)))

print()
print("Each cell shows both runs of that arm in the order they ran; the delta "
      "compares the two-run means. Decode is `gen_tps` over the full "
      "generation at each frontier.")

# Time to first token: not in the requested columns, but it is the other half
# of what a decode change does, and it is free to report.
print()
print("### Time to first token (`gen_first_ms`, lower is better)")
print()
print("| frontier | main | branch | delta |")
print("|---:|---:|---:|---:|")
for ctx in frontiers:
    m, b = pair("base", ctx, "gen_first_ms"), pair("branch", ctx, "gen_first_ms")
    print("| %d | %s | %s | %+.2f%% |" % (ctx, cell(m, "%.2f"), cell(b, "%.2f"), delta(b, m)))

# Repeatability: the spread between an arm's own two runs bounds how much of a
# delta could be drift rather than the change under test.
worst = 0.0
worst_where = ""
for ctx in frontiers:
    for arm, shown in arms:
        for col in ("prefill_tps", "gen_tps"):
            v = pair(arm, ctx, col)
            s = abs(v[0] - v[1]) / mean(v) * 100.0
            if s > worst:
                worst, worst_where = s, "%s %s at ctx %d" % (shown, col, ctx)
print()
print("### Repeatability")
print()
print("Worst spread between an arm's own two runs: **%.2f%%** (%s). "
      "A measured delta is only meaningful well above this." % (worst, worst_where))
print()
print("| frontier | main prefill | branch prefill | main decode | branch decode |")
print("|---:|---:|---:|---:|---:|")
for ctx in frontiers:
    out = []
    for col in ("prefill_tps", "gen_tps"):
        for arm, _ in arms:
            v = pair(arm, ctx, col)
            out.append("%.2f%%" % (abs(v[0] - v[1]) / mean(v) * 100.0))
    print("| %d | %s | %s | %s | %s |" % (ctx, out[0], out[1], out[2], out[3]))
PY_EOF

model_size=$(python3 -c "import os,sys; print('%.1f GiB' % (os.path.getsize(sys.argv[1])/1073741824))" "$MODEL")
prompt_size=$(python3 -c "import os,sys; print('{:,} bytes'.format(os.path.getsize(sys.argv[1])))" "$PROMPT")
base_subj=$(git -C "$REPO" log -1 --format=%s "$BASE_SHA")
branch_subj=$(git -C "$REPO" log -1 --format=%s "$BRANCH_SHA")
base_date=$(git -C "$REPO" log -1 --format=%cI "$BASE_SHA")
branch_date=$(git -C "$REPO" log -1 --format=%cI "$BRANCH_SHA")
merge_base=$(git -C "$REPO" merge-base "$BASE_SHA" "$BRANCH_SHA" 2>/dev/null || echo "n/a")
ahead=$(git -C "$REPO" rev-list --count "$BASE_SHA..$BRANCH_SHA" 2>/dev/null || echo "?")
behind=$(git -C "$REPO" rev-list --count "$BRANCH_SHA..$BASE_SHA" 2>/dev/null || echo "?")

if [ "$ORDER" = "MBBM" ]; then
    order_desc="MBBM — base, branch, branch, base"
else
    order_desc="BMMB — branch, base, base, branch"
fi

{
printf '# ds4 interleaved benchmark: `%s` vs `%s`\n\n' "$BRANCH" "$BASE_REF"
printf '%s · order **%s** · 4 runs, one process at a time\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$ORDER"

printf '## What was compared\n\n'
printf '| | |\n|---|---|\n'
printf '| base | `%s` @ `%s` — %s |\n' "$BASE_REF" "${BASE_SHA:0:12}" "$base_subj"
printf '| base committed | %s |\n' "$base_date"
printf '| branch | `%s` @ `%s` — %s |\n' "$BRANCH" "${BRANCH_SHA:0:12}" "$branch_subj"
printf '| branch committed | %s |\n' "$branch_date"
printf '| merge base | `%s` |\n' "${merge_base:0:12}"
printf '| branch vs base | %s commits ahead, %s behind |\n' "$ahead" "$behind"
printf '| repository | `%s` |\n' "$REPO"
printf '\n'

printf '## Benchmark\n\n'
printf '| | |\n|---|---|\n'
printf '| model | `%s` (%s) |\n' "$(basename "$MODEL")" "$model_size"
printf '| prompt | `%s` (%s) |\n' "$(basename "$PROMPT")" "$prompt_size"
printf '| frontiers | %s to %s, step x%s |\n' "$CTX_START" "$CTX_MAX" "$STEP_MUL"
printf '| decode | %s greedy tokens per frontier |\n' "$GEN_TOKENS"
printf '| order | %s |\n' "$order_desc"
printf '\n'
printf 'Command run in each arm'\''s worktree:\n\n'
printf '```\n./ds4-bench -m %s \\\n' "$MODEL"
printf '    --prompt-file %s \\\n' "$PROMPT"
printf '    --ctx-start %s --ctx-max %s --step-mul %s --gen-tokens %s' \
       "$CTX_START" "$CTX_MAX" "$STEP_MUL" "$GEN_TOKENS"
if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then printf ' \\\n    %s' "${EXTRA_ARGS[*]}"; fi
printf '\n```\n\n'
printf 'Each arm is built and run in its own detached worktree, because the Metal\n'
printf 'shaders are loaded from the `metal/` directory of the tree the binary runs\n'
printf 'in. Nothing is checked out while a run is in flight.\n\n'

printf '## Machine\n\n'
printf '| | |\n|---|---|\n'
printf '| chip | %s |\n' "$chip"
printf '| model identifier | %s |\n' "$hw_model"
printf '| CPU | %s |\n' "$cpu_desc"
[ -n "$sp_gpu_cores" ] && printf '| GPU | %s cores |\n' "$sp_gpu_cores"
printf '| memory | %s |\n' "$mem_desc"
printf '| macOS | %s (%s) |\n' "$os_ver" "$os_build"
printf '| compiler | %s |\n' "$cc_ver"
printf '\n'

printf '## Results\n\n'
cat "$WORK/results.md"
printf '\n'

printf '## Run order\n\n'
printf '| # | run | arm | started | ended | exit |\n|---:|---|---|---|---|---:|\n'
while IFS=$'\t' read -r n label arm s e rc; do
    printf '| %s | `%s` | %s | %s | %s | %s |\n' "$n" "$label" "$arm" "$s" "$e" "$rc"
done <"$WORK/timeline.txt"
printf '\n'
printf 'The first run of a session pays the model load from disk, so its wall time '
printf 'is not comparable to the others. Throughput is measured inside the run and '
printf 'is unaffected.\n\n'

first_label=$(head -1 "$WORK/timeline.txt" | cut -f2)
if [ -s "$WORK/$first_label.stderr" ]; then
    printf '## Engine load (from `%s`)\n\n```\n' "$first_label"
    grep -E 'Metal device|memory:|resident model|GLM session|graph|prefill chunk' \
        "$WORK/$first_label.stderr" 2>/dev/null | head -12
    printf '```\n\n'
fi

printf '## Raw CSV\n\n'
for label in base_1 base_2 branch_1 branch_2; do
    [ -f "$WORK/$label.csv" ] || continue
    printf '<details><summary><code>%s</code></summary>\n\n```\n' "$label"
    cat "$WORK/$label.csv"
    printf '```\n\n</details>\n\n'
done

printf -- '---\n\n'
printf 'Artifacts (CSV, stdout, stderr per run): `%s`\n' "$WORK"
} >"$REPORT"

note "report written"
printf '%s\n' "$REPORT"
