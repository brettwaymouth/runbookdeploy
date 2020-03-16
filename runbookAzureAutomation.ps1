#The following is an Azure Automation PowerShell runbook.
#Uses a preconfigured AutomationConnection object (AzureRunAsConnection) for authentication
#This object must be in place in your tenant with the appropriate role(s), and added as a connection asset in the
#Azure Automation account being used.
#Test

Param(
 [Parameter(Mandatory=$true)]
 [string]$subscriptionId,

 [Parameter(Mandatory=$true)]
 [string]$location,

 [Parameter(Mandatory=$true)]
 [string]$targetResourceGroupName,

 [Parameter(Mandatory=$true)]
 [string]$templateFileName,

 [Parameter(Mandatory=$true)]
 [string]$templateParametersFileName

 )

#Set standard template configuration
$templateResourceGroupName = "RG1"
$templateStorageAccountName = "bwstorage10"
$templateStorageContainer = "templates"

# Create timestamp and get automation connection
$timestamp = $(get-date -f MM-dd-yyyy_HH_mm_ss)
$conn = Get-AutomationConnection -Name 'AzureRunAsConnection'

# Authenticate Azure account and set subscription
Add-AzureRmAccount -ServicePrincipal -TenantId $conn.TenantId -ApplicationId $conn.ApplicationId -CertificateThumbprint $conn.CertificateThumbprint
Select-AzureRmSubscription -SubscriptionId $subscriptionId

# Create Resource group if it does not already exist
$rg = Get-AzureRmResourceGroup -Name $targetResourceGroupName -ev notPresent -ea 0
$rg
if(!$rg) {
    New-AzureRmResourceGroup -Name $targetResourceGroupName -Location $location
}

#Get a collection of any existing locks on the resource group, remove locks, store name and locklevel
Write-Output "Get the collection of any existing resource group locks, and remove them."
$existingLocks = Get-AzureRmResourceLock -ResourceGroupName $targetResourceGroupName | Select-Object @{Name="LockName";Expression={$_.Name}}, @{Name="LockLevel";Expression={$_.Properties.Level}}
$existingLocks | Remove-AzureRmResourceLock -ResourceGroupName $targetResourceGroupName -ErrorVariable removeLockError -ErrorAction SilentlyContinue -Force
if($removeLockError) {
    $RemoveLockError | ForEach-Object {Write-Output $_.Exception.Message}
}

# Get storage context, shared access tokens, and template blob
$context = (Get-AzureRmStorageAccount -Name $templateStorageAccountName -ResourceGroupName $templateResourceGroupName).Context
$templateSasToken = New-AzureStorageContainerSASToken -Container $templateStorageContainer -Context $context -StartTime ([System.DateTime]::UtcNow).AddMinutes(-2) -ExpiryTime ([System.DateTime]::UtcNow).AddMinutes(60) -Permission r
$scriptSasToken = New-AzureStorageContainerSASToken -Container $scriptStorageContainer -Context $context -StartTime ([System.DateTime]::UtcNow).AddMinutes(-2) -ExpiryTime ([System.DateTime]::UtcNow).AddMinutes(60) -Permission r
$templateBlob = Get-AzureStorageBlob -Context $context -Container $templateStorageContainer -Blob $templateFileName
$templatesContainerUri = ($context.BlobEndPoint + $templateStorageContainer)

# CONFIGURE DEPLOYMENT
if($templateParametersFileName) {
    Write-Output "Parameter file specified, continuing with deployment..."
    $templateUri = $templateBlob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri

    #Get parameter blob and save it to disk
    $parameterBlob = Get-AzureStorageBlob -Context $context -Container $templateStorageContainer -Blob $templateParametersFileName
    $parameterBlob | Get-AzureStorageBlobContent -Destination $env:TEMP -Context $context -Force
    $pathToFile = ($env:TEMP + "\" + $templateParametersFileName)

    # Add sas tokens to parameter file if required
    $templateUri = $templateBlob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri + $templateSasToken
    
    # DEPLOY TEMPLATE WITH PARAMETER FILE
    New-AzureRmResourceGroupDeployment -Name $timestamp -ResourceGroupName $targetResourceGroupName -Mode Incremental `
        -TemplateUri $templateUri `
        -TemplateParameterFile $pathToFile `
        -Force -Verbose
}
else {
  Write-Output "Parameter file not specified... SasToken required... continuing with deployment..."

  # formulate template uri with sas token
  $templateUri = $templateBlob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri + $templateSasToken

  # DEPLOY WITHOUT PARAMETER FILE WITH SAS TOKENS
  New-AzuurcreRmResoeGroupDeployment -Name $timestamp -ResourceGroupName $targetResourceGroupName -Mode Incremental `
      -TemplateUri $templateUri `
      -Force -Verbose
} 

# delete locally save parameter file if necessary
if ($templateParametersFileName) {
    Remove-Item $pathToFile
}

# if any existing resource group locks were found, re-apply to the resource group.
Write-Output "Re-apply any existing resource group locks."
if($existingLocks) {
    $existingLocks | Select-Object LockName, LockLevel, @{Name="LockNotes";Expression={$_.LockName + ": " + $_.LockLevel }} | `
    New-AzureRmResourceLock -ResourceGroupName $targetResourceGroupName -Verbose -Force -ErrorVariable addLockError -ErrorAction SilentlyContinue
}

if($addLockError) {
    $addLockError | ForEach-Object {Write-Output $_.Exception.Message}
}
