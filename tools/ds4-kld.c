/*
 * ds4-kld.c -- teacher-forced next-token distribution scorer for ds4.
 *
 * Runs one GGUF over a text one token at a time and, at every position,
 * looks at the full next-token distribution the model produces.  Two modes:
 *
 *   reference   --save-logits FILE   record the raw logits of every scored
 *                                    position to FILE (fp32, one row per
 *                                    position) and write per-position NLL.
 *   compare     --load-logits FILE   run a second model over the same token
 *                                    stream and emit, per position, the KL
 *                                    divergence of the two distributions,
 *                                    top-1 agreement, top-k overlap and both
 *                                    models' NLL of the actual next token.
 *
 * The token stream is checked to be identical in both runs, so a tokenizer
 * difference between two GGUFs is reported instead of silently skewing the
 * result.  Scoring goes through ds4_session_eval, the same path generation
 * uses, so what is measured is the decode numerics users actually get.
 *
 * Built against a ds4 tree's core objects by ds4-kld.mk; see
 * ds4-quality-compare.sh for the driver that runs both arms and writes a
 * report.
 */

#include "ds4.h"
#include "ds4_ssd.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define KLD_MAGIC "DS4KLD01"
#define KLD_VERSION 1u
#define KLD_MAX_TOP_K 64

typedef struct {
    char magic[8];
    uint32_t version;
    uint32_t vocab;
    uint32_t prefix;
    uint32_t scored;
    uint32_t ctx;
    uint32_t reserved[3];
} kld_header;
_Static_assert(sizeof(kld_header) == 40, "kld_header layout");

static void die(const char *msg) {
    fprintf(stderr, "ds4-kld: %s\n", msg);
    exit(1);
}

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s MODEL --text FILE (--save-logits FILE | --load-logits FILE) --tsv OUT\n"
            "          [--ctx N] [--tokens N] [--prefix N] [--top-k K] [--threads N]\n"
            "          [--quality] [--ssd-streaming] [--ssd-streaming-cold]\n"
            "          [--ssd-streaming-cache-experts N|NGB] [--ssd-streaming-preload-experts N]\n"
            "\n"
            "  --text FILE      raw text to score, tokenized with the model's own tokenizer\n"
            "  --save-logits    reference run: record every scored position's logits\n"
            "  --load-logits    compare run: score against a recorded reference\n"
            "  --tsv OUT        per-position results (tab separated, header row)\n"
            "  --ctx N          session context (default 4096); scoring never exceeds it\n"
            "  --tokens N       score at most N positions (default: all that fit)\n"
            "  --prefix N       seed positions before scoring starts (default 32)\n"
            "  --top-k K        top-k overlap size in compare mode (default 10, max %d)\n",
            prog, KLD_MAX_TOP_K);
    exit(2);
}

static const char *need_arg(int *i, int argc, char **argv, const char *opt) {
    if (*i + 1 >= argc) {
        fprintf(stderr, "ds4-kld: %s requires an argument\n", opt);
        exit(2);
    }
    return argv[++*i];
}

static int parse_positive_int(const char *s, const char *opt) {
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || !end || *end != '\0' || v <= 0 || v > INT_MAX) {
        fprintf(stderr, "ds4-kld: %s must be a positive integer\n", opt);
        exit(2);
    }
    return (int)v;
}

static char *read_file(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "ds4-kld: open %s: %s\n", path, strerror(errno));
        exit(1);
    }
    if (fseek(fp, 0, SEEK_END) != 0) die("fseek failed");
    long n = ftell(fp);
    if (n < 0) die("ftell failed");
    if (fseek(fp, 0, SEEK_SET) != 0) die("fseek failed");
    char *buf = malloc((size_t)n + 1);
    if (!buf) die("out of memory");
    if (n && fread(buf, 1, (size_t)n, fp) != (size_t)n) die("read failed");
    buf[n] = '\0';
    fclose(fp);
    return buf;
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Token text goes into a TSV cell, so tabs, newlines, backslashes and
 * control bytes are escaped C-style.  Partial UTF-8 sequences pass through
 * untouched; the reader decodes with replacement. */
static void put_escaped(FILE *fp, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        const unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '\\': fputs("\\\\", fp); break;
        case '\t': fputs("\\t", fp); break;
        case '\n': fputs("\\n", fp); break;
        case '\r': fputs("\\r", fp); break;
        default:
            if (c < 0x20 || c == 0x7f) fprintf(fp, "\\x%02x", c);
            else fputc(c, fp);
        }
    }
}

static void put_token_text(FILE *fp, ds4_engine *e, int id) {
    size_t n = 0;
    char *t = ds4_token_text(e, id, &n);
    if (t) {
        put_escaped(fp, t, n);
        free(t);
    }
}

/* Everything derived from one logits vector: log-sum-exp (so log p_i is
 * l_i - lse), argmax, entropy in nats, and the top-k ids in descending
 * order.  All accumulation is in double. */
typedef struct {
    double lse;
    double entropy;
    int argmax;
    int n_top;
    int top[KLD_MAX_TOP_K];
} dist_info;

static bool summarize(const float *l, int n, int k, dist_info *d) {
    float mx = -INFINITY;
    int best = -1;
    for (int i = 0; i < n; i++) {
        if (!isfinite(l[i])) return false;
        if (best < 0 || l[i] > mx) {
            mx = l[i];
            best = i;
        }
    }
    if (best < 0) return false;
    double sum = 0.0;
    for (int i = 0; i < n; i++) sum += exp((double)l[i] - (double)mx);
    d->lse = (double)mx + log(sum);
    d->argmax = best;

    double h = 0.0;
    for (int i = 0; i < n; i++) {
        const double lp = (double)l[i] - d->lse;
        const double p = exp(lp);
        if (p > 0.0) h -= p * lp;
    }
    d->entropy = h;

    d->n_top = 0;
    for (int i = 0; i < n; i++) {
        if (d->n_top == k && l[i] <= l[d->top[k - 1]]) continue;
        int pos = d->n_top < k ? d->n_top : k - 1;
        while (pos > 0 && l[i] > l[d->top[pos - 1]]) {
            d->top[pos] = d->top[pos - 1];
            pos--;
        }
        d->top[pos] = i;
        if (d->n_top < k) d->n_top++;
    }
    return true;
}

static double logprob_of(const float *l, const dist_info *d, int id) {
    return (double)l[id] - d->lse;
}

static bool write_all(FILE *fp, const void *p, size_t n) {
    return fwrite(p, 1, n, fp) == n;
}

int main(int argc, char **argv) {
    const char *model_path = NULL;
    const char *text_path = NULL;
    const char *save_path = NULL;
    const char *load_path = NULL;
    const char *tsv_path = NULL;
    int ctx_size = 4096;
    int tokens_cap = 0;
    int prefix_len = 32;
    int top_k = 10;
    int n_threads = 0;
    bool quality = false;
    bool ssd_streaming = false;
    bool ssd_streaming_cold = false;
    uint32_t ssd_cache_experts = 0;
    uint64_t ssd_cache_bytes = 0;
    uint32_t ssd_preload_experts = 0;

    if (argc < 2) usage(argv[0]);
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!strcmp(arg, "--text")) text_path = need_arg(&i, argc, argv, arg);
        else if (!strcmp(arg, "--save-logits")) save_path = need_arg(&i, argc, argv, arg);
        else if (!strcmp(arg, "--load-logits")) load_path = need_arg(&i, argc, argv, arg);
        else if (!strcmp(arg, "--tsv")) tsv_path = need_arg(&i, argc, argv, arg);
        else if (!strcmp(arg, "--ctx")) ctx_size = parse_positive_int(need_arg(&i, argc, argv, arg), arg);
        else if (!strcmp(arg, "--tokens")) tokens_cap = parse_positive_int(need_arg(&i, argc, argv, arg), arg);
        else if (!strcmp(arg, "--prefix")) prefix_len = parse_positive_int(need_arg(&i, argc, argv, arg), arg);
        else if (!strcmp(arg, "--top-k")) top_k = parse_positive_int(need_arg(&i, argc, argv, arg), arg);
        else if (!strcmp(arg, "--threads")) n_threads = parse_positive_int(need_arg(&i, argc, argv, arg), arg);
        else if (!strcmp(arg, "--quality")) quality = true;
        else if (!strcmp(arg, "--ssd-streaming")) ssd_streaming = true;
        else if (!strcmp(arg, "--ssd-streaming-cold")) ssd_streaming_cold = true;
        else if (!strcmp(arg, "--ssd-streaming-cache-experts")) {
            if (!ds4_parse_streaming_cache_experts_arg(need_arg(&i, argc, argv, arg),
                                                       &ssd_cache_experts, &ssd_cache_bytes)) {
                die("--ssd-streaming-cache-experts must be a positive count or <number>GB");
            }
        } else if (!strcmp(arg, "--ssd-streaming-preload-experts")) {
            ssd_preload_experts = (uint32_t)parse_positive_int(need_arg(&i, argc, argv, arg), arg);
        } else if (!strcmp(arg, "-h") || !strcmp(arg, "--help")) usage(argv[0]);
        else if (arg[0] == '-') {
            fprintf(stderr, "ds4-kld: unknown option %s\n", arg);
            usage(argv[0]);
        } else if (!model_path) model_path = arg;
        else usage(argv[0]);
    }
    if (!model_path || !text_path || !tsv_path) usage(argv[0]);
    if ((save_path == NULL) == (load_path == NULL)) die("give exactly one of --save-logits or --load-logits");
    if (top_k > KLD_MAX_TOP_K) top_k = KLD_MAX_TOP_K;
    if (ctx_size <= prefix_len) die("--ctx must be larger than --prefix");

    char *text = read_file(text_path);

    ds4_engine_options opt = {
        .model_path = model_path,
#ifdef __APPLE__
        .backend = DS4_BACKEND_METAL,
#else
        .backend = DS4_BACKEND_CUDA,
#endif
        .n_threads = n_threads,
        .context_size = ctx_size,
        .placement_ctx_hint = ctx_size,
        .ssd_streaming_cache_experts = ssd_cache_experts,
        .ssd_streaming_cache_bytes = ssd_cache_bytes,
        .ssd_streaming_preload_experts = ssd_preload_experts,
        .warm_weights = false,
        .quality = quality,
        .ssd_streaming = ssd_streaming,
        .ssd_streaming_cold = ssd_streaming_cold,
    };
    ds4_engine *engine = NULL;
    if (ds4_engine_open(&engine, &opt) != 0) die("failed to open model");
    const int vocab = ds4_engine_vocab_size(engine);
    if (vocab <= 0) die("engine reports no vocabulary");

    ds4_tokens tokens = {0};
    ds4_tokenize_text(engine, text, &tokens);
    free(text);
    if (tokens.len <= prefix_len) {
        fprintf(stderr, "ds4-kld: text has %d tokens; need more than the %d-token prefix\n",
                tokens.len, prefix_len);
        return 1;
    }

    /* ---- decide how many positions to score ---------------------------- */
    int scored = tokens.len - prefix_len;
    if (tokens_cap > 0 && scored > tokens_cap) scored = tokens_cap;
    if (scored > ctx_size - prefix_len) scored = ctx_size - prefix_len;

    FILE *ref_fp = NULL;
    if (load_path) {
        ref_fp = fopen(load_path, "rb");
        if (!ref_fp) {
            fprintf(stderr, "ds4-kld: open %s: %s\n", load_path, strerror(errno));
            return 1;
        }
        kld_header h;
        if (fread(&h, sizeof(h), 1, ref_fp) != 1) die("reference file is truncated");
        if (memcmp(h.magic, KLD_MAGIC, 8) != 0 || h.version != KLD_VERSION) {
            die("reference file is not a ds4-kld logits file of this version");
        }
        if ((int)h.vocab != vocab) {
            fprintf(stderr, "ds4-kld: reference vocab %u != this model's vocab %d; "
                            "these files do not share a vocabulary\n", h.vocab, vocab);
            return 1;
        }
        if ((int)h.prefix != prefix_len) {
            fprintf(stderr, "ds4-kld: using the reference prefix of %u tokens (not --prefix %d)\n",
                    h.prefix, prefix_len);
            prefix_len = (int)h.prefix;
        }
        if (scored > (int)h.scored) scored = (int)h.scored;
        if (scored > ctx_size - prefix_len) scored = ctx_size - prefix_len;
        if (scored < (int)h.scored) {
            fprintf(stderr, "ds4-kld: reference has %u scored positions; scoring the first %d\n",
                    h.scored, scored);
        }
        const int stream_len = prefix_len + (int)h.scored;
        int32_t *ref_tokens = malloc((size_t)stream_len * sizeof(int32_t));
        if (!ref_tokens) die("out of memory");
        if (fread(ref_tokens, sizeof(int32_t), (size_t)stream_len, ref_fp) != (size_t)stream_len) {
            die("reference file is truncated (token stream)");
        }
        if (tokens.len < prefix_len + scored) die("text is shorter than the reference token stream");
        for (int i = 0; i < prefix_len + scored; i++) {
            if (ref_tokens[i] != tokens.v[i]) {
                fprintf(stderr,
                        "ds4-kld: token stream differs from the reference at index %d "
                        "(reference %d, this model %d): the two GGUFs tokenize the text "
                        "differently, so a per-position comparison is not meaningful\n",
                        i, ref_tokens[i], tokens.v[i]);
                return 1;
            }
        }
        free(ref_tokens);
        /* Fail now rather than after minutes of decoding if the file is short. */
        const long data_start = ftell(ref_fp);
        if (fseek(ref_fp, 0, SEEK_END) != 0) die("fseek failed");
        const long file_len = ftell(ref_fp);
        const long need = data_start + (long)scored * (long)vocab * (long)sizeof(float);
        if (file_len < need) {
            fprintf(stderr, "ds4-kld: reference file holds fewer logits rows than its header claims "
                            "(the reference run probably aborted)\n");
            return 1;
        }
        if (fseek(ref_fp, data_start, SEEK_SET) != 0) die("fseek failed");
    }
    if (scored <= 0) die("nothing to score: raise --ctx or --tokens");

    FILE *save_fp = NULL;
    if (save_path) {
        save_fp = fopen(save_path, "wb");
        if (!save_fp) {
            fprintf(stderr, "ds4-kld: open %s: %s\n", save_path, strerror(errno));
            return 1;
        }
        kld_header h = {0};
        memcpy(h.magic, KLD_MAGIC, 8);
        h.version = KLD_VERSION;
        h.vocab = (uint32_t)vocab;
        h.prefix = (uint32_t)prefix_len;
        h.scored = (uint32_t)scored;
        h.ctx = (uint32_t)ctx_size;
        if (!write_all(save_fp, &h, sizeof(h))) die("write failed");
        for (int i = 0; i < prefix_len + scored; i++) {
            const int32_t t = tokens.v[i];
            if (!write_all(save_fp, &t, sizeof(t))) die("write failed");
        }
    }

    FILE *tsv = fopen(tsv_path, "wb");
    if (!tsv) {
        fprintf(stderr, "ds4-kld: open %s: %s\n", tsv_path, strerror(errno));
        return 1;
    }
    if (load_path) {
        fputs("pos\ttoken\ttoken_text\tnll_a\tnll_b\tp_a_target\tp_b_target"
              "\tentropy_a\tentropy_b\targmax_a\targmax_a_text\tp_a_argmax_a"
              "\targmax_b\targmax_b_text\tp_b_argmax_b\tp_b_argmax_a"
              "\ttop1_same\ttopk_overlap\tkld_ab\tkld_ba\tjsd\n", tsv);
    } else {
        fputs("pos\ttoken\ttoken_text\tnll_a\tp_a_target\tentropy_a"
              "\targmax_a\targmax_a_text\tp_a_argmax_a\n", tsv);
    }

    /* ---- session ------------------------------------------------------- */
    ds4_session *session = NULL;
    if (ds4_session_create(&session, engine, ctx_size) != 0) die("failed to create session");

    ds4_tokens prefix = {0};
    for (int i = 0; i < prefix_len; i++) ds4_tokens_push(&prefix, tokens.v[i]);
    char err[256];
    if (ds4_session_sync(session, &prefix, err, sizeof(err)) != 0) {
        fprintf(stderr, "ds4-kld: prefix sync failed: %s\n", err);
        return 1;
    }
    ds4_tokens_free(&prefix);

    float *lb = malloc((size_t)vocab * sizeof(float));
    float *la = load_path ? malloc((size_t)vocab * sizeof(float)) : NULL;
    if (!lb || (load_path && !la)) die("out of memory");

    fprintf(stderr, "ds4-kld: %s mode; %d text tokens; scoring %d positions after a %d-token prefix "
                    "in a %d-token context; vocab %d\n",
            load_path ? "compare" : "reference", tokens.len, scored, prefix_len, ctx_size, vocab);

    double nll_a_sum = 0.0, nll_b_sum = 0.0, kld_sum = 0.0;
    long top1_same_count = 0;
    const double t0 = now_s();

    for (int j = 0; j < scored; j++) {
        const int i = prefix_len + j;
        const int target = tokens.v[i];

        if (ds4_session_copy_logits(session, lb, vocab) != vocab) {
            fprintf(stderr, "ds4-kld: failed to copy logits at position %d\n", i);
            return 1;
        }
        dist_info db;
        if (!summarize(lb, vocab, top_k, &db)) {
            fprintf(stderr, "ds4-kld: non-finite logit at position %d\n", i);
            return 1;
        }

        if (save_fp) {
            if (!write_all(save_fp, lb, (size_t)vocab * sizeof(float))) die("write failed");
            const double lp = logprob_of(lb, &db, target);
            nll_a_sum -= lp;
            fprintf(tsv, "%d\t%d\t", i, target);
            put_token_text(tsv, engine, target);
            fprintf(tsv, "\t%.9g\t%.9g\t%.9g\t%d\t", -lp, exp(lp), db.entropy, db.argmax);
            put_token_text(tsv, engine, db.argmax);
            fprintf(tsv, "\t%.9g\n", exp(logprob_of(lb, &db, db.argmax)));
        } else {
            if (fread(la, sizeof(float), (size_t)vocab, ref_fp) != (size_t)vocab) {
                die("reference file read failed");
            }
            dist_info da;
            if (!summarize(la, vocab, top_k, &da)) {
                fprintf(stderr, "ds4-kld: non-finite reference logit at position %d\n", i);
                return 1;
            }
            double kl_ab = 0.0, kl_ba = 0.0, jsd = 0.0;
            for (int t = 0; t < vocab; t++) {
                const double lpa = (double)la[t] - da.lse;
                const double lpb = (double)lb[t] - db.lse;
                const double pa = exp(lpa);
                const double pb = exp(lpb);
                if (pa > 0.0) kl_ab += pa * (lpa - lpb);
                if (pb > 0.0) kl_ba += pb * (lpb - lpa);
                const double m = 0.5 * (pa + pb);
                if (m > 0.0) {
                    const double lm = log(m);
                    if (pa > 0.0) jsd += 0.5 * pa * (lpa - lm);
                    if (pb > 0.0) jsd += 0.5 * pb * (lpb - lm);
                }
            }
            /* Gibbs' inequality guarantees KL >= 0; rounding in the two
             * log-sum-exps can produce -1e-12.  Do not let that print as a
             * negative divergence, but do not hide anything larger. */
            if (kl_ab < 0.0 && kl_ab > -1e-9) kl_ab = 0.0;
            if (kl_ba < 0.0 && kl_ba > -1e-9) kl_ba = 0.0;
            if (jsd < 0.0 && jsd > -1e-9) jsd = 0.0;

            int overlap = 0;
            for (int x = 0; x < da.n_top; x++)
                for (int y = 0; y < db.n_top; y++)
                    if (da.top[x] == db.top[y]) { overlap++; break; }

            const double lpa_t = logprob_of(la, &da, target);
            const double lpb_t = logprob_of(lb, &db, target);
            const int same = da.argmax == db.argmax;
            nll_a_sum -= lpa_t;
            nll_b_sum -= lpb_t;
            kld_sum += kl_ab;
            top1_same_count += same;

            fprintf(tsv, "%d\t%d\t", i, target);
            put_token_text(tsv, engine, target);
            fprintf(tsv, "\t%.9g\t%.9g\t%.9g\t%.9g\t%.9g\t%.9g\t%d\t",
                    -lpa_t, -lpb_t, exp(lpa_t), exp(lpb_t), da.entropy, db.entropy, da.argmax);
            put_token_text(tsv, engine, da.argmax);
            fprintf(tsv, "\t%.9g\t%d\t", exp(logprob_of(la, &da, da.argmax)), db.argmax);
            put_token_text(tsv, engine, db.argmax);
            fprintf(tsv, "\t%.9g\t%.9g\t%d\t%.9g\t%.9g\t%.9g\t%.9g\n",
                    exp(logprob_of(lb, &db, db.argmax)),
                    exp(logprob_of(lb, &db, da.argmax)),
                    same,
                    top_k > 0 ? (double)overlap / (double)top_k : 0.0,
                    kl_ab, kl_ba, jsd);
        }

        if (((j + 1) % 64) == 0 || j + 1 == scored) {
            const double el = now_s() - t0;
            if (load_path) {
                fprintf(stderr, "\rds4-kld: %d/%d  %.1f tok/s  mean KLD %.6f  top-1 agree %.2f%%   ",
                        j + 1, scored, (j + 1) / (el > 0 ? el : 1e-9),
                        kld_sum / (j + 1), 100.0 * (double)top1_same_count / (j + 1));
            } else {
                fprintf(stderr, "\rds4-kld: %d/%d  %.1f tok/s  ppl %.4f   ",
                        j + 1, scored, (j + 1) / (el > 0 ? el : 1e-9), exp(nll_a_sum / (j + 1)));
            }
            fflush(stderr);
        }

        if (j + 1 < scored && ds4_session_eval(session, target, err, sizeof(err)) != 0) {
            fprintf(stderr, "\nds4-kld: decode failed at position %d: %s\n", i, err);
            return 1;
        }
    }
    fputc('\n', stderr);
    const double elapsed = now_s() - t0;

    if (fclose(tsv) != 0) die("failed to close --tsv output");
    if (save_fp && fclose(save_fp) != 0) die("failed to close --save-logits output");
    if (ref_fp) fclose(ref_fp);

    if (load_path) {
        printf("ds4-kld: mode=compare scored=%d prefix=%d ctx=%d vocab=%d elapsed_s=%.1f "
               "mean_kld=%.9f top1_agree=%.6f ppl_a=%.6f ppl_b=%.6f\n",
               scored, prefix_len, ctx_size, vocab, elapsed,
               kld_sum / scored, (double)top1_same_count / scored,
               exp(nll_a_sum / scored), exp(nll_b_sum / scored));
    } else {
        printf("ds4-kld: mode=reference scored=%d prefix=%d ctx=%d vocab=%d elapsed_s=%.1f ppl=%.6f\n",
               scored, prefix_len, ctx_size, vocab, elapsed, exp(nll_a_sum / scored));
    }

    free(la);
    free(lb);
    ds4_tokens_free(&tokens);
    ds4_session_free(session);
    ds4_engine_close(engine);
    return 0;
}
