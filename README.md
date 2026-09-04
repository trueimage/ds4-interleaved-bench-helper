# ds4-interleaved-bench-helper

An interleaved A/B/B/A benchmark harness for [DwarfStar (`ds4`)](https://github.com/antirez/ds4)
on macOS / Apple Silicon. It measures a branch against a base ref with
`ds4-bench` and writes a self-contained Markdown report.

A companion script, [`ds4-quality-compare.sh`](#comparing-quality), answers
the question a speed report cannot: whether two GGUF files, or two commits,
still produce the same next-token distributions. It reports the KL divergence
between the arms at every position of a teacher-forced text.

Two scripts, no dependencies beyond what you already need to build `ds4`.

## Why interleaved

The obvious way to measure a branch is to run the baseline, then the branch,
and compare. That cannot separate a real change from machine drift. Thermal
state, background load and page-cache warmth all move between the two runs,
and they move in one direction, so a slow baseline and a fast branch look
exactly like an improvement.

Interleaving fixes this by making the arm variable orthogonal to time. If both
arms have the same **mean position** in the session, a steady drift adds the
same amount to each arm and cancels out. `ABBA` does this exactly: A runs at
positions 1 and 4, B at 2 and 3, both averaging 2.5.

Running each arm more than once also gives you a free error bar. The spread
between an arm's own runs bounds how much of your measured delta could be
noise, and the report prints it. A `+35%` with a `0.4%` spread and a `+2%`
with a `0.4%` spread are very different claims.

## Choosing an order

**Longer is not better. Balanced is better.** More runs shrink *random* noise,
as `1/sqrt(n)`. Only a balanced order removes *systematic* drift, and drift is
almost always the larger error. A badly shaped 8-run order is worse than
`ABBA` while costing twice the machine time.

The test is whether the arms match on the mean of their positions (cancels
linear drift) and on the mean of their squared positions (cancels curvature,
which is what thermal saturation looks like):

| order | runs | linear | quadratic | verdict |
|---|---:|---|---|---|
| `ABBA` / `MBBM` | 4 | cancels | no | **the default; right for almost everything** |
| `BAAB` / `BMMB` | 4 | cancels | no | same design, reversed; useful as a confirmation |
| `ABBABAAB` (`tm8`) | 8 | cancels | cancels | **worth it for small effects or a drifty machine** |
| Thue-Morse 16 (`tm16`) | 16 | cancels | cancels (+cubic) | overkill for this workload |
| `ABBAAB` | 6 | **NO** | no | *worse than `ABBA`* and 50% more time |
| `AABBBBAA` | 8 | cancels | no | linear-safe but maximally exposed to curvature |
| `ABABABAB` | 8 | **NO** | no | alternating never balances; avoid |

Two of those deserve comment, because they look reasonable and are not:

- **`ABBAAB` (6 runs).** A's mean position is 3.33, B's is 3.67. It does not
  even cancel linear drift, so it is a strictly worse design than the 4-run
  default while costing 50% more machine time. Extending `ABBA` by tacking
  runs on the end generally breaks it.
- **`AABBBBAA` (8 runs, "2M4B2M").** Balanced on the mean, so linear drift
  cancels. But every B run is clustered in the middle of the session and every
  A run at the ends, so any curvature maps directly onto the arm difference —
  and thermal saturation is exactly a curve that is steep early and flat
  later. This is close to the worst realistic 8-run shape.

The good 8-run order is the **Prouhet-Thue-Morse** sequence `ABBABAAB`
(`--order tm8`), which balances both moments. That is not a coincidence:
Prouhet's theorem is precisely the statement that this sequence splits
`1..2^k` into two sets with equal power sums.

### Practical advice

Run `ABBA` first and read the repeatability line. Then:

- **Spread much smaller than the effect** (the usual case for a real kernel
  change: 0.3% spread, 30% effect) — you are done. More runs cannot make a
  30% result more true, and `tm8` would only confirm it at twice the cost.
- **Effect within a few multiples of the spread** — escalate to `--order tm8`.
  This is where the extra runs genuinely buy something: 4 samples per arm
  instead of 2, plus curvature cancellation.
- **Effect comparable to the spread** — more runs will not save you. Fix the
  machine instead: close everything else, let it settle, and if using SSD
  streaming, warm the cache. Then re-measure.
- **Sanity check a surprising result** by re-running with `--order bmmb`. A
  real effect reproduces under the reversed order; an artefact of session
  shape often does not.

The report grades whatever order you pass and warns you if it is unbalanced,
so you do not have to keep this table in your head.

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

The benchmark script is self-contained:

```sh
curl -O https://raw.githubusercontent.com/trueimage/ds4-interleaved-bench-helper/main/ds4-interleaved-bench.sh
chmod +x ds4-interleaved-bench.sh
```

The quality script compiles a small scorer from `tools/`, so it needs the
repository:

```sh
git clone https://github.com/trueimage/ds4-interleaved-bench-helper.git
```

## Usage

```
branch mode   ds4-interleaved-bench.sh --repo PATH --branch NAME --model FILE [options]
model mode    ds4-interleaved-bench.sh --repo PATH --model FILE --model-b FILE [options]
```

Branch mode compares two commits on one model. Model mode compares two model
files on one commit. Passing `--model-b` selects model mode.

### Required

| flag | meaning |
|---|---|
| `--repo PATH` | Path to the `ds4` git repository. |
| `--model FILE` | GGUF model (arm A). Relative paths resolve against `--repo`. |
| `--branch NAME` | *Branch mode:* branch, tag or commit-ish under test. |
| `--model-b FILE` | *Model mode:* second GGUF model (arm B). |

### Options

| flag | default | meaning |
|---|---|---|
| `--base-ref NAME` | `main` | Branch mode: baseline commit-ish. |
| `--ref NAME` | `main` | Model mode: the single commit both arms run at. |
| `--order SPEC` | `ABBA` | Interleave order. Preset or literal A/M and B string. |
| `--prompt-file FILE` | `speed-bench/promessi_sposi.txt` | Benchmark text, relative to `--repo`. |
| `--ctx-start N` | `2048` | First measured frontier. |
| `--ctx-max N` | `16384` | Last measured frontier. |
| `--step-mul F` | `2` | Multiplicative frontier step. |
| `--gen-tokens N` | `128` | Greedy decode tokens per frontier. |
| `--ssd-streaming` | off | Run both arms with `--ssd-streaming`. Implies `--warmup`. |
| `--warmup` | off | One short discarded run per arm before the sequence. |
| `--no-warmup` | — | Suppress the warmup that `--ssd-streaming` implies. |
| `--label-a TEXT` | auto | Override arm A's column label. |
| `--label-b TEXT` | auto | Override arm B's column label. |
| `--out-dir DIR` | `$HOME/ds4-bench-results` | Where the report is written. |
| `--cache-dir DIR` | `$HOME/.cache/ds4-bench` | Worktree and build cache. |
| `--bench-arg ARG` | — | Extra argument passed through to `ds4-bench`. Repeatable. |
| `--rebuild` | off | Rebuild even if a cached worktree binary exists. |
| `--keep-going` | off | Do not abort the sweep if one run fails. |

Order presets: `abba` / `mbbm` (4), `baab` / `bmmb` (4), `tm8` (8), `tm16` (16).
Any literal string of `A`/`M` and `B` also works, e.g. `--order ABBABAAB`.

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

Eight runs when the effect is small, and pass-through of any other
`ds4-bench` flag:

```sh
./ds4-interleaved-bench.sh --repo ~/ds4 --branch my-branch \
    --model gguf/model.gguf --order tm8

./ds4-interleaved-bench.sh --repo ~/ds4 --branch my-branch \
    --model gguf/model.gguf --bench-arg --prefill-chunk --bench-arg 8192
```

## Comparing two models

Pass `--model-b` to compare two model files on a single commit, holding the
engine fixed. This is the right tool for asking which quantization is faster:

```sh
./ds4-interleaved-bench.sh \
    --repo ~/ds4 \
    --ref my-branch \
    --model   gguf/GLM-5.3-Flash-Q2.gguf \
    --model-b gguf/GLM-5.3-Flash-Q4_K-kdaHeadQ8.gguf
```

Both arms build and run from one worktree, so only the model file varies.
Column labels are derived by stripping the shared leading part of the two file
names, so the example above yields `Q2` and `Q4_K-kdaHeadQ8` rather than two
near-identical long names. Override with `--label-a` / `--label-b`.

`--ref` selects the commit; it defaults to `main`. Everything else — orders,
the report, the repeatability check — behaves identically to branch mode.

## SSD streaming

`--ssd-streaming` runs both arms with the flag and records it in the report.
(Any other `ds4-bench` flag can be passed through with `--bench-arg`.)

Streaming reads weights from disk during decode, which makes the OS page cache
part of what you are measuring. A cold first run is penalised, and that
penalty does not cancel the way thermal drift does, because it hits run 1 only.
So `--ssd-streaming` implies `--warmup`: one short discarded run per arm
before the sequence, touching every layer. Use `--no-warmup` to opt out, and
the report will note that run 1 was cold.

Expect noisier numbers than a resident run — I/O variance is larger than GPU
variance — so read the repeatability line before believing a small delta.

## The report

Written to `$HOME/ds4-bench-results/`, named
`ds4-bench-<branch>-<model>-<order>-<timestamp>.md` in branch mode and
`ds4-bench-models-<a>-vs-<b>-<order>-<timestamp>.md` in model mode. The
timestamp makes every run a new file, so nothing is overwritten and reports
sort chronologically.

It opens with a one-line summary — generation, prefill and time-to-first-token
deltas averaged across the frontiers — a link back to this repo, and a compact
metadata line. Headings are kept at `h3`/`h4` and all raw data is collapsed
behind a `<details>` block, so a report can be pasted straight into a pull
request or issue comment without dominating the thread.

It contains:

- **What was compared** — branch and base names, commit hashes, subjects,
  commit dates, merge base, and ahead/behind counts.
- **Benchmark** — model and prompt with sizes, the frontier sweep, and the
  exact `ds4-bench` command.
- **Machine** — chip, model identifier, P/E core split, GPU cores, memory,
  macOS version and build, compiler version.
- **Interleave design** — the order, and whether it cancels linear and
  quadratic drift, with a warning if it does not.
- **Results** — the table below, plus time to first token and repeatability.
- **Raw data** — run timeline, engine load and per-run CSV, in one
  collapsed `<details>` block.

The results table shows **every run of each arm**, in the order they ran,
with deltas comparing the arms' means:

| frontier | main prefill | branch prefill | prefill | main decode | branch decode | decode |
|---:|---:|---:|---:|---:|---:|---:|
| 2048 | 431.42 / 431.43 | 431.63 / 431.73 | +0.06% | 26.50 / 26.65 | 36.26 / 36.14 | **+36.22%** |
| 4096 | 392.29 / 392.24 | 392.41 / 392.48 | +0.05% | 25.96 / 26.05 | 35.31 / 35.27 | **+35.70%** |

Showing the individual runs rather than only the mean is deliberate: it lets
a reader audit the claim without opening the CSVs. Two tight groups with a
large gap between them is a result. Two loose groups is not.

In model mode the column headers are the two model labels instead of
`main` / `branch`.

Followed by the repeatability check:

```
Worst spread within a single arm's own runs: 0.56% (main gen_tps at ctx 2048).
A delta is only meaningful well above this.
```

Decode is `gen_tps`, throughput over the full generation at each frontier.
Prefill is `prefill_tps` over the newest interval at each frontier.

## Comparing quality

`ds4-interleaved-bench.sh` measures throughput and nothing else. A quantization
that decodes faster is usually faster because it is smaller, and a kernel
change that is faster may have changed the numerics. `ds4-quality-compare.sh`
is the other half of that judgement:

```sh
./ds4-quality-compare.sh \
    --repo ~/ds4 \
    --ref my-branch \
    --model   gguf/GLM-5.3-Flash-Q4_K.gguf \
    --model-b gguf/GLM-5.3-Flash-Q4_K-kdaHeadQ8.gguf
```

It teacher-forces a text through both arms one token at a time, the way
generation decodes, records the full next-token logits of arm A at every
position, and scores arm B against them. Arm A is the reference and arm B the
candidate, so the headline is **KL(A‖B)**: how far B's next-token distribution
sits from A's, averaged over every scored position.

Like the benchmark script it has two modes. **Model mode** (`--model-b`)
compares two GGUF files on one commit and is the tool for "did this
requantization cost anything?". **Branch mode** (`--branch`, `--base-ref`)
compares two commits on one GGUF and is the tool for "did this kernel change
alter the numerics?". The flags mean the same as in the benchmark script and
the two share a worktree cache, so a commit you have already benchmarked does
not build again.

### Why KL divergence

Perplexity is one number per model, and it measures fit to the text, not
fidelity to the reference. Two models can have the same perplexity while
disagreeing at every position, and a candidate can even score a *lower*
perplexity than the reference on a given text while being further from the
original weights. Greedy decode comparisons only see the top token, and a
change that moves probability mass around below it is invisible until
sampling exposes it.

KL(A‖B) is computed at every position from the full distributions, so it
sees every disagreement, weighted by how much probability the reference puts
on it. It is the same quantity `llama-perplexity --kl-divergence` reports, so
the scale is one people already have intuitions for. The report prints the
mean with its standard error, the median and tail percentiles, and the share
of positions in each order of magnitude, because a small mean can hide a few
badly wrong positions and the tail is where correctness problems live.

### Reading the report

The report leads with one line: mean KL(A‖B), the noise floor, top-1
agreement and the perplexity change. Below it:

- **What differs between the files** (model mode). Parsed from the two GGUF
  headers: tensor counts and bytes by type, every tensor whose type or shape
  changed, grouped by name pattern with the layers it affects, and whether the
  metadata (tokenizer, architecture parameters) is identical. For the example
  above it says that 137 tensors went from BF16 to Q8_0: the four KDA
  projections in 34 layers and `output.weight`.
- **Distribution divergence.** The KL(A‖B) statistics, the reverse direction
  and the Jensen–Shannon distance, then the **noise floor**: arm A is run a
  third time and scored against its own logits. Whatever divergence that
  produces is run-to-run variation in the engine, and a difference between
  the arms is only a finding when it is well above it. On a deterministic
  path the floor is exactly zero and the report says so.
- **Next-token agreement.** How often the top-1 token is the same, which is
  the fraction of positions where greedy decoding would not diverge; the
  mean top-k overlap; and how much probability B gives A's favourite token.
- **Fit to the text.** Each arm's mean NLL, perplexity and greedy hit rate.
  Read this for sanity, not for fidelity.
- **By position.** The same numbers in eight position buckets, with the
  reference's mean entropy alongside. KDA layers carry a recurrent state and
  attention accumulates over the window, so a candidate can look fine early
  in a context and drift later. A flat table is reassuring; a rising one is
  the thing to investigate. Divergence that merely tracks entropy (high where
  the text is unpredictable, low where it is not) is the ordinary shape.
- **Worst positions.** The positions with the largest divergence, with the
  preceding text, the actual next token with both arms' probability for it,
  and each arm's top-1 token. This is where a real regression becomes
  legible: one look tells you whether B is hedging between two plausible
  tokens or confidently wrong.

As a rough scale from llama.cpp's KLD reports on dense models against their
f16 originals: Q8_0 lands around 0.001, Q6_K a few thousandths, Q4_K_M a
few hundredths, Q2_K a few tenths. The scale is model dependent, so the
noise floor and the top-1 agreement are the safer anchors.

### Official-continuation NLL

`ds4` ships its own quality gate under `gguf-tools/quality-testing`: prompts
with continuations collected from the hosted model, and a scorer that reports
the NLL each local GGUF assigns to those exact continuations, plus first-token
match and greedy longest common prefix. Pass `--official MANIFEST` to run it
on both arms and include `compare_scores.py`'s comparison in the report:

```sh
./ds4-quality-compare.sh --repo ~/ds4 --ref my-branch \
    --model gguf/A.gguf --model-b gguf/B.gguf \
    --official gguf-tools/quality-testing/data/glm53-flash-openrouter-zai-fp8-100/manifest.tsv
```

The manifest path is relative to the ds4 tree; the tracked fixture sets are
listed in `gguf-tools/quality-testing/README.md`. This is a task-level view
against an external reference where KL is a distribution-level view against
arm A, and the two are complementary: KL tells you whether B moved, the
official score tells you whether it moved in a direction that matters.

### Options

| flag | default | meaning |
|---|---|---|
| `--ref NAME` | `main` | Model mode: the single commit both arms run at. |
| `--base-ref NAME` | `main` | Branch mode: reference commit-ish (arm A). |
| `--text FILE` | `speed-bench/promessi_sposi.txt` | Text to score, relative to `--repo`. |
| `--ctx N` | `4096` | Session context. Scoring never exceeds it. |
| `--tokens N` | all that fit | Score at most N positions. |
| `--top-k K` | `10` | Top-k overlap size. |
| `--worst N` | `12` | Positions listed in the worst-positions table. |
| `--no-noise-floor` | off | Skip the third pass of arm A against itself. |
| `--quality` | off | Run both arms with the engine's `--quality` (exact kernels). |
| `--ssd-streaming` | off | Run both arms with `--ssd-streaming`. |
| `--engine-arg ARG` | — | Extra argument for the scorer. Repeatable. |
| `--official MANIFEST` | — | Also run `score_official` on both arms. |
| `--official-ctx N` | `4096` | Context for the official scorer. |
| `--official-cases N` | all | Score only the first N official cases. |
| `--keep-logits` | off | Keep the reference logits file. |
| `--label-a`, `--label-b`, `--out-dir`, `--cache-dir`, `--rebuild` | | As in the benchmark script. |

### Cost

Each pass is one model load plus the scored positions at decode speed, so at
the default context a 30 tok/s model takes about two and a half minutes per
pass, and there are three passes: reference, candidate, noise floor. The
reference logits file holds one fp32 vector per position (about 2.5 GB for
4,064 positions of a 155k vocabulary) and is deleted after the report unless
`--keep-logits` is given, in which case any later model can be scored against
it without re-running arm A, using the scorer binary the script left in the
worktree (`~/.cache/ds4-bench/wt-<sha>/ds4-kld --load-logits FILE`; run
`ds4-kld --help` from there for its flags).

Scoring goes through `ds4_session_eval`, one token at a time, rather than a
batched prefill. That is deliberate: it measures the decode path users
actually generate with, and the same path for both arms.

### How it is built

`tools/ds4-kld.c` is a small C program against the public `ds4.h` session API.
The script compiles it inside each arm's worktree with `tools/ds4-kld.mk`,
which piggybacks on `ds4`'s own Makefile for the core objects and link flags,
and runs it from that worktree so the Metal shaders it loads belong to the
commit being measured. `score_official` is built the same way, from the
target `ds4`'s Makefile already provides.

## Caching

Worktrees live in `$HOME/.cache/ds4-bench/wt-<sha>` and are keyed by commit, so
re-running the same pair of commits skips both builds. Both scripts share the
cache, so a commit you have benchmarked is already built for a quality run
and vice versa. Per-run artifacts (CSV, stdout, stderr, and for quality runs
the per-position TSV) are kept under `$HOME/.cache/ds4-bench/runs/<run-name>/`
and the report links to them.

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
- **A speed result is not a correctness result.** The benchmark measures
  throughput and nothing else. If a change touches numerics, run
  `ds4-quality-compare.sh` in branch mode on the same pair of commits.
- **Model mode compares speed only.** A quantization that decodes faster is
  not thereby better; it is usually faster because it is smaller. Run
  `ds4-quality-compare.sh` in model mode on the same pair of files before
  drawing a conclusion.
- **KL divergence is relative to arm A, not to the truth.** If arm A is
  itself a lossy quantization, a low KL(A‖B) says B matches A, not that either
  is close to the original. Use the highest-precision file you can run as
  arm A, and use `--official` for a reference that does not depend on A.

## Exit codes

Both scripts:

| code | meaning |
|---|---|
| `0` | All runs completed and the report was written. |
| `1` | A precondition failed, or a run failed (without `--keep-going`, for the benchmark). |
| `2` | Usage error. |

## License

MIT. See [LICENSE](LICENSE).
