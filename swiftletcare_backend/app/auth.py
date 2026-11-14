"""Xác thực/phân quyền ở server. Không tin UserId/Role do client gửi."""

import hmac
from functools import wraps

from flask import current_app, request, session, g

from .responses import ApiError


def simulator_required(view):
    """Endpoint ingest: yêu cầu token riêng của simulator (header X-Simulator-Token
    hoặc Authorization: Bearer <token>). Token lấy từ biến môi trường, không nằm trong Git."""

    @wraps(view)
    def wrapper(*args, **kwargs):
        expected = current_app.config.get("SIMULATOR_TOKEN")
        if not expected:
            raise ApiError(
                503, "SIMULATOR_DISABLED", "Chưa cấu hình SIMULATOR_TOKEN trên server."
            )
        supplied = request.headers.get("X-Simulator-Token", "")
        auth = request.headers.get("Authorization", "")
        if not supplied and auth.startswith("Bearer "):
            supplied = auth[7:]
        if not hmac.compare_digest(supplied.encode(), expected.encode()):
            raise ApiError(401, "UNAUTHORIZED", "Thiếu hoặc sai token simulator.")
        return view(*args, **kwargs)

    return wrapper


def login_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not session.get("user_id"):
            raise ApiError(401, "UNAUTHORIZED", "Bạn chưa đăng nhập.")
        from . import db

        users = db.query(
            "SELECT UserID,UserName,Role,IsActive FROM dbo.Users WHERE UserID=?",
            [session["user_id"]],
        )
        if not users or not users[0]["IsActive"]:
            session.clear()
            raise ApiError(401, "UNAUTHORIZED", "Phiên đăng nhập không còn hợp lệ.")
        g.user = users[0]
        session["role"] = g.user["Role"]
        return view(*args, **kwargs)

    return wrapper


def role_required(*roles):
    def decorator(view):
        @wraps(view)
        @login_required
        def wrapper(*args, **kwargs):
            if session.get("role") not in roles:
                raise ApiError(
                    403, "FORBIDDEN", "Bạn không có quyền thực hiện thao tác này."
                )
            return view(*args, **kwargs)

        return wrapper

    return decorator


def protect_mutation():
    if (
        request.path.startswith("/api/")
        and not request.path.startswith("/api/simulator/")
        and request.method in ("POST", "PUT", "PATCH", "DELETE")
    ):
        expected = session.get("csrf_token")
        supplied = request.headers.get("X-CSRF-Token", "")
        if not expected or not hmac.compare_digest(supplied, expected):
            raise ApiError(403, "CSRF_FAILED", "Hãy tải lại trang trước khi thao tác.")
