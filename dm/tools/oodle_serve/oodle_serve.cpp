// oodle_serve: Oodle (Kraken, Mermaid, Selkie, Leviathan, Hydra, LZNA, BitKnit) decoded without the game, by ooz (./ooz, Powzix's open-source decoder, GPL-3.0).
// It answers the same requests as the Mac host's tool mode (dm/host/hle_oodle.c), so the packer's tools use it in place of the game's own OodleLZ_Decompress where no Mac is at hand
// (the Windows packer: Unreal shader code archives, uepak.py):
//   oodle_serve [anything]          requests on stdin / stdout until stdin ends (DM_OODLE_SERVE): u64 compressed length, u64 decompressed length, the compressed bytes;
//                                   answer: u64 bytes decoded (0 on failure), then those bytes. Extra arguments are ignored (callers pass the Mac host's <rewritten modules>).
//   oodle_serve --job <job file>    a job (DM_OODLE_JOB): "DMOJ", u32 count, per record u32 compressed length, u32 raw length, the bytes → <job file>.out: "DMOR", u32 count,
//                                   per record u32 decoded length (0 = failed) and the bytes.
//   oodle_serve --version
// Exit status 1 when any request failed, as the host.
#include "ooz/stdafx.h"
#include <vector>
#include <string>
#if defined(_WIN32)
#include <io.h>
#include <fcntl.h>
#endif

int Kraken_Decompress(const byte *src, size_t src_len, byte *dst, size_t dst_len);

enum { SLACK = 0x10000 };   // ooz writes up to 64 bytes past the end of its output

static bool read_all(FILE *f, void *p, size_t n) { return n == 0 || fread(p, 1, n, f) == n; }
static void write_all(FILE *f, const void *p, size_t n) { if (n && fwrite(p, 1, n, f) != n) { fprintf(stderr, "oodle_serve: write failed\n"); exit(2); } }

static uint64 decode(const std::vector<byte> &comp, uint64 raw_len, std::vector<byte> &raw) {
    if (!raw_len) return 0;
    if (raw.size() < raw_len + SLACK) raw.resize(raw_len + SLACK);
    int got = Kraken_Decompress(comp.data(), comp.size(), raw.data(), (size_t)raw_len);
    return got >= 0 && (uint64)got == raw_len ? raw_len : 0;
}

static int serve() {
#if defined(_WIN32)
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
#endif
    std::vector<byte> comp, raw; uint64 n = 0, bad = 0;
    for (;;) {
        uint64 hdr[2];
        if (!read_all(stdin, hdr, sizeof hdr)) break;
        if (hdr[0] > (1ull << 32) || hdr[1] > (1ull << 32)) { fprintf(stderr, "oodle_serve: request too large (%llu -> %llu)\n", hdr[0], hdr[1]); return 2; }
        comp.resize((size_t)hdr[0]);
        if (!read_all(stdin, comp.data(), comp.size())) { fprintf(stderr, "oodle_serve: request cut short\n"); return 2; }
        uint64 out = decode(comp, hdr[1], raw);
        if (!out && hdr[1] && bad++ < 8) fprintf(stderr, "[RED] oodle_serve: request %llu (%llu -> %llu bytes) failed\n", n, hdr[0], hdr[1]);
        write_all(stdout, &out, sizeof out);
        write_all(stdout, raw.data(), (size_t)out);
        fflush(stdout); n++;
    }
    fprintf(stderr, "oodle_serve: %llu requests, %llu failed\n", n, bad);
    return bad ? 1 : 0;
}

static int job(const char *path) {
    FILE *in = fopen(path, "rb"); if (!in) { fprintf(stderr, "oodle_serve: cannot open %s\n", path); return 2; }
    uint32 h[2];
    if (!read_all(in, h, sizeof h) || h[0] != 0x4a4f4d44) { fprintf(stderr, "oodle_serve: %s is not a job file\n", path); return 2; }
    std::string outp = std::string(path) + ".out";
    FILE *out = fopen(outp.c_str(), "wb"); if (!out) { fprintf(stderr, "oodle_serve: cannot write %s\n", outp.c_str()); return 2; }
    uint32 oh[2] = {0x524f4d44, h[1]}; write_all(out, oh, sizeof oh);
    std::vector<byte> comp, raw; uint32 bad = 0; double total = 0;
    for (uint32 i = 0; i < h[1]; i++) {
        uint32 r[2];
        if (!read_all(in, r, sizeof r)) { fprintf(stderr, "oodle_serve: the job file ends early\n"); return 2; }
        comp.resize(r[0]);
        if (!read_all(in, comp.data(), comp.size())) { fprintf(stderr, "oodle_serve: record %u ends early\n", i); return 2; }
        uint32 got = (uint32)decode(comp, r[1], raw);
        if (!got && bad++ < 8) fprintf(stderr, "[RED] oodle_serve: record %u (%u -> %u bytes) failed\n", i, r[0], r[1]);
        write_all(out, &got, 4); write_all(out, raw.data(), got); total += got;
    }
    fclose(in);
    if (fclose(out)) { fprintf(stderr, "oodle_serve: cannot write %s\n", outp.c_str()); return 2; }
    fprintf(stderr, "oodle_serve: %u records decoded with ooz (%u failed, %.1f MB out) -> %s\n", h[1] - bad, bad, total / 1048576.0, outp.c_str());
    return bad ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--version")) { printf("oodle_serve 1 (ooz 05038060)\n"); return 0; }
    if (argc > 2 && !strcmp(argv[1], "--job")) return job(argv[2]);
    return serve();
}
