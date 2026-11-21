// The phone gamepads' own HTTPS certificate (phone_pads_tls.m): a self-signed X.509 certificate for an ECDSA P-256 key, in DER, built without a crypto library (the
// signature comes from the caller). Made to what Apple's TLS checks ask of a server certificate (a subject alternative name, server authentication, SHA-256, at most
// 825 days), so a phone that is told to trust it once accepts it.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#define PP_CERT_DAYS 800
// pub: the public key as X9.63 (0x04, x, y; 65 bytes); serial: 16 random bytes; sign: an ECDSA signature (DER, as X9.62) of the SHA-256 of the n bytes at tbs, into sig
// (cap bytes), returning its length or 0. The certificate's length, 0 when out does not hold it or the signature failed
size_t pp_cert_der(uint8_t *out, size_t cap, const uint8_t pub[65], const uint8_t serial[16], time_t now,
                   size_t (*sign)(void *ctx, const uint8_t *tbs, size_t n, uint8_t *sig, size_t cap), void *ctx);
