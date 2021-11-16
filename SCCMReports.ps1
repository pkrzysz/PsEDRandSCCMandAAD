#allowed OUs
$allowedOU="OU=Workstations,OU=Company,DC=company,DC=com"
$sccmserver="server"

#allow tls 1.2
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

#region get ad data
$adc=Get-ADComputer -LDAPFilter "(&(!operatingSystem=*server*))" -SearchBase $allowedOU -Properties lastLogonTimestamp,lastLogon,pwdLastSet,badPasswordTime,logonCount,operatingSystem,whenCreated,operatingSystem
$adcdict=@{}
#sanitize the data
$adc=$adc| Select name,@{Name="lastLogon";Expression={[datetime]::FromFileTimeUtc($_.'lastLogon')}},@{Name="lastLogonTimestamp";Expression={[datetime]::FromFileTimeUtc($_.'lastLogonTimestamp')}},@{Name="pwdLastSet";Expression={[datetime]::FromFileTimeUtc($_.'pwdLastSet')}},
             @{Name="badPasswordTime";Expression={[datetime]::FromFileTimeUtc($_.'badPasswordTime')}},logonCount,operatingSystem,whenCreated ,distinguishedName 
#put the data in dict
$adc| %{$adcdict.Add($_.distinguishedName,$_)}
"Obtained $($adc.Count) number of workstations from AD"

#endregion
#region get sccm data
$sccmData=Invoke-RestMethod -Uri "https://$sccmserver/adminservice/v1.0/Device" -UseDefaultCredentials 

#sanity check to verify if sccm connection is ok
if ($sccmData.value.Count -gt 5000)
{
    "Processing $($sccmData.value.Count) number of workstations for detailed data"

    $start=get-date
#region process data from scccm

    #get resources
    $sccmSystem= Invoke-RestMethod -Uri "https://$sccmserver/AdminService/wmi/SMS_R_System" -UseDefaultCredentials 
    $sccmSystemMap=@{}
    $sccmSystemMapRID=@{}
    $sccmSystem.value | select Name,DistinguishedName,ResourceID,CreationDate,@{n='OSBranch';e={switch ($_.OSBranch)
                                                                              {
                                                                                  0 {'CB or Semi-Annual Channel (Targeted)'}
                                                                                  1 {'CBB or Semi-Annual Channel)'}
                                                                                  2 {'LTSB'}
                                                                                  Default {'Other'}
                                                                              }}} |where DistinguishedName -ne $null |%{
            if ($sccmSystemMap.Contains($_.DistinguishedName))
                {
                 if ($sccmSystemMap[$_.DistinguishedName].CreationDate -lt $_.CreationDate)
                    {
                    $sccmSystemMap.Remove($_.DistinguishedName)
                    $sccmSystemMap.Add($_.DistinguishedName,$_)
                    }
                }
            else{
                $sccmSystemMap.Add($_.DistinguishedName,$_)
                }
        }
   
    $sccmSystem.value | %{ $sccmSystemMapRID.add($_.ResourceID,$_.DistinguishedName)}
    "Processed $($sccmSystem.value.Count) number of workstations for ad correlation"

    
    #get model
    $sccmComputerSystem= Invoke-RestMethod -Uri "https://$sccmserver/AdminService/wmi/SMS_G_System_COMPUTER_SYSTEM" -UseDefaultCredentials 
    $sccmComputerSystemMap=@{}
    $sccmComputerSystem.value | select ResourceID,@{n='Manufacturer';e={if ($_.Manufacturer -like 'HP'){'Hewlett-Packard'}else{$_.Manufacturer}}},Model | %{$sccmComputerSystemMap.Add($_.ResourceID,$_)}
    "Processed $($sccmComputerSystem.value.Count) number of workstations for model information"

    #get chasisInfo
    $sccmSystemenClosure= Invoke-RestMethod -Uri "https://$sccmserver/AdminService/wmi/SMS_G_System_SYSTEM_ENCLOSURE" -UseDefaultCredentials 
    $sccmLaptop=@("8","9","10","11","12","14","30","31","32")
    $sccmDesktop=@("3", "4", "5", "6", "7","13", "15", "16","24","33","34","35","36")
    $sccmServerS=@("17","18","23","28")
    $sccmSystemenClosureMap=@{}
    $sccmSystemenClosure.value| where ChassisTypes -NE 12 |select  ResourceID,SerialNumber,
                                    ChassisTypes, @{n='Name';e={$nameID[$_.ResourceID]}},
                                    @{n='Chasis';e={switch ($_.ChassisTypes)
                                                    {
                                                        {$_ -in $sccmLaptop} {'Laptop'}
                                                        {$_ -in $sccmDesktop} {'Desktop'}
                                                        {$_ -in $sccmServerS} {'Server'}
                                                        Default {'Other'}
                                                    } }} | %{$sccmSystemenClosureMap.add($_.ResourceID,$_)}
    "Processed $($sccmSystemenClosure.value.Count) number of workstations for chasis information"

    #get OS
    $sccmOperatingSystem= Invoke-RestMethod -Uri "https://$sccmserver/AdminService/wmi/SMS_G_System_OPERATING_SYSTEM" -UseDefaultCredentials 
    $sccmOperatingSystemMap=@{}
    $sccmOperatingSystem.value | select @{n='ResourceID';e={$_.'@odata.etag'.split(';')[1]}},
                                    Version,BuildNumber,RevisionID,OperatingSystemSKU,LastBootUpTime,
                                    InstallDate, @{n='Name';e={$nameID[$_.ResourceID]}} |
                                    %{ 
                                        if ($sccmOperatingSystemMap.Contains($_.ResourceID)) {
                                         if ($sccmOperatingSystemMap[$_.ResourceID].LastBootUpTime -lt $_.LastBootUpTime)
                                         {
                                         $sccmOperatingSystemMap.Remove($_.ResourceID)
                                         $sccmOperatingSystemMap.add($_.ResourceID,$_)
                                         }
                                        }else{
                                            $sccmOperatingSystemMap.add($_.ResourceID,$_)
                                        }
                                      }
        "Processed $($sccmOperatingSystem.value.Count) number of workstations for os"

    #get Model
    $sccmProduct= Invoke-RestMethod -Uri "https://$sccmserver/AdminService/wmi/SMS_G_System_COMPUTER_SYSTEM_PRODUCT" -UseDefaultCredentials 
    $sccmProductmap=@{}
    $sccmProduct.value | where vendor -like 'LENOVO'| select ResourceID,Version| % {$sccmProductmap.Add($_.ResourceID,$_.Version)}
    "Processed $($sccmProduct.value.Count) number of workstations for serviceTag"

#endregion
#region generate basic data   
    "Obtained data in {0}, starting generating data" -f ((get-date) - $start)

    $basicData=@{}
    foreach ($sccmHost in ($sccmData.value | where {$sccmSystemMapRID[$_.MachineId] -like "*$allowedOU"} ))
    {
    
    $LastSyncNowRequest=$null
    $LastClientCheckTime=$null
    $ADLastLogonTime=$null
    $LastActiveTime=$null
    $CNLastOnlineTime=$null
    $CNLastOfflineTime=$null
    $LastStatusMessage=$null
    $LastPolicyRequest=$null
    $LastDDR=$null
    $LastHardwareScan=$null
    $LastSoftwareScan=$null
    $LastActiveTime=$null
    $CA_ComplianceSetTime=$null
    $CA_ComplianceEvalTime=$null
    $EP_AntivirusSignatureUpdateDateTime=$null
    $EP_AntispywareSignatureUpdateDateTime=$null
    $EP_LastFullScanDateTimeStart=$null
    $EP_LastFullScanDateTimeEnd=$null
    $EP_LastQuickScanDateTimeStart=$null
    $EP_LastQuickScanDateTimeEnd=$null
    $EP_LastInfectionTime=$null
    $ATP_LastConnected=$null

    if ($sccmHost.LastSyncNowRequest){$LastSyncNowRequest= [datetime] $sccmHost.LastSyncNowRequest}
    if ($sccmHost.LastClientCheckTime){$LastClientCheckTime= [datetime] $sccmHost.LastClientCheckTime}
    if ($sccmHost.ADLastLogonTime){$ADLastLogonTime= [datetime] $sccmHost.ADLastLogonTime}
    if ($sccmHost.LastActiveTime){$LastActiveTime= [datetime] $sccmHost.LastActiveTime}
    if ($sccmHost.CNLastOnlineTime){$CNLastOnlineTime= [datetime]  $sccmHost.CNLastOnlineTime}
    if ($sccmHost.CNLastOfflineTime){$CNLastOfflineTime= [datetime] $sccmHost.CNLastOfflineTime}
    if ($sccmHost.LastStatusMessage){$LastStatusMessage= [datetime] $sccmHost.LastStatusMessage}
    if ($sccmHost.LastPolicyRequest){$LastPolicyRequest= [datetime] $sccmHost.LastPolicyRequest}
    if ($sccmHost.LastDDR){$LastDDR= [datetime] $sccmHost.LastDDR}
    if ($sccmHost.LastHardwareScan){$LastHardwareScan= [datetime] $sccmHost.LastHardwareScan}
    if ($sccmHost.LastSoftwareScan){$LastSoftwareScan= [datetime] $sccmHost.LastSoftwareScan}
    if ($sccmHost.LastActiveTime){$LastActiveTime= [datetime] $sccmHost.LastActiveTime}
    if ($sccmHost.CA_ComplianceSetTime){$CA_ComplianceSetTime= [datetime] $sccmHost.CA_ComplianceSetTime}
    if ($sccmHost.CA_ComplianceEvalTime){$CA_ComplianceEvalTime= [datetime] $sccmHost.CA_ComplianceEvalTime}
    if ($sccmHost.EP_AntivirusSignatureUpdateDateTime){$EP_AntivirusSignatureUpdateDateTime= [datetime] $sccmHost.EP_AntivirusSignatureUpdateDateTime}
    if ($sccmHost.EP_AntispywareSignatureUpdateDateTime){$EP_AntispywareSignatureUpdateDateTime= [datetime] $sccmHost.EP_AntispywareSignatureUpdateDateTime}
    if ($sccmHost.EP_LastFullScanDateTimeStart){$EP_LastFullScanDateTimeStart= [datetime] $sccmHost.EP_LastFullScanDateTimeStart}
    if ($sccmHost.EP_LastFullScanDateTimeEnd){$EP_LastFullScanDateTimeEnd= [datetime] $sccmHost.EP_LastFullScanDateTimeEnd}
    if ($sccmHost.EP_LastQuickScanDateTimeStart){$EP_LastQuickScanDateTimeStart= [datetime] $sccmHost.EP_LastQuickScanDateTimeStart}
    if ($sccmHost.EP_LastQuickScanDateTimeEnd){$EP_LastQuickScanDateTimeEnd= [datetime] $sccmHost.EP_LastQuickScanDateTimeEnd}
    if ($sccmHost.EP_LastInfectionTime){$EP_LastInfectionTime= [datetime] $sccmHost.EP_LastInfectionTime}
    if ($sccmHost.ATP_LastConnected){$ATP_LastConnected= [datetime] $sccmHost.ATP_LastConnected} 
    $primaryuser=$null
    if($sccmHost.PrimaryUser){
                        if ($sccmHost.PrimaryUser.length -gt 100)
                            {$primaryuser=$sccmHost.PrimaryUser.substring(0,98)}
                            else
                            {$primaryuser=$sccmHost.PrimaryUser}
                    }else{$null}
        $basicData.Add($sccmSystemMapRID[$sccmHost.MachineId], @{
        MachineId=$sccmHost.MachineId
        ArchitectureKey=$sccmHost.ArchitectureKey
        Name=$sccmHost.Name
        SMSID=$sccmHost.SMSID
        SiteCode=$sccmHost.SiteCode
        Domain=$sccmHost.Domain
        ClientEdition=$sccmHost.ClientEdition
        ClientType=$sccmHost.ClientType
        ClientVersion=$sccmHost.ClientVersion
        IsClient=$sccmHost.IsClient
        IsObsolete=$sccmHost.IsObsolete
        IsActive=$sccmHost.IsActive
        IsVirtualMachine=$sccmHost.IsVirtualMachine
        IsAOACCapable=$sccmHost.IsAOACCapable
        DeviceOwner=$sccmHost.DeviceOwner
        DeviceCategory=$sccmHost.DeviceCategory
        WipeStatus=$sccmHost.WipeStatus
        RetireStatus=$sccmHost.RetireStatus
        SyncNowStatus=$sccmHost.SyncNowStatus
        LastSyncNowRequest=$LastSyncNowRequest
        ManagementAuthority=$sccmHost.ManagementAuthority
        AMTStatus=$sccmHost.AMTStatus
        AMTFullVersion=$sccmHost.AMTFullVersion
        SuppressAutoProvision=$sccmHost.SuppressAutoProvision
        IsApproved=$sccmHost.IsApproved
        IsBlocked=$sccmHost.IsBlocked
        IsAlwaysInternet=$sccmHost.IsAlwaysInternet
        IsInternetEnabled=$sccmHost.IsInternetEnabled
        ClientCertType=$sccmHost.ClientCertType
        UserName=$sccmHost.UserName
        LastClientCheckTime=$LastClientCheckTime
        ClientCheckPass=$sccmHost.ClientCheckPass
        ADSiteName=$sccmHost.ADSiteName
        UserDomainName=$sccmHost.UserDomainName
        ADLastLogonTime=$ADLastLogonTime
        ClientRemediationSuccess=$sccmHost.ClientRemediationSuccess
        ClientActiveStatus=$sccmHost.ClientActiveStatus
        LastStatusMessage=$LastStatusMessage
        LastPolicyRequest=$LastPolicyRequest
        LastDDR=$LastDDR
        LastHardwareScan=$LastHardwareScan
        LastSoftwareScan=$LastSoftwareScan
        LastMPServerName=$sccmHost.LastMPServerName
        LastActiveTime=$LastActiveTime
        CP_Status=$sccmHost.CP_Status
        CP_LatestProcessingAttempt=$sccmHost.CP_LatestProcessingAttempt
        CP_LastInstallationError=$sccmHost.CP_LastInstallationError
        EAS_DeviceID=$sccmHost.EAS_DeviceID
        DeviceOS=$sccmHost.DeviceOS
        DeviceOSBuild=$sccmHost.DeviceOSBuild
        DeviceType=$sccmHost.DeviceType
        ExchangeServer=$sccmHost.ExchangeServer
        ExchangeOrganization=$sccmHost.ExchangeOrganization
        PolicyApplicationStatus=$sccmHost.PolicyApplicationStatus
        LastSuccessSyncTimeUTC=$sccmHost.LastSuccessSyncTimeUTC
        PhoneNumber=$sccmHost.PhoneNumber
        DeviceAccessState=$sccmHost.DeviceAccessState
        EP_DeploymentState=$sccmHost.EP_DeploymentState
        EP_DeploymentErrorCode=$sccmHost.EP_DeploymentErrorCode
        EP_DeploymentDescription=$sccmHost.EP_DeploymentDescription
        EP_PolicyApplicationState=$sccmHost.EP_PolicyApplicationState
        EP_PolicyApplicationErrorCode=$sccmHost.EP_PolicyApplicationErrorCode
        EP_PolicyApplicationDescription=$sccmHost.EP_PolicyApplicationDescription
        EP_Enabled=$sccmHost.EP_Enabled
        EP_ClientVersion=$sccmHost.EP_ClientVersion
        EP_ProductStatus=$sccmHost.EP_ProductStatus
        EP_EngineVersion=$sccmHost.EP_EngineVersion
        EP_AntivirusEnabled=$sccmHost.EP_AntivirusEnabled
        EP_AntivirusSignatureVersion=$sccmHost.EP_AntivirusSignatureVersion
        EP_AntivirusSignatureUpdateDateTime=$EP_AntivirusSignatureUpdateDateTime
        EP_AntispywareEnabled=$sccmHost.EP_AntispywareEnabled
        EP_AntispywareSignatureVersion=$sccmHost.EP_AntispywareSignatureVersion
        EP_AntispywareSignatureUpdateDateTime=$EP_AntispywareSignatureUpdateDateTime
        EP_LastFullScanDateTimeStart=$EP_LastFullScanDateTimeStart
        EP_LastFullScanDateTimeEnd=$EP_LastFullScanDateTimeEnd
        EP_LastQuickScanDateTimeStart=$EP_LastQuickScanDateTimeStart
        EP_LastQuickScanDateTimeEnd=$EP_LastQuickScanDateTimeEnd
        EP_InfectionStatus=$sccmHost.EP_InfectionStatus
        EP_PendingFullScan=$sccmHost.EP_PendingFullScan
        EP_PendingReboot=$sccmHost.EP_PendingReboot
        EP_PendingManualSteps=$sccmHost.EP_PendingManualSteps
        EP_PendingOfflineScan=$sccmHost.EP_PendingOfflineScan
        EP_LastInfectionTime=$EP_LastInfectionTime
        EP_LastThreatName=$sccmHost.EP_LastThreatName
        CNIsOnline=$sccmHost.CNIsOnline
        CNLastOnlineTime=$CNLastOnlineTime
        CNLastOfflineTime=$CNLastOfflineTime
        CNAccessMP=$sccmHost.CNAccessMP
        CNIsOnInternet=$sccmHost.CNIsOnInternet
        ClientState=$sccmHost.ClientState
        Unknown=$sccmHost.Unknown
        ATP_LastConnected=$ATP_LastConnected
        ATP_SenseIsRunning=$sccmHost.ATP_SenseIsRunning
        ATP_OnboardingState=$sccmHost.ATP_OnboardingState
        ATP_OrgId=$sccmHost.ATP_OrgId.length
        CA_IsCompliant=$sccmHost.CA_IsCompliant
        CA_ComplianceSetTime=$CA_ComplianceSetTime
        CA_ComplianceEvalTime=$CA_ComplianceEvalTime
        CA_ErrorDetails=$sccmHost.CA_ErrorDetails
        CA_ErrorLocation=$sccmHost.CA_ErrorLocation
        AADTenantID=$sccmHost.AADTenantID
        AADDeviceID=$sccmHost.AADDeviceID
        PasscodeResetState=$sccmHost.PasscodeResetState
        PasscodeResetStateTimeStamp=$sccmHost.PasscodeResetStateTimeStamp
        RemoteLockState=$sccmHost.RemoteLockState
        RemoteLockStateTimeStamp=$sccmHost.RemoteLockStateTimeStamp
        ActivationLockBypassState=$sccmHost.ActivationLockBypassState
        ActivationLockBypassStateTimeStamp=$sccmHost.ActivationLockBypassStateTimeStamp
        ActivationLockState=$sccmHost.ActivationLockState
        IsSupervised=$sccmHost.IsSupervised
        DeviceThreatLevel=$sccmHost.DeviceThreatLevel
        SerialNumber=$sccmHost.SerialNumber
        IMEI=$sccmHost.IMEI
        PrimaryUser=$primaryuser
        CurrentLogonUser=$sccmHost.CurrentLogonUser
        LastLogonUser=$sccmHost.LastLogonUser
        MACAddress=$sccmHost.MACAddress
        SMBIOSGUID=$sccmHost.SMBIOSGUID
        CoManaged=$sccmHost.CoManaged
        IsMDMActive=$sccmHost.IsMDMActive

        })

    }
    #endregion
#region advancedProcessing
    $AdvancedData=@{}
    foreach ($sc in $sccmSystemMap.Keys) {
    $scSM=$sccmSystemMap[$sc]
    $scCs=$sccmComputerSystemMap[$scSm.ResourceId]
    $scSC=$sccmSystemenClosureMap[$scSm.ResourceId]
    $scOS=$sccmOperatingSystemMap[("{0}" -f $scSm.ResourceId)]
    $scPS=$sccmProductmap[$scSm.ResourceId]
    $model= if ($scCs.Manufacturer -like '*Lenovo*')    {$scPS}else {$scCs.Model}

    $AdvancedData.Add($scSM.DistinguishedName,   @{
    Name         = $scSM.Name
    ResourceId   = $scSM.ResourceId

    Manufacturer = $scCs.Manufacturer
    Model        = $model
    ModelFamily  = if($model) {if ($model.Contains(' ')) {$model.Substring(0,$model.IndexOf(' '))} else {$model}} else {$null}
    ModelName    = if($model){ if ($model.Contains(' ')) {$model.Substring($model.IndexOf(' ')+1)} else {$model}} else {$null}
    SerialNumber = $scSC.SerialNumber
    ChassisTypes = $scSC.ChassisTypes
    Chasis       = $scSC.Chasis

    Version            = $scOS.Version
    BuildNumber        = $scOS.BuildNumber
    Branch             = $scSM.OSBranch
    RevisionID         = $scOS.RevisionID

    LastBootUpTime     = if ($scOS.LastBootUpTime -ne $null){[datetime]$scOS.LastBootUpTime};
    OSInstallDate        = if ($scOS.InstallDate -ne $null){[datetime]$scOS.InstallDate};
    SCCMCreationDate =  if ($scSM.CreationDate -ne $null){[datetime]$scSM.CreationDate};

    })

    }
    #endregion 
    $stop=get-date
    "Processed in {0}. Starting analysis" -f ($stop - $start)
} else {exit}
 #cleanup unused memory
    $sccmSystem= $null
    $sccmSystemMap=$null
    $sccmSystemMapRID=$null
    $sccmComputerSystem= $null
    $sccmComputerSystemMap=$null
    $sccmSystemenClosure=$null
    $sccmSystemenClosureMap=$null
    $sccmOperatingSystem= $null
    $sccmOperatingSystemMap=$null
    $sccmProduct=$null
    $sccmProductmap=$null
    $sccmData=$null
    [gc]::Collect()
#endregion

#region process sccm healthcheck
 
#get AD not contacted ad for 90 days
 $notThereFor90days =$adc | select *, @{n='lastcontactdate';e={$_.lastLogon,$_.lastLogonTimestamp, $_.pwdLastSet, $_.badPasswordTime | sort | select -Last 1}} | where lastcontactdate -lt (get-date).AddDays(-90) 
 #$notThereFor90days |Out-GridView -Title "get not contacted ad for 90 days"

#get no client for 90 days, and live in ad
$noClient=$adc | 
                    where {$basicData[$_.distinguishedName].isClient -eq 0 -or $basicData[$_.distinguishedName].isClient -eq $null } | 
                    select name,whenCreated,operatingSystem,distinguishedName,                          
                           @{n='lastcontactdate';e={$_.lastLogon,$_.lastLogonTimestamp, $_.pwdLastSet, $_.badPasswordTime | sort | select -Last 1}},
                           @{n='sccm';e={$basicData[$_.distinguishedName]}}|
                    where lastcontactdate -ge (get-date).AddDays(-90)|
                    where {$_.whenCreated -lt (get-date).AddDays(-15)}
 #$noClient |select name,whenCreated,lastcontactdate,operatingSystem,{$_.sccm.isClient},distinguishedName| Out-GridView -Title 'No Data in SCCM'

#no data in sccm
$noDataInSccm=$adc | 
                    where {$basicData[$_.distinguishedName].isClient -eq 1} | 
                    select name,whenCreated,operatingSystem,distinguishedName,                          
                           @{n='lastcontactdate';e={$_.lastLogon,$_.lastLogonTimestamp, $_.pwdLastSet, $_.badPasswordTime | sort | select -Last 1}},
                           @{n='sccm';e={$basicData[$_.distinguishedName]}}|
                    where lastcontactdate -ge (get-date).AddDays(-90)|
                    where {$_.sccm.LastActiveTime -lt (get-date).AddDays(-90)}|
                    where {$_.whenCreated -lt (get-date).AddDays(-15)}
# $noDataInSccm |select name,whenCreated,lastcontactdate,{$_.sccm.LastActiveTime},{$_.sccm.CNLastOnlinetime},operatingSystem,distinguishedName| Out-GridView -Title 'No Data in SCCM'

#extract the data for other reports
$SCCMHealthyWorkstations=$adc | 
                    where {$basicData[$_.distinguishedName].isClient -eq 1} | 
                    select name,whenCreated,operatingSystem,distinguishedName,                          
                           @{n='lastcontactdate';e={$_.lastLogon,$_.lastLogonTimestamp, $_.pwdLastSet, $_.badPasswordTime | sort | select -Last 1}},
                           @{n='sccm';e={$basicData[$_.distinguishedName]}},
                           @{n='sccmAdv';e={$AdvancedData[$_.distinguishedName]}}|
                    where lastcontactdate -ge (get-date).AddDays(-90)|
                    where {$_.sccm.LastActiveTime -ge (get-date).AddDays(-90)}|
                    where {$_.whenCreated -lt (get-date).AddDays(-15)}

#get windows10 outdated versions
$olderwin10 = $SCCMHealthyWorkstations | where {$_.sccmadv.BuildNumber -lt 18363 -and $_.sccmadv.BuildNumber -ne $null} 
#$olderwin10 |select name,whenCreated,lastcontactdate,operatingsystem,{$_.sccmAdv.BuildNumber},{$_.sccm.CNLastOnlinetime},distinguishedName| Out-GridView -Title 'Older builds'

#get windows 10 never version
$newerOS=$SCCMHealthyWorkstations | where {$_.sccmadv.BuildNumber -gt 18363 -and $_.sccmadv.BuildNumber -ne 7601}
#$newerOS |select name,whenCreated,lastcontactdate,operatingsystem,{$_.sccmAdv.BuildNumber},{$_.sccm.CNLastOnlinetime},distinguishedName| Out-GridView -Title 'Never builds'



#endregion

#region process edr

#sccm missing
$missingOnSCCM=$SCCMHealthyWorkstations | where {$_.sccm.ATP_OnboardingState-eq 1 -and $_.sccm.EP_Enabled -ne $true}
$missingOnSCCM|select name,whenCreated,lastcontactdate,operatingsystem,{$_.sccm.LastActiveTime},{$_.sccm.ATP_OnboardingState},{$_.sccm.EP_Enabled},distinguishedName | Out-GridView -Title "Missing in SCCM"

#av version not updated
$avOutdated=$SCCMHealthyWorkstations | where {$_.sccm.ATP_OnboardingState-eq 1 -and $_.sccm.EP_Enabled -eq $true -and $_.sccm.EP_AntivirusSignatureUpdateDateTime -lt (get-date).AddDays(-60)}
$avOutdated|select name,whenCreated,lastcontactdate,{$_.sccm.LastActiveTime},{$_.sccm.EP_AntivirusSignatureUpdateDateTime},distinguishedName | Out-GridView -Title "AV Update missing"

#av not enabled
$avnotenabled=$SCCMHealthyWorkstations | where {$_.sccm.ATP_OnboardingState-eq 1 -and $_.sccm.EP_Enabled -eq $true -and -not ($_.sccm.EP_AntivirusEnabled -and $_.sccm.EP_AntispywareEnabled) }
$avnotenabled|select name,whenCreated,lastcontactdate,{$_.sccm.LastActiveTime},{$_.sccm.EP_AntivirusSignatureUpdateDateTime},distinguishedName | Out-GridView -Title "AV not enabled"


#client version not updated
$clientOutdated=$SCCMHealthyWorkstations | where {$_.sccmadv.BuildNumber -ge 18363 -and $_.sccm.ATP_OnboardingState-eq 1 -and $_.sccm.EP_Enabled -eq $true -and [int]$_.sccm.EP_ClientVersion.Split(".")[2] -lt [int]("{0:yyMM}" -f (get-date).AddMonths(-3))}
$clientOutdated|select name,whenCreated,lastcontactdate,{$_.sccm.LastActiveTime},{$_.sccm.EP_ClientVersion},@{n="ClientVersion";e={$_.sccm.EP_ClientVersion.Split(".")[2]}},distinguishedName | Out-GridView -Title "AV not enabled"

#endregion
