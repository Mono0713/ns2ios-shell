// The server test's HTTPS (phone_pads_tls.h) with OpenSSL, for test_phone_pads.py off Apple: the same calls as phone_pads_tls.m, a certificate and key from the files
// PP_TEST_CERT and PP_TEST_KEY name. Linked only into the test's stand-in host, never into the app
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include "phone_pads_tls.h"

static SSL_CTX *ctx(void) {
    static SSL_CTX *c; static int tried;
    if (tried) return c;
    tried = 1;
    const char *cert = getenv("PP_TEST_CERT"), *key = getenv("PP_TEST_KEY");
    if (!cert || !key) return NULL;
    c = SSL_CTX_new(TLS_server_method());
    if (SSL_CTX_use_certificate_file(c, cert, SSL_FILETYPE_PEM) != 1 || SSL_CTX_use_PrivateKey_file(c, key, SSL_FILETYPE_PEM) != 1) { SSL_CTX_free(c); c = NULL; }
    return c;
}
void *pp_tls_new(int fd) {
    if (!ctx()) return NULL;
    SSL *s = SSL_new(ctx()); SSL_set_fd(s, fd); SSL_set_accept_state(s);
    return s;
}
long pp_tls_recv(void *t, void *buf, size_t n) {
    int r = SSL_read(t, buf, (int)n);
    if (r > 0) return r;
    int e = SSL_get_error(t, r);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) return -2;
    return e == SSL_ERROR_ZERO_RETURN ? 0 : -1;
}
int pp_tls_send(void *t, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        int r = SSL_write(t, b, (int)n);
        if (r > 0) { b += r; n -= (size_t)r; continue; }
        int e = SSL_get_error(t, r);
        if (e != SSL_ERROR_WANT_WRITE && e != SSL_ERROR_WANT_READ) return -1;
        struct pollfd pf = {.fd = SSL_get_fd(t), .events = e == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN};
        if (poll(&pf, 1, 1000) <= 0) return -1;
    }
    return 0;
}
void pp_tls_free(void *t) { SSL_free(t); }
