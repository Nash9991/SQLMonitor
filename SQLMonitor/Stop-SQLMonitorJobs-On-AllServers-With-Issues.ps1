﻿[CmdletBinding()]
Param (
    [Parameter(Mandatory=$false)]
    [String]$InventoryServer = 'localhost',
    [Parameter(Mandatory=$false)]
    [String]$InventoryDatabase = 'DBA',
    [Parameter(Mandatory=$false)]
    [String]$CredentialManagerDatabase = 'DBA',
    [Parameter(Mandatory=$false)]
    [Bool]$StopJob = $true,
    [Parameter(Mandatory=$false)]
    [Bool]$StartJob = $true,
    [Parameter(Mandatory=$false)]
    [String]$AllServerLogin
)

"$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "[Connect-DbaInstance] Create connection for InventoryServer '$InventoryServer'.."
$conInventoryServer = Connect-DbaInstance -SqlInstance $InventoryServer -Database $InventoryDatabase -ClientName "Stop-SQLMonitorJobs-On-AllServers-With-Issues.ps1" `
                                                    -TrustServerCertificate -EncryptConnection -ErrorAction Stop

if(-not [String]::IsNullOrEmpty($AllServerLogin)) 
{
    "$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "Fetch [$AllServerLogin] password from Credential Manager [$InventoryServer].[$CredentialManagerDatabase].."
    $getCredential = @"
/* Fetch Credentials */
declare @password varchar(256);
exec dbo.usp_get_credential 
		@server_ip = '*',
		@user_name = @all_server_login,
		@password = @password output;
select @password as [password];
"@
    [string]$allServerLoginPassword = $conInventoryServer | Invoke-DbaQuery -Database $CredentialManagerDatabase `
                                -Query $getCredential -SqlParameter @{all_server_login = $AllServerLogin} | 
                                        Select-Object -ExpandProperty password -First 1

    "$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "Create [$AllServerLogin] credential from fetched password.."
    [securestring]$secStringPassword = ConvertTo-SecureString $allServerLoginPassword -AsPlainText -Force
    [pscredential]$allServerLoginCredential = New-Object System.Management.Automation.PSCredential $AllServerLogin, $secStringPassword
}
else {
    "$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'WARNING:', "No login provided for parameter [AllServerLogin]."
    "$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'WARNING:', "Using windows authentication for SQL Connections."
}

$sqlGetAllStuckJobs = @"
declare @_buffer_time_minutes int = 30;
declare @_sql nvarchar(max);
declare @_params nvarchar(max);

set @_params = N'@_buffer_time_minutes int';
set quoted_identifier off;
set @_sql = "
select	/* [Tsql-Stop-Job] = 'exec msdb.dbo.sp_stop_job @job_name = '''+sj.JobName+'''' ,
		[Tsql-Start-Job] = 'exec msdb.dbo.sp_start_job @job_name = '''+sj.JobName+'''' , 
		*/
		[CollectionTimeUTC] = [UpdatedDateUTC],
		[sql_instance], sql_instance_with_port, [database], [JobName],
		[Job-Delay-Minutes] = case when sj.Last_Successful_ExecutionTime is null then 10080 else datediff(minute, sj.Last_Successful_ExecutionTime, dateadd(minute,-(sj.Successfull_Execution_ClockTime_Threshold_Minutes+@_buffer_time_minutes),getutcdate())) end,
		 [Last_RunTime], [Last_Run_Duration_Seconds], [Last_Run_Outcome], 
		 [Successfull_Execution_ClockTime_Threshold_Minutes], 
		 [Expected_Max_Duration_Minutes],
		 [Last_Successful_ExecutionTime], [Last_Successful_Execution_Hours], 
		 [Running_Since], [Running_StepName], [Running_Since_Min] 
from dbo.sql_agent_jobs_all_servers sj
outer apply (select top 1 sql_instance_with_port = coalesce(id.sql_instance +','+ id.sql_instance_port, id.sql_instance), [database] from dbo.instance_details id where id.sql_instance = sj.sql_instance and id.is_enabled = 1 and id.is_available = 1 and id.is_alias = 0) id
where 1=1
and sj.JobCategory = '(dba) SQLMonitor'
and sj.JobName like '(dba) %'
and sj.IsDisabled = 0
and sj.Successfull_Execution_ClockTime_Threshold_Minutes <> -1
and (	sj.Last_Run_Outcome is null 
	or	sj.Last_Run_Outcome in ('Succeeded','Canceled')
	or	sj.Running_Since_Min >= (sj.Successfull_Execution_ClockTime_Threshold_Minutes * 4)
	)
and (	dateadd(minute,-(sj.Successfull_Execution_ClockTime_Threshold_Minutes+@_buffer_time_minutes),getutcdate()) > sj.Last_Successful_ExecutionTime
			or sj.Last_Successful_ExecutionTime is null
		)
--order by Last_Run_Outcome
"
set quoted_identifier off;

exec sp_executesql @_sql, @_params, @_buffer_time_minutes = @_buffer_time_minutes;
"@

$resultGetAllStuckJobs = $conInventoryServer | Invoke-DbaQuery -Database $InventoryDatabase -Query $sqlGetAllStuckJobs;

# Execute SQL files & SQL Query
[System.Collections.ArrayList]$failedJobs = @()
[System.Collections.ArrayList]$successJobs = @()
$resultGetAllStuckJobsFiltered = @()
$resultGetAllStuckJobsFiltered += $resultGetAllStuckJobs

if ($resultGetAllStuckJobsFiltered.Count -eq 0) {
    "`n$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "No action required to be taken."
}

foreach($job in $resultGetAllStuckJobsFiltered)
{
    $sqlInstance = $job.sql_instance
    $sqlInstanceWithPort = $job.sql_instance_with_port
    $database = $job.database
    $jobName = $job.JobName
    $isSqlInstanceAvailable = $true

    try {
        "`n`t$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "Create connection to [$sqlInstanceWithPort].."
        $conSqlInstance = Connect-DbaInstance -SqlInstance $sqlInstanceWithPort -Database $database -ClientName "Inventory-(dba) Stop-StuckSQLMonitorJobs" `
                                    -TrustServerCertificate -EncryptConnection -ErrorAction Stop -SqlCredential $allServerLoginCredential
    }
    catch {
        $errMessage = $_.Exception.Message
        $isSqlInstanceAvailable = $false

        $errObj = [PSCustomObject]@{
                        SqlInstance = $sqlInstance; 
                        SqlIntanceWithPort = $sqlInstanceWithPort; 
                        JobName = $null; 
                        Action = 'Create SQL Connection';
                        ErrorDetails = $errMessage
                    }
        $failedJobs.Add($errObj) | Out-Null

        $errMessage | Write-Host -ForegroundColor Red
        "`n"
    }
    
    try 
    {
        if($StopJob -and $isSqlInstanceAvailable) 
        {
            "`n`t$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "Stop job [$jobName] on [$sqlInstance].."
            $conSqlInstance | Invoke-DbaQuery -CommandType StoredProcedure -EnableException `
                            -Database msdb -Query sp_stop_job -SqlParameter @{ job_name = $jobName }

            $resultObj = [PSCustomObject]@{
                            SqlInstance = $sqlInstance;
                            SqlIntanceWithPort = $sqlInstanceWithPort; 
                            JobName = $jobName; 
                            Action = 'Stop Job';
                            Result = 'Successes';
                      }
            $successJobs.Add($errObj) | Out-Null

            Start-Sleep -Seconds 5
        }
    }
    catch {
        $errMessage = $_.Exception.Message

        if($errMessage -notlike '*refused because the job is not currently running.') 
        {           
            $errObj = [PSCustomObject]@{
                            SqlInstance = $sqlInstance; 
                            SqlIntanceWithPort = $sqlInstanceWithPort; 
                            JobName = $jobName; 
                            Action = 'Stop Job';
                            ErrorDetails = $errMessage
                      }
            $failedJobs.Add($errObj) | Out-Null

            $errMessage | Write-Host -ForegroundColor Red
            "`n"
        }
    }

    try 
    {
        if($StartJob -and $isSqlInstanceAvailable)
        {
            "`t$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "Start job [$jobName] on [$sqlInstance].."
            $resultObj = [PSCustomObject]@{
                            SqlInstance = $sqlInstance;
                            SqlIntanceWithPort = $sqlInstanceWithPort; 
                            JobName = $jobName; 
                            Action = 'Start Job';
                            Result = 'Successes';
                      }
            $successJobs.Add($errObj) | Out-Null
        }
    }    
    catch {
        $errMessage = $_.Exception.Message

        if($errMessage -notlike '*the job is already running*') 
        {           
            $errObj = [PSCustomObject]@{
                            SqlInstance = $sqlInstance; 
                            SqlIntanceWithPort = $sqlInstanceWithPort; 
                            JobName = $jobName; 
                            Action = 'Start Job';
                            ErrorDetails = $errMessage
                      }
            $failedJobs.Add($errObj) | Out-Null

            $errMessage | Write-Host -ForegroundColor Red
            "`n"
        }
    }
}


if($failedJobs.Count -gt 0) {
    #$failedJobs | ogv -Title "Failed"
    "`nAction on following jobs failed:`n" | Write-Output
    "`n`t$(Get-Date -Format yyyyMMMdd_HHmm) {0,-10} {1}" -f 'INFO:', "Action on following jobs failed:`n"
    $failedJobs | Format-Table -AutoSize
}
#$successJobs | ogv -Title "Successful"

