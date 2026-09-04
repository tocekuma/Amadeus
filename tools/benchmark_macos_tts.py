"""Benchmark the installed GPT-SoVITS v3 voice on an Apple Silicon device."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


DEFAULT_REFERENCE_TEXT = (
    "そういえば,まともに自己紹介していませんでしたね……"
    "牧瀬くりすです.改めまして,よろしく"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--text", default="これはテストです。")
    parser.add_argument("--sample-steps", type=int, default=4)
    parser.add_argument("--max-seconds", type=float, default=3.5)
    parser.add_argument("--chunk-size-seconds", type=float, default=0.0)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument(
        "--reference-audio",
        default="assets/audio/reference/kurisu_reference.wav",
    )
    parser.add_argument("--reference-text", default=DEFAULT_REFERENCE_TEXT)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def configure_runtime(device: str) -> None:
    os.environ["TTS_DEVICE"] = device
    os.environ["BIGVGAN_USE_CUDA_KERNEL"] = "0"
    os.environ["ENABLE_CUDA_GRAPH"] = "0"
    os.environ["ENABLE_CUDA_GRAPH_PRECAPTURE"] = "0"
    os.environ["TTS_RUNTIME_WARMUP"] = "0"
    os.environ["TTS_T2S_FLASH_ATTN"] = "0"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_OFFLINE"] = "1"
    if device == "mps":
        os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def run_benchmark(args: argparse.Namespace) -> dict:
    import numpy as np
    import psutil
    import soundfile as sf
    import torch

    from local_tts_infer import TTSInferencer

    if args.device == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("PyTorch MPS is not available in this process")

    process = psutil.Process()
    started = time.perf_counter()
    inferencer = TTSInferencer(device=args.device)
    load_seconds = time.perf_counter() - started
    runs = []
    last_audio = None
    last_sample_rate = None

    for iteration in range(max(1, args.repeat)):
        chunks = []
        first_audio_seconds = None
        started = time.perf_counter()
        for sample_rate, chunk, _text in inferencer.infer_stream(
            text=args.text,
            ref_audio_path=args.reference_audio,
            prompt_text=args.reference_text,
            text_language="日文",
            prompt_language="日文",
            how_to_cut="不切",
            sample_steps=args.sample_steps,
            top_k=5,
            top_p=1.0,
            temperature=0.6,
            speed=1.1,
            pause_second=0.05,
            if_freeze=False,
            if_sr=False,
            enable_cuda_graph=False,
            enable_static_kv=False,
            chunk_size_seconds=(
                args.chunk_size_seconds if args.chunk_size_seconds > 0 else None
            ),
            max_sec_override=(args.max_seconds if args.max_seconds > 0 else None),
        ):
            if chunk is None or len(chunk) == 0:
                continue
            if first_audio_seconds is None:
                first_audio_seconds = time.perf_counter() - started
            chunks.append(np.asarray(chunk))

        total_seconds = time.perf_counter() - started
        if not chunks:
            raise RuntimeError("TTS returned no audio")
        audio = np.concatenate(chunks)
        duration_seconds = len(audio) / sample_rate
        runs.append(
            {
                "iteration": iteration + 1,
                "first_audio_seconds": first_audio_seconds,
                "total_seconds": total_seconds,
                "audio_duration_seconds": duration_seconds,
                "rtf": total_seconds / duration_seconds,
            }
        )
        last_audio = audio
        last_sample_rate = sample_rate

    if args.output is not None and last_audio is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        sf.write(args.output, last_audio, last_sample_rate, subtype="PCM_16")

    result = {
        "device": args.device,
        "torch": torch.__version__,
        "load_seconds": load_seconds,
        "rss_gb": process.memory_info().rss / (1024**3),
        "mps_allocated_gb": (
            torch.mps.current_allocated_memory() / (1024**3)
            if args.device == "mps"
            else 0.0
        ),
        "runs": runs,
        "output": str(args.output) if args.output is not None else None,
    }
    return result


def main() -> int:
    args = parse_args()
    configure_runtime(args.device)
    print(json.dumps(run_benchmark(args), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
