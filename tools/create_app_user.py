"""Create one application user with an existing restricted service login. No DDL."""

import argparse
import getpass
import sys
from pathlib import Path
from dotenv import load_dotenv
from werkzeug.security import generate_password_hash

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")
sys.path.insert(0, str(ROOT / "swiftletcare_backend"))
from app import create_app, db  # noqa: E402 - repository path and environment first


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("username")
    parser.add_argument("--role", choices=["ADMIN", "STAFF"], default="STAFF")
    args = parser.parse_args()
    if not 1 <= len(args.username) <= 50:
        parser.error("Tên đăng nhập phải dài 1–50 ký tự.")
    password = getpass.getpass("Mật khẩu mới (ít nhất 12 ký tự): ")
    if len(password) < 12 or password != getpass.getpass("Nhập lại mật khẩu: "):
        parser.error("Mật khẩu quá ngắn hoặc không khớp.")
    with create_app().app_context():
        db.query(
            "INSERT dbo.Users(UserName,PasswordHash,FullName,Role) VALUES (?,?,?,?)",
            [args.username, generate_password_hash(password), args.username, args.role],
        )
    print("Đã tạo tài khoản ứng dụng; không thay đổi tài khoản có sẵn.")


if __name__ == "__main__":
    main()
