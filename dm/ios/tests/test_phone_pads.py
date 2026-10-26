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


class Phone:
    """One phone's WebSocket connection (frames masked, as a browser sends them)"""
    def __init__(self, port, device_id=None):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=2)
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

    def close(self):
        self.s.close()


class PhonePadsTests(unittest.TestCase):
    controllers = 0   # players physical controllers hold before any phone connects

    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        if not cc: raise unittest.SkipTest('needs a C compiler')
        cls.tmp = Path(tempfile.mkdtemp())
        (cls.tmp / 'game_profile.h').write_text('#pragma once\n')   # dm.h includes the game profile; the server uses none of it
        exe = cls.tmp / 'phone_pads_check'
        r = subprocess.run([cc, '-std=gnu11', '-O1', '-Wall', '-Werror', '-Wno-unused-parameter', f'-I{cls.tmp}', f'-I{REPO / "dm/host"}', f'-I{SOURCES}', '-o', str(exe),
                            str(Path(__file__).with_name('phone_pads_check.c')), str(SOURCES / 'phone_pads.c'), str(SOURCES / 'shell_slots.c'), '-lpthread'], capture_output=True, text=True)
        if r.returncode: raise AssertionError(r.stdout + r.stderr)
        cls.port = free_port()
        cls.state_file = cls.tmp / 'state.json'
        cls.proc = subprocess.Popen([str(exe), str(cls.state_file), str(cls.controllers)], env=dict(os.environ, DM_PHONE_PADS_PORT=str(cls.port)), stderr=subprocess.PIPE, text=True)
        for _ in range(100):
            if cls.state_file.exists(): break
            time.sleep(0.02)

    @classmethod
    def tearDownClass(cls):
        cls.proc.kill(); cls.proc.wait()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def host(self):
        time.sleep(0.1)
        return json.loads(self.state_file.read_text())

    def test_page_is_served(self):
        with socket.create_connection(('127.0.0.1', self.port), timeout=2) as s:
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
        self.assertEqual(a.hello('phone-a'), {'t': 'assign', 'player': 1})
        self.assertEqual(b.hello('phone-b'), {'t': 'assign', 'player': 2})
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
        self.assertEqual(b.hello('phone-b'), {'t': 'assign', 'player': 2})
        # the same phone on a second connection while the first is still open (a reloaded page): the new one takes over its player
        b2 = Phone(self.port)
        self.assertEqual(b2.hello('phone-b'), {'t': 'assign', 'player': 2})
        self.assertEqual(self.host()['mask'], 0b11)
        # eight players at most
        more = [Phone(self.port, f'phone-{i}') for i in range(6)]
        self.assertEqual(self.host()['mask'], 0xff)
        ninth = Phone(self.port)
        self.assertEqual(ninth.hello('phone-9'), {'t': 'full'})
        for ph in [a, b, b2, ninth] + more: ph.close()
        self.assertEqual(self.host()['mask'], 0)


class PhonePadsWithControllersTests(PhonePadsTests):
    """Two physical controllers hold players 1 and 2: phones take the players after them, and the mask the host gets keeps the controllers'"""
    controllers = 2
    test_players = None
    test_page_is_served = None
    test_embedded_page_is_current = None

    def test_phones_after_controllers(self):
        self.assertEqual(self.host()['mask'], 0b11)
        a = Phone(self.port)
        self.assertEqual(a.hello('phone-a'), {'t': 'assign', 'player': 3})
        self.assertEqual(self.host()['mask'], 0b111)
        a.state(1, 1 << 0)
        self.assertEqual(self.host()['players'][2][0], 1)
        more = [Phone(self.port, f'phone-{i}') for i in range(5)]
        self.assertEqual(self.host()['mask'], 0xff)
        extra = Phone(self.port)
        self.assertEqual(extra.hello('phone-x'), {'t': 'full'})
        for ph in [a, extra] + more: ph.close()
        self.assertEqual(self.host()['mask'], 0b11)   # the phones leaving does not take the controllers' players away

if __name__ == '__main__':
    unittest.main()
