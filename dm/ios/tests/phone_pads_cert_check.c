// test_phone_pads.py: phone_pads_cert.c's certificate for a fresh P-256 key (OpenSSL signs, as the keychain key does on the device), written to the file argv[1] names (DER), its key to argv[2] (PEM): the HTTPS test's server certificate
#include <stdio.h>
#include <openssl/ec.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include "phone_pads_cert.h"
static size_t sign(void *ctx, const uint8_t *tbs, size_t n, uint8_t *sig, size_t cap) {
    EVP_MD_CTX *m = EVP_MD_CTX_new(); size_t sl = cap;
    if (EVP_DigestSignInit(m, NULL, EVP_sha256(), NULL, ctx) != 1 || EVP_DigestSign(m, sig, &sl, tbs, n) != 1) sl = 0;
    EVP_MD_CTX_free(m); return sl;
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    EVP_PKEY *k = EVP_EC_gen("P-256");
    uint8_t pub[65]; size_t pl = sizeof pub; EVP_PKEY_get_octet_string_param(k, "pub", pub, sizeof pub, &pl);
    uint8_t serial[16]; RAND_bytes(serial, 16);
    uint8_t der[2048]; size_t n = pp_cert_der(der, sizeof der, pub, serial, time(NULL), sign, k);
    if (!n) return 1;
    FILE *f = fopen(argv[1], "wb"); fwrite(der, 1, n, f); fclose(f);
    f = fopen(argv[2], "w"); PEM_write_PrivateKey(f, k, NULL, NULL, 0, NULL, NULL); fclose(f);
    printf("%zu bytes\n", n); return 0;
}
