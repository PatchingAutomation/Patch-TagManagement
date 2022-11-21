param(
    [Parameter(mandatory=$true)]
    [ValidateSet('query', 'set')]
    [string]$Action,

    [parameter(mandatory=$false)]
    [string]$VariableName,

    [parameter(mandatory=$false)]
    [string]$ServerTaglist,

    [parameter(mandatory=$true)]
    [string]$Subs,

    [parameter(mandatory=$true)]
    [string]$AutomationAccount,

    [parameter(mandatory=$true)]
    [string]$AutomationAccountRG
)

#Initial variables
$UTagServers = @()
$TagServers = @()

Function GetUnTagVMs($VirtualMachines){
    $temp = @()
    $VMs = @()
    $PriUPATServers = @()
	if([String]::IsNullOrEmpty($VirtualMachines)){
        $VMs=Get-AzVM -Status | where PowerState -eq "VM running"
    }else{
        foreach($VM in $VirtualMachines){
            $temp=Get-AzVM -Name $VM
            $VMs+=$temp
        }	
	}
    foreach ($vm in $VMs){
        if($vm.type -eq "Microsoft.Compute/virtualMachines"){
            if(($vm.Tags.Keys|?{$_ -like "UpdateManagement*"}) -eq $null){
                $PriUPATServers += $vm
            }
        }
    }
    return $PriUPATServers
}
Function SetTag($VirtualMachinesHask){
    $temp = @()
    $VMs = @()
    $PriTagedPATServers = @()
	if([String]::IsNullOrEmpty($VirtualMachinesHask)){
        write-output 'Please fill in the "TagVariable" for each server role in Json Format' 
    }else{
        foreach($VM in $VirtualMachinesHask.Keys){
            $temp=Get-AzVM -Name $VM
            if($temp.type -eq "Microsoft.Compute/virtualMachines"){
                #if(($temp.Tags.Keys|?{$_ -like "UpdateManagement*"}) -eq $null){
                    $mergedTag = @{$VirtualMachinesHask[$VM].Key = $VirtualMachinesHask[$VM].Value}
                    $result = Update-AzTag -ResourceId $temp.id -Tag $mergedTag -Operation Merge
                    $PriTagedPATServers += $temp.Name
                #}
            }
        }	
	}
    return $PriTagedPATServers 
}
Function AddVariable($ServerList,$Subs,$AA,$RG,$AzureContext){
    $PriServersHash = @{}
    foreach ($Server in $ServerList){
        $PriServersHash[$Server] = @{Key='UpdateManagement.others';Value='Update_Role'}
    }
    $PriVariableString = $PriServersHash | ConvertTo-Json
    
    $AzAutomationVariable= Get-AzAutomationVariable -Name "TagTempVariable" -ErrorAction SilentlyContinue -AutomationAccountName $AA -ResourceGroupName $RG -DefaultProfile $AzureContext
    if($AzAutomationVariable -eq $null) {  
        New-azAutomationVariable -Name "TagTempVariable" -Encrypted $False -AutomationAccountName $AA -ResourceGroupName $RG -Value $PriVariableString -DefaultProfile $AzureContext
    }
    else {
        Set-azAutomationVariable -Name "TagTempVariable" -Encrypted $False -AutomationAccountName $AA -ResourceGroupName $RG -Value $PriVariableString -DefaultProfile $AzureContext
    }
}
Function SetTagCSV($VirtualMachinesCSV){
    $temp = @()
    $VMs = @()
    $PriTagedPATServers = @()
	if([String]::IsNullOrEmpty($VirtualMachinesCSV)){
        write-output 'Please fill in the "TagVariable" for each server role in Json Format' 
    }else{
        foreach($VirtualMachineCSV in $VirtualMachinesCSV){
            $VM = $VirtualMachineCSV.split(",")[0]
            $key = $VirtualMachineCSV.split(",")[1]
            $Value = $VirtualMachineCSV.split(",")[2]
            $temp=Get-AzVM -Name $VM -ErrorVariable SilentlyContinue
            if($temp){
                if($temp.type -eq "Microsoft.Compute/virtualMachines"){
                    #if(($temp.Tags.Keys|?{$_ -like "UpdateManagement*"}) -eq $null){
                        $mergedTag = @{$key = $Value}
                        $result = Update-AzTag -ResourceId $temp.id -Tag $mergedTag -Operation Merge
                        $PriTagedPATServers += $temp.Name
                    #}
                }
            }
        }	
	}
    return $PriTagedPATServers 
}

#******************************************************************************
<# Main Script Start #>
#******************************************************************************
try{
    $Taghash = @{}
    $ExitCode = 0
    $TagJsonData = ""

    #========Login ============
    if ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT) {
        Write-Output "Get the AzureContext from Azure Runbook"
        $AzureContext = (Connect-AzAccount -Identity).context
        $Local = $false    
    }else{
        Set-StrictMode -Version Latest
        $here = if($MyInvocation.MyCommand.PSObject.Properties.Item("Path") -ne $null){(Split-Path -Parent $MyInvocation.MyCommand.Path)}else{$(Get-Location).Path}
        pushd $here
        Write-Output "This script ConfigScheduleUpdate running locally"
        if(Test-Path "$here\azurecontext.json"){
            $AzureContext = Import-AzContext -Path "$here\azurecontext.json"
        }else{
            $AzureContext = Connect-AzAccount -ErrorAction Stop
            Save-AzContext -Path "$here\azurecontext.json"
        }
        $Local = $true
    }

	if($VariableName){
		if($Local){
            $content = Get-AzAutomationVariable -Name $VariableName -ResourceGroupName $AutomationAccountRG -AutomationAccountName $AutomationAccount -ErrorAction SilentlyContinue
            $TagJsonData = $content.Value | ConvertFrom-Json
        }else{
            $content = Get-AutomationVariable -Name $VariableName -ErrorAction SilentlyContinue
            $TagJsonData = $content | ConvertFrom-Json
        } 
		foreach($property in $TagJsonData.PSObject.Properties){
            $Taghash[$property.Name]=$property.Value
        }
	}

	$Worker = $env:COMPUTERNAME
	Write-output "Running the script from $Worker"

    #query if Sever contains PAT tags
    if ($Action -eq "query"){
        $UTagServers = (GetUnTagVMs -VirtualMachines $Taghash.keys).Name | sort

        if($UTagServers -ne $null){
            Write-Output "Information: The following servers don't have PAT Tag:"
            $UTagServers
            Write-Output "Information: Generating Variable: 'TagTempVariable' for these servers"
            AddVariable $UTagServers $Subs $AutomationAccount $AutomationAccountRG $AzureContext
            Write-Output "Fix Step 1: Please open Azure Portal and choose Automaction Account:$AutomationAccount under SUbscription:$Subs."
            Write-Output "Fix Step 2: Please update variable 'TagTempVariable' with roles for these servers, you can refer to variable 'TagStdVariable' as standard."
            Write-Output "Fix Step 3: Run the Runbook 'Tag-Management' with parameters: Action: 'Set' and VariableName: 'TagTempVariable' and choose Hybrid Worker."
            $ExitCode = 1
        }else{
            Write-Output "No server found."
        }

    }    

    #set tags for servers batch
    if ($Action -eq "set"){
        if($ServerTaglist){
            $csv = gc $ServerTaglist
            $TagServers = SetTagCSV -VirtualMachinesCSV $csv
            if($TagServers -ne $null){
                Write-Output "The following servers have been updated with PAT Tag successfully"
                Write-Output $TagServers
            }else{
                Write-Output $Taghash
                Write-Output "No server need to update."
            }  

        }else{
            $TagServers = SetTag -VirtualMachinesHask $Taghash
            if($TagServers -ne $null){
                Write-Output "The following servers have been updated with PAT Tag successfully"
                Write-Output $TagServers
            }else{
                Write-Output $Taghash
                Write-Output "No server need to update."
            }   
        }
    }
    
    if ($ExitCode -ne 0) {throw "Tag Management execution failed."}  
}
catch{
    write-output "Error Message: $($_.Exception)"
    throw "Tag Management execution failed."
}