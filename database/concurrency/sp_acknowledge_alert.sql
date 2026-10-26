USE SwiftletCare;
GO

CREATE OR ALTER PROCEDURE dbo.sp_AcknowledgeAlert
    @AlertId BIGINT,
    @UserId INT,
    @ResultCode VARCHAR(32) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @EntryTranCount INT = @@TRANCOUNT;
    DECLARE @SavepointCreated BIT = 0;
    DECLARE @Success BIT = 0;
    DECLARE @Code VARCHAR(32) = 'SYSTEM_ERROR';
    DECLARE @Message NVARCHAR(255);
    DECLARE @ErrorNumber INT;
    DECLARE @ActionId BIGINT;
    DECLARE @Status VARCHAR(20);

    BEGIN TRY
        IF @EntryTranCount = 0
            BEGIN TRANSACTION;
        ELSE
        BEGIN
            SAVE TRANSACTION AcknowledgeAlertSave;
            SET @SavepointCreated = 1;
        END;

        -- VALIDATION
        IF @AlertId IS NULL OR @AlertId <= 0 OR @UserId IS NULL OR @UserId <= 0
            BEGIN
                SET @Code = 'VALIDATION_ERROR';
                SET @Message = N'AlertId và UserId phải là số nguyên dương.';
                GOTO BusinessFailure;
            END;

        IF NOT EXISTS (
            SELECT 1 FROM dbo.Users WITH (HOLDLOCK)
            WHERE UserID = @UserId AND IsActive = 1 AND Role IN ('ADMIN', 'STAFF')
        )
            BEGIN
                SET @Code = 'FORBIDDEN';
                SET @Message = N'Người dùng không hợp lệ hoặc đã bị khóa.';
                GOTO BusinessFailure;
            END;

        -- TRANSACTION
        UPDATE dbo.Alerts WITH (UPDLOCK, HOLDLOCK)
        SET Status = 'ACKNOWLEDGED'
        WHERE AlertId = @AlertId AND Status = 'PENDING';

        IF @@ROWCOUNT = 0
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.Alerts WHERE AlertId = @AlertId)
                BEGIN
                    SET @Code = 'ALERT_NOT_FOUND';
                    SET @Message = N'Cảnh báo không tồn tại.';
                    GOTO BusinessFailure;
                END;
            BEGIN
                SET @Code = 'INVALID_STATE';
                SET @Message = N'Cảnh báo không còn PENDING. Hãy tải lại dữ liệu.';
                GOTO BusinessFailure;
            END;
        END;

        INSERT INTO dbo.AlertActions (AlertId, UserId, ActionType, Note)
        VALUES (@AlertId, @UserId, 'ACKNOWLEDGE', N'Xác nhận cảnh báo bằng Stored Procedure');

        SET @ActionId = CONVERT(BIGINT, SCOPE_IDENTITY());
        SET @Status = 'ACKNOWLEDGED';
        IF @EntryTranCount = 0
            COMMIT TRANSACTION;

        SET @Success = 1;
        SET @Code = 'OK';
        SET @Message = N'Xác nhận cảnh báo thành công.';
    END TRY
    BEGIN CATCH
        -- ERROR HANDLING
        SET @ErrorNumber = ERROR_NUMBER();
        SET @Message = ERROR_MESSAGE();
        IF @EntryTranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @SavepointCreated = 1 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION AcknowledgeAlertSave;

        SET @Code = 'SYSTEM_ERROR';
        SET @Message = N'Không thể xác nhận cảnh báo. Hãy rollback giao dịch và thử lại.';
        SET @ActionId = NULL;
        SET @Status = NULL;
    END CATCH;

    GOTO Result;

    -- BUSINESS FAILURE
    BusinessFailure:
    IF @EntryTranCount = 0 AND XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    ELSE IF @SavepointCreated = 1 AND XACT_STATE() = 1
        ROLLBACK TRANSACTION AcknowledgeAlertSave;

    -- RESULT
    Result:
    SET @ResultCode = @Code;
    SELECT @Success AS Success, @Code AS Code, @Message AS Message,
           @ErrorNumber AS ErrorNumber, @AlertId AS AlertId,
           @Status AS Status, @ActionId AS ActionId;
END;
GO
