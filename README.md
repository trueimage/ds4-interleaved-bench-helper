# ds4-interleaved-bench-helper

An interleaved A/B/B/A benchmark harness for [DwarfStar (`ds4`)](https://github.com/antirez/ds4)
on macOS / Apple Silicon. It measures a branch against a base ref with
`ds4-bench` and writes a self-contained Markdown report.

One script, no dependencies beyond what you already need to build `ds4`.

## Why interleaved

The obvious way to measure a branch is to run the baseline, then run the
branch, and compare. That cannot separate a real change from machine drift.
Thermal state, background load, and page-cache warmth all move between the two
runs, and they move in one direction, so a slow baseline and a fast branch look
exactly like an improvement.

This harness runs each arm twice, interleaved:

```
MBBM:  base, branch, branch, base
BMMB:  branch, base, base, branch
```

Each arm gets one run in each half of the session, so any monotonic drift lands
on both arms alike instead of on one. The two runs of a single arm also give
you a free error bar: the spread between them bounds how much of your measured
delta could be noise. The report prints that spread and the worst case across
the sweep, so a "+35%" with a 0.4% spread reads very differently from a "+2%"
with the same spread.

Both are reported. If a delta is not comfortably larger than the spread, it is
not a result.

## What it does

For each arm it:

1. Resolves the ref to a commit.
2. Creates a **detached git worktree** for that commit, cached by SHA.
3. Builds `ds4-bench` in that worktree.
4. Runs the sweep, one process at a time, writing a CSV per run.

Then it assembles a Markdown report with the results table, the machine
description, the exact commits, and the raw CSVs.

### Why worktrees, and not `git checkout`

Two reasons, both load-bearing:

- **Metal shaders are loaded at runtime from the `metal/` directory of the tree
  the binary runs in.** A binary built at one commit but executed inside a tree
  checked out at another measures the wrong shaders. Each arm therefore needs
  its own tree, built and run in place.
- **Nothing is checked out while a run is in flight.** A long benchmark and a
  `git checkout` in the same directory is a race that silently corrupts a
  result.

A side benefit: your working tree is never touched, and because the worktrees
are detached, benchmarking the branch you currently have checked out is not a
conflict.

## Requirements

- macOS on Apple Silicon. The script refuses to run anywhere else rather than
  guess at Linux/WSL behaviour.
- A `ds4` git repository that builds.
- Xcode Command Line Tools (`cc`, `make`, `python3`).
- A GGUF model, and enough memory to hold it resident.

## Install

```sh
curl -O https://raw.githubusercontent.com/trueimage/ds4-interleaved-bench-helper/main/ds4-interleaved-bench.sh
chmod +x ds4-interleaved-bench.sh
```

## Usage

```
ds4-interleaved-bench.sh --repo PATH --branch NAME --model FILE [options]
```

### Required

| flag | meaning |
|---|---|
| `--repo PATH` | Path to the `ds4` git repository. |
| `--branch NAME` | Branch, tag, or any commit-ish under test. |
| `--model FILE` | GGUF model file. Relative paths resolve against `--repo`. |

### Options

| flag | default | meaning |
|---|---|---|
| `--base-ref NAME` | `main` | Baseline to compare against. |
| `--order MBBM\|BMMB` | `MBBM` | Interleave order. Case-insensitive. |
| `--prompt-file FILE` | `speed-bench/promessi_sposi.txt` | Benchmark text, relative to `--repo`. |
| `--ctx-start N` | `2048` | First measured frontier. |
| `--ctx-max N` | `16384` | Last measured frontier. |
| `--step-mul F` | `2` | Multiplicative frontier step. |
| `--gen-tokens N` | `128` | Greedy decode tokens per frontier. |
| `--out-dir DIR` | `$HOME/ds4-bench-results` | Where the report is written. |
| `--cache-dir DIR` | `$HOME/.cache/ds4-bench` | Worktree and build cache. |
| `--bench-arg ARG` | — | Extra argument passed through to `ds4-bench`. Repeatable. |
| `--rebuild` | off | Rebuild even if a cached worktree binary exists. |
| `--keep-going` | off | Do not abort the sweep if one run fails. |

The report path is printed on stdout; progress goes to stderr, so
`REPORT=$(ds4-interleaved-bench.sh ...)` works.

### Examples

Default sweep of a branch against `main`:

```sh
./ds4-interleaved-bench.sh \
    --repo ~/ds4 \
    --branch my-metal-tuning \
    --model gguf/GLM-5.3-Flash-Q4_K.gguf
```

Reverse the order to check that the interleave itself is not shaping the
result — a real effect reproduces under both:

```sh
./ds4-interleaved-bench.sh \
    --repo ~/ds4 \
    --branch my-metal-tuning \
    --model gguf/GLM-5.3-Flash-Q4_K.gguf \
    --order BMMB
```

A quick smoke run, and a comparison against something other than `main`:

```sh
./ds4-interleaved-bench.sh --repo ~/ds4 --branch my-branch \
    --model gguf/model.gguf --ctx-start 2048 --ctx-max 2048 --gen-tokens 16

./ds4-interleaved-bench.sh --repo ~/ds4 --branch my-branch \
    --base-ref v1.2.0 --model gguf/model.gguf
```

Pass flags through to `ds4-bench`:

```sh
./ds4-interleaved-bench.sh --repo ~/ds4 --branch my-branch \
    --model gguf/model.gguf --bench-arg --ssd-streaming
```

## The report

Written to `$HOME/ds4-bench-results/ds4-bench-<branch>-<model>-<order>-<timestamp>.md`.
The timestamp makes every run a new file, so nothing is overwritten and reports
sort chronologically.

It contains:

- **What was compared** — branch and base names, commit hashes, subjects,
  commit dates, merge base, and ahead/behind counts.
- **Benchmark** — model and prompt with sizes, the frontier sweep, and the
  exact `ds4-bench` command.
- **Machine** — chip, model identifier, P/E core split, GPU cores, memory,
  macOS version and build, compiler version.
- **Results** — the table below, plus time to first token and repeatability.
- **Run order** — every run with start, end, and exit code.
- **Engine load** — the `ds4:` lines from the first run, so the model path and
  memory plan are on the record.
- **Raw CSV** — all four, in collapsible blocks.

The results table shows **both runs of each arm**, `first / second` in the
order they ran, with deltas comparing the two-run means:

| frontier | main prefill | branch prefill | prefill | main decode | branch decode | decode |
|---:|---:|---:|---:|---:|---:|---:|
| 2048 | 431.42 / 431.43 | 431.63 / 431.73 | +0.06% | 26.50 / 26.65 | 36.26 / 36.14 | **+36.22%** |
| 4096 | 392.29 / 392.24 | 392.41 / 392.48 | +0.05% | 25.96 / 26.05 | 35.31 / 35.27 | **+35.70%** |

Showing both runs rather than only the mean is deliberate: it lets a reader
audit the claim without opening the CSVs. Two tight pairs and a large gap
between them is a result. Two loose pairs is not.

Followed by the repeatability check:

```
Worst spread between an arm's own two runs: 0.56% (main gen_tps at ctx 2048).
A measured delta is only meaningful well above this.
```

Decode is `gen_tps`, throughput over the full generation at each frontier.
Prefill is `prefill_tps` over the newest interval at each frontier.

## Caching

Worktrees live in `$HOME/.cache/ds4-bench/wt-<sha>` and are keyed by commit, so
re-running the same pair of commits skips both builds. Per-run artifacts (CSV,
stdout, stderr) are kept under `$HOME/.cache/ds4-bench/runs/<run-name>/` and the
report links to them.

Expect roughly 130 MB per cached worktree. To reclaim:

```sh
rm -rf ~/.cache/ds4-bench
git -C ~/ds4 worktree prune
```

## Caveats

- **Committed state only.** Both arms are built from commits in detached
  worktrees, so uncommitted changes in your working tree are not measured.
  Commit first, or stash to a temporary commit.
- **One model process at a time.** The script serialises its own runs, but it
  cannot know about anything else you start. Do not run another large model
  alongside it.
- **The first run pays the cold model load.** Wall-clock times in the run-order
  table are not comparable across runs for that reason. Throughput is measured
  inside the run and is unaffected.
- **A speed result is not a correctness result.** This measures throughput and
  nothing else. If a change touches numerics, verify it separately — for
  greedy decode, byte-compare generations between the two builds.

## Exit codes

| code | meaning |
|---|---|
| `0` | All four runs completed and the report was written. |
| `1` | A precondition failed, or a run failed without `--keep-going`. |
| `2` | Usage error. |

## License

MIT. See [LICENSE](LICENSE).
