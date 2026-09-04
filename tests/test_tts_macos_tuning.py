from __future__ import annotations

from pathlib import Path

import pytest


torch = pytest.importorskip("torch", reason="test requires the local-model tier")
pytest.importorskip("librosa", reason="test requires the local-model tier")

from local_tts_infer import TTSInferencer


def test_mps_warmup_runs_one_short_inference(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    reference = tmp_path / "reference.wav"
    reference.write_bytes(b"placeholder")
    inferencer = TTSInferencer.__new__(TTSInferencer)
    inferencer.device = "mps"
    inferencer._resolve_runtime_warmup_ref = lambda: (str(reference), "reference", "ja")
    calls: list[dict] = []
    inferencer.infer = lambda **kwargs: calls.append(kwargs) or (24000, [])
    inferencer._synchronize_device = lambda: None

    inferencer._warmup_mps_inference_runtime()

    assert len(calls) == 1
    assert calls[0]["text"] == "これはテストです。"
    assert calls[0]["sample_steps"] == 4
    assert calls[0]["enable_cuda_graph"] is False


def test_cpu_skips_mps_full_warmup(monkeypatch: pytest.MonkeyPatch) -> None:
    inferencer = TTSInferencer.__new__(TTSInferencer)
    inferencer.device = "cpu"
    inferencer._resolve_runtime_warmup_ref = lambda: pytest.fail("CPU resolved MPS warmup reference")

    inferencer._warmup_mps_inference_runtime()
