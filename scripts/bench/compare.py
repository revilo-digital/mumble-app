#!/usr/bin/env python3
"""Runs Mumble's saved recordings through each speech engine and writes a side-by-side report.

Engines: Apple (what Mumble heard live, and a timed rerun), Parakeet (plain, and with custom words), and
Whisper large-v3 turbo (plain, and with a context prompt: custom words, window title, recent dictations and
the text before the cursor). Everything runs on this Mac.

Needs the tools set up by scripts/bench/setup.sh, and Whisper's server running (setup.sh starts it).

    scripts/bench/compare.py [--last N]

To score accuracy, add "meant": "what you actually said" to a recording's .json file.
"""
import argparse
import html
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from datetime import datetime, timedelta
from pathlib import Path

RECORDINGS = Path.home() / "Library/Application Support/Mumble/Recordings"
BENCH = Path.home() / "Library/Caches/MumbleBench"
APPLE = BENCH / "apple-transcribe"
PARAKEET = BENCH / "FluidAudio/.build/release/fluidaudiocli"
WHISPER_URL = "http://localhost:50060/v1/audio/transcriptions"

# Recent dictations count as context for this long in the same app, and only briefly in another app:
# switching from Cursor to Mail usually means a new topic.
SAME_APP_WINDOW = timedelta(minutes=15)
OTHER_APP_WINDOW = timedelta(minutes=2)


def custom_words():
    out = subprocess.run(["defaults", "export", "nz.olly.Mumble", "-"], capture_output=True).stdout
    try:
        saved = plistlib.loads(out).get("customWords")
        return [w["word"] for w in json.loads(saved)] if saved else []
    except Exception:
        return []


def load(last):
    items = []
    for info_path in sorted(RECORDINGS.glob("*.json")):
        wav = info_path.with_suffix(".wav")
        if not wav.exists():
            continue
        info = json.loads(info_path.read_text())
        info["wav"] = str(wav)
        info["name"] = info_path.stem
        info["when"] = datetime.fromisoformat(info["date"].replace("Z", "+00:00"))
        items.append(info)
    return items, items[-last:] if last else items


def context_prompt(item, history, words):
    """What Whisper is told came before: custom words, the window, recent dictations, the text before the cursor."""
    ctx = item.get("context", {})
    parts = []
    if words:
        parts.append(", ".join(words) + ".")
    if ctx.get("windowTitle"):
        parts.append(ctx["windowTitle"] + ".")
    for earlier in history:
        if earlier["when"] >= item["when"] or not earlier.get("inserted"):
            continue
        age = item["when"] - earlier["when"]
        same_app = earlier.get("context", {}).get("bundleID") == ctx.get("bundleID")
        if age <= (SAME_APP_WINDOW if same_app else OTHER_APP_WINDOW):
            parts.append(earlier["inserted"])
    if ctx.get("textBefore"):
        parts.append(ctx["textBefore"][-300:])
    prompt = " ".join(p.strip() for p in parts if p.strip())
    return prompt[-800:]  # Whisper only looks at the last ~224 tokens.


def run_apple(paths):
    out = subprocess.run([str(APPLE), *paths], capture_output=True, text=True)
    results = {}
    for line in out.stdout.splitlines():
        row = json.loads(line)
        results[row["file"]] = (row["text"], row["seconds"])
    return results


def run_parakeet(path, vocab=None):
    with tempfile.TemporaryDirectory() as tmp:
        out_json = Path(tmp) / "out.json"
        cmd = [str(PARAKEET), "transcribe", path, "--output-json", str(out_json)]
        if vocab:
            cmd += ["--custom-vocab", vocab]
        subprocess.run(cmd, capture_output=True, text=True)
        if not out_json.exists():
            return ("(failed)", None)
        row = json.loads(out_json.read_text())
        return (row.get("text", "").strip(), row.get("processingTimeSeconds"))


def run_whisper(path, prompt=None):
    boundary = uuid.uuid4().hex
    fields = {"model": "whisper", "language": "en", "response_format": "json"}
    if prompt:
        fields["prompt"] = prompt
    body = b""
    for key, value in fields.items():
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
             f"Content-Type: audio/wav\r\n\r\n").encode() + Path(path).read_bytes() + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    request = urllib.request.Request(WHISPER_URL, data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            text = json.loads(response.read()).get("text", "").strip()
    except Exception as error:
        return (f"(failed: {error})", None)
    return (text, time.time() - started)


def words_of(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def word_errors(meant, heard):
    """Word error rate: substitutions + insertions + deletions, over the words meant."""
    a, b = words_of(meant), words_of(heard)
    if not a:
        return None
    row = list(range(len(b) + 1))
    for i, wa in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, wb in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (wa != wb))
    return row[-1] / len(a)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--last", type=int, default=0, help="only the newest N recordings")
    parser.add_argument("--no-whisper", action="store_true")
    args = parser.parse_args()

    history, items = load(args.last)
    if not items:
        sys.exit(f"No recordings in {RECORDINGS}. Turn on Settings → Keep recordings and dictate a few.")
    words = custom_words()
    vocab = None
    if words:
        vocab_file = BENCH / "custom-vocab.txt"
        vocab_file.write_text("\n".join(words) + "\n")
        vocab = str(vocab_file)

    engines = ["Apple (live)", "Apple", "Parakeet", "Parakeet + words", "Whisper", "Whisper + context"]
    print(f"Running {len(items)} recordings…", file=sys.stderr)
    apple = run_apple([i["wav"] for i in items])
    rows = []
    for n, item in enumerate(items, 1):
        print(f"  {n}/{len(items)} {item['name']}", file=sys.stderr)
        prompt = context_prompt(item, history, words)
        results = {
            "Apple (live)": (item.get("heard", ""), None),
            "Apple": apple.get(item["wav"], ("(failed)", None)),
            "Parakeet": run_parakeet(item["wav"]),
            "Parakeet + words": run_parakeet(item["wav"], vocab) if vocab else ("(no custom words)", None),
        }
        if not args.no_whisper:
            results["Whisper"] = run_whisper(item["wav"])
            results["Whisper + context"] = run_whisper(item["wav"], prompt) if prompt else ("(no context)", None)
        rows.append((item, prompt, results))

    # Summary: average processing time per second of audio, and word errors where "meant" is filled in.
    summary = []
    for engine in engines:
        times = [r[engine][1] for _, _, r in rows if engine in r and r[engine][1] is not None]
        audio = [i["seconds"] for i, _, r in rows if engine in r and r[engine][1] is not None]
        errors = [word_errors(i["meant"], r[engine][0]) for i, _, r in rows if i.get("meant") and engine in r]
        errors = [e for e in errors if e is not None]
        summary.append((
            engine,
            f"{sum(times) / len(times):.2f}s" if times else "–",
            f"{sum(audio) / max(sum(times), 1e-9):.0f}× real time" if times else "streams while you talk",
            f"{100 * sum(errors) / len(errors):.0f}% ({len(errors)})" if errors else "–",
        ))

    report = RECORDINGS / "comparison.html"
    report.write_text(render(rows, summary, engines))
    print("\nEngine              avg time   speed                    word errors (scored)")
    for engine, avg, speed, err in summary:
        print(f"{engine:<19} {avg:<10} {speed:<24} {err}")
    print(f"\nReport: {report}")
    subprocess.run(["open", str(report)])


def render(rows, summary, engines):
    e = html.escape
    out = ["""<!doctype html><meta charset="utf-8"><title>Speech engines</title>
<style>
:root{color-scheme:light dark;--line:#8884;--muted:#888}
body{font:14px -apple-system,system-ui,sans-serif;margin:24px;max-width:1100px}
table{border-collapse:collapse;width:100%;margin:12px 0 28px}
td,th{border-top:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
th{font-weight:600;white-space:nowrap}
.muted{color:var(--muted);font-size:12px}
.engine{width:150px;white-space:nowrap}
.time{width:70px;color:var(--muted);text-align:right}
h2{font-size:15px;margin:28px 0 4px}
</style>
<h1>Speech engines on your recordings</h1>
<p class="muted">All on this Mac. Time is processing time after the audio is in; Apple (live) works while you talk.
Add <code>"meant"</code> to a recording's .json to score it.</p>
<table><tr><th>Engine</th><th>Avg time</th><th>Speed</th><th>Word errors</th></tr>"""]
    for engine, avg, speed, err in summary:
        out.append(f"<tr><td>{e(engine)}</td><td>{avg}</td><td>{speed}</td><td>{err}</td></tr>")
    out.append("</table>")
    for item, prompt, results in reversed(rows):
        ctx = item.get("context", {})
        where = " · ".join(x for x in [ctx.get("app"), ctx.get("windowTitle")] if x)
        out.append(f"<h2>{e(item['name'])} <span class='muted'>{item['seconds']:.1f}s · {e(where)}</span></h2>")
        if item.get("meant"):
            out.append(f"<p><b>Meant:</b> {e(item['meant'])}</p>")
        out.append("<table>")
        for engine in engines:
            if engine not in results:
                continue
            text, seconds = results[engine]
            t = f"{seconds:.2f}s" if seconds is not None else ""
            out.append(f"<tr><td class='engine'>{e(engine)}</td><td>{e(text)}</td><td class='time'>{t}</td></tr>")
        out.append("</table>")
        if prompt:
            out.append(f"<p class='muted'>Context given to Whisper: {e(prompt)}</p>")
    return "\n".join(out)


if __name__ == "__main__":
    main()
