USE SwiftletCare;
GO
CREATE OR ALTER PROCEDURE dbo.sp_ReopenAlert
    @AlertId BIGINT,@UserId INT,@ResultCode VARCHAR(32)=NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.sp_TransitionAlert @AlertId,@UserId,'REOPEN',@ResultCode OUTPUT;
END;
GO
