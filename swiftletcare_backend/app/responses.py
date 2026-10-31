"""Định dạng JSON thống nhất:
   thành công: {"success": true,  "code": "OK", "message": "...", "data": ...}
   lỗi:        {"success": false, "code": "...", "message": "..."}"""
from flask import jsonify


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def ok(data=None, message="OK", code="OK", status=200):
    return jsonify({"success": True, "code": code, "message": message, "data": data}), status


def fail(code, message, status):
    return jsonify({"success": False, "code": code, "message": message}), status
