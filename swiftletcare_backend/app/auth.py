"""Xác thực/phân quyền ở server. Không tin UserId/Role do client gửi."""
import hmac
from functools import wraps

from flask import current_app, request, session

from .responses import ApiError


def simulator_required(view):
    """Endpoint ingest: yêu cầu token riêng của simulator (header X-Simulator-Token
    hoặc Authorization: Bearer <token>). Token lấy từ biến môi trường, không nằm trong Git."""
    @wraps(view)
    def wrapper(*args, **kwargs):
        expected = current_app.config.get("SIMULATOR_TOKEN")
        if not expected:
            raise ApiError(503, "SIMULATOR_DISABLED", "Chưa cấu hình SIMULATOR_TOKEN trên server.")
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
        return view(*args, **kwargs)
    return wrapper


def role_required(*roles):
    def decorator(view):
        @wraps(view)
        @login_required
        def wrapper(*args, **kwargs):
            if session.get("role") not in roles:
                raise ApiError(403, "FORBIDDEN", "Bạn không có quyền thực hiện thao tác này.")
            return view(*args, **kwargs)
        return wrapper
    return decorator
