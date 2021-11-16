$ClientCertificate = Get-Item Cert:\CurrentUser\My\Thumbprint
$ClientID=''
$TenantID=''
$MailboxToImpersonate="test@test.com"
$recipient="Test2@test.com"

#install-module MSAL.PS
$token = Get-MsalToken -ClientId  $ClientID`
                       -TenantId  $TenantID`
                       -ClientCertificate $ClientCertificate `
                        -Scope 'https://outlook.office365.com/.default'

    If ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
        [Net.ServicePointManager]::SecurityProtocol += [Net.SecurityProtocolType]::Tls12
        Write-Host "Enabled Tls1.2 in '[Net.ServicePointManager]::SecurityProtocol'" -ForegroundColor Yellow
    }

#region ews

#CHECK FOR EWS MANAGED API, IF PRESENT IMPORT THE HIGHEST VERSION EWS DLL, ELSE EXIT
$EWSDLL = ("C:\Program Files\ews\Microsoft.Exchange.WebServices.dll")
Import-Module $EWSDLL -DisableNameChecking -ErrorAction Stop
#endregion

#Create EWS Object
$ews = New-Object Microsoft.Exchange.WebServices.Data.ExchangeService -ArgumentList "Exchange2013_SP1" -ErrorAction Stop
$ews.UseDefaultCredentials = $False
$ews.Credentials = [Microsoft.Exchange.WebServices.Data.OAuthCredentials]$token.AccessToken
$ews.url = "https://outlook.office365.com/EWS/Exchange.asmx"

$ews.ImpersonatedUserId = New-Object Microsoft.Exchange.WebServices.Data.ImpersonatedUserId([Microsoft.Exchange.WebServices.Data.ConnectingIdType]::SMTPAddress,$MailboxToImpersonate );

#Connect to the Inbox and display basic statistics
$InboxFolder= new-object Microsoft.Exchange.WebServices.Data.FolderId([Microsoft.Exchange.WebServices.Data.WellKnownFolderName]::Inbox,$ImpersonatedMailboxName)
$Inbox = [Microsoft.Exchange.WebServices.Data.Folder]::Bind($ews,$InboxFolder)
 

 $folderid= new-object Microsoft.Exchange.WebServices.Data.FolderId([Microsoft.Exchange.WebServices.Data.WellKnownFolderName]::SentItems,$ImpersonatedMailboxName)   
  $SentItems = [Microsoft.Exchange.WebServices.Data.Folder]::Bind($ews,$folderid)
  $EmailMessage = New-Object Microsoft.Exchange.WebServices.Data.EmailMessage -ArgumentList $ews  
  $EmailMessage.Subject = "test ews"
  #Add Recipients    
  $EmailMessage.ToRecipients.Add($recipient)  
  $EmailMessage.Body = New-Object Microsoft.Exchange.WebServices.Data.MessageBody  
  $EmailMessage.Body.BodyType = [Microsoft.Exchange.WebServices.Data.BodyType]::HTML  
  $EmailMessage.Body.Text = "Body"  
  $EmailMessage.From = $ImpersonatedMailboxName
 
  $EmailMessage.SendAndSaveCopy($SentItems.Id) 


  $folderid= new-object Microsoft.Exchange.WebServices.Data.FolderId([Microsoft.Exchange.WebServices.Data.WellKnownFolderName]::Contacts,$ImpersonatedMailboxName)   
 $contacts = [Microsoft.Exchange.WebServices.Data.Folder]::Bind($ews,$folderid)
  $ivItemView =  New-Object Microsoft.Exchange.WebServices.Data.ItemView($contacts.TotalCount)  
  
$fiItems = $ews.FindItems($contacts.Id,$ivItemView)  
