#!/usr/bin/env python3
"""
Desktop clap listener: reads the default microphone and, on a double clap,
plays music (a local WAV in the background, or a Spotify link), opens any
number of pages in Chrome, and speaks a welcome line via ElevenLabs.

Run:
  .venv\\Scripts\\python -m pip install -r requirements.txt
  .venv\\Scripts\\python jarvis.py

Debug mode (prints measured level/threshold on every detected peak):
  set JARVIS_DEBUG=1   (Windows cmd)   |   $env:JARVIS_DEBUG=1   (PowerShell)

Tuning (constants below):
  SAMPLE_RATE       — usually 44100 or 48000; match your device if needed.
  BLOCK_MS          — analysis window size; smaller = snappier, noisier.
  SPIKE_RATIO       — how many times louder than the noise floor counts as a
                        candidate spike; raise if false triggers, lower if
                        claps are missed.
  MIN_RMS           — absolute floor a spike must clear regardless of noise
                        floor (helps in quiet rooms where the floor is tiny).
  CLAP_DECAY_WINDOW_S / CLAP_DECAY_RATIO — a real clap collapses fast: this
                        checks that, CLAP_DECAY_WINDOW_S after a spike, the
                        level has fallen below CLAP_DECAY_RATIO * peak. A
                        sustained sound (voice, music) fails this check and
                        is ignored, even if it was loud enough to be a spike.
  COOLDOWN_S        — minimum seconds between two confirmed double claps.
  MIN_DOUBLE_GAP_S / MAX_DOUBLE_GAP_S — allowed time between the two claps
                        of a double clap.
  RETRIGGER_RATIO   — audio must fall below threshold * this before another
                        spike candidate can be armed.
  NOISE_FLOOR_ALPHA — closer to 1 = slower baseline adaptation to room noise.
  SONG_FILE_DEFAULT — path to a local WAV file played directly in the
                        background (no app window). Overridable via SONG_FILE
                        in .env. Falls back to SONG_URI (opens Spotify/Chrome)
                        when unset or the file is missing.
  SONG_URI          — Spotify link opened on each double clap (fallback).
  DASHBOARD_URLS_DEFAULT — comma-separated pages opened as Chrome tabs, as
                        many as you want. Overridable via DASHBOARD_URLS in
                        .env (e.g. DASHBOARD_URLS=https://a.com,https://b.com).
  JARVIS_WELCOME_*  — TTS after the song (ElevenLabs). Configure via
                        environment or a `.env` file next to this script
                        (ELEVENLABS_API_KEY, ELEVENLABS_VOICE_ID, etc.).
                        With JARVIS_WELCOME_CACHE_ENABLED, audio is cached
                        under `.cache/jarvis_welcome/` (WAV) and replayed
                        when phrase + voice + model + format match — no
                        repeat API call.
"""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import subprocess
import sys
import threading
import time
import wave
import webbrowser
from pathlib import Path

from dotenv import load_dotenv
import numpy as np
import sounddevice as sd

# --- tuning knobs -----------------------------------------------------------
SAMPLE_RATE = 44100
BLOCK_MS = 40
CHANNELS = 1

SPIKE_RATIO = 7.0
MIN_RMS = 0.02
COOLDOWN_S = 0.45
MIN_DOUBLE_GAP_S = 0.12
MAX_DOUBLE_GAP_S = 0.35
RETRIGGER_RATIO = 0.55
NOISE_FLOOR_ALPHA = 0.992
QUIET_GATE_MULT = 2.2  # update noise floor only when below floor * this

# A clap must collapse fast: within CLAP_DECAY_WINDOW_S it must fall below
# CLAP_DECAY_RATIO * its own peak, or it's treated as voice/music and ignored.
CLAP_DECAY_WINDOW_S = 0.10
CLAP_DECAY_RATIO = 0.35

# Startup mic probe: if default input RMS stays below this, scan for a louder device.
INPUT_PROBE_S = 0.5
INPUT_SILENT_RMS = 0.001

# Music played on each double clap.
# If SONG_FILE (.env) points to a local WAV file, it's played directly in the
# background (no app window). Otherwise SONG_URI is opened (opens Spotify/Chrome).
SONG_URI = "https://open.spotify.com/intl-fr/track/1hQMzVXdoDZXcO16GOhWc5?si=44715db9253b48c6"
SONG_FILE_DEFAULT = ""  # e.g. "wake.wav" (relative to this script, or an absolute path)

# Pages opened in Chrome on each double clap: comma-separated list, as many as you want.
# Overridable via .env: DASHBOARD_URLS=https://a.com,https://b.com,https://c.com
DASHBOARD_URLS_DEFAULT = "https://n8n.digital-mib.com/,https://mail.google.com/mail/u/0/#inbox"

JARVIS_WELCOME_ENABLED = True
JARVIS_WELCOME_PHRASE = "Bonjour Patron, voici votre tableau de bord n8n et vos emails."
# Seconds after launching SONG_URI before speaking (gives Spotify/Chrome time to start).
JARVIS_AFTER_SONG_DELAY_S = 1.0
# Save ElevenLabs PCM as WAV under .cache/jarvis_welcome/; replay skips the API when the key matches.
JARVIS_WELCOME_CACHE_ENABLED = True

load_dotenv(Path(__file__).resolve().parent / ".env")

DEBUG = (os.environ.get("JARVIS_DEBUG") or "").strip().lower() in {"1", "true", "yes", "on"}

logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("jarvis")


def block_samples() -> int:
    n = int(SAMPLE_RATE * BLOCK_MS / 1000)
    return max(n, 1)


def rms_mono(block: np.ndarray) -> float:
    if block.ndim > 1:
        block = np.mean(block.astype(np.float64), axis=1)
    else:
        block = block.astype(np.float64)
    if block.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(block**2)))


def _input_devices() -> list[tuple[int, dict]]:
    return [
        (i, dev)
        for i, dev in enumerate(sd.query_devices())
        if dev["max_input_channels"] >= 1
    ]


def _resolve_input_device_index(spec: str) -> int:
    spec = spec.strip()
    if spec.isdigit():
        idx = int(spec)
        sd.query_devices(idx)
        return idx
    needle = spec.lower()
    for idx, dev in _input_devices():
        if needle in dev["name"].lower():
            return idx
    raise ValueError(f"No input device matches {spec!r}")


def _probe_input_max_rms(device: int, blocksize: int) -> float | None:
    try:
        with sd.InputStream(
            device=device,
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=blocksize,
        ) as stream:
            peak = 0.0
            deadline = time.monotonic() + INPUT_PROBE_S
            while time.monotonic() < deadline:
                data, _ = stream.read(blocksize)
                peak = max(peak, rms_mono(data))
            return peak
    except sd.PortAudioError:
        return None


def _choose_input_device(blocksize: int) -> int:
    log.info("Audio devices:\n%s", sd.query_devices())

    override = (os.environ.get("JARVIS_INPUT_DEVICE") or "").strip()
    if override:
        try:
            idx = _resolve_input_device_index(override)
        except ValueError as e:
            log.error("%s", e)
            log.error("Set JARVIS_INPUT_DEVICE to a device index or name substring.")
            raise SystemExit(1) from e
        name = sd.query_devices(idx)["name"]
        peak = _probe_input_max_rms(idx, blocksize)
        log.info("Using JARVIS_INPUT_DEVICE [%d]: %s", idx, name)
        if peak is None:
            log.warning("Could not open configured mic; trying anyway.")
        elif peak < INPUT_SILENT_RMS:
            log.warning(
                "Configured mic looks silent (probe rms=%.5f). "
                "Check Windows input level or try another JARVIS_INPUT_DEVICE.",
                peak,
            )
        else:
            log.info("Mic probe OK (rms=%.5f).", peak)
        return idx

    default = sd.default.device[0]
    if default is not None and default >= 0:
        default_name = sd.query_devices(default)["name"]
        peak = _probe_input_max_rms(default, blocksize)
        if peak is not None and peak >= INPUT_SILENT_RMS:
            log.info(
                "Using default microphone [%d]: %s (probe rms=%.5f)",
                default,
                default_name,
                peak,
            )
            return default
        log.warning(
            "Default mic [%d] %s is silent or unavailable (probe rms=%s); "
            "scanning other inputs...",
            default,
            default_name,
            f"{peak:.5f}" if peak is not None else "unopenable",
        )

    best_idx: int | None = None
    best_peak = -1.0
    for idx, dev in _input_devices():
        if default is not None and idx == default:
            continue
        peak = _probe_input_max_rms(idx, blocksize)
        if peak is not None and peak > best_peak:
            best_peak = peak
            best_idx = idx

    if best_idx is not None and best_peak >= INPUT_SILENT_RMS:
        log.info(
            "Auto-selected microphone [%d]: %s (probe rms=%.5f)",
            best_idx,
            sd.query_devices(best_idx)["name"],
            best_peak,
        )
        return best_idx

    if default is not None and default >= 0:
        log.warning("No active mic found; falling back to default [%d].", default)
        return default
    inputs = _input_devices()
    if not inputs:
        log.error("No input devices found.")
        raise SystemExit(1)
    idx, dev = inputs[0]
    log.warning("No active mic found; falling back to [%d] %s.", idx, dev["name"])
    return idx


def _elevenlabs_pcm_sample_rate(output_format: str) -> int:
    override = (os.environ.get("ELEVENLABS_PCM_SAMPLE_RATE") or "").strip()
    if override.isdigit():
        return int(override)
    if output_format.startswith("pcm_"):
        try:
            return int(output_format.split("_", maxsplit=1)[1])
        except (ValueError, IndexError):
            pass
    return 24000


def elevenlabs_env_config() -> tuple[str, str, str, int]:
    """voice_id, model_id, output_format, pcm_sample_rate."""
    voice = (os.environ.get("ELEVENLABS_VOICE_ID") or "").strip()
    model = (os.environ.get("ELEVENLABS_MODEL_ID") or "eleven_multilingual_v2").strip()
    fmt = (os.environ.get("ELEVENLABS_OUTPUT_FORMAT") or "pcm_24000").strip()
    rate = _elevenlabs_pcm_sample_rate(fmt)
    return voice, model, fmt, rate


def _jarvis_welcome_cache_dir() -> Path:
    base = Path(__file__).resolve().parent
    override = (os.environ.get("JARVIS_WELCOME_CACHE_DIR") or "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return base / ".cache" / "jarvis_welcome"


def _jarvis_welcome_cache_path(
    text: str, voice_id: str, model_id: str, output_format: str
) -> Path:
    key = f"{text}|{voice_id}|{model_id}|{output_format}".encode()
    digest = hashlib.sha256(key).hexdigest()[:24]
    return _jarvis_welcome_cache_dir() / f"{digest}.wav"


def _play_pcm_wav_file(path: Path) -> bool:
    try:
        with wave.open(str(path), "rb") as wf:
            ch = wf.getnchannels()
            sw = wf.getsampwidth()
            rate = wf.getframerate()
            if ch != 1 or sw != 2:
                log.warning("Unsupported cached WAV (channels=%s, width=%s).", ch, sw)
                return False
            raw = wf.readframes(wf.getnframes())
    except (OSError, wave.Error) as e:
        log.warning("Could not read cached welcome audio: %s", e)
        return False
    if not raw:
        return False
    pcm_i16 = np.frombuffer(raw, dtype=np.int16)
    pcm_f = pcm_i16.astype(np.float32) / 32768.0
    try:
        sd.play(pcm_f, rate)
        sd.wait()
    except Exception as e:
        log.warning("Could not play cached welcome audio: %s", e)
        return False
    return True


def _save_pcm_wav_file(path: Path, pcm_bytes: bytes, sample_rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        with wave.open(str(tmp), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(pcm_bytes)
        tmp.replace(path)
    except OSError:
        if tmp.is_file():
            tmp.unlink(missing_ok=True)
        raise


def say_jarvis_welcome() -> None:
    if not JARVIS_WELCOME_ENABLED or not JARVIS_WELCOME_PHRASE.strip():
        return
    text = JARVIS_WELCOME_PHRASE.strip()
    vid, model_id, output_format, pcm_rate = elevenlabs_env_config()
    if not vid:
        log.warning("Set ELEVENLABS_VOICE_ID in the environment for ElevenLabs TTS.")
        return

    cache_path = _jarvis_welcome_cache_path(text, vid, model_id, output_format)
    if JARVIS_WELCOME_CACHE_ENABLED and cache_path.is_file():
        log.info("Playing welcome from cache: %s", cache_path)
        if _play_pcm_wav_file(cache_path):
            return
        log.warning("Cache miss after read failure; fetching from ElevenLabs.")

    api_key = (os.environ.get("ELEVENLABS_API_KEY") or "").strip()
    if not api_key:
        log.warning("Set ELEVENLABS_API_KEY in the environment for ElevenLabs TTS.")
        return
    try:
        from elevenlabs.client import ElevenLabs
    except ImportError:
        log.warning("Install dependencies: pip install -r requirements.txt")
        return
    try:
        client = ElevenLabs(api_key=api_key)
        chunks = client.text_to_speech.convert(
            voice_id=vid,
            text=text,
            model_id=model_id,
            output_format=output_format,
        )
        raw = b"".join(chunks)
    except Exception as e:
        log.warning("ElevenLabs TTS failed: %s", e)
        return
    if not raw:
        log.warning("ElevenLabs returned empty audio.")
        return
    if JARVIS_WELCOME_CACHE_ENABLED:
        try:
            _save_pcm_wav_file(cache_path, raw, pcm_rate)
            log.info("Saved welcome audio to cache: %s", cache_path)
        except OSError as e:
            log.warning("Could not save welcome cache: %s", e)
    pcm_i16 = np.frombuffer(raw, dtype=np.int16)
    pcm_f = pcm_i16.astype(np.float32) / 32768.0
    try:
        sd.play(pcm_f, pcm_rate)
        sd.wait()
    except Exception as e:
        log.warning("Could not play ElevenLabs audio: %s", e)


def _play_local_wav_background(path: Path) -> bool:
    """Decode and play a local WAV file directly (no app window)."""
    try:
        with wave.open(str(path), "rb") as wf:
            ch = wf.getnchannels()
            sw = wf.getsampwidth()
            rate = wf.getframerate()
            raw = wf.readframes(wf.getnframes())
    except (OSError, wave.Error) as e:
        log.warning("Could not read SONG_FILE (%s): %s", path, e)
        return False
    if not raw:
        return False
    if sw == 2:
        pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sw == 1:
        pcm = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        log.warning("Unsupported WAV sample width (%d bytes) for SONG_FILE.", sw)
        return False
    if ch > 1:
        pcm = pcm.reshape(-1, ch)
    try:
        sd.play(pcm, rate)
    except Exception as e:
        log.warning("Could not play SONG_FILE: %s", e)
        return False
    return True


def play_song(uri: str) -> None:
    song_file = (os.environ.get("SONG_FILE") or SONG_FILE_DEFAULT).strip()
    if song_file:
        path = Path(song_file)
        if not path.is_absolute():
            path = Path(__file__).resolve().parent / path
        if path.is_file():
            if _play_local_wav_background(path):
                return
            log.warning("SONG_FILE playback failed; falling back to SONG_URI.")
        else:
            log.warning("SONG_FILE not found (%s); falling back to SONG_URI.", path)

    u = uri.strip()
    if not u:
        return
    try:
        if sys.platform == "win32":
            os.startfile(u)
        else:
            webbrowser.open(u)
    except OSError as e:
        log.warning("Could not open SONG_URI: %s", e)


def _chrome_executable() -> str | None:
    if sys.platform == "win32":
        for base in (
            os.environ.get("ProgramFiles", r"C:\Program Files"),
            os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
            os.environ.get("LOCALAPPDATA", ""),
        ):
            if not base:
                continue
            p = os.path.join(base, "Google", "Chrome", "Application", "chrome.exe")
            if os.path.isfile(p):
                return p
    return shutil.which("google-chrome") or shutil.which("chrome")


def open_dashboard_apps() -> None:
    """Open every DASHBOARD_URLS entry as a tab in a new Chrome window."""
    raw = (os.environ.get("DASHBOARD_URLS") or DASHBOARD_URLS_DEFAULT).strip()
    urls = [u.strip() for u in raw.replace("\n", ",").split(",") if u.strip()]
    if not urls:
        return
    chrome = _chrome_executable()
    try:
        if chrome:
            popen_kw: dict = {
                "stdin": subprocess.DEVNULL,
                "stdout": subprocess.DEVNULL,
                "stderr": subprocess.DEVNULL,
            }
            if sys.platform == "win32":
                popen_kw["creationflags"] = subprocess.CREATE_NO_WINDOW
            subprocess.Popen([chrome, "--new-window", *urls], **popen_kw)
        else:
            log.warning("Chrome introuvable ; ouverture dans le navigateur par defaut.")
            for u in urls:
                webbrowser.open(u)
    except OSError as e:
        log.warning("Could not open n8n/Gmail in Chrome: %s", e)


def run_double_clap_actions() -> None:
    """Run outside the mic loop so sleeps do not stall capture."""
    play_song(SONG_URI)
    open_dashboard_apps()
    if JARVIS_WELCOME_ENABLED and JARVIS_WELCOME_PHRASE.strip():
        delay = max(0.0, JARVIS_AFTER_SONG_DELAY_S)
        if delay:
            time.sleep(delay)
        threading.Thread(target=say_jarvis_welcome, daemon=True).start()


def main() -> int:
    blocksize = block_samples()
    noise_floor = 1e-4
    last_logged_double = 0.0
    first_clap_time: float | None = None
    spike_armed = True
    pending_peak: dict[str, float] | None = None
    last_debug_log = 0.0

    log.info(
        "Listening (double clap: %.2f-%.2fs apart, rate=%d, block=%d ms, "
        "spike_ratio=%.1f, min_rms=%.2f, cooldown=%.2fs). Ctrl+C to stop.",
        MIN_DOUBLE_GAP_S,
        MAX_DOUBLE_GAP_S,
        SAMPLE_RATE,
        BLOCK_MS,
        SPIKE_RATIO,
        MIN_RMS,
        COOLDOWN_S,
    )
    dashboard_urls = (os.environ.get("DASHBOARD_URLS") or DASHBOARD_URLS_DEFAULT).strip()
    song_file = (os.environ.get("SONG_FILE") or SONG_FILE_DEFAULT).strip()
    music_desc = f"local file {song_file}" if song_file else (SONG_URI or "(no song)")
    log.info("Double clap: plays %s, opens in Chrome: %s", music_desc, dashboard_urls)
    if JARVIS_WELCOME_ENABLED:
        ev, em, ef, er = elevenlabs_env_config()
        log.info(
            "After song + %.2fs: %r (ElevenLabs voice=%s, model=%s, format=%s, pcm_rate=%d)",
            JARVIS_AFTER_SONG_DELAY_S,
            JARVIS_WELCOME_PHRASE.strip(),
            ev or "(unset)",
            em,
            ef,
            er,
        )
    if DEBUG:
        log.debug(
            "JARVIS_DEBUG actif: niveau/seuil affiches en continu (toutes les 0.5s) "
            "et a chaque pic."
        )

    input_idx = _choose_input_device(blocksize)

    try:
        with sd.InputStream(
            device=input_idx,
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=blocksize,
        ) as stream:
            while True:
                data, overflowed = stream.read(blocksize)
                if overflowed:
                    log.warning("Input overflow; try a larger BLOCK_MS")

                level = rms_mono(data)
                now = time.monotonic()

                quiet_gate = noise_floor * QUIET_GATE_MULT
                if level < quiet_gate:
                    noise_floor = NOISE_FLOOR_ALPHA * noise_floor + (
                        1.0 - NOISE_FLOOR_ALPHA
                    ) * level
                    noise_floor = max(noise_floor, 1e-7)

                threshold = max(noise_floor * SPIKE_RATIO, MIN_RMS)
                retrigger_level = threshold * RETRIGGER_RATIO

                if DEBUG and (now - last_debug_log) >= 0.5:
                    last_debug_log = now
                    log.debug(
                        "niveau=%.4f noise_floor=%.5f threshold=%.4f",
                        level,
                        noise_floor,
                        threshold,
                    )

                if level < retrigger_level:
                    spike_armed = True

                # A spike is pending verification: is it clap-shaped (fast decay)?
                if pending_peak is not None:
                    pending_peak["level"] = max(pending_peak["level"], level)
                    elapsed = now - pending_peak["start"]
                    if elapsed >= CLAP_DECAY_WINDOW_S:
                        peak = pending_peak["level"]
                        decay_limit = peak * CLAP_DECAY_RATIO
                        is_clap = level <= decay_limit
                        if DEBUG:
                            log.debug(
                                "Pic verifie: peak=%.3f niveau=%.3f limite_decay=%.3f -> %s",
                                peak,
                                level,
                                decay_limit,
                                "CLAP" if is_clap else "voix/musique (ignore)",
                            )
                        clap_time = pending_peak["start"]
                        pending_peak = None
                        if is_clap:
                            if first_clap_time is None:
                                first_clap_time = clap_time
                            else:
                                gap = clap_time - first_clap_time
                                if gap < MIN_DOUBLE_GAP_S:
                                    pass
                                elif gap <= MAX_DOUBLE_GAP_S:
                                    first_clap_time = None
                                    last_logged_double = now
                                    log.info(
                                        "Double clap detecte (gap=%.3fs, rms=%.5f, "
                                        "noise_floor=%.5f, threshold=%.5f)",
                                        gap,
                                        level,
                                        noise_floor,
                                        threshold,
                                    )
                                    threading.Thread(
                                        target=run_double_clap_actions, daemon=True
                                    ).start()
                                else:
                                    first_clap_time = clap_time
                        continue

                if (
                    pending_peak is None
                    and spike_armed
                    and level >= threshold
                    and (now - last_logged_double) >= COOLDOWN_S
                ):
                    spike_armed = False
                    pending_peak = {"level": level, "start": now}
                    if DEBUG:
                        log.debug(
                            "Pic detecte: niveau=%.3f seuil=%.3f noise_floor=%.5f "
                            "-> verification en cours (%.0f ms)...",
                            level,
                            threshold,
                            noise_floor,
                            CLAP_DECAY_WINDOW_S * 1000,
                        )

    except KeyboardInterrupt:
        log.info("Stopped.")
        return 0
    except sd.PortAudioError as e:
        log.error("Audio error: %s", e)
        log.error("If PortAudio fails, install/repair drivers or try another SAMPLE_RATE.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
