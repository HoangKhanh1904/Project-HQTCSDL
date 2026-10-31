USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_TransitionAlert
    @AlertId BIGINT, @UserId INT, @ActionType VARCHAR(30),
    @ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @EntryTranCount INT=@@TRANCOUNT,@SavepointCreated BIT=0;
    DECLARE @Success BIT=0,@Code VARCHAR(32)='SYSTEM_ERROR',@Message NVARCHAR(255),@ErrorNumber INT;
    DECLARE @ZoneId INT,@LockedZone INT,@AlertType VARCHAR(30),@Status VARCHAR(20),@ActionId BIGINT;
    DECLARE @ExpectedStatus VARCHAR(20)=CASE @ActionType WHEN 'RESOLVE' THEN 'ACKNOWLEDGED' WHEN 'REOPEN' THEN 'RESOLVED' END;
    DECLARE @NewStatus VARCHAR(20)=CASE @ActionType WHEN 'RESOLVE' THEN 'RESOLVED' WHEN 'REOPEN' THEN 'PENDING' END;
    BEGIN TRY
        IF @EntryTranCount=0 BEGIN TRANSACTION;
        ELSE BEGIN SAVE TRANSACTION TransitionAlertSave; SET @SavepointCreated=1; END;

        -- VALIDATION
        IF @AlertId IS NULL OR @AlertId<=0 OR @UserId IS NULL OR @UserId<=0 OR @ExpectedStatus IS NULL
        BEGIN
            SET @Code='VALIDATION_ERROR'; SET @Message=N'Tham số chuyển trạng thái không hợp lệ.'; GOTO BusinessFailure;
        END;
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WITH (HOLDLOCK) WHERE UserID=@UserId AND IsActive=1 AND Role IN ('ADMIN','STAFF'))
        BEGIN
            SET @Code='FORBIDDEN'; SET @Message=N'Người dùng không hợp lệ hoặc bị khóa.'; GOTO BusinessFailure;
        END;
        SELECT @ZoneId=ZoneId FROM dbo.Alerts WHERE AlertId=@AlertId;
        IF @ZoneId IS NULL
        BEGIN
            SET @Code='ALERT_NOT_FOUND'; SET @Message=N'Cảnh báo không tồn tại.'; GOTO BusinessFailure;
        END;
        SELECT @LockedZone=ZoneId FROM dbo.Zones WITH (UPDLOCK,HOLDLOCK) WHERE ZoneId=@ZoneId;
        SELECT @AlertType=AlertType,@Status=Status FROM dbo.Alerts WITH (UPDLOCK,HOLDLOCK)
        WHERE AlertId=@AlertId AND ZoneId=@ZoneId;
        IF @Status IS NULL
        BEGIN
            SET @Code='ALERT_NOT_FOUND'; SET @Message=N'Cảnh báo không tồn tại.'; GOTO BusinessFailure;
        END;
        IF @Status<>@ExpectedStatus
        BEGIN
            SET @Code='INVALID_STATE'; SET @Message=N'Cảnh báo không ở trạng thái cho phép.'; GOTO BusinessFailure;
        END;
        IF @ActionType='REOPEN' AND EXISTS (SELECT 1 FROM dbo.Alerts
            WHERE ZoneId=@ZoneId AND AlertType=@AlertType AND AlertId<>@AlertId AND Status IN ('PENDING','ACKNOWLEDGED'))
        BEGIN
            SET @Code='OPEN_ALERT_EXISTS'; SET @Message=N'Zone đã có cảnh báo cùng loại chưa xử lý xong.'; GOTO BusinessFailure;
        END;

        -- TRANSACTION
        UPDATE dbo.Alerts SET Status=@NewStatus,
            ResolvedAt=CASE WHEN @ActionType='RESOLVE' THEN SYSDATETIME() ELSE NULL END
        WHERE AlertId=@AlertId AND Status=@ExpectedStatus AND ZoneId=@ZoneId;
        IF @@ROWCOUNT<>1
        BEGIN
            SET @Code='INVALID_STATE'; SET @Message=N'Trạng thái cảnh báo đã thay đổi.'; GOTO BusinessFailure;
        END;
        INSERT dbo.AlertActions(AlertId,UserId,ActionType,Note)
        VALUES (@AlertId,@UserId,@ActionType,N'Xử lý cảnh báo bằng Stored Procedure');
        SET @ActionId=CONVERT(BIGINT,SCOPE_IDENTITY());
        IF @EntryTranCount=0 COMMIT;
        SET @Success=1; SET @Code='OK'; SET @Message=N'Đã chuyển trạng thái cảnh báo.';
    END TRY
    BEGIN CATCH
        SET @ErrorNumber=ERROR_NUMBER(); SET @Code='SYSTEM_ERROR'; SET @Message=N'Không thể xử lý cảnh báo. Hãy rollback giao dịch.';
        IF @EntryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
        ELSE IF @SavepointCreated=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION TransitionAlertSave;
    END CATCH;
    GOTO Result;

    -- ROLLBACK
    BusinessFailure:
    IF @EntryTranCount=0 AND XACT_STATE()<>0 ROLLBACK;
    ELSE IF @SavepointCreated=1 AND XACT_STATE()=1 ROLLBACK TRANSACTION TransitionAlertSave;

    -- RESULT
    Result:
    SET @ResultCode=@Code;
    SELECT @Success AS Success,@Code AS Code,@Message AS Message,@ErrorNumber AS ErrorNumber,
           @AlertId AS AlertId,CASE WHEN @Success=1 THEN @NewStatus ELSE CONVERT(VARCHAR(20),NULL) END AS Status,
           CASE WHEN @Success=1 THEN @ActionId ELSE CONVERT(BIGINT,NULL) END AS ActionId;
END;
GO
