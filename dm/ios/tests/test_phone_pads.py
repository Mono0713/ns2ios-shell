"""Phone controllers (dm/ios/Sources/phone_pads.c): compile the server with a stand-in host (phone_pads_check.c) for this machine and drive it as phones would, over a
plain socket: the page, the WebSocket handshake, player assignment (from the shared slot table, shell_slots.c), input reaching the right player, ordering, the silence release, the eight-player limit and reconnects.
Also checks that the embedded page (phone_pad_page.h) matches dm/ios/phone_pad.html."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCES = REPO / 'dm/ios/Sources'


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def connect(port, tls=False):   # a plain connection, or HTTPS taking the server's own certificate as a phone does once its owner trusts it
    s = socket.create_connection(('127.0.0.1', port), timeout=2)
    if not tls: return s
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.check_hostname = False; c.verify_mode = ssl.CERT_NONE
    return c.wrap_socket(s)


class Phone:
    """One phone's WebSocket connection (frames masked, as a browser sends them)"""
    def __init__(self, port, device_id=None, tls=False):
        self.s = connect(port, tls)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(f'GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
        head = b''
        while b'\r\n\r\n' not in head: head += self.s.recv(1)
        want = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.handshake_ok = head.startswith(b'HTTP/1.1 101') and f'Sec-WebSocket-Accept: {want}'.encode() in head
        if device_id: self.hello(device_id)

    def frame(self, op, data):
        mask = os.urandom(4)
        self.s.sendall(bytes([0x80 | op, 0x80 | len(data)]) + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(data)))

    def hello(self, device_id):
        self.frame(1, json.dumps({'t': 'hello', 'v': 1, 'id': device_id, 'name': 'test'}).encode())
        return self.reply()

    def reply(self):
        h = self.s.recv(2)
        return json.loads(self.s.recv(h[1]))

    def state(self, seq, buttons, lx=0, ly=0, rx=0, ry=0):
        self.frame(2, struct.pack('<BBHbbbb', 1, seq & 255, buttons, lx, ly, rx, ry))

    def motion(self, seq, ms, grav, rot):
        self.frame(2, motion_packet(seq, ms, grav, rot))

    def close(self):
        self.s.close()


def motion_packet(seq, ms, grav, rot):   # gravity in G, rotation in degrees / s, the controller's frame
    return struct.pack('<BBH3h3h', 3, seq & 255, ms & 0xffff, *(round(g * 4096) for g in grav), *(round(r * 8) for r in rot))


class PostPhone:
    """A page that sends by POST (iPhone Safari over HTTPS): requests on one kept connection, or a new one"""
    def __init__(self, port, device_id, tls=False):
        self.port, self.id, self.tls = port, device_id, tls
        self.s = connect(port, tls)

    def post(self, *messages):   # each a str (text) or bytes (binary); returns the messages for the phone
        body = b''.join(bytes([1 if isinstance(m, str) else 2]) + struct.pack('<H', len(m)) + (m.encode() if isinstance(m, str) else m) for m in messages)
        self.s.sendall(f'POST /p?id={self.id} HTTP/1.1\r\nHost: t\r\nContent-Type: application/octet-stream\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body)
        head = b''
        while b'\r\n\r\n' not in head: head += self.s.recv(1)
        assert head.startswith(b'HTTP/1.1 200'), head
        n = int(head.split(b'Content-Length:')[1].split(b'\r\n')[0])
        data = b''
        while len(data) < n: data += self.s.recv(n - len(data))
        return [json.loads(line) for line in data.decode().splitlines() if line]

    def hello(self):
        return self.post(json.dumps({'t': 'hello', 'v': 1, 'id': self.id, 'name': 'test'}))

    def state(self, seq, buttons, lx=0, ly=0, rx=0, ry=0):
        return self.post(struct.pack('<BBHbbbb', 1, seq & 255, buttons, lx, ly, rx, ry))

    def reconnect(self):   # the browser may send the next request on another connection
        self.s.close(); self.s = connect(self.port, self.tls)

    def close(self):
        self.s.close()


class PhonePadsServer(unittest.TestCase):
    controllers = 0   # players physical controllers hold before any phone connects
    tls = False       # HTTPS too (phone_pads_tls_test.c with OpenSSL, a certificate made for the test)

    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        if not cc: raise unittest.SkipTest('needs a C compiler')
        cls.tmp = Path(tempfile.mkdtemp())
        (cls.tmp / 'game_profile.h').write_text('#pragma once\n')   # dm.h includes the game profile; the server uses none of it
        exe = cls.tmp / 'phone_pads_check'
        extra, env = [], {}
        if cls.tls:
            if not shutil.which('openssl') or not Path('/usr/include/openssl/ssl.h').exists() and not shutil.which('brew'): raise unittest.SkipTest('needs OpenSSL')
            # the certificate the app makes itself (phone_pads_cert.c), here signed by OpenSSL, and openssl's own check that it is a server certificate
            mk = cls.tmp / 'cert_check'
            r = subprocess.run([cc, '-std=gnu11', '-Wall', '-Werror', f'-I{SOURCES}', '-o', str(mk), str(Path(__file__).with_name('phone_pads_cert_check.c')), str(SOURCES / 'phone_pads_cert.c'),
                                '-lcrypto'], capture_output=True, text=True)
            if r.returncode: raise unittest.SkipTest('needs OpenSSL to build against: ' + r.stderr[-300:])
            subprocess.run([str(mk), str(cls.tmp / 'cert.der'), str(cls.tmp / 'key.pem')], check=True, capture_output=True)
            subprocess.run(['openssl', 'x509', '-inform', 'der', '-in', str(cls.tmp / 'cert.der'), '-out', str(cls.tmp / 'cert.pem')], check=True, capture_output=True)
            r = subprocess.run(['openssl', 'verify', '-CAfile', str(cls.tmp / 'cert.pem'), '-purpose', 'sslserver', str(cls.tmp / 'cert.pem')], capture_output=True, text=True)
            if r.returncode: raise AssertionError('the certificate does not check out: ' + r.stdout + r.stderr)
            extra = [str(Path(__file__).with_name('phone_pads_tls_test.c')), '-lssl', '-lcrypto']
            env = {'PP_TEST_CERT': str(cls.tmp / 'cert.pem'), 'PP_TEST_KEY': str(cls.tmp / 'key.pem')}
        r = subprocess.run([cc, '-std=gnu11', '-O1', '-Wall', '-Werror', '-Wno-unused-parameter', f'-I{cls.tmp}', f'-I{REPO / "dm/host"}', f'-I{SOURCES}', '-o', str(exe),
                            str(Path(__file__).with_name('phone_pads_check.c')), str(SOURCES / 'phone_pads.c'), str(SOURCES / 'shell_slots.c'), str(SOURCES / 'shell_motion.c'), str(REPO / 'dm/host/hle_haptics.c')] + extra + ['-lpthread', '-lm'], capture_output=True, text=True)
        if r.returncode: raise AssertionError(r.stdout + r.stderr)
        cls.port = free_port()
        cls.state_file = cls.tmp / 'state.json'
        cls.proc = subprocess.Popen([str(exe), str(cls.state_file), str(cls.controllers)], env=dict(os.environ, DM_PHONE_PADS_PORT=str(cls.port), **env), stdin=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True)
        for _ in range(100):
            if cls.state_file.exists(): break
            time.sleep(0.02)

    @classmethod
    def tearDownClass(cls):
        cls.proc.kill(); cls.proc.wait()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def launcher(self, line):   # what the launcher's player list does (shell_slots.h)
        self.proc.stdin.write(line + '\n'); self.proc.stdin.flush()

    def host(self):
        time.sleep(0.1)
        return json.loads(self.state_file.read_text())


class PhonePadsTests(PhonePadsServer):
    def test_page_is_served(self):
        with connect(self.port, self.tls) as s:
            s.sendall(b'GET / HTTP/1.1\r\nHost: t\r\n\r\n')
            data = b''
            while chunk := s.recv(65536): data += chunk
        head, body = data.split(b'\r\n\r\n', 1)
        self.assertTrue(head.startswith(b'HTTP/1.1 200'))
        self.assertEqual(body, (REPO / 'dm/ios/phone_pad.html').read_bytes())

    def test_embedded_page_is_current(self):
        r = subprocess.run([sys.executable, str(REPO / 'dm/ios/tools/gen_phone_pad_page.py'), '--check'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_players(self):
        a, b = Phone(self.port), Phone(self.port)
        self.assertTrue(a.handshake_ok and b.handshake_ok)
        self.assertEqual(a.hello('phone-a'), {'t': 'assign', 'layout': 'switch', 'player': 1})
        self.assertEqual(b.hello('phone-b'), {'t': 'assign', 'layout': 'switch', 'player': 2})
        self.assertEqual(self.host()['mask'], 0b11)
        # input reaches each phone's own player; NpadButton bits pass through, sticks scale to the host's range
        a.state(1, 1 << 0, lx=127, ly=-127)
        b.state(1, (1 << 9) | (1 << 13))
        p = self.host()['players']
        self.assertEqual(p[0], [1, 127 * 258, -127 * 258, 0, 0])
        self.assertEqual(p[1], [(1 << 9) | (1 << 13), 0, 0, 0, 0])
        # a packet older than the last one taken is dropped; the sequence number wraps
        a.state(0, 1 << 1)
        self.assertEqual(self.host()['players'][0][0], 1)
        for seq in (200, 255, 0, 3): a.state(seq, seq)
        self.assertEqual(self.host()['players'][0][0], 3)
        # a phone that goes quiet for a second has everything released
        b.state(2, 1 << 2)
        self.assertEqual(self.host()['players'][1][0], 1 << 2)
        time.sleep(1.3)
        self.assertEqual(self.host()['players'][1][0], 0)
        # a phone that leaves frees its player and gets it back when it returns; the host releases it meanwhile
        b.close()
        host = self.host()
        self.assertEqual(host['mask'], 0b01)
        self.assertEqual(host['players'][1], [0, 0, 0, 0, 0])
        b = Phone(self.port)
        self.assertEqual(b.hello('phone-b'), {'t': 'assign', 'layout': 'switch', 'player': 2})
        # the same phone on a second connection while the first is still open (a reloaded page): the new one takes over its player
        b2 = Phone(self.port)
        self.assertEqual(b2.hello('phone-b'), {'t': 'assign', 'layout': 'switch', 'player': 2})
        # the old page is told so, and closed: the page then stops reconnecting, so two pages of one phone do not keep taking the player from each other
        self.assertEqual(b.reply(), {'t': 'replaced'})
        self.assertEqual(b.s.recv(1), b'')
        self.assertEqual(self.host()['mask'], 0b11)
        # eight players at most
        more = [Phone(self.port, f'phone-{i}') for i in range(6)]
        self.assertEqual(self.host()['mask'], 0xff)
        ninth = Phone(self.port)
        self.assertEqual(ninth.hello('phone-9'), {'t': 'full'})
        for ph in [a, b, b2, ninth] + more: ph.close()
        self.assertEqual(self.host()['mask'], 0)

    def test_quick_tap_is_held_for_the_game(self):   # a press and its release together (a quick tap, or two packets the Wi-Fi handed over at once) still reach the game
        a = Phone(self.port, 'phone-tap')
        real, sent = a.s, []
        a.s = type('W', (), {'sendall': lambda self, d: sent.append(d)})()
        a.state(1, 1 << 14); a.state(2, 0)   # D-pad right and let go, in one write: the server takes both in one read
        a.s = real; real.sendall(b''.join(sent))
        seen, t0 = 0, time.time()
        while time.time() - t0 < 0.2:
            try: seen |= json.loads(self.state_file.read_text())['players'][0][0]
            except (ValueError, OSError): pass
            time.sleep(0.005)
        self.assertEqual(seen & (1 << 14), 1 << 14)
        self.assertEqual(self.host()['players'][0][0], 0)   # and let go after it
        # a button held longer than that goes up as soon as the phone lets go
        a.state(3, 1 << 0); time.sleep(0.1); a.state(4, 0)
        self.assertEqual(self.host()['players'][0][0], 0)
        a.close()

    def test_silent_page_is_dropped(self):   # a page left in a background tab keeps its socket open but sends nothing: after 15 s its player is freed
        g = Phone(self.port)
        self.assertEqual(g.hello('phone-gone')['t'], 'assign')
        self.assertEqual(self.host()['mask'], 0b1)
        time.sleep(15.6)
        self.assertEqual(self.host()['mask'], 0)
        g.close()

    def test_idle_connections_do_not_lock_phones_out(self):   # spare browser connections that never send a request: more than the server holds, while phones play
        a, b = Phone(self.port, 'phone-a'), Phone(self.port, 'phone-b')
        idle = [socket.create_connection(('127.0.0.1', self.port), timeout=2) for _ in range(30)]
        time.sleep(0.3)
        c = Phone(self.port)
        self.assertEqual(c.hello('phone-0'), {'t': 'assign', 'layout': 'switch', 'player': 3})   # the oldest idle ones made room, the players kept theirs
        a.state(1, 1 << 0); b.state(1, 1 << 1); c.state(1, 1 << 2)
        self.assertEqual([p[0] for p in self.host()['players'][:3]], [1 << 0, 1 << 1, 1 << 2])
        # and an idle connection is closed after 10 s on its own
        time.sleep(10.5)
        idle[-1].settimeout(1)
        self.assertEqual(idle[-1].recv(1), b'')
        for s in idle + [a, b, c]: s.close()
        self.assertEqual(self.host()['mask'], 0)


class PhonePadsWithControllersTests(PhonePadsTests):
    """Two physical controllers hold players 1 and 2: phones take the players after them, and the mask the host gets keeps the controllers'"""
    controllers = 2
    test_players = None
    test_page_is_served = None
    test_embedded_page_is_current = None
    test_silent_page_is_dropped = None
    test_idle_connections_do_not_lock_phones_out = None

    def test_phones_after_controllers(self):   # and the launcher's swap, layout and remove
        self.assertEqual(self.host()['mask'], 0b11)
        a = Phone(self.port)
        self.assertEqual(a.hello('phone-a'), {'t': 'assign', 'layout': 'switch', 'player': 3})
        self.assertEqual(self.host()['mask'], 0b111)
        a.state(1, 1 << 0)
        self.assertEqual(self.host()['players'][2][0], 1)
        more = [Phone(self.port, f'phone-{i}') for i in range(5)]
        self.assertEqual(self.host()['mask'], 0xff)
        extra = Phone(self.port)
        self.assertEqual(extra.hello('phone-x'), {'t': 'full'})
        # the launcher swaps a phone with a controller: the phone is told its new player and its input goes there
        self.launcher('swap 0 2')
        self.assertEqual(a.reply(), {'t': 'assign', 'player': 1, 'layout': 'switch'})
        self.assertEqual(self.host()['slots'][0][0], 2)   # a phone (SHELL_SLOT_PHONE) holds player 1 now, a controller player 3
        self.assertEqual(self.host()['slots'][2][0], 1)
        a.state(2, 1 << 1)
        self.assertEqual(self.host()['players'][0][0], 1 << 1)
        # the Xbox layout reaches the page
        self.launcher('layout 0 1')
        self.assertEqual(a.reply(), {'t': 'assign', 'player': 1, 'layout': 'xbox'})
        self.assertEqual(self.host()['slots'][0], [2, 1])
        # the phone's own layout switch: answered with an assign in that layout, and the slot table has it
        a.frame(1, json.dumps({'t': 'layout', 'xbox': 0}).encode())
        self.assertEqual(a.reply(), {'t': 'assign', 'player': 1, 'layout': 'switch'})
        self.assertEqual(self.host()['slots'][0], [2, 0])
        # a removed phone is released, told so, and stays out when it reconnects until it asks to join again
        a.state(3, 1 << 0)
        self.launcher('kick 0')
        self.assertEqual(a.reply(), {'t': 'kicked'})
        host = self.host()
        self.assertEqual(host['players'][0][0], 0)
        self.assertEqual(host['slots'][0][0], 0)
        a.close()
        a = Phone(self.port)
        self.assertEqual(a.hello('phone-a'), {'t': 'kicked'})
        a.frame(1, json.dumps({'t': 'hello', 'v': 1, 'id': 'phone-a', 'name': 'test', 'join': 1}).encode())
        self.assertEqual(a.reply(), {'t': 'assign', 'player': 1, 'layout': 'switch'})
        for ph in [a, extra] + more: ph.close()
        self.assertEqual(self.host()['mask'], 0b110)   # the phones leaving does not take the controllers' players away (now players 2 and 3)

class PhoneMenuAuthorityTests(PhonePadsServer):
    def test_menu_authority_when_player_one_disconnects(self):
        def join(name, slot):
            phone = Phone(self.port)
            self.addCleanup(phone.close)
            self.assertEqual(phone.hello(name)['player'], slot)
            return phone

        first = join('authority-first', 1)
        second = join('authority-second', 2)
        third = join('authority-third', 3)
        self.assertEqual(self.host()['menu_players'][:3], [0, 1, 2])

        first.close()
        state = self.host()
        self.assertEqual(state['mask'], 0b110)
        self.assertEqual(state['menu_players'][:3], [-1, 0, 0])
        fourth = join('authority-new', 4)
        self.assertEqual(self.host()['menu_players'][:4], [-1, 0, 0, 0])
        fourth.close()
        first = join('authority-first', 1)
        self.assertEqual(self.host()['menu_players'][:3], [0, 1, 2])

        first.close()
        self.assertEqual(self.host()['mask'], 0b110)
        self.launcher('swap 0 2')
        self.assertEqual(third.reply()['player'], 1)
        self.assertEqual(self.host()['menu_players'][:3], [0, 1, -1])
        first = join('authority-first', 3)
        self.assertEqual(self.host()['menu_players'][:3], [0, 1, 2])
        for phone in (first, second, third):
            phone.close()
        self.assertEqual(self.host()['mask'], 0)


class PhoneJoyconTests(PhonePadsServer):
    controllers = 2

    def test_joycon_moves_with_phone_and_reconnects(self):
        a = Phone(self.port)
        self.addCleanup(lambda: a.close())
        a.frame(1, b'{"t":"hello","v":1,"id":"right-joy","name":"test","mode":"joyright"}')
        self.assertEqual(a.reply()['player'], 3)
        self.assertEqual(self.host()['joyright'], 0b100)
        rail_buttons = (1 << 6) | (1 << 8)
        a.state(1, rail_buttons, rx=60)
        self.assertEqual(self.host()['players'][2], [(1 << 26) | (1 << 27), 0, 0, 60 * 258, 0])
        self.launcher('swap 0 2')
        self.assertEqual(a.reply()['player'], 1)
        host = self.host()
        self.assertEqual(host['joyright'], 0b1)
        self.assertEqual(host['players'][2], [0, 0, 0, 0, 0])
        a.frame(1, b'{"t":"padtype","mode":"pro"}')
        self.assertEqual(a.reply()['player'], 1)
        a.state(2, rail_buttons)
        host = self.host()
        self.assertEqual(host['joyright'], 0)
        self.assertEqual(host['players'][0][0], rail_buttons)
        a.close()
        self.assertEqual(self.host()['players'][0][0], 0)
        a = Phone(self.port)
        a.frame(1, b'{"t":"hello","v":1,"id":"right-joy","name":"test","mode":"joyright"}')
        self.assertEqual(a.reply()['player'], 1)
        self.assertEqual(self.host()['joyright'], 0b1)


class PhoneJoyconPostTests(PhonePadsServer):
    def test_joycon_over_post(self):
        p = PostPhone(self.port, 'joy-post', self.tls)
        self.addCleanup(p.close)
        hello = '{"t":"hello","v":1,"id":"joy-post","name":"test","mode":"joyright"}'
        self.assertEqual(p.post(hello)[0]['player'], 1)
        p.state(1, 1 << 8, rx=-60)
        host = self.host()
        self.assertEqual(host['joyright'], 1)
        self.assertEqual(host['players'][0], [1 << 27, 0, 0, -60 * 258, 0])
        p.reconnect()
        self.assertEqual(p.post('{"t":"padtype","mode":"pro"}')[0]['player'], 1)
        for _ in range(10):
            if not self.host()['joyright']:
                break
        self.assertEqual(self.host()['joyright'], 0)


if __name__ == '__main__':
    unittest.main()


class PhonePadsMotionTests(PhonePadsTests):
    """The phone's motion as its player's six-axis sensor, the game's rumble back to the phone, and the POST pages iPhone Safari uses over HTTPS"""
    test_players = None
    test_page_is_served = None
    test_embedded_page_is_current = None
    test_silent_page_is_dropped = None
    test_idle_connections_do_not_lock_phones_out = None

    def test_motion_and_rumble(self):
        a = Phone(self.port, None, self.tls)
        self.assertEqual(a.hello('phone-m'), {'t': 'assign', 'layout': 'switch', 'player': 1})
        for i in range(10): a.motion(i, 1000 + 10 * i, (0, 0, -1), (0, 0, 90))   # lying flat, turning left at 90 degrees / s
        m = self.host()['motion'][0]
        self.assertGreater(m[0], 0)
        self.assertAlmostEqual(m[3], -1, delta=0.01)   # the sensor reads gravity down
        self.assertAlmostEqual(m[6], 0.25, delta=0.01)   # and a quarter turn a second about z
        self.launcher('rumble 0 80')
        r = a.reply()
        self.assertEqual(r['t'], 'r'); self.assertGreater(r['l'], 100)
        self.launcher('rumble 0 0')
        for _ in range(5):   # (a repeat of the running rumble may come first)
            if a.reply() == {'t': 'r', 'l': 0}: break
        else: self.fail('the rumble did not stop')
        a.close()

    def test_post_page(self):
        p = PostPhone(self.port, 'phone-post', self.tls)
        self.assertIn({'t': 'assign', 'layout': 'switch', 'player': 1}, p.hello())
        p.state(1, 1 << 0)
        self.assertEqual(self.host()['players'][0][0], 1)
        # the next request on another connection is the same page
        p.reconnect()
        p.state(2, 1 << 1)
        self.assertEqual(self.host()['players'][0][0], 1 << 1)
        # the game's rumble comes with the next answer
        self.launcher('rumble 0 50'); time.sleep(0.1)
        r = [m for m in p.state(3, 0) if m['t'] == 'r']
        self.assertTrue(r and r[-1]['l'] > 0, r)
        self.launcher('rumble 0 0'); time.sleep(0.1)
        self.assertIn({'t': 'r', 'l': 0}, p.state(4, 0))
        # the same phone opening a WebSocket page takes over, and the POST page hears it was replaced
        w = Phone(self.port, None, self.tls)
        self.assertEqual(w.hello('phone-post'), {'t': 'assign', 'layout': 'switch', 'player': 1})
        w.close(); p.close()
        time.sleep(0.2)
        self.assertEqual(self.host()['mask'], 0)

    def test_page_without_hello_is_asked_for_one(self):   # its hello was lost (a failed POST) or the app started again under it: it is asked, then plays
        p = PostPhone(self.port, 'phone-lost', self.tls)
        self.assertIn({'t': 'who'}, p.state(1, 1 << 0))
        self.assertEqual(self.host()['mask'], 0)
        self.assertNotIn({'t': 'who'}, p.state(2, 1 << 0))   # asked at most once a second
        self.assertIn({'t': 'assign', 'layout': 'switch', 'player': 1}, p.hello())
        p.state(3, 1 << 1)
        self.assertEqual(self.host()['players'][0][0], 1 << 1)
        w = Phone(self.port, None, self.tls)   # and a WebSocket page the same
        w.state(1, 1 << 2)
        self.assertEqual(w.reply(), {'t': 'who'})
        self.assertEqual(w.hello('phone-lost-ws'), {'t': 'assign', 'layout': 'switch', 'player': 2})
        x = Phone(self.port, None, self.tls); x.hello('phone-lost')   # the POST page's session ends (it would hold player 1 for 15 s)
        x.close(); w.close(); p.close()
        time.sleep(0.2)
        self.assertEqual(self.host()['mask'], 0)

class PhonePadsHttpsTests(PhonePadsMotionTests):
    """All of it over HTTPS on the same port"""
    tls = True
    test_page_is_served = PhonePadsTests.test_page_is_served
