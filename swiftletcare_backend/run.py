"""Local application entry point; configuration lives in repository .env."""

from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")
from app import create_app, socketio  # noqa: E402 - environment must load before app imports
from app import realtime  # noqa: E402

app = create_app()
# P2: emitter chay nen (query dashboard moi 2s, chi emit khi du lieu doi).
realtime.start_emitter(app)

if __name__ == "__main__":
    # P2: Flask-SocketIO thay app.run; polling 2s o frontend lam fallback.
    socketio.run(app, host="127.0.0.1", port=5000)