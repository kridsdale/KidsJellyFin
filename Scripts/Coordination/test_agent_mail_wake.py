from contextlib import closing
import base64
import hashlib
import json
import os
import plistlib
import shutil
from pathlib import Path
import select
import socket
import sqlite3
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch

import agent_mail_wake as wake
import install as installer


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.dbpath = self.root / 'mail.sqlite3'
        self.config = {'database': str(self.dbpath), 'project': '/project',
            'recipient': 'BlueLake', 'sender': 'GreenCastle',
            'socket': str(self.root / 'desktop.sock'), 'thread': 'existing-chat'}
        with sqlite3.connect(self.dbpath) as db:
            db.executescript('''
                CREATE TABLE projects(id INTEGER, human_key TEXT);
                CREATE TABLE agents(id INTEGER, name TEXT);
                CREATE TABLE messages(id INTEGER, project_id INTEGER, sender_id INTEGER, thread_id TEXT);
                CREATE TABLE message_recipients(message_id INTEGER, agent_id INTEGER, read_ts TEXT);
                INSERT INTO projects VALUES(1, '/project');
                INSERT INTO agents VALUES(1, 'GreenCastle'), (2, 'BlueLake'), (3, 'OtherPeer');
                INSERT INTO messages VALUES(1,1,1,'kids-test'),(2,1,1,'kids-next'),(3,1,3,'kids-other');
                INSERT INTO message_recipients VALUES(1,2,NULL),(2,2,NULL),(3,2,NULL);
            ''')
        self.state = self.root / 'state.json'
        wake.atomic_json(self.state, {'cursor': 0, 'inflight': None})

    def test_metadata_scope_and_cursor(self):
        self.assertEqual(wake.messages(self.config, 0), [{'id': 1, 'bead': 'kids-test'}, {'id': 2, 'bead': 'kids-next'}])
        self.assertEqual(wake.messages(self.config, 1), [{'id': 2, 'bead': 'kids-next'}])
        with sqlite3.connect(self.dbpath) as db:
            self.assertEqual(db.execute('select count(*) from message_recipients where read_ts is not null').fetchone()[0], 0)

    def factory(self, loaded=True, failure=False):
        events = []
        class FakeDesktop:
            def __init__(self, path): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def loaded(self, thread): return loaded
            def deliver(self, thread, event):
                events.append((thread, event))
                if failure: raise wake.Waiting('AMBIGUOUS')
                return {'turn': {'id': 'turn-1'}}
        return FakeDesktop, events

    def test_coalesces_once_and_requires_exact_receipt(self):
        factory, events = self.factory()
        self.assertEqual(wake.reconcile(self.config, self.state, factory), 'DELIVERY_ACCEPTED')
        self.assertEqual(wake.reconcile(self.config, self.state, factory), 'WAITING_FOR_OWNER_RECEIPT')
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0][1]['message_ids'], [1, 2])
        with self.assertRaises(ValueError): wake.receipt(self.state, 1)
        wake.receipt(self.state, 2)
        self.assertEqual(wake.reconcile(self.config, self.state, factory), 'IDLE')
        self.assertEqual(json.loads(self.state.read_text())['cursor'], 2)

    def test_ambiguous_send_is_not_repeated_after_restart(self):
        factory, events = self.factory(failure=True)
        with self.assertRaises(wake.Waiting): wake.reconcile(self.config, self.state, factory)
        self.assertEqual(json.loads(self.state.read_text())['inflight']['phase'], 'sending')
        self.assertEqual(wake.reconcile(self.config, self.state, factory), 'WAITING_FOR_OWNER_RECEIPT')
        self.assertEqual(len(events), 1)

    def test_unloaded_chat_is_never_resumed(self):
        factory, events = self.factory(loaded=False)
        self.assertEqual(wake.reconcile(self.config, self.state, factory), 'WAITING_FOR_LOADED_DESKTOP_CHAT')
        self.assertEqual(events, [])
        self.assertIsNone(json.loads(self.state.read_text())['inflight'])

    def test_missing_socket_preserves_mail_and_state(self):
        before = self.state.read_bytes()
        with self.assertRaisesRegex(wake.Waiting, 'WAITING_FOR_DESKTOP_SOCKET'):
            wake.reconcile(self.config, self.state)
        self.assertEqual(self.state.read_bytes(), before)

    def test_watch_nearest_existing_socket_ancestor(self):
        self.config['socket'] = str(self.root / 'missing' / 'control.sock')
        self.assertIn(self.root, wake.watch_paths(self.config, self.state))

    @unittest.skipUnless(hasattr(select, 'kqueue'), 'macOS event mechanism')
    def test_kqueue_wakes_on_creation_without_timer(self):
        fd = os.open(self.root, os.O_EVTONLY)
        self.addCleanup(os.close, fd)
        with closing(select.kqueue()) as queue:
            queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)], 0, 0)
            (self.root / 'new-socket-dir').mkdir()
            self.assertTrue(queue.control([], 1, 1))

    def test_install_preserves_cursor_and_uses_no_timer(self):
        with sqlite3.connect(self.dbpath) as db:
            db.execute('update projects set human_key=?', ('/Users/kridsdale/Documents/JellyfinPlayer',))
        destination = self.root / 'private' / 'wake'
        (destination.parent / 'data').mkdir(parents=True)
        shutil.copyfile(self.dbpath, destination.parent / 'data/storage.sqlite3')
        config, plist = installer.install(destination, self.root / 'LaunchAgents', 'existing-chat')
        state = destination / 'state.json'
        self.assertEqual(json.loads(state.read_text())['cursor'], 2)
        wake.atomic_json(state, {'cursor': 9, 'inflight': None})
        installer.install(destination, self.root / 'LaunchAgents', 'existing-chat')
        self.assertEqual(json.loads(state.read_text())['cursor'], 9)
        definition = plistlib.loads(plist.read_bytes())
        self.assertNotIn('StartInterval', definition)
        self.assertNotIn('StartCalendarInterval', definition)
        self.assertNotIn('KeepAlive', definition)
        self.assertEqual(definition['ProgramArguments'][-1], 'run')

    def test_real_unix_websocket_readiness_and_tool_output_shape(self):
        path = self.root / 'desktop.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        os.chmod(path, 0o600)
        os.chmod(self.root, 0o700)
        listener.listen(1)
        requests, errors = [], []
        def server():
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(3)
                    def exact(size):
                        data = b''
                        while len(data) < size:
                            chunk = connection.recv(size-len(data))
                            if not chunk: raise EOFError()
                            data += chunk
                        return data
                    header = b''
                    while not header.endswith(b'\r\n\r\n'): header += exact(1)
                    key = [line.split(b': ',1)[1] for line in header.split(b'\r\n') if line.startswith(b'Sec-WebSocket-Key:')][0]
                    accept = base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                    connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
                    for _ in range(4):
                        first, second = exact(2)
                        size = second & 127
                        if size == 126: size = struct.unpack('!H',exact(2))[0]
                        mask = exact(4)
                        body = exact(size)
                        request = json.loads(bytes(b ^ mask[i%4] for i,b in enumerate(body)))
                        requests.append(request)
                        if 'id' not in request: continue
                        result = {'thread': {'status': {'type': 'idle'}}} if request['method']=='thread/read' else {}
                        payload = json.dumps({'id':request['id'],'result':result}).encode()
                        connection.sendall(bytes([0x81, len(payload)])+payload)
            except BaseException as error: errors.append(error)
        worker = threading.Thread(target=server)
        worker.start()
        with wake.Desktop(path) as desktop:
            self.assertTrue(desktop.loaded('existing-chat'))
            desktop.deliver('existing-chat', {'message_ids':[1,2]})
        worker.join(4)
        listener.close()
        self.assertFalse(worker.is_alive())
        self.assertFalse(errors, errors)
        self.assertEqual([r['method'] for r in requests], ['initialize','initialized','thread/read','turn/start'])
        self.assertEqual(requests[-1]['params']['input'], [])
        self.assertEqual(requests[-1]['params']['toolOutput']['name'], 'agent_mail_event')
        self.assertNotIn('thread/resume', str(requests))


if __name__ == '__main__': unittest.main()
