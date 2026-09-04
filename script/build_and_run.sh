#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELECTRON_DIR="$ROOT_DIR/electron"
ELECTRON_APP="$ELECTRON_DIR/node_modules/electron/dist/Electron.app"
ELECTRON_BIN="$ELECTRON_APP/Contents/MacOS/Electron"
RUNTIME_DIR="$ROOT_DIR/runtime"
LOG_ROOT="${TMPDIR:-/tmp}"
LOG_DIR="${LOG_ROOT%/}/amadeus-runtime-logs"
PID_FILE="$RUNTIME_DIR/amadeus-electron.pid"
PYTHON_BIN="$ROOT_DIR/.venv-macos-voice/bin/python"
BACKEND_TOKEN=''
BACKEND_NONCE=''

usage() {
  printf 'Usage: %s [run|--debug|--logs|--telemetry|--verify|--help]\n' "$0"
}

stop_existing() {
  local pids=''
  local backend_pids=''
  local pid command

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids="$pids $pid"
  done < <(pgrep -f "$ELECTRON_BIN" 2>/dev/null || true)

  if [[ -f "$PID_FILE" ]]; then
    pid="$(tr -dc '0-9' < "$PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
      && [[ " $pids " != *" $pid "* ]]; then
      pids="$pids $pid"
    fi
  fi

  for pid in $pids; do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" != "$ELECTRON_BIN"* ]]; then
      printf 'Refusing to stop PID %s because it is not this Amadeus instance.\n' "$pid" >&2
      exit 1
    fi
    kill "$pid"
  done

  for _ in {1..50}; do
    local running=false
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        running=true
        break
      fi
    done
    if [[ "$running" == false ]]; then
      break
    fi
    sleep 0.1
  done
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Existing Amadeus process did not stop within 5 seconds.\n' >&2
      exit 1
    fi
  done

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && backend_pids="$backend_pids $pid"
  done < <(pgrep -f "$ROOT_DIR/.venv-macos-voice/bin/python3? -m server.app --port 17777" 2>/dev/null || true)
  for pid in $backend_pids; do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" != "$ROOT_DIR/.venv-macos-voice/bin/python -m server.app --port 17777" \
      && "$command" != "$ROOT_DIR/.venv-macos-voice/bin/python3 -m server.app --port 17777" ]]; then
      printf 'Refusing to stop backend PID %s because it is not this Amadeus instance.\n' "$pid" >&2
      exit 1
    fi
    kill "$pid"
  done
  : > "$PID_FILE"
}

build_app() {
  if [[ ! -x "$ELECTRON_BIN" ]]; then
    printf 'Electron runtime is missing. Run npm ci in %s first.\n' "$ELECTRON_DIR" >&2
    exit 1
  fi
  npm --prefix "$ELECTRON_DIR" run build
}

launch_app() {
  mkdir -p "$LOG_DIR"
  mkdir -p "$RUNTIME_DIR"
  LOG_FILE="$LOG_DIR/electron_$(date '+%Y%m%d-%H%M%S').log"
  ERROR_LOG="${LOG_FILE%.log}.error.log"
  BACKEND_TOKEN="$(openssl rand -hex 32)"
  BACKEND_NONCE="$(openssl rand -hex 18)"
  : > "$LOG_FILE"
  : > "$ERROR_LOG"
  /usr/bin/open -n "$ELECTRON_APP" \
    --stdout "$LOG_FILE" \
    --stderr "$ERROR_LOG" \
    --env NODE_ENV=production \
    --env PYTHONUNBUFFERED=1 \
    --env "AMADEUS_BACKEND_TOKEN=$BACKEND_TOKEN" \
    --env "AMADEUS_BACKEND_INSTANCE_NONCE=$BACKEND_NONCE" \
    --args "$ELECTRON_DIR"

  APP_PID=''
  for _ in {1..50}; do
    APP_PID="$(pgrep -f "$ELECTRON_BIN.*$ELECTRON_DIR" 2>/dev/null | tail -n 1 || true)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.1
  done
  if [[ -z "$APP_PID" ]]; then
    printf 'Electron launched but its Amadeus process could not be identified.\n' >&2
    exit 1
  fi
  printf '%s\n' "$APP_PID" > "$PID_FILE"
  printf 'Amadeus launched (PID %s). Logs: %s, %s\n' "$APP_PID" "$LOG_FILE" "$ERROR_LOG"
}

verify_wallpaper() {
  if [[ ! -x "$PYTHON_BIN" ]]; then
    printf 'Mac voice environment is missing: %s\n' "$PYTHON_BIN" >&2
    exit 1
  fi
  AMADEUS_BACKEND_TOKEN="$BACKEND_TOKEN" \
    "$PYTHON_BIN" "$ROOT_DIR/tools/verify_macos_wallpaper.py"

  for _ in {1..60}; do
    if grep -Fq '[electron-slice] renderer shape committed' "$LOG_FILE" \
      && grep -Fq '[electron-canvas] renderer hit regions committed' "$LOG_FILE"; then
      swift "$ROOT_DIR/tools/verify_macos_window_level.swift" "$APP_PID"
      printf 'Amadeus wallpaper verified: scene, interactive Canvas, IPC, and desktop layers are ready.\n'
      return
    fi
    sleep 1
  done
  printf 'Wallpaper bridge started, but the scene or interactive Canvas did not become ready.\n' >&2
  tail -n 80 "$LOG_FILE" >&2
  tail -n 80 "$ERROR_LOG" >&2
  exit 1
}

verify_app() {
  for _ in {1..120}; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      printf 'Amadeus exited before startup completed.\n' >&2
      tail -n 80 "$LOG_FILE" >&2
      tail -n 80 "$ERROR_LOG" >&2
      exit 1
    fi
    if grep -Fq '[electron] backend ready' "$LOG_FILE" \
      && grep -Fq '[electron] main window ready' "$LOG_FILE"; then
      printf 'Amadeus startup verified: backend and main window are ready.\n'
      return
    fi
    sleep 1
  done
  printf 'Amadeus did not report readiness within 120 seconds.\n' >&2
  tail -n 80 "$LOG_FILE" >&2
  tail -n 80 "$ERROR_LOG" >&2
  exit 1
}

case "$MODE" in
  --help|-h|help)
    usage
    ;;
  run)
    stop_existing
    build_app
    launch_app
    ;;
  --debug|debug)
    stop_existing
    build_app
    env NODE_ENV=production PYTHONUNBUFFERED=1 lldb -- "$ELECTRON_BIN" "$ELECTRON_DIR"
    ;;
  --logs|logs|--telemetry|telemetry)
    stop_existing
    build_app
    launch_app
    tail -F "$LOG_FILE" "$ERROR_LOG"
    ;;
  --verify|verify)
    stop_existing
    build_app
    launch_app
    verify_app
    verify_wallpaper
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
