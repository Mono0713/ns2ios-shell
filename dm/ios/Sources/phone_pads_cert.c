// The phone gamepads' own HTTPS certificate (phone_pads_cert.h)
#include <string.h>
#include "phone_pads_cert.h"

typedef struct { uint8_t *b; size_t n, cap; int bad; } der;
static void put(der *d, const void *p, size_t n) { if (d->n + n > d->cap) { d->bad = 1; return; } memcpy(d->b + d->n, p, n); d->n += n; }
static void tlv(der *d, uint8_t tag, const void *p, size_t n) {   // tag, length (short or long form), contents
    uint8_t h[4] = {tag}; size_t hn;
    if (n < 128) { h[1] = (uint8_t)n; hn = 2; }
    else if (n < 256) { h[1] = 0x81; h[2] = (uint8_t)n; hn = 3; }
    else { h[1] = 0x82; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hn = 4; }
    put(d, h, hn); put(d, p, n);
}
// A constructed value from its parts, built in a scratch buffer
typedef struct { uint8_t b[1024]; der d; } part;
static der *begin(part *p) { p->d = (der){p->b, 0, sizeof p->b, 0}; return &p->d; }
static void end(der *d, uint8_t tag, part *p) { if (p->d.bad) d->bad = 1; tlv(d, tag, p->b, p->d.n); }

static const uint8_t OID_ECDSA_SHA256[] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02};   // 1.2.840.10045.4.3.2
static const uint8_t OID_EC_KEY[] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01};             // 1.2.840.10045.2.1
static const uint8_t OID_P256[] = {0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07};        // 1.2.840.10045.3.1.7
static const uint8_t OID_CN[] = {0x55, 0x04, 0x03};
static const uint8_t OID_SAN[] = {0x55, 0x1d, 0x11}, OID_EKU[] = {0x55, 0x1d, 0x25}, OID_BC[] = {0x55, 0x1d, 0x13}, OID_KU[] = {0x55, 0x1d, 0x0f};
static const uint8_t OID_SERVER_AUTH[] = {0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01};

static void alg(der *d) { part p; der *s = begin(&p); tlv(s, 0x06, OID_ECDSA_SHA256, sizeof OID_ECDSA_SHA256); end(d, 0x30, &p); }
static void name(der *d) {   // CN=SwitchPad
    part a, b, c; der *rdn = begin(&a), *set = begin(&b), *atv = begin(&c);
    tlv(atv, 0x06, OID_CN, sizeof OID_CN); tlv(atv, 0x0c, "SwitchPad", 9);
    end(set, 0x30, &c); end(rdn, 0x31, &b); end(d, 0x30, &a);
}
static void utc(der *d, time_t t) {
    struct tm g; gmtime_r(&t, &g);
    char s[16]; strftime(s, sizeof s, "%y%m%d%H%M%SZ", &g);
    tlv(d, 0x17, s, 13);
}
static void ext(der *d, const uint8_t *oid, size_t on, int critical, const part *value) {
    part p; der *s = begin(&p);
    tlv(s, 0x06, oid, on);
    if (critical) { static const uint8_t t = 0xff; tlv(s, 0x01, &t, 1); }
    tlv(s, 0x04, value->b, value->d.n);
    end(d, 0x30, &p);
}

size_t pp_cert_der(uint8_t *out, size_t cap, const uint8_t pub[65], const uint8_t serial[16], time_t now,
                   size_t (*sign)(void *ctx, const uint8_t *tbs, size_t n, uint8_t *sig, size_t cap), void *ctx) {
    part tbsp; der *tbs = begin(&tbsp);
    static const uint8_t v3[] = {0x02, 0x01, 0x02}; tlv(tbs, 0xa0, v3, sizeof v3);
    uint8_t sn[17] = {0}; memcpy(sn + 1, serial, 16); sn[1] &= 0x7f; sn[1] |= 0x40; tlv(tbs, 0x02, sn + 1, 16);   // positive, 16 bytes
    alg(tbs);
    name(tbs);
    { part p; der *v = begin(&p); utc(v, now - 86400); utc(v, now + (time_t)PP_CERT_DAYS * 86400); end(tbs, 0x30, &p); }
    name(tbs);
    {   // the public key
        part p, a; der *spki = begin(&p), *ai = begin(&a);
        tlv(ai, 0x06, OID_EC_KEY, sizeof OID_EC_KEY); tlv(ai, 0x06, OID_P256, sizeof OID_P256);
        end(spki, 0x30, &a);
        uint8_t bits[66] = {0}; memcpy(bits + 1, pub, 65); tlv(spki, 0x03, bits, sizeof bits);
        end(tbs, 0x30, &p);
    }
    {   // extensions: the name switchpad.local, server authentication, not a CA, signing only
        part list, all; der *l = begin(&list);
        part san; { part g; der *gs = begin(&g); tlv(gs, 0x82, "switchpad.local", 15); der *s = begin(&san); end(s, 0x30, &g); }
        ext(l, OID_SAN, sizeof OID_SAN, 0, &san);
        part eku; { part g; der *gs = begin(&g); tlv(gs, 0x06, OID_SERVER_AUTH, sizeof OID_SERVER_AUTH); der *s = begin(&eku); end(s, 0x30, &g); }
        ext(l, OID_EKU, sizeof OID_EKU, 0, &eku);
        part bc; { der *s = begin(&bc); tlv(s, 0x30, NULL, 0); }
        ext(l, OID_BC, sizeof OID_BC, 1, &bc);
        part ku; { der *s = begin(&ku); static const uint8_t b[] = {0x07, 0x80}; tlv(s, 0x03, b, sizeof b); }   // digitalSignature
        ext(l, OID_KU, sizeof OID_KU, 1, &ku);
        der *a = begin(&all); end(a, 0x30, &list);
        end(tbs, 0xa3, &all);
    }
    part tbsw; der *w = begin(&tbsw); end(w, 0x30, &tbsp);   // the TBSCertificate as signed
    if (tbsw.d.bad) return 0;
    uint8_t sig[80]; size_t sn2 = sign(ctx, tbsw.b, tbsw.d.n, sig + 1, sizeof sig - 1);
    if (!sn2) return 0;
    sig[0] = 0;   // no unused bits
    part certp; der *c = begin(&certp);
    put(c, tbsw.b, tbsw.d.n); alg(c); tlv(c, 0x03, sig, sn2 + 1);
    der o = {out, 0, cap, 0}; end(&o, 0x30, &certp);
    return o.bad ? 0 : o.n;
}
