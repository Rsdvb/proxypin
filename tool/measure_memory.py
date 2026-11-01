#!/usr/bin/env python3
"""Measures sing-box memory the way iOS counts it, to see what each config choice costs.

Runs each binary and config with the Go settings libbox applies on iOS, reads the
physical footprint (what jetsam looks at) while idle and under load, and prints a
Markdown table. No TUN here, so a real tunnel adds its stack on top of these numbers.

Usage: measure_memory.py <config dir> <binary> [<binary> ...]
"""
import asyncio
import json
import os
import pathlib
import re
import subprocess
import sys
import time

CONNECTIONS = 200
LOAD_SECONDS = 8
CHUNK = b'x' * (64 * 1024)


def footprint(pid):
    """Physical footprint in MB. Falls back to RSS where footprint is unavailable."""
    try:
        output = subprocess.run(['sudo', 'footprint', '-p', str(pid)], capture_output=True, text=True, timeout=30).stdout
        match = re.search(r'phys_footprint:\s+([\d.]+)\s*(KB|MB|GB)', output)
        if match:
            value = float(match.group(1))
            return value * {'KB': 1 / 1024, 'MB': 1, 'GB': 1024}[match.group(2)]
    except (OSError, subprocess.TimeoutExpired):
        pass
    rss = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return int(rss) / 1024 if rss else 0.0


async def sink(reader, writer):
    """Sends data until the client goes away."""
    try:
        while True:
            writer.write(CHUNK)
            await writer.drain()
            await asyncio.sleep(0.05)
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def client(proxy_port, target_port, stop):
    """One connection through the proxy, reading until told to stop."""
    try:
        reader, writer = await asyncio.open_connection('127.0.0.1', proxy_port)
        writer.write(f'CONNECT 127.0.0.1:{target_port} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'.encode())
        await writer.drain()
        await reader.readuntil(b'\r\n\r\n')
        while not stop.is_set():
            if not await reader.read(65536):
                break
        writer.close()
    except (OSError, asyncio.IncompleteReadError):
        pass


async def load(proxy_port, pid):
    """Peak footprint while CONNECTIONS connections are moving data."""
    server = await asyncio.start_server(sink, '127.0.0.1', 0)
    target = server.sockets[0].getsockname()[1]
    stop = asyncio.Event()
    tasks = [asyncio.create_task(client(proxy_port, target, stop)) for _ in range(CONNECTIONS)]

    peak = 0.0
    deadline = time.monotonic() + LOAD_SECONDS
    while time.monotonic() < deadline:
        await asyncio.sleep(1)
        peak = max(peak, await asyncio.to_thread(footprint, pid))

    stop.set()
    await asyncio.gather(*tasks, return_exceptions=True)
    server.close()
    return peak


def wait_for_port(port, timeout=20):
    import socket
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as sock:
            sock.settimeout(0.3)
            if sock.connect_ex(('127.0.0.1', port)) == 0:
                return True
        time.sleep(0.1)
    return False


def measure(binary, config):
    data = json.loads(config.read_text(encoding='utf-8'))
    port = next(e['listen_port'] for e in data['inbounds'] if e['tag'] == 'mixed-in')
    environment = {**os.environ, 'GOGC': '50', 'GOMEMLIMIT': '40MiB'}
    process = subprocess.Popen([binary, 'run', '-c', config.name, '-D', '.'], cwd=config.parent, env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        if not wait_for_port(port):
            process.kill()
            return None, None, None, (process.stderr.read() or '')[-200:]
        time.sleep(3)
        idle = footprint(process.pid)
        peak = asyncio.run(load(port, process.pid))
        time.sleep(5)
        after = footprint(process.pid)
        return idle, peak, after, ''
    finally:
        process.terminate()
        process.wait(timeout=10)


def main():
    directory = pathlib.Path(sys.argv[1])
    binaries = sys.argv[2:]
    lines = [
        f'| binary | size MB | config | idle MB | peak MB ({CONNECTIONS} conns) | after MB |',
        '|---|---|---|---|---|---|',
    ]
    for binary in binaries:
        size = os.path.getsize(binary) / (1 << 20)
        for config in sorted(directory.glob('*.json')):
            idle, peak, after, error = measure(os.path.abspath(binary), config)
            name = pathlib.Path(binary).name
            if idle is None:
                lines.append(f'| {name} | {size:.1f} | {config.stem} | failed: {error} | | |')
            else:
                lines.append(f'| {name} | {size:.1f} | {config.stem} | {idle:.1f} | {peak:.1f} | {after:.1f} |')
            print(lines[-1], flush=True)

    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as output:
            output.write('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
