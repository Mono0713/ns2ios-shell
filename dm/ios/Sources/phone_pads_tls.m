// HTTPS for the phone gamepads (phone_pads_tls.h): Secure Transport over the server's own non-blocking sockets, so it fits the one poll() loop of phone_pads.c, and a
// certificate the app makes itself the first time (phone_pads_cert.h): an ECDSA P-256 key made in the keychain (it never leaves it; the keychain signs the certificate),
// the certificate stored beside it, the two found again as one identity on later starts. Made again when it is older than PP_CERT_DAYS less a month, or gone.
// Secure Transport is deprecated, but it is the one TLS API on iOS that works on a socket the caller drives; Network.framework would need a listener of its own.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Security/SecureTransport.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include "dm.h"
#include "phone_pads_cert.h"
#include "phone_pads_tls.h"

static NSString *const kLabel = @"SwitchPad phone gamepads";
static NSString *const kMadeKey = @"PhonePadsCertificateMade";   // NSUserDefaults: when the certificate was made (seconds since 1970)

typedef struct { SSLContextRef ctx; int fd; int logged; } pp_tls;

static size_t keychain_sign(void *ctx, const uint8_t *tbs, size_t n, uint8_t *sig, size_t cap) {
    CFErrorRef err = NULL;
    CFDataRef s = SecKeyCreateSignature((SecKeyRef)ctx, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (__bridge CFDataRef)[NSData dataWithBytes:tbs length:n], &err);
    if (!s) { LOG("[RED] phone pads: HTTPS: the keychain key could not sign the certificate (%ld)", err ? (long)CFErrorGetCode(err) : 0L); if (err) CFRelease(err); return 0; }
    size_t len = (size_t)CFDataGetLength(s);
    if (len > cap) len = 0; else memcpy(sig, CFDataGetBytePtr(s), len);
    CFRelease(s); return len;
}
static SecIdentityRef find_identity(void) {
    CFTypeRef r = NULL;
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassIdentity, (__bridge id)kSecAttrLabel: kLabel, (__bridge id)kSecReturnRef: @YES};
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &r) == errSecSuccess && r) return (SecIdentityRef)r;
    return NULL;
}
static void forget(void) {
    SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassCertificate, (__bridge id)kSecAttrLabel: kLabel});
    SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassKey, (__bridge id)kSecAttrLabel: kLabel});
}
static SecIdentityRef make_identity(void) {
    forget();
    NSDictionary *attrs = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom, (__bridge id)kSecAttrKeySizeInBits: @256,
                            (__bridge id)kSecPrivateKeyAttrs: @{(__bridge id)kSecAttrIsPermanent: @YES, (__bridge id)kSecAttrLabel: kLabel,
                                                                (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly}};
    CFErrorRef err = NULL;
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &err);
    if (!key) { LOG("[RED] phone pads: HTTPS: no key (%ld)", err ? (long)CFErrorGetCode(err) : 0L); if (err) CFRelease(err); return NULL; }
    SecKeyRef pub = SecKeyCopyPublicKey(key);
    CFDataRef pd = pub ? SecKeyCopyExternalRepresentation(pub, NULL) : NULL;
    SecIdentityRef ident = NULL;
    if (pd && CFDataGetLength(pd) == 65) {
        uint8_t serial[16]; arc4random_buf(serial, sizeof serial);
        uint8_t der[1024]; size_t n = pp_cert_der(der, sizeof der, CFDataGetBytePtr(pd), serial, time(NULL), keychain_sign, (void *)key);
        SecCertificateRef cert = n ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)[NSData dataWithBytes:der length:n]) : NULL;
        if (cert) {
            OSStatus st = SecItemAdd((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassCertificate, (__bridge id)kSecValueRef: (__bridge id)cert,
                                                                 (__bridge id)kSecAttrLabel: kLabel}, NULL);
            if (st != errSecSuccess && st != errSecDuplicateItem) LOG("[RED] phone pads: HTTPS: the certificate could not be kept (%d)", (int)st);
            CFRelease(cert);
            ident = find_identity();
            if (ident) { [NSUserDefaults.standardUserDefaults setDouble:time(NULL) forKey:kMadeKey]; LOG("phone pads: HTTPS: made this iPad's own certificate (%zu bytes, %d days)", n, PP_CERT_DAYS); }
            else LOG("[RED] phone pads: HTTPS: the certificate and its key are not found together");
        } else LOG("[RED] phone pads: HTTPS: the certificate could not be made");
    } else LOG("[RED] phone pads: HTTPS: no public key");
    if (pd) CFRelease(pd);
    if (pub) CFRelease(pub);
    CFRelease(key);
    return ident;
}
static SecIdentityRef identity(void) {   // the server thread only
    static SecIdentityRef ident; static int tried;
    if (ident || tried) return ident;
    tried = 1;
    @autoreleasepool {
        double made = [NSUserDefaults.standardUserDefaults doubleForKey:kMadeKey];
        int fresh = made > 0 && time(NULL) - made < (PP_CERT_DAYS - 30) * 86400.0;
        ident = fresh ? find_identity() : NULL;
        if (!ident) ident = make_identity();
    }
    if (!ident) LOG("[RED] phone pads: no HTTPS: phones can play, but not with their motion");
    return ident;
}

static OSStatus io_read(SSLConnectionRef c, void *data, size_t *len) {
    const pp_tls *t = c; size_t want = *len;
    ssize_t r = recv(t->fd, data, want, 0);
    if (r > 0) { *len = (size_t)r; return (size_t)r < want ? errSSLWouldBlock : noErr; }
    *len = 0;
    if (r == 0) return errSSLClosedGraceful;
    return errno == EAGAIN || errno == EINTR ? errSSLWouldBlock : errSSLClosedAbort;
}
static OSStatus io_write(SSLConnectionRef c, const void *data, size_t *len) {
    const pp_tls *t = c; size_t want = *len;
    ssize_t w = send(t->fd, data, want, 0);
    if (w > 0) { *len = (size_t)w; return (size_t)w < want ? errSSLWouldBlock : noErr; }
    *len = 0;
    return w < 0 && (errno == EAGAIN || errno == EINTR) ? errSSLWouldBlock : errSSLClosedAbort;
}

void *pp_tls_new(int fd) {
    SecIdentityRef ident = identity(); if (!ident) return NULL;
    SSLContextRef ctx = SSLCreateContext(NULL, kSSLServerSide, kSSLStreamType); if (!ctx) return NULL;
    pp_tls *t = calloc(1, sizeof *t); t->ctx = ctx; t->fd = fd;
    CFArrayRef certs = CFArrayCreate(NULL, (const void **)&ident, 1, &kCFTypeArrayCallBacks);
    OSStatus st = SSLSetIOFuncs(ctx, io_read, io_write);
    if (!st) st = SSLSetConnection(ctx, t);
    if (!st) st = SSLSetCertificate(ctx, certs);
    if (!st) st = SSLSetProtocolVersionMin(ctx, kTLSProtocol12);
    CFRelease(certs);
    if (st) { LOG("[RED] phone pads: HTTPS: could not set up a connection (%d)", (int)st); CFRelease(ctx); free(t); return NULL; }
    return t;
}
long pp_tls_recv(void *p, void *buf, size_t n) {
    pp_tls *t = p; SSLSessionState s = kSSLIdle;
    SSLGetSessionState(t->ctx, &s);
    if (s == kSSLIdle || s == kSSLHandshake) {
        OSStatus st = SSLHandshake(t->ctx);
        if (st == errSSLWouldBlock) return -2;
        if (st) {   // most often a phone that has not trusted the certificate yet and dropped the connection; logged once per connection
            if (!t->logged++) LOG("phone pads: HTTPS: a phone's handshake ended (%d): not trusted yet, or the page was closed", (int)st);
            return -1;
        }
    }
    size_t got = 0; OSStatus st = SSLRead(t->ctx, buf, n, &got);
    if (got) return (long)got;
    if (st == errSSLWouldBlock) return -2;
    return st == errSSLClosedGraceful || st == errSSLClosedNoNotify ? 0 : -1;
}
int pp_tls_send(void *p, const void *data, size_t n) {
    pp_tls *t = p; const uint8_t *b = data;
    for (;;) {
        size_t done = 0; OSStatus st = SSLWrite(t->ctx, b, n, &done);
        b += done; n -= done;
        if (st == noErr && !n) return 0;
        if (st != errSSLWouldBlock && st != noErr) return -1;
        if (st == errSSLWouldBlock) { struct pollfd pf = {.fd = t->fd, .events = POLLOUT}; if (poll(&pf, 1, 1000) <= 0) return -1; }   // a write of 0 then flushes what is buffered
    }
}
void pp_tls_free(void *p) {
    pp_tls *t = p; if (!t) return;
    SSLClose(t->ctx); CFRelease(t->ctx); free(t);
}
