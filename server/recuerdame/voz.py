"""Audios: voz desde texto con Piper y archivos cifrados (AES-256-GCM) en disco."""

import io
import os
import threading
import wave
from functools import cache
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Voz elegida en la fase 0 (plan §2): Laura suave.
_AJUSTES = {"length_scale": 1.1, "noise_scale": 0.5, "noise_w_scale": 0.6}
_candado = threading.Lock()  # ponytail: una síntesis a la vez; basta para una familia


@cache
def _voz():
    from piper import PiperVoice  # pesado: solo se carga si se usa

    return PiperVoice.load(os.environ["RECUERDAME_VOZ"])


def sintetizar(texto: str) -> bytes:
    """WAV mono con la voz de Laura diciendo `texto`."""
    from piper import SynthesisConfig

    salida = io.BytesIO()
    with _candado, wave.open(salida, "wb") as w:
        _voz().synthesize_wav(texto, w, syn_config=SynthesisConfig(**_AJUSTES))
    return salida.getvalue()


def guardar(carpeta: Path, llave: bytes, audio_id: str, datos: bytes) -> None:
    nonce = os.urandom(12)
    cifrado = AESGCM(llave).encrypt(nonce, datos, audio_id.encode())
    tmp = carpeta / f"{audio_id}.tmp"
    tmp.write_bytes(nonce + cifrado)
    tmp.replace(carpeta / audio_id)


def leer(carpeta: Path, llave: bytes, audio_id: str) -> bytes | None:
    ruta = carpeta / audio_id
    if not ruta.exists():
        return None
    blob = ruta.read_bytes()
    return AESGCM(llave).decrypt(blob[:12], blob[12:], audio_id.encode())


def borrar(carpeta: Path, audio_id: str) -> None:
    (carpeta / audio_id).unlink(missing_ok=True)
