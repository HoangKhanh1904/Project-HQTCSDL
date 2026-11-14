# Chạy và nghiệm thu SwiftletCare Application

Ứng dụng tích hợp Backend (nguồn Python-FL), Frontend (nguồn FRONTEND) và Analytics/QA (nguồn feature/analytics-qa), dựa trên database ở `feature/database-upgrade` (`212466eb`). Bản QA hiện tại sửa trực tiếp procedure điều khiển để xử lý audit mode-only; giữ nguyên schema, CHECK/FK/quyền và lịch sử cũ.

## Chạy ứng dụng trên database đã triển khai

Yêu cầu Python 3.13, ODBC Driver 18 for SQL Server, SQL Server đã triển khai đầy đủ database upgrade. Các lệnh dưới dùng PowerShell tại gốc repository.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.application.example .env
# Sửa .env bằng thông tin kết nối riêng.
.\.venv\Scripts\python.exe tools/create_app_user.py admin --role ADMIN
.\.venv\Scripts\python.exe swiftletcare_backend/run.py
```

Mở http://127.0.0.1:5000. CLI tạo user hỏi mật khẩu, không ghi plaintext vào source và không đổi tài khoản đã tồn tại. Seed `TEST_ONLY` không phải mật khẩu đăng nhập hợp lệ. Sau khi tạo quản trị viên, có thể tạo tài khoản STAFF bằng cùng CLI với `--role STAFF`.

**Kết nối:** dùng một service login thuộc `SwiftletAdmin` của database đã hoàn tất, không thuộc sysadmin/db_owner. Role này cho phép server đọc Users để xác thực, CRUD danh mục, đọc dữ liệu và gọi procedure; đây không phải role người dùng trình duyệt. HTTP kiểm tra lại `Users.IsActive/Role` mỗi request đã đăng nhập, chỉ ADMIN được sửa danh mục/ngưỡng. STAFF được đọc và xử lý cảnh báo/sự kiện/điều khiển theo procedure. Token simulator chỉ được ghi ingest. Không cấp login ứng dụng trực tiếp cho người dùng trình duyệt.

Ứng dụng không tự tạo login SQL hay thay quyền trên database hiện tại. Nếu service login chưa được tạo, quản trị database cần ánh xạ login đó vào role có sẵn. Trước khi vận hành ngoài máy local, dùng WSGI server phù hợp, HTTPS, cookie secure, quản lý secret và giới hạn đăng nhập tại reverse proxy. Entry point hiện tại phục vụ kiểm tra application local.

## Hành vi chính

- Nhà yến/khu vực/thiết bị: thêm, sửa, tìm kiếm/lọc toàn bộ dữ liệu trên SQL Server trước phân trang và tính tổng; danh mục phân trang 50 dòng. Tìm kiếm hiểu %, _ và [ theo nghĩa đen. Mục mới xuất hiện trước; reload vẫn giữ vì đã ghi SQL.
- “Ngừng hoạt động” là cập nhật trạng thái INACTIVE; không xóa lịch sử hoặc cascade dữ liệu liên quan.
- Ngưỡng: chọn nút Ngưỡng ở khu vực. ADMIN tạo/sửa, STAFF chỉ đọc. PUT gửi RowVer hex, xung đột trả 409 và cần tải lại.
- Dashboard: trung bình trên latest reading của từng sensor theo procedure hiện có, không gọi đó là số đo tức thời duy nhất hay tổng số lần đo. Hiển thị đủ NO_DATA/UNCONFIGURED/INCOMPLETE_DATA/WARNING/NORMAL.
- Cảm biến: biểu đồ 4 chỉ số, lọc sensor và khoảng `[from,to)`, tối đa 1000 số đo mới nhất. NULL khác 0. Dữ liệu lỗi giữ lần tải trước với thông báo rõ chưa xác nhận mới.
- Cảnh báo: PENDING → ACKNOWLEDGED → RESOLVED → PENDING theo procedure. Lỗi trạng thái trả 409. Sự kiện mô phỏng dùng NEW → ACKNOWLEDGED → RESOLVED và replay không ghi đè audit.
- Chim: tổng IN/OUT theo ngày Việt Nam, không diễn giải thành tổng đàn cư trú.
- AUTO/MANUAL là trạng thái SQL mô phỏng, không có xác nhận phần cứng. AUTO áp dụng theo yêu cầu của người dùng, không chạy nền. Khi bỏ reading_id, API chọn số đo mới nhất của cảm biến ACTIVE cùng Zone; khi truyền reading_id, procedure vẫn kiểm tra số đo mới nhất và cùng Zone. LIGHT chưa có rule AUTO và trả RULE_UNAVAILABLE.
- Chỉ thay đổi IsOn mới tạo TURN_ON/TURN_OFF. Mode-only vẫn cập nhật settings trong transaction nhưng không tạo lệnh bật/tắt; phản hồi bổ sung ModeChanged/StateChanged, Changed vẫn bao gồm cả hai. Thao tác lặp trả NO_CHANGE, không cập nhật timestamp/nhật ký. Khởi tạo OFF không tạo TURN_OFF. Lịch sử cũ được giữ nguyên.
- Dashboard/cảnh báo/sự kiện/điều khiển cập nhật mỗi 10 giây khi tab hiển thị; không tạo polling chồng nhau.

## Hợp đồng API

JSON thành công: `{success:true, code, message, data}`. Lỗi: `{success:false, code, message}`. Dữ liệu SQL được giữ nguyên tên cột trừ Dashboard ánh xạ snake_case có nghĩa rõ ràng. BIGINT vượt giới hạn an toàn JavaScript được gửi dạng chuỗi.

| Nhóm | Endpoint | Quyền / request |
|---|---|---|
| Phiên | GET `/api/auth`; POST `/api/auth/login`, `/logout` | Lấy CSRF trước login; username/password; login thay token |
| Danh mục | GET/POST `/api/farms`, `/areas`, `/devices`; PUT/DELETE `/<id>` | Đọc khi đăng nhập; GET hỗ trợ search/status/page/limit, areas thêm house_id, devices thêm zone_id/device_type; ghi ADMIN. POST/PUT gồm name/status; farms thêm address/manager_id; areas house_id/description; devices zone_id/device_type |
| Quản lý | GET `/api/managers` | ADMIN; không trả password hash |
| Dashboard | GET `/api/dashboard/zones?zone_id=` | `data.zones`: zone_id/name, house_name, temperature/humidity trung bình, sensor_count, reading_sensor_count, status, last_updated |
| Số đo | GET `/api/metrics?house_id=&zone_id=&device_id=&from=&to=&limit=` | Không có range: latest từng sensor; có range: history. from/to phải đi cùng, có timezone, from < to; limit 1–1000 |
| Ngưỡng | GET/POST/PUT `/api/thresholds/<zone_id>` | Ghi ADMIN; MinTemperature/MaxTemperature/MinHumidity/MaxHumidity; PUT thêm row_version |
| Cảnh báo | GET `/api/alerts?zone_id=&limit=`; POST `/api/alerts/<id>/acknowledge`, `/resolve`, `/reopen` | ADMIN/STAFF; UserId lấy từ session |
| Chim | GET `/api/birds?house_id=&from=&to=` | house_id bắt buộc; timestamp có múi giờ, phân nhóm theo Việt Nam |
| Sự kiện | GET `/api/events?house_id=&zone_id=&status=&limit=`; POST `/api/events/<id>/status` | expected_status và status; mặc định GET chỉ chưa resolved |
| Điều khiển | GET `/api/controls`; POST `/api/controls/<device_id>` | GET mặc định giữ mảng trạng thái cũ. GET ?view=history trả items/total/page/limit, lọc device_id/zone_id/command/mode/from/to (khoảng [from,to) có timezone). POST: action SET_MODE với mode, MANUAL với is_on boolean, AUTO với reading_id tùy chọn; ADMIN/STAFF |
| Ingest | POST `/api/simulator/readings`, `/bird-movements`, `/events` | Token X-Simulator-Token hoặc Bearer; không dùng session |

Mọi API thay đổi bằng session yêu cầu header X-CSRF-Token. Ingest cần UUID source_event_id, giữ nguyên payload khi retry. Mới tạo 201, replay 200, IDEMPOTENCY_CONFLICT 409; SYSTEM_ERROR 500; không kết nối DB 503. Giới hạn số đo khớp SQL: nhiệt độ -40..100, độ ẩm 0..100, CO₂ 0..100000, lux 0..200000. Không đổi hợp đồng SQL cũ hoặc tham số OUTPUT thứ năm.

Timestamp readings legacy dùng `MSSQL_TIMEZONE`, phải cấu hình theo giờ thực tế trên server, không dự đoán lại lịch sử. Event/control của extension dùng Asia/Ho_Chi_Minh. Timestamp trả ISO có offset. Ingest chim/sự kiện bắt buộc `event_time` có offset; server chuyển sang giờ Việt Nam và không tự tạo thời gian mới cho retry.

```powershell
# SIMULATOR_TOKEN đặt trong biến môi trường, cùng giá trị server.
.\.venv\Scripts\python.exe swiftletcare_backend/simulator/run.py --scenario repeat_event --device 1 --duration 10 --seed 7
.\.venv\Scripts\python.exe swiftletcare_backend/simulator/run.py --scenario birds --house 1 --duration 10 --seed 7
.\.venv\Scripts\python.exe swiftletcare_backend/simulator/run.py --scenario predator --house 1 --zone 1 --device 1 --duration 10 --seed 7
```

## Kiểm thử riêng, không tác động database đang dùng

Docker cần chạy trước. Script tạo container mới có nhãn application-test, bind localhost:14339; không tái sử dụng `swiftletcare-sqlserver` hiện tại. Credential sinh ngẫu nhiên lưu `%TEMP%/swiftletcare-test-env.json`, có thể đổi bằng SWIFTLET_TEST_CONFIG. Database kiểm thử tên `SwiftletCare_AppTest_*` được giữ để kiểm tra bằng chứng. Đặt PYTHONDONTWRITEBYTECODE=1 trước mọi lệnh Python để không tạo bytecode trong repository.

```powershell
.\.venv\Scripts\python.exe -m pip install -r requirements-test.txt
.\.venv\Scripts\python.exe -m playwright install chromium
.\.venv\Scripts\python.exe tools/prepare_application_tests.py
$env:PYTHONDONTWRITEBYTECODE = "1"
.\.venv\Scripts\python.exe -m pytest -q -p no:cacheprovider --junitxml="$env:TEMP/swiftletcare-test-artifacts/results.xml"
```

Nếu SQL Server khởi động lâu, dùng `--resume-container <tên container do script vừa tạo>`; script kiểm tra nhãn trước khi tiếp tục. Nếu không có cấu hình test, integration/browser bị SKIP, nghĩa là **NOT RUN**, không phải PASS. Không trỏ cấu hình test sang database thật.

Bộ kiểm thử có HTTP server Flask thực, pyodbc/SQL Server thực, Chromium thực; mocks chỉ ở bộ unit riêng. Ảnh desktop/mobile và trace mặc định ở `%TEMP%/swiftletcare-test-artifacts/`, có thể đổi bằng SWIFTLET_TEST_ARTIFACTS. Mỗi lần chạy tạo fixture có ID riêng, giữ dữ liệu trong container riêng; kiểm tra migration/restore tạo database riêng nữa. Không yêu cầu chạy script QA trực tiếp bằng SQL login ứng dụng vì QA cần tạo/rollback fixture.

Workflow `Application regression` hiện có chạy cùng bộ test trên PR vào `test` và qua `workflow_dispatch`, dùng Ubuntu 24.04, SQL Server container riêng và Chromium. Cài ODBC theo [hướng dẫn chính thức của Microsoft](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server). Workflow lưu artifact và credential trong runner.temp, tắt bytecode/cache pytest và chỉ upload thư mục evidence; không upload credential test. Kết quả local không đồng nghĩa CI đã chạy thành công; xem trạng thái trên PR.

| Mục QA bổ sung | Test thực tế |
|---|---|
| QA14 | Bird back-test: mốc nửa đêm Việt Nam, IN/OUT, `[from,to)`, retry/conflict |
| QA15 | CO₂/lux, biên hợp lệ/không hợp lệ, NULL khác 0, latest Dashboard |
| QA16 | AUTO hysteresis, MANUAL override, mode-only/no-op và audit bật/tắt; không dùng XFAIL |
| QA17 | Simulated events, đúng loại PREDATOR_DETECTED, thời gian, trạng thái và replay |
| QA18 | HTTP UUID race cùng/khác payload; rowversion race; MANUAL giữ lock trước HTTP AUTO |
| QA19 | Rollback fault injection, migration schema cũ hai lần, tham số OUTPUT cũ, backup/restore |

Mapping QA14–QA19 này là mapping bổ sung cho application trong bản tích hợp, không khẳng định thay thế một rubric bên ngoài chưa được cung cấp. QA01–QA13 và QA20–QA23 cũ được chạy trên SQL Server qua script fail-fast.

## Hợp đồng audit và giới hạn

Test `test_known_database_mode_only_audit` đã bỏ strict XFAIL và phải PASS trên SQL Server thật. Không thêm loại Command mới hoặc sửa nhật ký cũ. Các dòng mode-only trước bản sửa được giữ nguyên; không thể suy ra lại đầy đủ trạng thái trước đó từ lịch sử này. Nhật ký SIMULATED dùng giờ Việt Nam, legacy dùng MSSQL_TIMEZONE.

Báo cáo `TEST-REPORT.md` lưu kết quả lịch sử ngày 08/11/2026; kết quả bản sửa hiện tại được trình bày trực tiếp trong phản hồi Codex. Backup/restore được kiểm tra trên Linux SQL Server của container, không chứng minh tương thích mọi cách cài SQL Server khác. Concurrency kiểm tra các lịch cụ thể có barrier/lock, không chứng minh tất cả lịch chạy có thể xảy ra.

Sau khi review PR vào `test`, nhóm triển khai bản tích hợp lên môi trường test, nghiệm thu bằng dữ liệu của nhóm. Chưa đưa vào `main` khi còn lỗi đã biết hoặc kiểm thử bắt buộc chưa chạy.
