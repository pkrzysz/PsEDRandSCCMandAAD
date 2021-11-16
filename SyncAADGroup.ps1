#used to sync group membership of aad security group (fe. from local ad)
#to Azure ad group (fe. role granting group)

$tenantId = '' # Paste your own tenant ID here
$ApplicationID = ""
$AccessSecret = ""

$groupSource='Group Source AD'
$groupTarget='Group Destination AAD'
#region access token

$resourceAppIdUri = 'https://graph.microsoft.com'
$oAuthUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
$body = [Ordered] @{
    resource = "$resourceAppIdUri"
    client_id = "$ApplicationID"
    client_secret = "$AccessSecret"
    grant_type = 'client_credentials'
}
$response = Invoke-RestMethod -Method Post -Uri $oAuthUri -Body $body -ErrorAction Stop
$aadToken = $response.access_token


#endregion
#region function definition
<#
.Synopsis
   Synchronizes Azure AD Group with role assigment
.DESCRIPTION
   Synchronizes Azure AD Group with role assigment
   Required permission are:
   Directory.Read.All
   GroupMemeber.ReadWrite.All
   RoleManagement.ReadWrite.Directory

.EXAMPLE
   Simple usage
   Sync-AADGroups -groupSource 'GOU-66810' -groupTarget 'RG_Security_Readers' -authtoken $aadToken -Verbose
.EXAMPLE
   Verbose output
   Sync-AADGroups -groupSource $groupSource -groupTarget $groupTarget -authtoken $aadToken -Verbose
#>
function Sync-AADGroups
{
    [CmdletBinding()]
    [Alias()]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        $groupSource,

        # Param2 help description
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=1)]
        $groupTarget,
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=1)]
        $authtoken
    )

    Begin
    {
    $headers = @{ 
    'Content-Type' = 'application/json'
    Authorization = "Bearer $authtoken" 
    }
    write-verbose $headers
    $url = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName%20eq%20'$groupSource'"
    $groupSourceObj = (Invoke-RestMethod -Headers $headers -Uri $URL -Method GET -UseBasicParsing).value
    if ($null -eq $groupSourceObj.id) {Write-Error "Source group not found"; break}
    $url = "https://graph.microsoft.com/v1.0/groups/$($groupSourceObj.id)/members"  
    $groupSourceObjMembers = (Invoke-RestMethod -Headers $headers -Uri $URL -Method GET -UseBasicParsing).value 

    $url = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName%20eq%20'$groupTarget'"
    $groupTargetObj = (Invoke-RestMethod -Headers $headers -Uri $URL -Method GET -UseBasicParsing).value
    if ($null -eq $groupTargetObj.id) {Write-Error "Target group not found";break}
    $url = "https://graph.microsoft.com/v1.0/groups/$($groupTargetObj.id)/members"  
    $groupTargetObjMembers = (Invoke-RestMethod -Headers $headers -Uri $URL -Method GET -UseBasicParsing).value 
    Write-Verbose  ("Retrived {0} Source Group Members and {1} Destination group members" -f  $groupSourceObjMembers.Count,$groupTargetObjMembers.Count)
    }
    Process
    {
        if ($null -ne $groupSourceObj -and $null -ne $groupTargetObj)
        {
        $targetids=$groupTargetObjMembers | select -ExpandProperty id
        $sourceids=$groupSourceObjMembers | select -ExpandProperty id

        $url = "https://graph.microsoft.com/v1.0/groups/$($groupTargetObj.id)/members/`$ref"  
            write-verbose ("Will process {0} additions" -f ($groupSourceObjMembers | where id -NotIn $targetids).count)
            #additions
            foreach ($missing in ($groupSourceObjMembers | where id -NotIn $targetids))
            {
            $body = ConvertTo-Json -InputObject @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($missing.id)" }
            $webResponse = Invoke-WebRequest -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop -UseBasicParsing
            }
        $url = "https://graph.microsoft.com/v1.0/groups/$($groupTargetObj.id)/members/{0}/`$ref"  

            write-verbose ("will process {0} deletions" -f ($groupTargetObjMembers | where id -NotIn $sourceids).count)
            #deletion
            foreach ($surplus in ($groupTargetObjMembers | where id -NotIn $sourceids))
            {
            $webResponse = Invoke-WebRequest -Method Delete -Uri ($url -f $surplus.id) -Headers $headers  -ErrorAction Stop -UseBasicParsing
            }
        }else
        {
         write-error ( "Nothing to process = source or destination null")
        }
    }
    End
    {
    }
}
#endregion

Sync-AADGroups -groupSource $groupSource -groupTarget $groupTarget -authtoken $aadToken -Verbose
