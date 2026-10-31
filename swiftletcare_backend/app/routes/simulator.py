from flask import Blueprint

from .. import repository
from ..auth import simulator_required
from ..responses import ApiError, fail, ok
from ..validation import json_body, number, req_guid, req_int

bp = Blueprint("simulator", __name__, url_prefix="/api/simulator")

# Mã lỗi nghiệp vụ trong cột `Code` của procedure -> HTTP. Đối chiếu lại với proc thật của TV1.
CODE_TO_HTTP = {
    "INVALID_INPUT": 400, "VALIDATION_ERROR": 400,
    "FORBIDDEN": 403,
    "NOT_FOUND": 404, "DEVICE_NOT_FOUND": 404,
    "INVALID_STATE": 409, "CONCURRENCY_CONFLICT": 409,
    "PAYLOAD_MISMATCH": 409, "DUPLICATE_PAYLOAD_MISMATCH": 409,
}


@bp.post("/readings")
@simulator_required
def post_reading():
    """Body: device_id, temperature, humidity, source_event_id (GUID, bắt buộc, giữ nguyên khi retry);
    tùy chọn: co2_ppm, light_lux. 201 = bản ghi mới, 200 = replay cùng SourceEventId."""
    data = json_body()
    reading = {
        "device_id": req_int(data, "device_id"),
        "temperature": number(data, "temperature", -10, 80, required=True),
        "humidity": number(data, "humidity", 0, 100, required=True),
        "co2_ppm": number(data, "co2_ppm", 0, 10_000),
        "light_lux": number(data, "light_lux", 0, 200_000),
        "source_event_id": req_guid(data, "source_event_id"),
    }
    row = repository.insert_reading(reading)
    if row is None:
        raise ApiError(502, "BAD_PROCEDURE_RESPONSE", "Procedure không trả về kết quả hợp lệ.")

    code = row.get("Code") or ("OK" if row.get("Success") else "ERROR")
    message = row.get("Message") or ""
    if not row.get("Success"):
        return fail(code, message or "Không thể ghi số liệu.", CODE_TO_HTTP.get(code, 400))

    duplicate = bool(row.get("Duplicate"))
    data_out = {k: row.get(k) for k in ("ReadingId", "AlertCount", "ThresholdStatus")}
    data_out["Duplicate"] = duplicate
    return ok(data_out, message=message or "OK", code=code, status=200 if duplicate else 201)
