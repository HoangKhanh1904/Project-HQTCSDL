# Báo cáo kiểm thử Application — 08/11/2026

## Kết quả local

**60 PASS, 0 FAIL, 0 ERROR, 1 XFAIL trong 61 test**. XFAIL là lỗi đã biết, không tính vào PASS. Một lần chạy toàn bộ suite trước đó có 42 PASS/1 XFAIL; sau đó bổ sung kiểm thử simulator, lỗi kết nối/khóa ngoại, nhiều sensor và các luồng UI còn lại, rồi chạy toàn bộ suite cuối.

Lệnh thực tế:

```powershell
.\.venv\Scripts\python.exe -m pytest -q --junitxml=.test-artifacts/results.xml --tb=short
```

Python 3.13.12 trên Windows; Flask 3.1.3, pyodbc 5.5.0, pytest 9.2.0, Playwright 1.64.1 / Chromium. Dependencies được ghi trong requirements. SQL Server chạy trong container mới riêng `hqtcsdl-app-tests-*`, cổng localhost 14339, database `SwiftletCare_AppTest_*`. Không dùng container `swiftletcare-sqlserver` hay database đang làm việc của nhóm.

Kiểm tra định dạng/rà lỗi Python bằng Ruff và cú pháp JavaScript bằng Node đã đạt. `git diff origin/feature/database-upgrade -- database` rỗng: không sửa source database đã hoàn tất.

| Phần kiểm tra | Bằng chứng thực tế | Kết quả |
|---|---|---|
| Unit | Validation, token simulator, lỗi API, vai trò, tên procedure/tham số | PASS |
| Flask + SQL | HTTP server thực, CRUD danh mục, Dashboard, CO₂/lux, NULL/0, biên hợp lệ/không hợp lệ | PASS |
| Idempotency | UUID retry cùng ID, khác payload HTTP 409, không nhân reading/alert | PASS |
| Chim | Replay dữ liệu cố định, IN/OUT, nửa đêm Việt Nam, khoảng `[from,to)` | PASS |
| Sự kiện | PREDATOR_DETECTED, đủ payload, timezone, retry và chuyển trạng thái | PASS |
| Cảnh báo | ACK/RESOLVE/REOPEN và số dòng audit; trạng thái không hợp lệ 409 | PASS |
| Concurrency HTTP | 8 client cùng UUID; 2 payload tranh cùng UUID; 2 sensor cùng Zone; ACK tranh nhau | PASS |
| Concurrency SQL/HTTP | Hai cập nhật cùng RowVer chỉ một thắng; MANUAL giữ khóa trước HTTP AUTO | PASS |
| Rollback | Fault injection sau khi ghi state/reading, audit/alert bị lỗi; dữ liệu một phần không tồn tại; request sau phục hồi | PASS |
| Quyền | Anonymous/STAFF/ADMIN, CSRF, service login không sysadmin/db_owner, ghi reading trực tiếp bị SQL chặn | PASS |
| Lỗi môi trường | Kết nối DB thất bại 503, FK lỗi 409, không lộ traceback/credential | PASS |
| Tương thích | Triển khai schema cũ thật, nâng cấp hai lần, dữ liệu legacy giữ nguyên, OUTPUT thứ năm hoạt động | PASS |
| Backup/restore | COPY_ONLY + CHECKSUM, VERIFYONLY, restore database riêng, đối chiếu readings và gọi procedure | PASS |
| SQL QA cũ | Chạy analytics_qa.sql và QA01–QA13/QA20–QA23 trên SQL Server, fail-fast | PASS |
| Simulator | 11 scenario CLI thực gọi HTTP, bao gồm repeat_event, birds và 4 loại sự kiện | PASS |
| Chromium | Đăng nhập, thêm/sửa/reload/tìm nhà yến, XSS hiển thị dạng text, Dashboard, history, ngưỡng, sự kiện, điều khiển, desktop/mobile | PASS |
| Lỗi UI | Mô phỏng riêng phản hồi 503 để kiểm tra thông báo chưa xác nhận dữ liệu; các luồng E2E thành công dùng SQL/HTTP thật | PASS |
| Audit chỉ đổi mode | Database ghi TURN_ON/TURN_OFF dù IsOn giữ nguyên | **XFAIL đã biết** |

## Lỗi database giữ nguyên theo phạm vi

`database/procedures/sp_simulate_device_control.sql` tại `212466eb` ghi lệnh bật/tắt khi chỉ đổi ControlMode. Test `test_known_database_mode_only_audit` xác nhận lỗi trên SQL Server thực. Không sửa SQL vì phạm vi lần này là ba phần Backend/Frontend/Analytics-QA và dùng database đã hoàn tất của chủ dự án.

Đây là điểm cần chủ database quyết định trước khi nghiệm thu tính chính xác của nhật ký điều khiển và đưa vào main. Suite dùng strict XFAIL để không che giấu; khi database được sửa, XPASS sẽ làm suite fail và yêu cầu cập nhật kiểm thử.

## Vị trí bằng chứng và giới hạn

- JUnit: `.test-artifacts/results.xml`.
- Ảnh: `.test-artifacts/dashboard-desktop.png`, `history-desktop.png`, `farms-mobile.png`.
- Trace: `.test-artifacts/browser-trace.zip`.
- Credential test: `.test-env.json`, được gitignore, không bàn giao qua Git.
- Các file evidence giữ local; CI có workflow tải riêng thư mục evidence khi chạy trên PR. Kết quả local này không tự chứng minh workflow Ubuntu đã PASS.
- Test bổ sung sau khi sửa application; chưa chứng minh red/green trên mọi bản code cũ. Không thử phần cứng, production deployment hay mọi phiên bản SQL Server/ODBC. Concurrency chỉ chứng minh các lịch đã kiểm tra.

Bản này dùng để review và kiểm tra application trên `test`; chưa kết luận sẵn sàng vào `main` khi còn điểm audit database nêu trên.
