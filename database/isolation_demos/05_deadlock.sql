USE SwiftletCare;
GO
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=3 AND major_id=SCHEMA_ID('sc_isolation') AND name=N'SwiftletCareIsolation' AND CONVERT(NVARCHAR(100),value)=N'v1') 
    THROW 52611,'Deploy the owned isolation setup first.',1;
GO

-- =========================================================================
-- Kịch bản Demo: KHÓA CHẾT (DEADLOCK) - CHƯƠNG 3 HQTCSDL
-- Nguyên nhân: T1 giữ khóa trên Tài khoản 1 và chờ khóa trên Tài khoản 2.
--             T2 giữ khóa trên Tài khoản 2 và chờ khóa trên Tài khoản 1.
--             Cả hai bên chờ lẫn nhau tạo thành chu trình (Wait-For Graph).
--             SQL Server Deadlock Monitor sẽ phát hiện chu trình và chọn 1
--             giao tác làm nạn nhân (Deadlock Victim - Lỗi 1205).
-- Giải pháp (@Fix = 1):
--   Quy tắc "Cấp khóa theo thứ tự" (Resource / Lock Ordering):
--   Tất cả các giao tác bắt buộc phải xin khóa theo thứ tự tăng dần của matk
--   (Luôn khóa matk=1 trước rồi mới khóa matk=2). Không bao giờ có chu trình chờ chéo.
-- =========================================================================

-- SESSION T1
CREATE OR ALTER PROCEDURE sc_isolation.sp_deadlock_T1 @RunTag NVARCHAR(24), @Fix BIT=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Đặt timeout để không treo vĩnh viễn nếu hệ quản trị gặp sự cố
    SET LOCK_TIMEOUT 30000;

    IF @@TRANCOUNT <> 0 OR @Fix IS NULL 
       OR NOT EXISTS(SELECT 1 FROM sc_isolation.TaiKhoan WITH (READUNCOMMITTED) WHERE RunTag=@RunTag AND matk=1)
        THROW 52610, 'Start with a fresh fixture and no ambient transaction.', 1;

    DECLARE @First DECIMAL(18,2), @Second DECIMAL(18,2);

    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        BEGIN TRANSACTION;

        -- Bước 1 của T1: Luôn khóa tài khoản 1 (matk=1)
        UPDATE sc_isolation.TaiKhoan
        SET sotien = sotien - 50
        WHERE RunTag = @RunTag AND matk = 1;

        SELECT @First = sotien FROM sc_isolation.TaiKhoan WHERE RunTag = @RunTag AND matk = 1;

        -- Tạm dừng để Session T2 kịp chạy bước 1 của nó
        WAITFOR DELAY '00:00:03';

        -- Bước 2 của T1: Xin khóa tiếp tài khoản 2 (matk=2)
        UPDATE sc_isolation.TaiKhoan
        SET sotien = sotien + 50
        WHERE RunTag = @RunTag AND matk = 2;

        SELECT @Second = sotien FROM sc_isolation.TaiKhoan WHERE RunTag = @RunTag AND matk = 2;

        COMMIT TRANSACTION;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        SELECT @@SPID AS SPID, @Fix AS Fix, 'T1_SUCCESS' AS Result,
               @First AS TK1_Balance, @Second AS TK2_Balance,
               @@TRANCOUNT AS TranCount, XACT_STATE() AS XactState, SYSDATETIME() AS FinishedAt;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        -- Trả về thông tin chi tiết lỗi (đặc biệt khi bị chọn làm Deadlock Victim - Mã lỗi 1205)
        SELECT @@SPID AS SPID, @Fix AS Fix, 'T1_FAILED' AS Result,
               ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage,
               XACT_STATE() AS XactState, SYSDATETIME() AS FinishedAt;
        THROW;
    END CATCH;
END;
GO

-- SESSION T2
CREATE OR ALTER PROCEDURE sc_isolation.sp_deadlock_T2 @RunTag NVARCHAR(24), @Fix BIT=0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 30000;

    IF @@TRANCOUNT <> 0 OR @Fix IS NULL 
       OR NOT EXISTS(SELECT 1 FROM sc_isolation.TaiKhoan WITH (READUNCOMMITTED) WHERE RunTag=@RunTag AND matk=1)
        THROW 52610, 'Start with a fresh fixture and no ambient transaction.', 1;

    DECLARE @First DECIMAL(18,2), @Second DECIMAL(18,2);

    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
        BEGIN TRANSACTION;

        IF @Fix = 0
        BEGIN
            -- [KỊCH BẢN LỖI - DEADLOCK]: T2 khóa ngược thứ tự (Khóa matk=2 trước)
            UPDATE sc_isolation.TaiKhoan
            SET sotien = sotien - 30
            WHERE RunTag = @RunTag AND matk = 2;

            SELECT @First = sotien FROM sc_isolation.TaiKhoan WHERE RunTag = @RunTag AND matk = 2;

            -- Tạm dừng để T1 kịp tiến tới đòi khóa matk=2
            WAITFOR DELAY '00:00:03';

            -- Sau đó T2 mới đòi khóa matk=1 (đang bị T1 giữ) => DEADLOCK XẢY RA!
            UPDATE sc_isolation.TaiKhoan
            SET sotien = sotien + 30
            WHERE RunTag = @RunTag AND matk = 1;

            SELECT @Second = sotien FROM sc_isolation.TaiKhoan WHERE RunTag = @RunTag AND matk = 1;
        END
        ELSE
        BEGIN
            -- [KỊCH BẢN KHẮC PHỤC - LOCK ORDERING]:
            -- Cả T2 cũng tuân thủ thứ tự: Luôn xin khóa matk=1 trước, rồi mới xin khóa matk=2.
            -- Vì T1 đã giữ khóa matk=1, T2 sẽ an toàn xếp hàng chờ T1 xong, KHÔNG BAO GIỜ bị Deadlock!
            UPDATE sc_isolation.TaiKhoan
            SET sotien = sotien + 30
            WHERE RunTag = @RunTag AND matk = 1;

            SELECT @First = sotien FROM sc_isolation.TaiKhoan WHERE RunTag = @RunTag AND matk = 1;

            UPDATE sc_isolation.TaiKhoan
            SET sotien = sotien - 30
            WHERE RunTag = @RunTag AND matk = 2;

            SELECT @Second = sotien FROM sc_isolation.TaiKhoan WHERE RunTag = @RunTag AND matk = 2;
        END;

        COMMIT TRANSACTION;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        SELECT @@SPID AS SPID, @Fix AS Fix, 'T2_SUCCESS' AS Result,
               @First AS Step1_Balance, @Second AS Step2_Balance,
               @@TRANCOUNT AS TranCount, XACT_STATE() AS XactState, SYSDATETIME() AS FinishedAt;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

        SELECT @@SPID AS SPID, @Fix AS Fix, 'T2_FAILED' AS Result,
               ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage,
               XACT_STATE() AS XactState, SYSDATETIME() AS FinishedAt;
        THROW;
    END CATCH;
END;
GO

-- =========================================================================
-- Hướng dẫn chạy thử nghiệm trong SSMS hoặc Azure Data Studio:
-- 1. Khởi tạo dữ liệu:
--    EXEC sc_isolation.sp_Fixture N'deadlock_test', 'RESET';
--
-- 2. Thử nghiệm Lỗi Deadlock (@Fix = 0):
--    - Mở Cửa sổ 1 (Session 1): EXEC sc_isolation.sp_deadlock_T1 N'deadlock_test', 0;
--    - Mở Cửa sổ 2 (Session 2): EXEC sc_isolation.sp_deadlock_T2 N'deadlock_test', 0;
--    -> Chạy gần như cùng lúc! Sau khoảng 3-5 giây, 1 trong 2 session sẽ bị lỗi:
--       "Msg 1205: Transaction (Process ID ...) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction."
--
-- 3. Thử nghiệm Khắc phục bằng Cấp khóa theo thứ tự (@Fix = 1):
--    - Reset dữ liệu: EXEC sc_isolation.sp_Fixture N'deadlock_test', 'RESET';
--    - Mở Cửa sổ 1 (Session 1): EXEC sc_isolation.sp_deadlock_T1 N'deadlock_test', 1;
--    - Mở Cửa sổ 2 (Session 2): EXEC sc_isolation.sp_deadlock_T2 N'deadlock_test', 1;
--    -> Chạy gần như cùng lúc! Session 2 sẽ kiên nhẫn chờ Session 1 hoàn tất,
--       cả hai giao tác đều SUCCESS và không bao giờ xảy ra Deadlock.
--
-- 4. Dọn dẹp dữ liệu:
--    EXEC sc_isolation.sp_Fixture N'deadlock_test', 'CLEANUP';
-- =========================================================================
