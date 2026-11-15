# SPIKE fase 0(b), ronda 2: voces femeninas latinas más suaves que Daniela.
# uv run --python 3.12 --with piper-tts --with kokoro-onnx --with soundfile python muestras.py
import json
import time
import wave
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro
from piper import PiperVoice, SynthesisConfig

TEXTO = "Hola mamá. Son las dos de la tarde. Es hora de tomar la pastilla de la presión, el Losartán."
M = Path("modelos")
OUT = Path("ronda2")
OUT.mkdir(exist_ok=True)


def piper(nombre, modelo, **cfg):
    info = json.loads(Path(f"{modelo}.json").read_text(encoding="utf-8"))
    print(f"{nombre}: espeak={info['espeak']['voice']} sr={info['audio']['sample_rate']}")
    voz = PiperVoice.load(modelo)
    t = time.perf_counter()
    with wave.open(str(OUT / f"{nombre}.wav"), "wb") as w:
        voz.synthesize_wav(TEXTO, w, syn_config=SynthesisConfig(**cfg))
    print(f"  gen={time.perf_counter() - t:.1f}s")


# length_scale > 1 = más pausada; noise_* más bajos = entonación más calmada y pareja.
daniela = M / "es_AR-daniela-high.onnx"
piper("1-daniela-original", daniela)
piper("2-daniela-suave", daniela, length_scale=1.12, noise_scale=0.45, noise_w_scale=0.6)
piper("3-laura-mx", M / "comunidad/es_MX-laura-high.onnx")
piper("4-laura-mx-suave", M / "comunidad/es_MX-laura-high.onnx", length_scale=1.1, noise_scale=0.5, noise_w_scale=0.6)

k = Kokoro(str(M / "kokoro/kokoro-v1.0.onnx"), str(M / "kokoro/voices-v1.0.bin"))


def kokoro(nombre, voz, speed):
    t = time.perf_counter()
    audio, sr = k.create(TEXTO, voice=voz, speed=speed, lang="es-419")  # español latino
    sf.write(OUT / f"{nombre}.wav", audio, sr)
    print(f"{nombre}: kokoro sr={sr} gen={time.perf_counter() - t:.1f}s")


dora = k.get_voice_style("ef_dora")
kokoro("5-kokoro-dora", dora, 1.0)
kokoro("6-kokoro-dora-pausada", dora, 0.88)
# Mezcla con una voz inglesa cálida para suavizar el timbre (puede colar algo de acento).
kokoro("7-kokoro-dora-calida", 0.75 * dora + 0.25 * k.get_voice_style("af_heart"), 0.9)
