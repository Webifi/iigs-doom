/* docrender BANK SONG OUT.wav [SECONDS] [GAIN] [DESCRIPTORS]: a song image of the music
 * bank (tools/musbank.py v5) as the player of src/iigs/irq65.s plays it on
 * MAME 0.289's ES5503 (es5503.cpp): 32 oscillators (26320 Hz), voices on
 * oscillators 16 + v, channel v & 1 (0 left, 1 right), the alarm one-shot
 * pass of ceil(130560 / fc) + 1 samples plus 0.8 of wake latency, all
 * register writes of a wake at its sample. Prints the wakes and register
 * writes. Output: 16-bit stereo at 26320 Hz, MAME's level (sum / 8) x GAIN. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DOC_RATE (894886.0 / 34.0)
#define TIC (DOC_RATE / 140.0)
#define NV 14

static uint8_t ram[65536];
static const uint32_t accmasks[8] = {0xff, 0x1ff, 0x3ff, 0x7ff, 0xfff, 0x1fff, 0x3fff, 0x7fff};
static const uint32_t wavemasks[8] = {0x1ff00, 0x1fe00, 0x1fc00, 0x1f800, 0x1f000, 0x1e000, 0x1c000, 0x18000};

typedef struct {
    uint32_t acc;
    uint16_t freq;
    uint8_t vol, ptr, size, ctl;   /* ctl bit 0: halted; bits 1-2 mode; bit 4 channel */
    float gv;                      /* the volume heard (ramped, DOCR_RAMP) */
    int fade;                      /* samples of a halt fade left */
} Osc;
static int ramp = 0;

static Osc osc[NV];

static int vol_of(int k)
{
    if ((k >> 3) >= 16) return 0;
    int m = (int)lround(192 * 256 * pow(2.0, -(k & 7) / 8.0));
    return ((m >> (k >> 3)) + 128) >> 8;
}

static int alarm_fc(int n)
{
    int fc = (int)lround(130560.0 / (TIC * n));
    return fc < 1 ? 1 : fc;
}

static void run(Osc *o, float *out, long a, long b)
{
    if (o->ctl & 1) {
        if (!ramp || o->fade <= 0) return;
    }
    int sz = o->size >> 3 & 7, res = o->size & 7;
    uint32_t wtptr = ((uint32_t)o->ptr << 8) & wavemasks[sz];
    int resshift = 9 + res - sz;
    uint32_t sizemask = accmasks[sz];
    uint32_t wtsize = (256u << sz) - 1;
    int mode = o->ctl >> 1 & 3;
    int ch = o->ctl >> 4 & 1;
    uint32_t acc = o->acc;
    int halted = o->ctl & 1;
    for (long s = a; s < b; s++) {
        float target = halted ? 0 : o->vol;
        if (ramp) { o->gv += (target - o->gv) / ramp; } else o->gv = target;
        if (halted && --o->fade <= 0) break;
        uint32_t altram = acc >> resshift;
        uint32_t ramptr = altram & sizemask;
        acc += o->freq;
        uint8_t d = ram[(ramptr + wtptr) & 0xffff];
        if (d == 0) { o->ctl |= 1; break; }
        out[2 * s + ch] += (float)((int)d - 128) * o->gv;
        if (altram >= wtsize) {
            if (mode != 0) { o->ctl |= 1; break; }
            acc -= wtsize << resshift;
        }
    }
    o->acc = acc;
}

int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: docrender BANK SONG OUT.wav [SECONDS] [GAIN]\n"); return 1; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *bank = malloc(n);
    if (fread(bank, 1, n, f) != (size_t)n) return 1;
    fclose(f);
    int song = atoi(argv[2]);
    uint32_t off = bank[2 + 8 * song] | bank[3 + 8 * song] << 8 | bank[4 + 8 * song] << 16 | (uint32_t)bank[5 + 8 * song] << 24;
    uint32_t len = bank[6 + 8 * song] | bank[7 + 8 * song] << 8 | bank[8 + 8 * song] << 16 | (uint32_t)bank[9 + 8 * song] << 24;
    if (!len) { fprintf(stderr, "no song %d\n", song); return 1; }
    uint8_t *img = bank + off;
    int D = img[0], P = img[1] ? img[1] : 256, SL = img[2] | img[3] << 8, low = img[4];
    uint8_t *stream = img + 6;
    uint8_t *plo = stream + SL, *phi = plo + P;
    uint8_t *dptr = phi + P, *dsiz = dptr + D, *dmode = dsiz + D, *lptr = dmode + D, *lsiz = lptr + D;
    uint8_t *doc = lsiz + D;
    memcpy(ram + 256 * low, doc, 256 * (255 - low));
    double secs = argc > 4 ? atof(argv[4]) : 0;
    double gain = argc > 5 ? atof(argv[5]) : 1.0;
    /* DESCRIPTORS: a comma list; only the voices playing those tables sound */
    ramp = getenv("DOCR_RAMP") ? atoi(getenv("DOCR_RAMP")) : 0;
    int mask[256];
    for (int i = 0; i < 256; i++) mask[i] = argc <= 6;
    if (argc > 6) {
        char *p = argv[6];
        while (*p) { mask[strtol(p, &p, 10) & 255] = 1; if (*p == ',') p++; }
    }
    int vscale[128];
    for (int i = 0; i < 128; i++) vscale[i] = vol_of(i);
    /* the length: one pass of the stream */
    long total = secs > 0 ? (long)(secs * DOC_RATE) : (long)(600 * DOC_RATE);
    float *out = calloc(2 * (size_t)total, sizeof(float));
    uint8_t level[16], vdesc[16] = {0}, vctl[16] = {0}, ctlr[16], ctlh[16];
    memset(level, 0xff, sizeof level);   /* musStart: no level yet */
    for (int v = 0; v < NV; v++) {
        ctlr[v] = (v & 1) << 4;
        ctlh[v] = ctlr[v] | 1;
        osc[v].ctl = ctlh[v];
        osc[v].size = 0;
        osc[v].ptr = low;
    }
    long wakes = 0, writes = 0, cmds = 0, maxw = 0;
    int pos = 0, fchi = -1, fclo = 0;
    double t = 0;
    long end = total;
    for (;;) {
        /* one wake at sample t */
        long w0 = writes;
        uint8_t c = stream[pos++];
        int nt = c & 15;
        int fc = alarm_fc(nt);
        writes += 1;                      /* the restart of the one-shot alarm */
        if (c >= 0xe0) {
            writes += 1;
            if (c < 0xf0) { fchi = fc >> 8; writes++; }
            fclo = fc & 255;
        }
        int afc = (fchi << 8) | fclo;
        double wait = ceil(130560.0 / afc) + 1 + 0.8;
        int stop = 0;
        for (;;) {
            c = stream[pos];
            if (c >= 0xd0) {
                if (c == 0xe0) stop = 1;
                break;
            }
            pos++;
            cmds++;
            int k = c >> 4, v = c & 15;
            if (c == 0xbf) {
                v = stream[pos++];
                if(v>=NV)return 1;
                osc[v].ctl=stream[pos++];writes++;continue;
            }
            if (c == 0xbe) {
                v = stream[pos++];
                if (v >= NV) { fprintf(stderr, "bad wave-page voice\n"); return 1; }
                osc[v].ptr = stream[pos++]; writes++;
                continue;
            }
            Osc *o = &osc[v];
            switch (k) {
            case 0: level[v] += 4; o->vol = vscale[level[v] & 127]; writes++; break;
            case 8: level[v] += 8; o->vol = vscale[level[v] & 127]; writes++; break;
            case 9: level[v] -= 4; o->vol = vscale[level[v] & 127]; writes++; break;
            case 1: level[v] = stream[pos++]; o->vol = vscale[level[v] & 127]; writes++; break;
            case 3: case 7: case 12: case 2: case 10: {
                /* a note (src/iigs/irq65.s): 0x3v d p a, 0x7v p a (the table again),
                 * 0xCv a (the table again, the same pitch), 0x2v p a, 0xAv a; bit 7
                 * of a: halted by a halt command (no halt write); a level as the
                 * voice has: no volume write */
                if (k == 3) vdesc[v] = stream[pos++];
                int has_p = (k == 3 || k == 7 || k == 2);
                int a = stream[pos + has_p];
                if (!(a & 0x80)) { o->ctl = ctlh[v]; writes++; }
                if (k == 3 || k == 7 || k == 12) {
                    int d = vdesc[v];
                    o->ptr = dptr[d]; o->size = dsiz[d]; writes += 2;
                    vctl[v] = dmode[d] | ctlr[v];
                }
                if (has_p) { int p = stream[pos++]; o->freq = plo[p] | phi[p] << 8; writes += 2; }
                a = stream[pos++] & 0x7f;
                if (a != level[v]) { level[v] = a; o->vol = vscale[a]; writes++; }
                if (o->ctl & 1) o->acc = 0;     /* key on */
                o->ctl = vctl[v]; writes++;
                break;
            }
            case 4: { int p = stream[pos++]; o->freq = plo[p] | phi[p] << 8; writes += 2; break; }
            case 5: { int p = stream[pos++]; o->freq = (o->freq & 0xff00) | plo[p]; writes++; break; }
            case 6: o->ctl = ctlh[v]; o->fade = ramp * 4; writes++; break;
            case 11: {
                int d = vdesc[v]; o->ptr = lptr[d]; o->size = lsiz[d]; writes += 2;
                if (getenv("DOCR_IDEALSWITCH")) {   /* (a test: no burst of wraps) */
                    uint32_t wt = (256u << (o->size >> 3 & 7)) - 1;
                    uint32_t alt = o->acc >> 9, frac = o->acc & 511;
                    o->acc = ((alt % wt) << 9) | frac;
                }
                break;
            }
            default: fprintf(stderr, "bad command %02x at %d\n", c, pos - 1); return 1;
            }
        }
        wakes++;
        if (writes - w0 > maxw) maxw = writes - w0;
        long a = (long)t, b = (long)(t + wait);
        if (stop || b >= total) { end = stop ? a : total; if (!stop) b = total; }
        if (b > total) b = total;
        for (int v = 0; v < NV; v++) {
            if (mask[vdesc[v]]) run(&osc[v], out, a, b);
            else { float *junk = calloc(2 * (size_t)(b - a + 1), sizeof(float)); run(&osc[v], junk - 2 * a, a, b); free(junk); }
        }
        t += wait;
        if (stop || (long)t >= total) { if (stop) end = (long)t; break; }
    }
    if (end > total) end = total;
    printf("%ld wakes, %ld commands, %ld register writes in %.1f s: %.1f wakes/s, %.1f writes/s, max %ld writes a wake; stream %d bytes, %d tables, %d pitches, %d pages\n",
           wakes, cmds, writes, end / DOC_RATE, wakes / (end / DOC_RATE), writes / (end / DOC_RATE), maxw, SL, D, P, 255 - low);
    FILE *o = fopen(argv[3], "wb");
    uint32_t bytes = (uint32_t)end * 4;
    uint8_t h[44] = "RIFF____WAVEfmt \x10\0\0\0\x01\0\x02\0________\x04\0\x10\0data____";
    uint32_t rate = (uint32_t)DOC_RATE, br = rate * 4, rl = 36 + bytes;
    memcpy(h + 4, &rl, 4); memcpy(h + 24, &rate, 4); memcpy(h + 28, &br, 4); memcpy(h + 40, &bytes, 4);
    fwrite(h, 1, 44, o);
    long clip = 0;
    for (long s = 0; s < 2 * end; s++) {
        double x = out[s] / 8.0 * gain;
        if (x > 32767) { x = 32767; clip++; }
        if (x < -32768) { x = -32768; clip++; }
        int16_t y = (int16_t)lrint(x);
        fwrite(&y, 2, 1, o);
    }
    fclose(o);
    if (clip) printf("%ld samples clipped\n", clip);
    return 0;
}
