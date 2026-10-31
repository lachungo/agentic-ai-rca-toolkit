USE DBA;
GO

EXEC dbo.usp_RCA_ShowRootCauseSynthesis
     @CaptureRunID = 3;
GO