-- Döp den här filen till: DE25_Assignment_1_Jahan_RazzaghRostami
-- Placera din kod enligt följande:
--
-- Kör hela skriptet i den databas där lärarens tabeller redan finns:
--   InterestRates, EnergyClassMargin, DepreciationRates, CreditRiskTier
--   och månadstabellerna CarInformation_yyyymm.
--
-- Affärsregel (uppgiftens basformel):
--   TotalInterestRate = BaseInterestRate + MarginRate
--   EstimatedProfit   = BasePrice * TotalInterestRate / 100
--
-- Ränta och marginal ligger som procenttal (4.50 och 1.00, inte 0.045 och 0.01),
-- eftersom formeln delar med 100. Marginalen slås upp i EnergyClassMargin
-- (Electric 1.00, Hybrid 1.50, Gasoline/Diesel 2.50) och hårdkodas inte.
--
-- RiskAdjustment och DepreciationRate tas med i resultatet. Diagrammet pekar ut
-- de tabellerna, men de ingår inte i den publicerade basformeln.

-- =============================================================================
-- 1. Saker som behöver köras innan jag skapar ditt jobbsteg:
-- =============================================================================

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

-- Database Mail måste vara påslaget för bekräftelsemejlet (VG).
IF NOT EXISTS (
    SELECT 1
    FROM sys.configurations
    WHERE name = N'Database Mail XPs'
      AND value_in_use = 1
)
BEGIN
    EXEC sys.sp_configure N'show advanced options', 1;
    RECONFIGURE;
    EXEC sys.sp_configure N'Database Mail XPs', 1;
    RECONFIGURE;
END;

IF OBJECT_ID(N'dbo.ETL_Log', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ETL_Log (
        LogID        bigint         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunID        uniqueidentifier NOT NULL,
        LogTime      datetime2(0)   NOT NULL CONSTRAINT DF_ETL_Log_LogTime DEFAULT (SYSDATETIME()),
        Severity     varchar(10)    NOT NULL,
        StepName     nvarchar(80)   NOT NULL,
        Message      nvarchar(4000) NOT NULL,
        RowsAffected int            NULL
    );

    CREATE INDEX IX_ETL_Log_RunID ON dbo.ETL_Log (RunID, LogID);
END;

-- En rad. Byt ProfileName till profilen som finns på servern,
-- och Recipients till den adress som ska få körningsbekräftelsen.
IF OBJECT_ID(N'dbo.ETL_MailConfig', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ETL_MailConfig (
        ConfigID    int            NOT NULL CONSTRAINT PK_ETL_MailConfig PRIMARY KEY,
        ProfileName sysname        NOT NULL,
        Recipients  nvarchar(500)  NOT NULL,
        CONSTRAINT CK_ETL_MailConfig_OneRow CHECK (ConfigID = 1)
    );
END;

IF NOT EXISTS (SELECT 1 FROM dbo.ETL_MailConfig WHERE ConfigID = 1)
BEGIN
    INSERT INTO dbo.ETL_MailConfig (ConfigID, ProfileName, Recipients)
    VALUES (1, N'NackademinMail', N'you@example.com');
END;

-- Staging töms vid varje körning. Den ägs av ETL-jobbet, inte av källsystemet.
DROP TABLE IF EXISTS dbo.CarInformation_Staging;
CREATE TABLE dbo.CarInformation_Staging (
    StageRowID       int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
    RecordID         int            NULL,
    CarModel         nvarchar(100)  NULL,
    EnergyClassRaw   nvarchar(50)   NULL,
    EnergyClass      nvarchar(20)   NULL,
    ManufactureYear  int            NULL,
    BasePrice        decimal(18,2)  NULL,
    FileMonth        date           NULL,
    CustomerRiskTier nvarchar(20)   NULL,
    IsValid          bit            NOT NULL CONSTRAINT DF_CarInformation_Staging_IsValid DEFAULT (0),
    RejectReason     nvarchar(400)  NULL
);

-- Alias så att "gas", "el", "bensin" och liknande träffar EnergyClassMargin
-- utan att marginalen hårdkodas. Raden används bara när råvärdet inte redan
-- matchar en nyckel i EnergyClassMargin.
IF OBJECT_ID(N'dbo.EnergyClassSynonym', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.EnergyClassSynonym (
        RawValue    nvarchar(50) NOT NULL PRIMARY KEY,
        EnergyClass nvarchar(20) NOT NULL
    );
END;

MERGE dbo.EnergyClassSynonym AS tgt
USING (VALUES
    (N'electric',    N'Electric'),
    (N'el',          N'Electric'),
    (N'ev',          N'Electric'),
    (N'elbil',       N'Electric'),
    (N'hybrid',      N'Hybrid'),
    (N'elhybrid',    N'Hybrid'),
    (N'laddhybrid',  N'Hybrid'),
    (N'plug-in',     N'Hybrid'),
    (N'plugin',      N'Hybrid'),
    (N'phev',        N'Hybrid'),
    (N'gasoline',    N'Gasoline'),
    (N'gas',         N'Gasoline'),
    (N'petrol',      N'Gasoline'),
    (N'bensin',      N'Gasoline'),
    (N'diesel',      N'Diesel'),
    (N'dieselbil',   N'Diesel')
) AS src (RawValue, EnergyClass)
ON tgt.RawValue = src.RawValue
WHEN NOT MATCHED BY TARGET THEN
    INSERT (RawValue, EnergyClass) VALUES (src.RawValue, src.EnergyClass);

-- Valfri mailprofil. Lämna @SmtpHost tom om profilen redan finns på servern.
-- Fyll i uppgifter här endast på den server som ska skicka mejlet.
DECLARE @SmtpHost nvarchar(200) = N'';
DECLARE @SmtpPort int = 587;
DECLARE @SmtpEnableSsl bit = 1;
DECLARE @SmtpUser nvarchar(200) = N'';
DECLARE @SmtpPassword nvarchar(200) = N'';
DECLARE @MailFrom nvarchar(200) = N'you@example.com';
DECLARE @ProfileName sysname;

SELECT @ProfileName = ProfileName
FROM dbo.ETL_MailConfig
WHERE ConfigID = 1;

IF @SmtpHost <> N''
AND NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName)
BEGIN
    DECLARE @AccountName sysname = @ProfileName + N'_account';

    EXEC msdb.dbo.sysmail_add_account_sp
        @account_name = @AccountName,
        @email_address = @MailFrom,
        @display_name = N'Loan profit ETL',
        @mailserver_name = @SmtpHost,
        @port = @SmtpPort,
        @enable_ssl = @SmtpEnableSsl,
        @username = @SmtpUser,
        @password = @SmtpPassword;

    EXEC msdb.dbo.sysmail_add_profile_sp
        @profile_name = @ProfileName,
        @description = N'Bekräftelsemejl efter ETL_LoanProfitEstimates';

    EXEC msdb.dbo.sysmail_add_profileaccount_sp
        @profile_name = @ProfileName,
        @account_name = @AccountName,
        @sequence_number = 1;

    EXEC msdb.dbo.sysmail_add_principalprofile_sp
        @profile_name = @ProfileName,
        @principal_name = N'public',
        @is_default = 0;
END;

GO

-- =============================================================================
-- 2. Ditt jobbsteg (Stored Procedure):
-- =============================================================================

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LoadLoanProfitEstimates
    @AsOfDate date = NULL   -- Tomt värde betyder dagens datum. Används av jobbet.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunID uniqueidentifier = NEWID();
    DECLARE @Started datetime2(0) = SYSDATETIME();
    DECLARE @Finished datetime2(0);
    DECLARE @YearMonth char(6);
    DECLARE @SourceTable sysname;
    DECLARE @SourceSchema sysname;
    DECLARE @TargetTable sysname;
    DECLARE @QualifiedSource nvarchar(300);
    DECLARE @MonthStart date;
    DECLARE @MonthEnd date;
    DECLARE @BaseInterestRate decimal(8,2);
    DECLARE @InterestEffectiveDate date;
    DECLARE @UsedFallback bit = 0;
    DECLARE @RowsRead int = 0;
    DECLARE @RowsRejected int = 0;
    DECLARE @RowsLoaded int = 0;
    DECLARE @Sql nvarchar(max);
    DECLARE @ProfileName sysname;
    DECLARE @Recipients nvarchar(500);
    DECLARE @Subject nvarchar(255);
    DECLARE @Body nvarchar(max);
    DECLARE @Succeeded bit = 0;
    DECLARE @ErrorMessage nvarchar(4000);
    DECLARE @MailError nvarchar(4000);
    DECLARE @ThrowMessage nvarchar(2048);

    BEGIN TRY
        SET @AsOfDate = ISNULL(@AsOfDate, CAST(GETDATE() AS date));
        SET @YearMonth = CONVERT(char(6), @AsOfDate, 112); -- yyyyMM
        SET @MonthStart = DATEFROMPARTS(YEAR(@AsOfDate), MONTH(@AsOfDate), 1);
        SET @MonthEnd = EOMONTH(@AsOfDate);
        SET @SourceTable = N'CarInformation_' + @YearMonth;
        SET @TargetTable = N'LoanProfitEstimates_' + @YearMonth;

        IF @YearMonth NOT LIKE N'[0-9][0-9][0-9][0-9][0-9][0-9]'
            THROW 50001, N'Could not build a yyyyMM suffix from the run date.', 1;

        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
        VALUES (@RunID, N'INFO', N'Start',
                N'ETL started for ' + @SourceTable + N'. Output table ' + @TargetTable + N'.');

        -- Månadstabellen väljs på namn. Ingen lista över månader underhålls.
        SELECT TOP (1) @SourceSchema = s.name
        FROM sys.tables AS t
        INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.name = @SourceTable
        ORDER BY CASE WHEN s.name = N'dbo' THEN 0 ELSE 1 END, s.name;

        IF @SourceSchema IS NULL
        BEGIN
            -- Exakt den beskrivning uppgiften ber om, med den verkliga månaden.
            SET @ErrorMessage = N'CarInformation_' + @YearMonth + N' table for the current month not found.';
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'ERROR', N'Source', @ErrorMessage);
            THROW 50002, @ErrorMessage, 1;
        END;

        SET @QualifiedSource = QUOTENAME(@SourceSchema) + N'.' + QUOTENAME(@SourceTable);

        -- Senaste räntan vars EffectiveDate ligger i den aktuella månaden.
        SELECT TOP (1)
            @BaseInterestRate = r.BaseInterestRate,
            @InterestEffectiveDate = r.EffectiveDate
        FROM dbo.InterestRates AS r
        WHERE r.EffectiveDate >= @MonthStart
          AND r.EffectiveDate <= @MonthEnd
        ORDER BY r.EffectiveDate DESC;

        IF @BaseInterestRate IS NULL
        BEGIN
            -- G: fall tillbaka till den senaste tidigare månaden som har en ränta.
            SELECT TOP (1)
                @BaseInterestRate = r.BaseInterestRate,
                @InterestEffectiveDate = r.EffectiveDate
            FROM dbo.InterestRates AS r
            WHERE r.EffectiveDate < @MonthStart
            ORDER BY r.EffectiveDate DESC;

            IF @BaseInterestRate IS NULL
            BEGIN
                SET @ErrorMessage = N'No base interest rate is available for the current month or any earlier month.';
                INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
                VALUES (@RunID, N'ERROR', N'InterestRate', @ErrorMessage);
                THROW 50003, @ErrorMessage, 1;
            END;

            SET @UsedFallback = 1;
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (
                @RunID,
                N'WARNING',
                N'InterestRate',
                N'Base interest rate for the current month is missing. Value from the previous month was used.'
            );

            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (
                @RunID,
                N'INFO',
                N'InterestRate',
                N'Fallback rate '
                    + CONVERT(nvarchar(20), @BaseInterestRate)
                    + N' from '
                    + CONVERT(char(10), @InterestEffectiveDate, 23)
                    + N' was used.'
            );
        END
        ELSE
        BEGIN
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (
                @RunID,
                N'INFO',
                N'InterestRate',
                N'Base interest rate '
                    + CONVERT(nvarchar(20), @BaseInterestRate)
                    + N' effective '
                    + CONVERT(char(10), @InterestEffectiveDate, 23)
                    + N' was used.'
            );
        END;

        TRUNCATE TABLE dbo.CarInformation_Staging;

        -- En set-baserad läsning. Dynamisk SQL används bara för tabellnamnet.
        -- TRY_CONVERT gör att ett felaktigt värde blir en rad att avvisa,
        -- i stället för att hela körningen avbryts.
        SET @Sql = N'
            INSERT INTO dbo.CarInformation_Staging (
                RecordID, CarModel, EnergyClassRaw, ManufactureYear,
                BasePrice, FileMonth, CustomerRiskTier
            )
            SELECT
                TRY_CONVERT(int, src.RecordID),
                NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100), src.CarModel))), N''''),
                NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(50), src.EnergyClass))), N''''),
                TRY_CONVERT(int, src.ManufactureYear),
                COALESCE(
                    TRY_CONVERT(decimal(18,2), src.BasePrice),
                    TRY_CONVERT(decimal(18,2), REPLACE(REPLACE(CONVERT(nvarchar(40), src.BasePrice), N'' '', N''''), N'','', N''.''))
                ),
                COALESCE(
                    TRY_CONVERT(date, src.FileMonth),
                    CASE
                        WHEN LEN(LTRIM(RTRIM(CONVERT(nvarchar(20), src.FileMonth)))) = 6
                        THEN TRY_CONVERT(date, CONVERT(nvarchar(6), src.FileMonth) + N''01'')
                    END
                ),
                NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(20), src.CustomerRiskTier))), N'''')
            FROM ' + @QualifiedSource + N' AS src;';

        EXEC sys.sp_executesql @Sql;
        SET @RowsRead = @@ROWCOUNT;

        -- Kanoniskt energiklassvärde från dimensionen. Synonym används som andra försök.
        UPDATE s
        SET EnergyClass = COALESCE(directMatch.EnergyClass, synonymMatch.EnergyClass)
        FROM dbo.CarInformation_Staging AS s
        OUTER APPLY (
            SELECT TOP (1) m.EnergyClass
            FROM dbo.EnergyClassMargin AS m
            WHERE LOWER(LTRIM(RTRIM(m.EnergyClass))) = LOWER(s.EnergyClassRaw)
        ) AS directMatch
        OUTER APPLY (
            SELECT TOP (1) m.EnergyClass
            FROM dbo.EnergyClassSynonym AS y
            INNER JOIN dbo.EnergyClassMargin AS m
                ON LOWER(LTRIM(RTRIM(m.EnergyClass))) = LOWER(y.EnergyClass)
            WHERE LOWER(y.RawValue) = LOWER(s.EnergyClassRaw)
        ) AS synonymMatch;

        ;WITH DuplicateIds AS (
            SELECT RecordID
            FROM dbo.CarInformation_Staging
            WHERE RecordID IS NOT NULL
            GROUP BY RecordID
            HAVING COUNT(*) > 1
        )
        UPDATE s
        SET RejectReason = NULLIF(CONCAT_WS(
                N'; ',
                CASE WHEN s.RecordID IS NULL
                    THEN N'RecordID is missing or not an integer' END,
                CASE WHEN d.RecordID IS NOT NULL
                    THEN N'Duplicate RecordID' END,
                CASE WHEN s.BasePrice IS NULL OR s.BasePrice < 0
                    THEN N'BasePrice is missing or negative' END,
                CASE WHEN s.EnergyClass IS NULL
                    THEN N'EnergyClass is missing or not in EnergyClassMargin' END
            ), N'')
        FROM dbo.CarInformation_Staging AS s
        LEFT JOIN DuplicateIds AS d ON d.RecordID = s.RecordID;

        UPDATE dbo.CarInformation_Staging
        SET IsValid = CASE WHEN RejectReason IS NULL THEN 1 ELSE 0 END;

        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message, RowsAffected)
        SELECT
            @RunID,
            N'WARNING',
            N'Validate',
            N'Rejected ' + CONVERT(nvarchar(20), COUNT(*)) + N' rows: ' + RejectReason,
            COUNT(*)
        FROM dbo.CarInformation_Staging
        WHERE IsValid = 0
        GROUP BY RejectReason;

        SELECT @RowsRejected = COUNT(*)
        FROM dbo.CarInformation_Staging
        WHERE IsValid = 0;

        -- Måltabellen byggs om i en transaktion. En andra körning samma månad
        -- ersätter resultatet. Misslyckas insatsen rullas även DROP tillbaka.
        BEGIN TRANSACTION;

        SET @Sql = N'DROP TABLE IF EXISTS dbo.' + QUOTENAME(@TargetTable) + N';
            CREATE TABLE dbo.' + QUOTENAME(@TargetTable) + N' (
                RecordID               int            NOT NULL PRIMARY KEY,
                CarModel               nvarchar(100)  NULL,
                EnergyClass            nvarchar(20)   NOT NULL,
                ManufactureYear        int            NULL,
                BasePrice              decimal(18,2)  NOT NULL,
                FileMonth              date           NULL,
                CustomerRiskTier       nvarchar(20)   NULL,
                BaseInterestRate       decimal(8,2)   NOT NULL,
                InterestEffectiveDate  date           NOT NULL,
                MarginRate             decimal(8,2)   NOT NULL,
                RiskAdjustment         decimal(8,2)   NULL,
                DepreciationRate       decimal(8,2)   NULL,
                TotalInterestRate      decimal(8,2)   NOT NULL,
                EstimatedProfit        decimal(18,2)  NOT NULL
            );';
        EXEC sys.sp_executesql @Sql;

        SET @Sql = N'
            INSERT INTO dbo.' + QUOTENAME(@TargetTable) + N' (
                RecordID, CarModel, EnergyClass, ManufactureYear, BasePrice, FileMonth,
                CustomerRiskTier, BaseInterestRate, InterestEffectiveDate, MarginRate,
                RiskAdjustment, DepreciationRate, TotalInterestRate, EstimatedProfit
            )
            SELECT
                s.RecordID,
                s.CarModel,
                s.EnergyClass,
                s.ManufactureYear,
                s.BasePrice,
                s.FileMonth,
                COALESCE(risk.RiskTier, s.CustomerRiskTier),
                @BaseInterestRate,
                @InterestEffectiveDate,
                margin.MarginRate,
                risk.RiskAdjustment,
                dep.DepreciationRate,
                CAST(@BaseInterestRate + margin.MarginRate AS decimal(8,2)),
                CAST(ROUND(s.BasePrice * (@BaseInterestRate + margin.MarginRate) / 100.0, 2) AS decimal(18,2))
            FROM dbo.CarInformation_Staging AS s
            INNER JOIN dbo.EnergyClassMargin AS margin
                ON LOWER(LTRIM(RTRIM(margin.EnergyClass))) = LOWER(s.EnergyClass)
            OUTER APPLY (
                SELECT TOP (1) c.RiskTier, c.RiskAdjustment
                FROM dbo.CreditRiskTier AS c
                WHERE LOWER(LTRIM(RTRIM(c.RiskTier))) = LOWER(s.CustomerRiskTier)
                ORDER BY c.RiskTier
            ) AS risk
            OUTER APPLY (
                SELECT TOP (1) d.DepreciationRate
                FROM dbo.DepreciationRates AS d
                WHERE s.ManufactureYear BETWEEN d.MinYear AND d.MaxYear
                ORDER BY d.MinYear, d.MaxYear
            ) AS dep
            WHERE s.IsValid = 1;';

        EXEC sys.sp_executesql
            @Sql,
            N'@BaseInterestRate decimal(8,2), @InterestEffectiveDate date',
            @BaseInterestRate = @BaseInterestRate,
            @InterestEffectiveDate = @InterestEffectiveDate;

        SET @RowsLoaded = @@ROWCOUNT;
        COMMIT TRANSACTION;
        SET @Succeeded = 1;

        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message, RowsAffected)
        VALUES (
            @RunID,
            N'INFO',
            N'Load',
            N'Loaded ' + CONVERT(nvarchar(20), @RowsLoaded)
                + N' rows into dbo.' + @TargetTable
                + N'. Read ' + CONVERT(nvarchar(20), @RowsRead)
                + N', rejected ' + CONVERT(nvarchar(20), @RowsRejected) + N'.',
            @RowsLoaded
        );
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @Succeeded = 0;
        IF @ErrorMessage IS NULL
            SET @ErrorMessage = ERROR_MESSAGE();

        -- Käll- och räntefelen är redan loggade innan THROW. Övriga fel loggas här.
        IF ERROR_NUMBER() NOT IN (50002, 50003)
        BEGIN
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'ERROR', N'Failed', @ErrorMessage);
        END;
    END CATCH;

    SELECT @ProfileName = ProfileName, @Recipients = Recipients
    FROM dbo.ETL_MailConfig
    WHERE ConfigID = 1;

    SET @Finished = SYSDATETIME();

    SET @Subject = CASE
        WHEN @Succeeded = 1
        THEN N'Loan profit ETL succeeded - ' + ISNULL(@TargetTable, N'(no output table)')
        ELSE N'Loan profit ETL failed - ' + ISNULL(@TargetTable, N'(no output table)')
    END;

    SET @Body =
        N'The ETL job ' + CASE WHEN @Succeeded = 1 THEN N'completed successfully.' ELSE N'failed.' END + NCHAR(13) + NCHAR(10)
        + NCHAR(13) + NCHAR(10)
        + N'Output table: dbo.' + ISNULL(@TargetTable, N'(not created)') + NCHAR(13) + NCHAR(10)
        + N'Rows processed: ' + CONVERT(nvarchar(20), @RowsLoaded) + NCHAR(13) + NCHAR(10)
        + N'Rows read: ' + CONVERT(nvarchar(20), @RowsRead) + NCHAR(13) + NCHAR(10)
        + N'Rows rejected: ' + CONVERT(nvarchar(20), @RowsRejected) + NCHAR(13) + NCHAR(10)
        + N'Base interest rate: ' + COALESCE(CONVERT(nvarchar(20), @BaseInterestRate), N'(none)')
        + CASE
            WHEN @InterestEffectiveDate IS NULL THEN N''
            ELSE N' effective ' + CONVERT(char(10), @InterestEffectiveDate, 23)
          END + NCHAR(13) + NCHAR(10)
        + N'Fallback rate used: ' + CASE WHEN @UsedFallback = 1 THEN N'Yes' ELSE N'No' END + NCHAR(13) + NCHAR(10)
        + N'Started: ' + CONVERT(nvarchar(19), @Started, 120) + NCHAR(13) + NCHAR(10)
        + N'Finished: ' + CONVERT(nvarchar(19), @Finished, 120) + NCHAR(13) + NCHAR(10)
        + N'Database: ' + DB_NAME() + NCHAR(13) + NCHAR(10)
        + N'Server: ' + @@SERVERNAME
        + CASE
            WHEN @Succeeded = 0 THEN NCHAR(13) + NCHAR(10) + NCHAR(13) + NCHAR(10) + N'Error: ' + ISNULL(@ErrorMessage, N'')
            ELSE N''
          END;

    IF @ProfileName IS NULL OR @Recipients IS NULL
    BEGIN
        INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
        VALUES (@RunID, N'ERROR', N'Email',
                N'Confirmation email was not sent. dbo.ETL_MailConfig is missing a profile or recipient. '
                + @Body);
    END
    ELSE
    BEGIN
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name = @ProfileName,
                @recipients = @Recipients,
                @subject = @Subject,
                @body = @Body;

            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'INFO', N'Email', N'Confirmation email sent to ' + @Recipients + N'. ' + @Body);
        END TRY
        BEGIN CATCH
            SET @MailError = ERROR_MESSAGE();
            INSERT INTO dbo.ETL_Log (RunID, Severity, StepName, Message)
            VALUES (@RunID, N'ERROR', N'Email',
                    N'Confirmation email could not be sent. ' + @MailError + N' ' + @Body);
        END CATCH;
    END;

    PRINT @Body;

    IF @Succeeded = 0
    BEGIN
        SET @ThrowMessage = LEFT(ISNULL(@ErrorMessage, N'ETL failed.'), 2047);
        THROW 50000, @ThrowMessage, 1;
    END;
END;
GO

-- =============================================================================
-- 3. Ditt SQL Agent-jobb:
-- =============================================================================

SET NOCOUNT ON;

DECLARE @JobName sysname = N'ETL_LoanProfitEstimates';
DECLARE @ScheduleName sysname = N'Monthly_LoanProfitEstimates';
DECLARE @DatabaseName sysname = DB_NAME();
DECLARE @Owner sysname = SUSER_SNAME();

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = @JobName,
        @delete_unused_schedule = 1;
END;

EXEC msdb.dbo.sp_add_job
    @job_name = @JobName,
    @enabled = 1,
    @description = N'Månadsvis ETL. Läser CarInformation_yyyymm för aktuell månad, beräknar estimerad lånevinst och skriver LoanProfitEstimates_yyyymm. Skickar bekräftelsemejl med antal rader och tabellnamn.',
    @owner_login_name = @Owner,
    @notify_level_eventlog = 2;

EXEC msdb.dbo.sp_add_jobstep
    @job_name = @JobName,
    @step_name = N'Load LoanProfitEstimates',
    @step_id = 1,
    @subsystem = N'TSQL',
    @database_name = @DatabaseName,
    @command = N'EXEC dbo.usp_LoadLoanProfitEstimates;',
    @on_success_action = 1,  -- avsluta med lyckat resultat
    @on_fail_action = 2;     -- avsluta med fel

EXEC msdb.dbo.sp_update_job
    @job_name = @JobName,
    @start_step_id = 1;

-- Dag 1 varje månad kl. 07:00, lokal servertid.
-- Tabellen väljs på körningsdatum, så dagen kan flyttas till det dygn filen brukar landa.
EXEC msdb.dbo.sp_add_schedule
    @schedule_name = @ScheduleName,
    @enabled = 1,
    @freq_type = 16,                 -- månadsvis
    @freq_interval = 1,              -- den 1:a
    @freq_recurrence_factor = 1,
    @active_start_date = 20261001,
    @active_start_time = 070000;

EXEC msdb.dbo.sp_attach_schedule
    @job_name = @JobName,
    @schedule_name = @ScheduleName;

EXEC msdb.dbo.sp_add_jobserver
    @job_name = @JobName,
    @server_name = N'(LOCAL)';
GO
