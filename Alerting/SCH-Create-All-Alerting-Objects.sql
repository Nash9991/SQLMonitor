use DBA
go

/*
	Version -> 2024-05-25
	2024-04-26 - #10 - Setup Alert Engine Using Python+SQLServer
	-----------------

	https://github.com/imajaydwivedi/SQLMonitor/issues/10

	*** Self Pre Steps ***
	----------------------
	1) Python, Git needs to be installed on Inventory server
	2) Credential Manager needs to be installed on Inventory Server

	*** Steps in this Script ****
	-----------------------------
	1) Create table dbo.sma_inventory
	2) Create table dbo.sma_oncall_teams
	3) Create table dbo.sma_oncall_schedule
	4) Create table dbo.sma_errorlog
	5) Create sequence object dbo.sma_alert_sequence
	6) Create table dbo.sma_alert
	7) Create table dbo.sma_alert_rules
	8) Create table dbo.sma_alert_history
	9) Create table dbo.sma_alert_affected_servers
*/

IF DB_NAME() = 'master'
	raiserror ('Kindly execute all queries in [DBA] database', 20, -1) with log;
go

/* ***** 1) Create table dbo.sma_inventory ***************************** */
-- drop table [dbo].[sma_inventory]
create table [dbo].[sma_inventory]
(	
	[sql_instance] varchar(255) not null,
	[sql_instance_port] varchar(10) null,
	[host_name] varchar(255) not null,
	[friendly_name] varchar(255) null,
	[stability] varchar(20) not null default 'dev',
	[priority] tinyint not null default '2',
	[server_type] varchar(20) not null default 'windows',
	[has_hadr] bit not null default 0,
	[is_monitoring_enabled] bit not null default 1,
	[is_decommissioned] bit not null default 0,
	[backup_strategy] varchar(255) not null default 'native-backup',
	[rpo_worst_case_minutes] int not null,
	[rto_minutes] int not null,
	[created_date_utc] datetime2 not null default getutcdate(),
	[updated_date_utc] datetime2 not null default getutcdate(),
	[updated_by] varchar(255) not null default suser_name(),
	[server_owner] varchar(255) null,
	[server_owner_email] varchar(500) null,
	[data_center] varchar(255) null,
	[application] varchar(500) null,
	[application_email_contacts] varchar(2000) null,
	[purpose] varchar(2000) null,
	[dependency] varchar(2000) null,	
	[avg_utilization] varchar(1000) null,	
	[rdp_credential] varchar(125) null,
	[sql_credential] varchar(125) null,
	[other_details] varchar(2000) null,
	[wsfc_cluster_name] varchar(255) null,
	[wsfc_cluster_ip] varchar(15) null,
	[sql_cluster_name] varchar(255) null,
	[sql_cluster_ip] varchar(15) null,
	[sql_cluster_preferred_role] varchar(30) null,
	[sql_cluster_current_role] varchar(30) null,
	[ag_listener_name] varchar(255) null,
	[ag_listener_ip] varchar(15) null,
	[ag_preferred_role] varchar(30) null,
	[ag_current_role] varchar(30) null,
	[mirroring_partner] varchar(255) null,
	[availability_zone] varchar(125) null,
	[known_challenges] varchar(2000) null

	,[valid_from] DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
    ,[valid_to] DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
    ,PERIOD FOR SYSTEM_TIME ([valid_from],[valid_to])

	,constraint [pk_sma_inventory] primary key clustered ([sql_instance], [host_name])
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.sma_inventory_history))
go
alter table dbo.sma_inventory add constraint chk_sma_inventory__stability check ( [stability] in ('dev', 'uat', 'qa', 'stg', 'prod', 'proddr', 'stgdr','qadr', 'uatdr', 'devdr') )
go

/* ***** 2) Create table dbo.sma_oncall_teams ***************************** */
-- drop table [dbo].[sma_oncall_teams]
create table [dbo].[sma_oncall_teams]
(
	[team_name] varchar(125) not null,
	[description] varchar(500) not null,
	[team_lead_email] varchar(125) null,
	[team_lead_slack_account] varchar(125) null,
	[created_by] varchar(125) not null default suser_name(),
	[created_date_utc] smalldatetime not null default getutcdate()

	,constraint pk_sma_oncall_teams primary key clustered ([team_name])
)
go


/* ***** 3) Create table dbo.sma_oncall_schedule ***************************** */
-- drop table [dbo].[sma_oncall_schedule]
create table [dbo].[sma_oncall_schedule]
(
	[team_name] varchar(125) not null,
	[oncall_role] varchar(50) not null default 'primary', -- primary, secondary
	[oncall_email] varchar(125) null,
	[oncall_slack_account] varchar(125) null,
	[oncall_start_time] datetime2 not null,
	[oncall_end_time] datetime2 not null,

	[created_by] varchar(125) not null default suser_name(),
	[created_date_utc] smalldatetime not null default getutcdate()

	,index ci_sma_oncall_schedule clustered ([oncall_start_time],[oncall_end_time])
)
go


/* ***** 4) Create table dbo.sma_errorlog ***************************** */
-- drop table [dbo].[sma_errorlog]
create table [dbo].[sma_errorlog]
( 	[collection_time_utc] datetime2 not null default getutcdate(), 
	[sql_instance] varchar(255) null,
    [cmdlet] varchar(125) not null, 
	[command] varchar(1000) null, 
	[error] varchar(1000) not null, 
    [remark] varchar(1000) null

	,index [ci_sma_errorlog] clustered (collection_time_utc)
)
go


/* ***** 5) Create sequence object dbo.sma_alert_sequence ***************************** */
-- drop sequence dbo.sma_alert_sequence  
create sequence dbo.sma_alert_sequence  
    AS bigint start with 1 increment by 1 cycle cache 500;
go

/* ***** 6) Create table dbo.sma_alert ***************************** */
-- drop table [dbo].[sma_alert]
create table [dbo].[sma_alert]
(	[id] bigint not null constraint DF__sma_alert__id default next value for dbo.sma_alert_sequence,
	[created_date_utc] datetime2 not null default sysutcdatetime(),
	[alert_key] varchar(255) not null,
	[alert_owner_team] varchar(125) not null, -- 'DBA'
	[state] varchar(15) not null default 'Active', -- 'Active','Suppressed','Cleared', 'Resolved'
	[severity] varchar(15) not null default 'High', -- 'Critical', 'High', 'Medium', 'Low'
	--[email_to] varchar(500) not null,
	--[last_occurred_date_utc] datetime not null default getutcdate(),
	--[last_notified_date_utc] datetime not null default getutcdate(),
	--[notification_counts] int not null default 1,
	[suppress_start_date_utc] datetime null,
	[suppress_end_date_utc] datetime null
    --[servers_affected] varchar(1000) null
)
go
alter table dbo.sma_alert add constraint pk_sma_alert primary key (id)
go
alter table dbo.sma_alert add constraint chk_sma_alert__state check ( [state] in ('Active','Suppressed','Cleared','Resolved') )
go
alter table dbo.sma_alert add constraint chk_sma_alert__severity check ( [severity] in ('Critical', 'High', 'Medium', 'Low') )
go
alter table dbo.sma_alert add constraint chk_sma_alert__suppress_state 
	check ( (case	when	[state] <> 'Suppressed'
					then	1
					when	[state] = 'Suppressed'
							and ( suppress_start_date_utc is null or suppress_end_date_utc is null )
					then	0
					when	[state] = 'Suppressed'
							and ( datediff(day,suppress_start_date_utc,suppress_end_date_utc) >= 7 )
					then	0
					else	1
					end) = 1 )
go
create index ix_sma_alert__alert_key__active on dbo.sma_alert (alert_key) where [state] in ('Active','Suppressed')
go
create unique index uq_sma_alert__alert_key__severity__active on dbo.sma_alert (alert_key, severity, alert_owner_team) where [state] in ('Active','Suppressed')
go
create index ix_sma_alert__created_date_utc__alert_key on dbo.sma_alert (created_date_utc, alert_key)
go
create index ix_sma_alert__state__active on dbo.sma_alert ([state]) where [state] in ('Active','Suppressed')
go
--create index ix_sma_alert__servers_affected on dbo.sma_alert ([servers_affected]);
--go


/* ***** 7) Create table dbo.sma_alert_rules ***************************** */
-- drop table [dbo].[sma_alert_rules]
create table dbo.sma_alert_rules
(	rule_id bigint identity(1,1) not null,
	alert_key varchar(255) not null,
	server_friendly_name varchar(255) null,
	[database_name] varchar(255) null,
	client_app_name varchar(255) null,
	login_name varchar(125) null,
	client_host_name varchar(255) null,
	severity varchar(15) null,
	severity_low_threshold decimal(5,2) null,
	severity_medium_threshold decimal(5,2) null,
	severity_high_threshold decimal(5,2) null,
	severity_critical_threshold decimal(5,2) null,
	alert_owner_team varchar(125) not null, /* Alert Owner */
	delay_minutes smallint null,
	compute_duration_minutes smallint null,
	[start_date] date null,
	[start_time] time null,
	[end_date] date null,
	[end_time] time null,
	copy_dba bit not null default 1,
	created_by varchar(125) not null default suser_name(),
	created_date_utc datetime not null default getutcdate(),
	reference_request varchar(125) not null,
    is_active bit not null default 1
	
	,valid_from DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
    ,valid_to DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
    ,PERIOD FOR SYSTEM_TIME (valid_from,valid_to)

	,constraint pk_sma_alert_rules__rule_id primary key clustered (rule_id)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.sma_alert_rules_history));
go
create unique nonclustered index nci_uq_sma_alert_rules__alert_key__plus on dbo.sma_alert_rules 
    (alert_key, server_friendly_name, [database_name], client_app_name, login_name, client_host_name, severity) where is_active = 1;
go
alter table dbo.sma_alert_rules add constraint chk_sma_alert_rules__severity check ( [severity] in ('Critical', 'High', 'Medium', 'Low') )
go
--alter table dbo.sma_alert_rules add constraint chk_sma_alert_rules__group_by check ( server_friendly_name is null or server_owner is null )
--go


/* ***** 8) Create table dbo.sma_alert_history ***************************** */
-- drop table [dbo].[sma_alert_history]
create table [dbo].[sma_alert_history]
(	[log_time] datetime2 not null default sysutcdatetime(),
	[alert_id] bigint not null,
	[logger] varchar(125) not null,	
    --[servers_affected] varchar(1000) null
	[header] varchar(500) not null,
	[description] nvarchar(max) null
)
go

/* ***** 9) Create table dbo.sma_alert_affected_servers ***************************** */
-- drop table dbo.sma_alert_affected_servers
create table [dbo].[sma_alert_affected_servers]
(
	[alert_id] bigint not null,
	[sql_instance] varchar(255) null,
	[host_name] varchar(255) null

	,index ci_sma_alert_affected_servers clustered ([alert_id])
)
go



