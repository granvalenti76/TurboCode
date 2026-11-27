# Minimal client for the Prassitele agent server (MCP over HTTP on this Mac's loopback).
# A stdlib-only copy of call() from Prassitele's scripts/sessions.py: the bundled torso
# scripts must run from any folder, without Prassitele's repository or numpy.
import json
import urllib.request


def call(port, name, args):
    """Calls one Prassitele tool; returns (result, error, images)."""
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                       'params': {'name': name, 'arguments': args}}).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}/mcp', body,
                                 {'Content-Type': 'application/json',
                                  'Accept': 'application/json, text/event-stream'})
    res = json.load(urllib.request.urlopen(req, timeout=120))['result']
    texts = [c['text'] for c in res['content'] if c['type'] == 'text']
    images = [c['data'] for c in res['content'] if c['type'] == 'image']
    if res.get('isError'):
        return None, texts[0] if texts else 'error', images
    try:
        return json.loads(texts[0]), None, images
    except (ValueError, IndexError):
        return texts, None, images
