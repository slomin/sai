#!/usr/bin/env -S uv run --script
"""Checks the LAN inference box against sai's endpoint contract (#23).

    uv run tool/smoke/lan.py [base-url] [--full]

Defaults to the built-in `lan` endpoint (`sai_core`'s `lanEndpoint`);
stdlib only, no API key. One `ok`/`FAIL` line per check, exit 1 on any
failure. Nothing here goes through sai — it is the wire contract the
provider relies on, checked directly:

  health     /health is {"status": "ok"}
  models     /v1/models lists the alias with the full native context
  props      /props reports the alias and default_generation_settings.n_ctx
  stream     a chat completion streams, with usage and llama.cpp timings
  thinking   chat_template_kwargs.enable_thinking turns reasoning off/on
  vision     a generated 64x64 PNG (blue square on red) is described
  needle     a word buried after ~64k tokens of filler comes back;
             with --full the needle sits near the 262k limit, which
             holds the box's single slot for a few minutes (run last)
"""
import base64
import json
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib

ENDPOINT = 'http://192.168.1.5:8080/v1'
MODEL = 'sai-qwen38-27b-unsloth-q6k-fullctx-generic-mtp'
CONTEXT = 262144


def get(base, path, timeout=10):
    root = base[: -len('/v1')] if base.endswith('/v1') else base
    with urllib.request.urlopen(root + path, timeout=timeout) as r:
        return json.load(r)


def chat(base, body, timeout=600):
    req = urllib.request.Request(
        base + '/chat/completions',
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def stream(base, body, timeout=120):
    """The SSE chunks of a streaming call, parsed."""
    body = dict(body, stream=True, stream_options={'include_usage': True})
    req = urllib.request.Request(
        base + '/chat/completions',
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'},
    )
    chunks = []
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for line in r:
            line = line.decode().strip()
            if not line.startswith('data:'):
                continue
            data = line[5:].strip()
            if data == '[DONE]':
                break
            chunks.append(json.loads(data))
    return chunks


def fixture_png():
    """A 64x64 PNG: a blue square centred on red. Generated, not stored."""
    w = h = 64
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            inside = 16 <= x < 48 and 16 <= y < 48
            row += bytes([0, 0, 255]) if inside else bytes([255, 0, 0])
        rows.append(bytes(row))

    def chunk(kind, data):
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', crc)

    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(b''.join(rows)))
        + chunk(b'IEND', b'')
    )


def user(content):
    return {'model': MODEL, 'messages': [{'role': 'user', 'content': content}]}


def main(base, full):
    results = []

    def check(name, fn):
        try:
            detail = fn()
            results.append(True)
            print(f'ok   {name}  {detail}', flush=True)
        except Exception as e:  # noqa: BLE001 — every failure is a line
            results.append(False)
            print(f'FAIL {name}  {type(e).__name__}: {e}', flush=True)

    def health():
        h = get(base, '/health')
        assert h == {'status': 'ok'}, h
        return h

    def models():
        m = get(base, '/v1/models')
        ids = [d['id'] for d in m['data']]
        assert MODEL in ids, ids
        meta = next(d for d in m['data'] if d['id'] == MODEL).get('meta', {})
        assert meta.get('n_ctx') == CONTEXT, meta
        return f'{ids} n_ctx={meta["n_ctx"]}'

    def props():
        p = get(base, '/props')
        n = p['default_generation_settings']['n_ctx']
        assert p.get('model_alias') == MODEL, p.get('model_alias')
        assert n == CONTEXT, n
        return f'alias={p["model_alias"]} n_ctx={n}'

    def streaming():
        chunks = stream(base, dict(user('Say hi in three words.'), max_tokens=64,
                                   chat_template_kwargs={'enable_thinking': False}))
        text = ''.join(
            c['choices'][0]['delta'].get('content') or ''
            for c in chunks
            if c.get('choices')
        )
        last = chunks[-1]
        assert text.strip(), 'no content streamed'
        assert 'usage' in last and 'timings' in last, last
        return (
            f'{len(chunks)} chunks, {last["usage"]["completion_tokens"]} tokens, '
            f'{last["timings"]["predicted_per_second"]:.0f} tok/s'
        )

    def thinking():
        q = 'What is 17*23? Answer with the number only.'
        for on in (False, True, False):
            body = dict(user(q), max_tokens=300, temperature=0,
                        chat_template_kwargs={'enable_thinking': on})
            m = chat(base, body)['choices'][0]['message']
            thought = bool(m.get('reasoning_content'))
            assert thought == on, f'enable_thinking={on} but reasoning={thought}'
            assert '391' in (m.get('content') or ''), m
        return 'off/on/off as asked'

    def vision():
        data = base64.b64encode(fixture_png()).decode()
        body = dict(user([
            {'type': 'text', 'text': 'What colours and shapes are in this '
                                     'image? One sentence.'},
            {'type': 'image_url',
             'image_url': {'url': 'data:image/png;base64,' + data}},
        ]), max_tokens=400, chat_template_kwargs={'enable_thinking': False})
        answer = chat(base, body)['choices'][0]['message']['content'].lower()
        assert 'blue' in answer and 'red' in answer, answer
        return answer.strip()

    def needle():
        target = 250_000 if full else 64_000
        line = 'The quick brown fox jumps over the lazy dog. ' * 8 + '\n'
        # ~80 tokens a line on this tokenizer; the needle sits at the end.
        filler = line * (target // 80)
        prompt = (filler + '\nThe secret word is PELICAN.\n'
                  'What is the secret word? Answer with the word only.')
        body = dict(user(prompt), max_tokens=16, temperature=0,
                    chat_template_kwargs={'enable_thinking': False})
        started = time.time()
        r = chat(base, body, timeout=3600)
        content = r['choices'][0]['message']['content']
        n = r['usage']['prompt_tokens']
        assert n > target * 0.9, f'only {n} prompt tokens'
        assert n < CONTEXT, f'{n} tokens would not fit'
        assert 'PELICAN' in content.upper(), content
        return f'{n} prompt tokens in {time.time() - started:.0f}s: {content!r}'

    check('health', health)
    check('models', models)
    check('props', props)
    check('stream', streaming)
    check('thinking', thinking)
    check('vision', vision)
    check('needle' + (' (full)' if full else ''), needle)
    return 0 if all(results) else 1


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--full']
    sys.exit(main(args[0] if args else ENDPOINT, '--full' in sys.argv))
