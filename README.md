# SwiftletCare 🐦

**Bài tập lớn môn Hệ quản trị cơ sở dữ liệu (HQTCSDL)**  
**Đề tài:** Ứng dụng quản lý và giám sát nhà yến (SwiftletCare)  
**Nhóm:** 4 thành viên

> **Lưu ý về phạm vi:** Đây là ứng dụng phục vụ bài tập lớn **SQL Server và T-SQL**. Dữ liệu nhiệt độ, độ ẩm, lượt chim ra/vào và cảnh báo được **mô phỏng hoặc nhập thủ công**. Nhóm **không bắt buộc** triển khai cảm biến IoT, camera hay AI thực tế.

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
| Database | Microsoft SQL Server | Lưu trữ dữ liệu quan hệ |
| Ngôn ngữ DB | T-SQL | Truy vấn và xử lý nghiệp vụ tại CSDL |
| Kết nối DB | `pyodbc`, Microsoft ODBC Driver for SQL Server | Kết nối Python với SQL Server |
| Công cụ DB | SQL Server Management Studio (SSMS) | Tạo và kiểm thử database |
| Làm việc nhóm | Git, GitHub | Quản lý phiên bản và review code |
| Tùy chọn | Bootstrap, Chart.js, Postman | Giao diện, biểu đồ, kiểm thử API |

## 3. Phạm vi chức năng dự kiến

| Module | Chức năng | Gợi ý nội dung T-SQL |
| --- | --- | --- |
| Tài khoản & nhà yến | Quản lý tài khoản, nhà yến và khu vực | PK/FK, `UNIQUE`, CRUD |
| Thiết bị | Quản lý thiết bị và trạng thái | Quan hệ 1-n, `CHECK`, `DEFAULT` |
| Giám sát môi trường | Lưu và xem nhiệt độ, độ ẩm, ánh sáng mô phỏng | Procedure, View, Index |
| Điều khiển mô phỏng | Cấu hình ngưỡng, lưu lịch sử thao tác | Procedure, Transaction, Trigger |
| Theo dõi chim | Ghi nhận lượt vào/ra, tổng hợp theo ngày | Function, `GROUP BY`, CTE |
| Cảnh báo | Phát hiện dữ liệu vượt ngưỡng, ghi nhận xử lý | Procedure, View, Trigger phù hợp |
| Báo cáo | Thống kê dữ liệu theo ngày/tháng/nhà yến | JOIN, Window Function, Index |

**Ưu tiên MVP:** quản lý nhà yến/khu vực/thiết bị, dữ liệu môi trường mô phỏng, lịch sử điều khiển, lượt chim vào/ra và dashboard cơ bản. Các tính năng nâng cao chỉ triển khai khi phần cốt lõi đã ổn định.

## 4. Kiến trúc tổng quan

```text
Trình duyệt (HTML/CSS/JavaScript)
              |
              v
      Python Flask + Jinja2
              |
            pyodbc
              |
              v
       Microsoft SQL Server
    Tables / Views / Procedures
    Functions / Triggers / Indexes
```

Dữ liệu mô phỏng có thể được tạo bằng SQL script hoặc một chương trình Python riêng. Ứng dụng phải thể hiện rõ vai trò của **SQL Server/T-SQL**, không chỉ lưu dữ liệu và xử lý mọi nghiệp vụ ở Python.

## 5. Cấu trúc thư mục dự kiến

> **Đây là cấu trúc đề xuất, chưa có nghĩa tất cả file/thư mục đã được tạo.** Nhóm sẽ cập nhật khi triển khai thực tế.

```text
Project-HQTCSDL/
├── README.md
├── requirements.txt            # Danh sách thư viện Python (sẽ tạo)
├── .env.example                # Mẫu cấu hình, không chứa mật khẩu thật
├── app.py                      # Điểm khởi chạy Flask (dự kiến)
├── db.py                       # Kết nối SQL Server (dự kiến)
├── routes/                     # Các route theo chức năng
├── templates/                  # Giao diện HTML/Jinja2
├── static/
│   ├── css/
│   └── js/
├── database/
│   ├── 01_schema.sql
│   ├── 02_seed.sql
│   ├── 03_views.sql
│   ├── 04_functions.sql
│   ├── 05_procedures.sql
│   ├── 06_triggers.sql
│   ├── 07_indexes.sql
│   └── tests/
├── simulator/                  # Sinh dữ liệu giả lập (nếu có)
└── docs/                       # ERD, mô tả bảng, kiểm thử, báo cáo
```

## 6. Hướng dẫn thiết lập môi trường với Docker

### 6.1. Yêu cầu phần mềm

Mỗi thành viên cần cài đặt:

- Docker Desktop (Linux containers, WSL2 trên Windows).
- SQL Server Management Studio (SSMS).
- Python 3.
- Microsoft ODBC Driver 18 for SQL Server.
- Git và VS Code.

**Lưu ý:** Không cần cài SQL Server Database Engine trực tiếp trên Windows. SQL Server sẽ chạy trong Docker Container.

### 6.2. Clone repository

```bash
git clone https://github.com/HoangKhanh1904/Project-HQTCSDL.git
cd Project-HQTCSDL
```

### 6.3. Tạo cấu hình Docker Compose

Tạo file `compose.yaml` tại thư mục gốc:

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

Thay mật khẩu mẫu bằng mật khẩu riêng đủ mạnh.

Tạo `.env.example` để chia sẻ mẫu cấu hình:

```dotenv
MSSQL_SA_PASSWORD=YOUR_STRONG_PASSWORD_HERE
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

Mở Docker Desktop và đảm bảo Docker Engine đang chạy.

Tại thư mục chứa `compose.yaml`, chạy:

```powershell
docker compose up -d
docker compose ps
docker compose logs --tail=50 sqlserver
```

Chờ đến khi log xuất hiện thông báo SQL Server sẵn sàng nhận kết nối.

### 6.6. Kết nối SQL Server bằng SSMS

Sử dụng các thông số:

| Trường | Giá trị |
| --- | --- |
| Server name | `127.0.0.1,14330` |
| Authentication | SQL Server Authentication |
| Login | `sa` |
| Password | Mật khẩu trong `.env` |
| Trust server certificate | Bật cho môi trường local |

Sau khi kết nối, chạy:

```sql
IF DB_ID(N'SwiftletCare') IS NULL
    CREATE DATABASE SwiftletCare;
GO

USE SwiftletCare;
GO

SELECT DB_NAME() AS CurrentDatabase;
```

Kết quả mong đợi: `SwiftletCare`.

### 6.7. Thiết lập Python

Tạo môi trường ảo:

```powershell
python -m venv .venv
```

Cài các thư viện:

```powershell
.\.venv\Scripts\python.exe -m pip install flask pyodbc python-dotenv
```

Khi nhóm có `requirements.txt`, ưu tiên cài đặt bằng file đó.

### 6.8. Kiểm tra kết nối Python – SQL Server

Tạo file `test_connection.py`:

```python
import os
import pyodbc
from dotenv import load_dotenv

load_dotenv()

connection_string = (
    "DRIVER={ODBC Driver 18 for SQL Server};"
    "SERVER=127.0.0.1,14330;"
    "DATABASE=SwiftletCare;"
    "UID=sa;"
    f"PWD={os.environ['MSSQL_SA_PASSWORD']};"
    "Encrypt=yes;"
    "TrustServerCertificate=yes;"
)

with pyodbc.connect(connection_string, timeout=5) as conn:
    cursor = conn.cursor()
    cursor.execute("SELECT DB_NAME()")
    print("Connected to:", cursor.fetchone()[0])
```

Chạy:

```powershell
.\.venv\Scripts\python.exe test_connection.py
```

Kết quả mong đợi:

```text
Connected to: SwiftletCare
```

Tài khoản `sa` chỉ dùng cho thiết lập và kiểm tra ban đầu. Khi phát triển ứng dụng, nên tạo tài khoản SQL có quyền giới hạn cho Flask.

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

Mỗi thành viên chạy một SQL Server Container trên máy cá nhân.

Để đồng bộ cấu trúc Database, nhóm cần:

1. Lưu các thay đổi schema, Stored Procedure, Function, Trigger và View thành SQL scripts.
2. Commit các script lên GitHub.
3. Pull thay đổi mới trước khi chạy script.
4. Thực hiện các script theo đúng thứ tự.
5. Không giả định Docker tự động đồng bộ dữ liệu giữa các máy.

### 6.11. Xử lý lỗi thường gặp

**Docker daemon không hoạt động:** Mở Docker Desktop, kiểm tra Linux Engine và chạy `docker info`.

**Không kết nối được SSMS:** Kiểm tra `docker compose ps`, cổng `14330`, tài khoản `sa` và mật khẩu.

**Python báo thiếu ODBC Driver:** Cài Microsoft ODBC Driver 18 và kiểm tra tên driver trong chuỗi kết nối.

**Container tự thoát:** Kiểm tra `docker compose logs sqlserver`, RAM khả dụng và mật khẩu.

**Đổi mật khẩu `.env` nhưng mật khẩu SQL Server không đổi:** Mật khẩu `sa` đã được lưu trong Database hiện có. Thay đổi biến môi trường không tự động thay đổi mật khẩu của Database đã khởi tạo.

### 6.12. Chạy ứng dụng Flask

Sau khi nhóm hoàn thiện `app.py`, có thể chạy:

```powershell
.\.venv\Scripts\python.exe -m flask --app app run --debug
```

Truy cập `http://127.0.0.1:5000`.

Đây là lệnh dự kiến; chỉ sử dụng khi ứng dụng Flask đã được triển khai. Chế độ debug chỉ dành cho phát triển cục bộ.
## 7. Phân công nhóm 4 người

| Thành viên | Vai trò chính | Công việc và sản phẩm bàn giao |
| --- | --- | --- |
| **TV1 – Database Lead** | Thiết kế dữ liệu | ERD, chuẩn hóa, bảng, PK/FK, constraints, seed data, tài liệu cấu trúc DB |
| **TV2 – Backend Lead** | Python Flask | Kết nối `pyodbc`, route/API, CRUD, Stored Procedure, Transaction |
| **TV3 – Frontend Lead** | HTML/CSS/JS | Layout, form, bảng dữ liệu, dashboard, tích hợp route; hỗ trợ View/truy vấn |
| **TV4 – Analytics & QA** | Mô phỏng và kiểm thử | Sinh dữ liệu, thống kê chim, cảnh báo, Function/CTE/Index, test case, báo cáo |

**Nguyên tắc:** Mỗi thành viên cần hiểu ERD, biết chạy script SQL và trình bày được ít nhất một phần T-SQL mình tham gia thực hiện. Cả nhóm cùng review và kiểm thử tích hợp.

## 8. Quy trình làm việc trên GitHub

1. Trước khi code, cập nhật nhánh `main`:

   ```bash
   git checkout main
   git pull origin main
   ```

2. Tạo nhánh mới theo công việc:

   ```bash
   git checkout -b feature/farm-management
   ```

3. Chỉ thêm những file liên quan, kiểm tra trước khi commit:

   ```bash
   git status
   git add <ten-file-hoac-thu-muc>
   git commit -m "feat: add farm management"
   git push -u origin feature/farm-management
   ```

4. Trên GitHub, tạo **Pull Request** từ nhánh tính năng vào `main`, mô tả thay đổi và nhờ ít nhất một thành viên review.
5. Không tự ý `force push` lên `main`. Khi có xung đột (merge conflict), trao đổi với người phụ trách phần code liên quan.

**Quy ước commit gợi ý:**

- `feat:` thêm chức năng
- `fix:` sửa lỗi
- `docs:` cập nhật tài liệu
- `db:` thay đổi database/T-SQL
- `test:` thêm hoặc sửa kiểm thử
- `refactor:` cải thiện code mà không đổi chức năng

## 9. Quy ước SQL Server và T-SQL

- Tên bảng, cột và khóa phải nhất quán; thống nhất cách đặt tên trước khi triển khai.
- Mỗi bảng có khóa chính phù hợp; khai báo khóa ngoại và các ràng buộc `NOT NULL`, `UNIQUE`, `CHECK`, `DEFAULT` khi cần.
- Ưu tiên kiểu dữ liệu phù hợp, ví dụ `DATETIME2` cho thời gian, `DECIMAL` cho giá trị đo cần độ chính xác xác định.
- Dùng tham số khi truy vấn từ Python; **không ghép chuỗi SQL từ dữ liệu người dùng**.
- Dùng `STORED PROCEDURE` cho nghiệp vụ có nhiều bước; `TRANSACTION` khi cần đảm bảo tính nguyên tử.
- Chỉ dùng `TRIGGER` cho trường hợp có lý do rõ ràng (ví dụ audit), tránh logic ẩn khó kiểm thử.
- Tạo `INDEX` dựa trên truy vấn thực tế; lưu Execution Plan hoặc kết quả đo khi báo cáo tối ưu.
- Mọi thay đổi schema và đối tượng T-SQL phải được lưu thành file `.sql` và đưa vào Git.
- Không lưu mật khẩu dạng văn bản thuần trong database; khi triển khai đăng nhập cần băm mật khẩu phù hợp.

## 10. Kế hoạch triển khai tham khảo (6 tuần)

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

- [ ] ERD và tài liệu mô tả bảng, quan hệ, kiểu dữ liệu
- [ ] Script tạo database và bảng chạy được trên máy khác
- [ ] Dữ liệu mẫu đủ để demo các tình huống
- [ ] Ràng buộc PK, FK, UNIQUE, CHECK, DEFAULT được kiểm thử
- [ ] Có Stored Procedure, Function, View, Trigger theo yêu cầu môn học
- [ ] Có minh họa Transaction và xử lý rollback
- [ ] Có truy vấn thống kê nhiều bảng (JOIN, GROUP BY, CTE hoặc Window Function)
- [ ] Có Index và giải thích vì sao sử dụng
- [ ] Có phương án backup/restore và phân quyền (nếu giảng viên yêu cầu)

### Ứng dụng & bàn giao

- [ ] Flask kết nối SQL Server ổn định
- [ ] Các chức năng CRUD hoạt động
- [ ] Dashboard hiển thị dữ liệu mô phỏng đúng
- [ ] Có xử lý lỗi đầu vào và thông báo lỗi dễ hiểu
- [ ] Có hướng dẫn cài đặt và cấu hình thực tế
- [ ] Không đưa mật khẩu, `.env`, `.venv` vào Git
- [ ] Có kịch bản demo và ảnh chụp kết quả kiểm thử
- [ ] Cả 4 thành viên nắm được phần mình phụ trách

## 12. Kịch bản demo gợi ý

1. Tạo nhà yến, khu vực và thiết bị trên giao diện.
2. Thử nhập dữ liệu sai để minh họa ràng buộc CSDL.
3. Sinh dữ liệu cảm biến mô phỏng và hiển thị trên dashboard.
4. Thay đổi ngưỡng môi trường, lưu lịch sử điều khiển.
5. Xem cảnh báo khi giá trị mô phỏng vượt ngưỡng.
6. Xem thống kê lượt chim ra/vào theo ngày.
7. Mở SSMS, thực thi Stored Procedure/View/Function tương ứng.
8. Minh họa Transaction rollback và so sánh truy vấn có/không có Index.

## 13. Lưu ý bảo mật và làm việc nhóm

- Thêm `.env`, `.venv/`, `__pycache__/`, `*.pyc` và các file bí mật vào `.gitignore`.
- Không chia sẻ tài khoản SQL Server có quyền quản trị cho mọi tác vụ của ứng dụng.
- Kiểm tra dữ liệu đầu vào ở cả backend và database.
- Thống nhất cách đặt tên, tránh sửa trực tiếp cùng một file trên `main`.
- Cập nhật README khi quy trình cài đặt, cấu trúc thư mục hoặc phân công thay đổi.

---

**Repository:** <https://github.com/HoangKhanh1904/Project-HQTCSDL>  
**Trạng thái:** Đang xây dựng — các phần chưa triển khai được ghi là *dự kiến* trong tài liệu.

