import math
import uuid
from datetime import datetime, timezone

from flask import request

from .responses import ApiError


def _bad(message):
    return ApiError(400, "INVALID_INPUT", message)


def json_body():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise _bad("Body phải là JSON object.")
    return data


def req_guid(data, key):
    value = data.get(key)
    if not isinstance(value, str):
        raise _bad(f"'{key}' là bắt buộc và phải là GUID.")
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise _bad(f"'{key}' không phải GUID hợp lệ.")


def req_int(data, key, minimum=1, maximum=2_147_483_647):
    value = data.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise _bad(f"'{key}' là bắt buộc và phải là số nguyên.")
    if not minimum <= value <= maximum:
        raise _bad(f"'{key}' phải nằm trong khoảng {minimum}..{maximum}.")
    return value


def number(data, key, minimum, maximum, required=False):
    value = data.get(key)
    if value is None:
        if required:
            raise _bad(f"'{key}' là bắt buộc.")
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise _bad(f"'{key}' phải là số.")
    if not minimum <= value <= maximum:
        raise _bad(f"'{key}' phải nằm trong khoảng {minimum}..{maximum}.")
    return float(value)


def choice(data, key, allowed):
    value = str(data.get(key, "")).upper()
    if value not in allowed:
        raise _bad(f"'{key}' phải là một trong: {', '.join(sorted(allowed))}.")
    return value


def event_time(data, key="event_time"):
    """ISO 8601 có múi giờ (vd 2026-10-31T08:30:00+07:00). Trả về UTC naive hoặc None.
    Không cho thời điểm ở tương lai quá 5 phút."""
    value = data.get(key)
    if value is None:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        raise _bad(f"'{key}' phải theo ISO 8601.")
    if dt.tzinfo is None:
        raise _bad(f"'{key}' phải kèm múi giờ (vd +07:00 hoặc Z).")
    dt = dt.astimezone(timezone.utc).replace(tzinfo=None)
    if (dt - datetime.now(timezone.utc).replace(tzinfo=None)).total_seconds() > 300:
        raise _bad(f"'{key}' không được ở tương lai.")
    return dt
