# local-dictation — build, run, remap, smoke
#
# The Swift app supervises the Python server itself (spawns
# server/.venv/bin/local-dictation-serve). `make run` only launches the app.

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP_DIR := $(ROOT)/app
SERVER_DIR := $(ROOT)/server
APP_BIN := $(APP_DIR)/.build/release/LocalDictation
SERVER_BIN := $(SERVER_DIR)/.venv/bin/local-dictation-serve
SMOKE_WAV := $(SERVER_DIR)/test.wav
SMOKE_PORT := 8471
MODEL := mlx-community/Voxtral-Mini-4B-Realtime-6bit

.PHONY: server app run model remap unremap smoke lint clean help

help:
	@echo "Targets:"
	@echo "  server  - uv sync Python deps in server/"
	@echo "  app     - swift build -c release"
	@echo "  run     - build app if needed, launch (app supervises server)"
	@echo "  model   - pre-download the default HF model (~3.5 GB)"
	@echo "  remap   - remap mic key (🎤) → F13 via hidutil"
	@echo "  unremap - clear UserKeyMapping"
	@echo "  smoke   - generate test WAV, start server briefly, run ws_smoke"
	@echo "  lint    - ruff check + format --check + ty check"
	@echo "  clean   - remove build artifacts and venv"

server:
	cd $(SERVER_DIR) && uv sync --group dev

app:
	cd $(APP_DIR) && swift build -c release

# App expects server at server/.venv/bin/local-dictation-serve and starts it.
run: $(APP_BIN)
	@test -x $(SERVER_BIN) || { \
	  echo "error: $(SERVER_BIN) missing — run 'make server' first"; \
	  exit 1; \
	}
	@echo "Launching LocalDictation (app will supervise the server)…"
	"$(APP_BIN)"

$(APP_BIN):
	$(MAKE) app

model: server
	cd $(SERVER_DIR) && uv run python -c "from huggingface_hub import snapshot_download; snapshot_download('$(MODEL)')"

# PLAN fact #1: mic key = HID Consumer 0x0C/0xCF → F13 (0x700000068)
remap:
	hidutil property --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000CF,"HIDKeyboardModifierMappingDst":0x700000068}]}'
	@echo "Mic key remapped to F13. Prefer installing the LaunchAgent from the app UI so it survives reboot."
	@echo "Also set System Settings → Keyboard → Dictation → Shortcut → Off."

unremap:
	hidutil property --set '{"UserKeyMapping":[]}'
	@echo "UserKeyMapping cleared."

# Automated smoke: start server, wait for /health, run ws_smoke, tear down.
# Needs model cached (make model). First boot can take minutes while MLX loads.
smoke: server
	@echo "Generating $(SMOKE_WAV)…"
	cd $(SERVER_DIR) && uv run python scripts/make_test_wav.py $(SMOKE_WAV)
	@echo "Starting server on port $(SMOKE_PORT)…"
	@rm -f /tmp/local-dictation-smoke.pid /tmp/local-dictation-smoke.log
	@$(SERVER_BIN) --port $(SMOKE_PORT) --host 127.0.0.1 \
	  > /tmp/local-dictation-smoke.log 2>&1 & \
	  echo $$! > /tmp/local-dictation-smoke.pid
	@echo "Waiting for http://127.0.0.1:$(SMOKE_PORT)/health …"
	@ok=0; \
	for i in $$(seq 1 180); do \
	  if curl -sf "http://127.0.0.1:$(SMOKE_PORT)/health" >/dev/null 2>&1; then \
	    ok=1; break; \
	  fi; \
	  if ! kill -0 $$(cat /tmp/local-dictation-smoke.pid) 2>/dev/null; then \
	    echo "server exited early; log:"; \
	    cat /tmp/local-dictation-smoke.log; \
	    exit 1; \
	  fi; \
	  sleep 2; \
	done; \
	if [ "$$ok" != 1 ]; then \
	  echo "timeout waiting for /health; log:"; \
	  cat /tmp/local-dictation-smoke.log; \
	  kill $$(cat /tmp/local-dictation-smoke.pid) 2>/dev/null || true; \
	  exit 1; \
	fi
	@echo "Running ws_smoke…"
	@cd $(SERVER_DIR) && uv run python scripts/ws_smoke.py --port $(SMOKE_PORT) $(SMOKE_WAV); \
	  status=$$?; \
	  kill $$(cat /tmp/local-dictation-smoke.pid) 2>/dev/null || true; \
	  wait $$(cat /tmp/local-dictation-smoke.pid) 2>/dev/null || true; \
	  rm -f /tmp/local-dictation-smoke.pid; \
	  exit $$status

# Two-terminal alternative (if make smoke is awkward):
#   Terminal A: server/.venv/bin/local-dictation-serve --port 8471
#   Terminal B: cd server && uv run python scripts/make_test_wav.py test.wav \
#                && uv run python scripts/ws_smoke.py test.wav

lint: server
	cd $(SERVER_DIR) && uv run ruff check src/ scripts/
	cd $(SERVER_DIR) && uv run ruff format --check src/ scripts/
	cd $(SERVER_DIR) && uv run ty check src/

clean:
	rm -rf $(APP_DIR)/.build
	rm -rf $(SERVER_DIR)/.venv
	rm -rf $(SERVER_DIR)/.ruff_cache
	rm -f $(SMOKE_WAV)
	find $(SERVER_DIR) -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleaned. Hugging Face model cache left intact."
