// HTTPS for the phone gamepads (phone_pads.c): a connection that opens with a TLS handshake gets one, under the app's own certificate (phone_pads_tls.m: made on the
// device the first time, an ECDSA P-256 key in the keychain, renewed before it runs out). Browsers give a page the phone's motion sensors only over HTTPS.
// All calls on the phone server's thread; the socket is non-blocking.
#pragma once
#include <stddef.h>
void *pp_tls_new(int fd);                              // the connection's TLS, NULL when there is none (no certificate, or not on Apple)
long pp_tls_recv(void *t, void *buf, size_t n);        // > 0 bytes read, 0 closed, -1 failed, -2 nothing yet (the handshake goes on inside)
int pp_tls_send(void *t, const void *p, size_t n);     // 0 sent (waits up to a second for room), -1 failed
void pp_tls_free(void *t);
