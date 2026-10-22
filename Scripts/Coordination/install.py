#!/usr/bin/env python3
"""Stage/load the user-only adapter; never launch or restart Desktop/app-server."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from agent_mail_wake import atomic_json, messages

LABEL = 'local.codex.agent-mail-wake'


def install(destination, launch_agents, thread, load=False):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = {'project': '/Users/kridsdale/Documents/JellyfinPlayer',
        'recipient': 'BlueLake', 'sender': 'GreenCastle', 'thread': thread,
        'database': str(destination.parent / 'data/storage.sqlite3'),
        'socket': str(Path.home() / '.codex/app-server-control/app-server-control.sock')}
    config_path = destination / 'config.json'
    if config_path.exists():
        if json.loads(config_path.read_text()) != config:
            raise RuntimeError('existing adapter configuration differs; preserve it and review manually')
    else:
        atomic_json(config_path, config)
    state = destination / 'state.json'
    if not state.exists():
        existing = messages(config, -1)
        atomic_json(state, {'cursor': max((m['id'] for m in existing), default=0), 'inflight': None})
    target = destination / 'agent_mail_wake.py'
    if target.exists() and load:
        raise RuntimeError('adapter already staged; refuse replacing running code')
    shutil.copyfile(Path(__file__).with_name('agent_mail_wake.py'), target)
    launch_agents = Path(launch_agents)
    launch_agents.mkdir(parents=True, exist_ok=True)
    plist = launch_agents / (LABEL + '.plist')
    definition = {'Label': LABEL, 'ProgramArguments': [sys.executable, str(target),
        '--config', str(config_path), 'run'], 'RunAtLoad': True,
        'ProcessType': 'Background', 'Umask': 0o077,
        'StandardOutPath': str(destination / 'stdout.log'),
        'StandardErrorPath': str(destination / 'stderr.log')}
    if plist.exists() and plistlib.loads(plist.read_bytes()) != definition:
        raise RuntimeError('existing LaunchAgent differs; no overwrite')
    plist.write_bytes(plistlib.dumps(definition))
    atomic_json(destination / 'status.json', {'status': 'WAITING_FOR_DESKTOP_SOCKET'})
    if load:
        subprocess.run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)], check=True)
    return config_path, plist


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--thread', required=True)
    parser.add_argument('--load', action='store_true', help='load only this user adapter; never starts Desktop/app-server')
    parser.add_argument('--destination', type=Path,
        default=Path.home() / 'Library/Application Support/CodexAgentMail/wake')
    parser.add_argument('--launch-agents', type=Path, default=Path.home() / 'Library/LaunchAgents')
    args = parser.parse_args()
    install(args.destination, args.launch_agents, args.thread, args.load)
    print('Adapter staged. Mail is unchanged. Check status.json for observed readiness.')
    print('Future migration after Desktop exits naturally (not executed by this installer):')
    print('/opt/homebrew/bin/codex app-server daemon bootstrap')
    print('CODEX_APP_SERVER_USE_LOCAL_DAEMON=1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT')
    print('Open the existing chat in that Desktop; adapter never starts/resumes it.')


if __name__ == '__main__':
    main()
