from faster_whisper import WhisperModel

from config import config

_model = WhisperModel(config.whisper_model, device="cpu", compute_type="int8")


def transcribe(audio_path):
    segments, _info = _model.transcribe(audio_path, vad_filter=True)
    return [
        {"start": seg.start, "end": seg.end, "text": seg.text.strip()}
        for seg in segments
    ]
