from flask import Blueprint

from .. import db
from ..responses import ok

bp = Blueprint("health", __name__, url_prefix="/api")


@bp.get("/health")
def health():
    db.ping()  # lỗi -> ApiError 503 với thông báo an toàn
    return ok({"db": "up"})
