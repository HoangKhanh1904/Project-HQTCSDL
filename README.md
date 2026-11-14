# SwiftletCare 🐦

## 1. Mục tiêu

- Xây dựng ứng dụng web quản lý thông tin nhà yến, khu vực, thiết bị và dữ liệu giám sát.
- Thiết kế cơ sở dữ liệu quan hệ trên **Microsoft SQL Server** với khóa chính, khóa ngoại và các ràng buộc toàn vẹn.
- Vận dụng **T-SQL**: truy vấn nhiều bảng, `VIEW`, `STORED PROCEDURE`, `FUNCTION`, `TRIGGER`, `TRANSACTION`, `INDEX` và phân quyền (theo yêu cầu giảng viên).
- Kết nối ứng dụng **Python Flask** với SQL Server, hiển thị và thao tác dữ liệu trên giao diện web.
- Kiểm thử, trình diễn quy trình nghiệp vụ và giải thích được cách hoạt động của cơ sở dữ liệu.

## 2. Công nghệ sử dụng

| Thành phần | Công nghệ | Vai trò |
| --- | --- | --- |
| Backend | Python 3, Flask | Xử lý yêu cầu, định tuyến và nghiệp vụ |
| Frontend | HTML5, CSS3, JavaScript | Giao diện người dùng |
| Template | Jinja2 (đi kèm Flask) | Hiển thị dữ liệu từ backend |
| Database | Microsoft SQL Server 2022 | Lưu trữ dữ liệu quan hệ |
| Ngôn ngữ DB | T-SQL | Truy vấn và xử lý nghiệp vụ tại CSDL |
| Kết nối DB | `pyodbc`, Microsoft ODBC Driver for SQL Server | Kết nối Python với SQL Server |
| Công cụ DB | SQL Server Management Studio (SSMS) | Tạo và kiểm thử database |
| Làm việc nhóm | Git, GitHub | Quản lý phiên bản và review code |
| Ảo hóa | Docker, Docker Compose | Khởi chạy SQL Server Container |

## 3. Phạm vi chức năng hệ thống

| Module | Chức năng | Hiện thực T-SQL & Database |
| --- | --- | --- |
| Tài khoản & nhà yến | Quản lý tài khoản, nhà yến và khu vực | PK/FK, `UNIQUE`, CRUD, phân quyền RBAC |
| Thiết bị | Quản lý thiết bị và trạng thái | Quan hệ 1-n, `CHECK`, `DEFAULT` |
| Giám sát môi trường | Lưu và xem nhiệt độ, độ ẩm, CO₂, ánh sáng | Stored Procedure, Latest Readings, CTE |
| Điều khiển mô phỏng | Cấu hình ngưỡng, lưu nhật ký điều khiển | Procedure, Transaction, Optimistic Locking (`rowversion`) |
| Theo dõi chim | Ghi nhận lượt vào/ra, tổng hợp theo ngày | `GROUP BY`, DATE aggregation, múi giờ Việt Nam |
| Cảnh báo | Phát hiện dữ liệu vượt ngưỡng, ghi nhận xử lý | Procedure (`sp_AcknowledgeAlert`, `sp_ResolveAlert`), Lock hàng |
| Kiểm toán & Báo cáo | Thống kê vi khí hậu và kiểm tra định kỳ | Stored Procedure với CURSOR, Window Function, Aggregate |

## 4. Kiến trúc tổng quan

Hệ thống được tổ chức theo kiến trúc 3 tầng (3-Tier Architecture) phân tách rõ ràng nhiệm vụ:
- **Tầng giao diện (Client):** Xây dựng bằng HTML5, CSS3 và Vanilla JavaScript, chịu trách nhiệm nhận tương tác từ người dùng và hiển thị biểu đồ vi khí hậu.
- **Tầng ứng dụng (Backend):** Sử dụng Python Flask xử lý định tuyến REST API, kiểm soát phiên đăng nhập, xác thực vai trò (ADMIN/STAFF) và bảo vệ chống CSRF.
- **Tầng cơ sở dữ liệu (Database):** Sử dụng Microsoft SQL Server 2022 kết nối qua `pyodbc`. Mọi nghiệp vụ cốt lõi, kiểm soát giao tác ACID, xử lý con trỏ (Cursor) và các kịch bản khóa tương tranh đều được thực thi trực tiếp tại cơ sở dữ liệu.

## 5. Cấu trúc thư mục dự án

```text
Project-HQTCSDL/
├── compose.yaml                      # Cấu hình Docker SQL Server
├── requirements.txt                  # Danh sách thư viện Python
├── .env.example                      # Mẫu biến môi trường kết nối
├── README.md                         # Tài liệu hướng dẫn dự án
│
├── swiftletcare_backend/             # Ứng dụng Backend Flask
│   ├── run.py                        # Điểm khởi chạy server
│   ├── app/
│   │   ├── db.py                     # Quản lý kết nối SQL Server (pyodbc)
│   │   ├── auth.py                   # Xác thực & Phân quyền (ADMIN/STAFF)
│   │   └── routes/                   # Các route API và trang web
│   └── simulator/                    # Bộ mô phỏng sinh dữ liệu cảm biến
│
├── templates/                        # Giao diện HTML (application.html)
├── static/                           # Tài nguyên tĩnh (CSS, JavaScript)
│
├── database/                         # Kịch bản SQL và Database Migration
│   ├── create_tables.sql             # Tạo bảng và ràng buộc toàn vẹn
│   ├── seed_data.sql                 # Dữ liệu mẫu ban đầu
│   ├── queries.sql                   # 30 câu truy vấn nghiệp vụ (Q01–Q30)
│   ├── security.sql                  # Phân quyền vai trò người dùng
│   ├── complete_database.py          # Script triển khai cơ sở dữ liệu
│   ├── procedures/                   # Các Stored Procedure nghiệp vụ & Cursor
│   └── isolation_demos/              # Kịch bản demo 5 hiện tượng tương tranh & Deadlock
│
├── tools/                            # Công cụ hỗ trợ
│   ├── create_app_user.py            # Tạo và đổi mật khẩu người dùng
│   └── demo_hqtcsdl.py               # Công cụ CLI demo nhanh
│
└── docs/                             # Tài liệu kỹ thuật, hướng dẫn & báo cáo
    ├── APPLICATION.md
    └── TEST-REPORT.md
```

## 6. Hướng dẫn thiết lập môi trường với Docker

### 6.1. Yêu cầu phần mềm

Mỗi thành viên cần cài đặt:

- Docker Desktop (Linux containers, WSL2 trên Windows).
- SQL Server Management Studio (SSMS) hoặc Azure Data Studio.
- Python 3.
- Microsoft ODBC Driver 18 for SQL Server.
- Git và VS Code.

**Lưu ý:** Không cần cài SQL Server Database Engine trực tiếp trên Windows. SQL Server sẽ chạy trong Docker Container.

### 6.2. Clone repository

```bash
git clone https://github.com/HoangKhanh1904/Project-HQTCSDL.git
cd Project-HQTCSDL
```

### 6.3. Cấu hình Docker Compose

File `compose.yaml` tại thư mục gốc:

```yaml
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: swiftletcare-sqlserver
    restart: unless-stopped
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_PID: "Developer"
      MSSQL_SA_PASSWORD: ${MSSQL_SA_PASSWORD}
    ports:
      - "127.0.0.1:14330:1433"
    volumes:
      - sqlserver_data:/var/opt/mssql

volumes:
  sqlserver_data:
```

### 6.4. Thiết lập biến môi trường

Tạo file `.env` tại thư mục chứa `compose.yaml`:

```dotenv
MSSQL_SA_PASSWORD=ThayBangMatKhauManh_2026!
```

Đảm bảo `.gitignore` chứa:

```gitignore
.env
.venv/
__pycache__/
*.pyc
```

Không commit `.env` lên GitHub.

### 6.5. Khởi động SQL Server

Mở Docker Desktop và đảm bảo Docker Engine đang chạy. Chạy lệnh:

```powershell
docker compose up -d
docker compose ps
docker compose logs --tail=50 sqlserver
```

### 6.6. Kết nối SQL Server bằng SSMS

Sử dụng các thông số:

| Trường | Giá trị |
| --- | --- |
| Server name | `127.0.0.1,14330` |
| Authentication | SQL Server Authentication |
| Login | `sa` |
| Password | Mật khẩu trong `.env` |
| Trust server certificate | Bật cho môi trường local |

### 6.7. Thiết lập môi trường Python

Tạo môi trường ảo và cài đặt thư viện:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

### 6.8. Triển khai Database & Nạp Stored Procedures

Chạy script tự động thiết lập toàn bộ bảng, dữ liệu mẫu, quyền và thủ tục:

```powershell
.\.venv\Scripts\python.exe database/complete_database.py deploy
```

### 6.9. Các lệnh Docker thường dùng

| Mục đích | Lệnh |
| --- | --- |
| Khởi động | `docker compose up -d` |
| Xem trạng thái | `docker compose ps` |
| Xem log | `docker compose logs -f sqlserver` |
| Dừng | `docker compose stop` |
| Khởi động lại | `docker compose start` |
| Xóa container, giữ volume | `docker compose down` |

**Cảnh báo:** Không dùng `docker compose down -v` nếu muốn giữ dữ liệu trong Docker Volume.

### 6.10. Đồng bộ Database giữa các thành viên

Mỗi thành viên chạy một SQL Server Container trên máy cá nhân:
1. Lưu các thay đổi schema, Stored Procedure, Function, Trigger và View thành SQL scripts trong `database/`.
2. Commit các script lên GitHub qua Pull Request.
3. Pull thay đổi mới trước khi chạy script.
4. Chạy các script theo đúng thứ tự.

### 6.11. Xử lý lỗi thường gặp

- **Docker daemon không hoạt động:** Mở Docker Desktop, kiểm tra Linux Engine.
- **Không kết nối được SSMS:** Kiểm tra cổng `14330`, tài khoản `sa` và mật khẩu.
- **Python báo thiếu ODBC Driver:** Cài Microsoft ODBC Driver 18 for SQL Server.
- **Container tự thoát:** Kiểm tra RAM khả dụng và mật khẩu `MSSQL_SA_PASSWORD`.

### 6.12. Chạy ứng dụng Flask

Khởi chạy server ứng dụng:

```powershell
.\.venv\Scripts\python.exe swiftletcare_backend/run.py
```

Truy cập `http://127.0.0.1:5000`.

## 7. Phân công nhóm 4 người

| Thành viên | Vai trò chính | Công việc và sản phẩm bàn giao |
| --- | --- | --- |
| **TV1 – Database Lead** | Thiết kế dữ liệu | ERD, chuẩn hóa, bảng, PK/FK, constraints, seed data, tài liệu cấu trúc DB |
| **TV2 – Backend Lead** | Python Flask | Kết nối `pyodbc`, route/API, CRUD, Stored Procedure, Transaction |
| **TV3 – Frontend Lead** | HTML/CSS/JS | Layout, form, bảng dữ liệu, dashboard, tích hợp route; hỗ trợ View/truy vấn |
| **TV4 – Analytics & QA** | Mô phỏng và kiểm thử | Sinh dữ liệu, thống kê chim, cảnh báo, Function/CTE/Index, test case, báo cáo |

## 8. Quy trình làm việc trên GitHub

1. Cập nhật nhánh tích hợp `test`:
   ```bash
   git checkout test
   git pull origin test
   ```
2. Tạo nhánh mới theo công việc:
   ```bash
   git checkout -b feature/farm-management
   ```
3. Commit và push nhánh:
   ```bash
   git add .
   git commit -m "feat: add farm management"
   git push -u origin feature/farm-management
   ```
4. Trên GitHub, tạo Pull Request vào `test`, review và kiểm thử trước khi merge vào `main`.

## 9. Quy ước SQL Server và T-SQL

- Tên bảng, cột và khóa nhất quán; định dạng chữ hoa/thường chuẩn.
- Mỗi bảng có khóa chính; khai báo đầy đủ các ràng buộc `NOT NULL`, `UNIQUE`, `CHECK`, `DEFAULT`.
- Sử dụng kiểu dữ liệu tối ưu: `DATETIME2` cho thời gian, `DECIMAL` cho các chỉ số đo vi khí hậu.
- Dùng tham số khi truy vấn từ Python; tuyệt đối không ghép chuỗi SQL.
- Dùng `STORED PROCEDURE` cho các luồng nghiệp vụ phức tạp; bao bọc `TRANSACTION` và xử lý lỗi `TRY...CATCH`.
- Tạo `INDEX` hỗ trợ tăng tốc các truy vấn thống kê lớn.
- Băm mật khẩu người dùng trước khi lưu trữ, không lưu plaintext.

## 10. Kế hoạch triển khai (6 tuần)

| Tuần | Mục tiêu |
| --- | --- |
| 1 | Chốt yêu cầu, ERD, phân công, thiết lập GitHub và môi trường |
| 2 | Tạo bảng/constraints/seed, kết nối Flask–SQL Server, giao diện khung |
| 3 | CRUD nhà yến/khu vực/thiết bị, Stored Procedure cơ bản |
| 4 | Dữ liệu môi trường mô phỏng, dashboard, lượt chim vào/ra |
| 5 | Điều khiển mô phỏng, cảnh báo, View/Function/Trigger/Transaction, báo cáo |
| 6 | Kiểm thử, tối ưu Index, hoàn thiện tài liệu và luyện demo |

## 11. Checklist trước khi nộp

### Database & T-SQL
- [x] Lược đồ quan hệ bảng, ràng buộc PK, FK, UNIQUE, CHECK, DEFAULT.
- [x] Bộ Stored Procedure hoàn chỉnh và xử lý Transaction an toàn.
- [x] Đã áp dụng Stored Procedure dùng **CURSOR** duyệt danh sách khu vực.
- [x] Đầy đủ 30 câu truy vấn nghiệp vụ nhiều bảng (JOIN, GROUP BY, CTE, Window Function).
- [x] Kịch bản demo 5 hiện tượng điều khiển tương tranh và Deadlock.
- [x] Phân quyền vai trò người dùng (Roles: SwiftletAdmin, SwiftletStaff).

### Ứng dụng & Bàn giao
- [x] Flask kết nối SQL Server ổn định qua pyodbc.
- [x] Các chức năng quản lý, dashboard và điều khiển hoạt động tốt.
- [x] Xử lý lỗi đầu vào và thông báo thân thiện.
- [x] Bộ kiểm thử tự động (Unit Test / Integration Test) hoàn thành.
- [x] Không đưa mật khẩu, `.env`, `.venv` vào Git.

## 12. Kịch bản demo gợi ý

1. Đăng nhập hệ thống với tài khoản quản trị.
2. Thao tác CRUD nhà yến, khu vực và thiết bị; minh họa các ràng buộc toàn vẹn.
3. Xem trạng thái môi trường các khu vực được tính toán trên Dashboard.
4. Cấu hình ngưỡng môi trường, minh họa tính năng chống xung đột cập nhật (OCC - `rowversion`).
5. Thao tác xác nhận và giải quyết cảnh báo, minh họa Transaction và khóa dòng.
6. Demo Stored Procedure kiểm toán vi khí hậu bằng Cursor (`/api/audit/cursor`).
7. Demo hiện tượng Khóa chết (Deadlock) và giải pháp cấp khóa theo thứ tự trên SSMS.

## 13. Lưu ý bảo mật và làm việc nhóm

- Thêm `.env`, `.venv/`, `__pycache__/`, `*.pyc` và các file bí mật vào `.gitignore`.
- Không chia sẻ tài khoản SQL Server có quyền quản trị cho mọi tác vụ của ứng dụng.
- Kiểm tra dữ liệu đầu vào ở cả backend và database.
- Thống nhất cách đặt tên, tránh sửa trực tiếp cùng một file trên `main`.
- Thường xuyên cập nhật tài liệu khi có thay đổi nghiệp vụ.

---

**Repository:** <https://github.com/HoangKhanh1904/Project-HQTCSDL>  
**Trạng thái:** Đã hoàn thiện mã nguồn và kiểm thử.
