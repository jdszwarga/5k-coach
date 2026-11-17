"""Regenerates the spoken cue clips in /audio.

Uses Microsoft's neural voices via edge-tts, then converts to the format the app
renders workouts at (11025 Hz, 16-bit, mono WAV) with ffmpeg.

    python -m pip install edge-tts      # once; also needs ffmpeg on PATH
    python tools/make-cues.py [--voice en-NZ-MollyNeural]

List other voices with:  edge-tts --list-voices
"""
import argparse
import asyncio
import pathlib
import subprocess
import tempfile

import edge_tts

CUES = {
    "warmup": "Warm up. Start with a brisk walk.",
    "run": "Run!",
    "walk": "Walk.",
    "lastrun": "Last run. Finish strong!",
    "halfway": "Halfway there.",
    "oneminute": "One minute left.",
    "cooldown": "Cool down. Nice easy walk.",
    "done": "Workout complete. Great job!",
}

OUT = pathlib.Path(__file__).resolve().parent.parent / "audio"


async def main(voice: str, rate: str) -> None:
    OUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, text in CUES.items():
            mp3 = pathlib.Path(tmp) / f"{name}.mp3"
            await edge_tts.Communicate(text, voice, rate=rate).save(str(mp3))
            wav = OUT / f"{name}.wav"
            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-y", "-i", str(mp3),
                 "-ac", "1", "-ar", "11025", "-sample_fmt", "s16", str(wav)],
                check=True,
            )
            print(f"{name:10} {wav.stat().st_size:>7,} bytes  \"{text}\"")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="en-NZ-MollyNeural")
    ap.add_argument("--rate", default="+0%")
    a = ap.parse_args()
    asyncio.run(main(a.voice, a.rate))
