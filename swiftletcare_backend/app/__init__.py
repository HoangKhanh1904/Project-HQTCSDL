import logging
import os

from flask import Flask
from werkzeug.exceptions import HTTPException

from . import db
from .responses import ApiError, fail, ok  # noqa: F401


def create_app(test_config=None):
    app = Flask(__name__)
    app.json.ensure_ascii = False
    app.config.update(
        SECRET_KEY=os.getenv("FLASK_SECRET_KEY"),
        SIMULATOR_TOKEN=os.getenv("SIMULATOR_TOKEN"),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        # Bật =1 khi chạy sau HTTPS. Local http://127.0.0.1 cần để 0.
        SESSION_COOKIE_SECURE=os.getenv("SESSION_COOKIE_SECURE", "0") == "1",
        MAX_CONTENT_LENGTH=64 * 1024,  # body tối đa 64 KB
    )
    if test_config:
        app.config.update(test_config)
    if not app.config.get("SECRET_KEY"):
        raise RuntimeError("Thiếu FLASK_SECRET_KEY trong .env")

    logging.basicConfig(level=logging.INFO)
    db.init_app(app)

    from .routes import health, simulator
    app.register_blueprint(health.bp)
    app.register_blueprint(simulator.bp)

    @app.errorhandler(ApiError)
    def handle_api_error(err):
        return fail(err.code, err.message, err.status)

    @app.errorhandler(HTTPException)
    def handle_http_error(err):
        code = (err.name or "HTTP_ERROR").upper().replace(" ", "_")
        return fail(code, err.description or err.name, err.code or 500)

    @app.errorhandler(Exception)
    def handle_unexpected(err):
        app.logger.exception("Unhandled error")  # chi tiết chỉ nằm trong log
        return fail("INTERNAL_ERROR", "Lỗi máy chủ.", 500)

    return app
