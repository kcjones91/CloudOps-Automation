param(
    [Parameter(Mandatory=$false)]
    [string]$VMName,
    
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$false)]
    [string]$TicketNumber,
    
    [Parameter(Mandatory=$false)]
    [string]$SnapshotResourceGroup,
    
    [Parameter(Mandatory=$false)]
    [switch]$MultipleVMs,
    
    [Parameter(Mandatory=$false)]
    [string]$VMList
)

# Fail if no ticket number provided
if ([string]::IsNullOrEmpty($TicketNumber)){
    throw "ERROR: Ticket number is required. Use -TicketNumber parameter."
}

# Check Azure connection before proceeding
Write-Output "Verifying Azure connection..."
$context = Get-AzContext
if (-not $context) {
    throw "No Azure context found. Please run 'Connect-AzAccount'."
}

# Verify we can actually make calls
try {
    $subscription = Get-AzSubscription -SubscriptionId $context.Subscription.Id -ErrorAction Stop
    Write-Output "Connected to Azure subscription: $($subscription.Name)"
} catch {
    throw "Azure authentication expired or invalid. Please run 'Connect-AzAccount'."
}

# If no snapshot resource group provided, use the same as VM resource group
if ([string]::IsNullOrEmpty($SnapshotResourceGroup)) {
    $SnapshotResourceGroup = $ResourceGroupName
    Write-Output "No snapshot resource group specified. Using VM resource group: $SnapshotResourceGroup"
}

# Initialize summary tracking for multiple VMs
$summaryReport = @()
$totalVMs = 0
$successfulVMs = 0
$failedVMs = 0
$skippedSnapshots = 0
$createdSnapshots = 0

# Determine which VMs to process
$VMsToProcess = @()

if ($MultipleVMs) {
    if ([string]::IsNullOrEmpty($VMList)) {
        throw "ERROR: When using -MultipleVMs flag, you must provide -VMList parameter with comma-separated VM names."
    }
    $VMsToProcess = $VMList -split ',' | ForEach-Object { $_.Trim() }
    Write-Output "Processing multiple VMs: $($VMsToProcess -join ', ')"
    $totalVMs = $VMsToProcess.Count
} else {
    if ([string]::IsNullOrEmpty($VMName)) {
        throw "ERROR: You must provide either -VMName for single VM or -MultipleVMs with -VMList for multiple VMs."
    }
    $VMsToProcess = @($VMName)
    Write-Output "Processing single VM: $VMName"
}

# Process each VM
foreach ($CurrentVMName in $VMsToProcess) {
    Write-Output ""
    Write-Output ("="*50)
    Write-Output "Processing VM: $CurrentVMName"
    Write-Output ("="*50)
    
    # Initialize VM-specific tracking
    $vmResult = [PSCustomObject]@{
        VMName = $CurrentVMName
        Status = "Unknown"
        OSSnapshotCreated = $false
        OSSnapshotName = ""
        OSSnapshotSkipped = $false
        DataSnapshots = @()
        ErrorMessage = ""
    }
    
    # Get the VM
    Write-Output "Getting VM details for: $CurrentVMName"
    $vm = Get-AzVM -Name $CurrentVMName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    
    if ($vm) {
        Write-Output "VM found: $($vm.Name) in location: $($vm.Location)"
        
        # Create timestamp for snapshot names (with seconds for uniqueness)
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        
        # Create OS disk snapshot
        Write-Output "Creating OS disk snapshot..."
        $osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
        $osDiskName = $vm.StorageProfile.OsDisk.Name
        $osSnapshotName = "$osDiskName-snapshot-$TicketNumber-$timestamp"
        $vmResult.OSSnapshotName = $osSnapshotName
        
        # Check if snapshot already exists
        $existingSnapshot = Get-AzSnapshot -ResourceGroupName $SnapshotResourceGroup -SnapshotName $osSnapshotName -ErrorAction SilentlyContinue
        if ($existingSnapshot) {
            Write-Warning "OS disk snapshot '$osSnapshotName' already exists. Skipping creation."
            $vmResult.OSSnapshotSkipped = $true
            $skippedSnapshots++
        } else {
            try {
                $osSnapshotConfig = New-AzSnapshotConfig -SourceUri $osDiskId -Location $vm.Location -CreateOption Copy
                $osSnapshot = New-AzSnapshot -Snapshot $osSnapshotConfig -SnapshotName $osSnapshotName -ResourceGroupName $SnapshotResourceGroup
                Write-Output "OS disk snapshot created: $osSnapshotName"
                $vmResult.OSSnapshotCreated = $true
                $createdSnapshots++
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-Error "Failed to create OS disk snapshot for ${CurrentVMName}: $errorMessage"
                $vmResult.ErrorMessage = "OS Snapshot: $errorMessage"
                $vmResult.Status = "Failed"
                $failedVMs++
                $summaryReport += $vmResult
                continue
            }
        }
        
        # Create data disk snapshots
        if ($vm.StorageProfile.DataDisks.Count -gt 0) {
            Write-Output "Creating data disk snapshots..."
            foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
                $dataDiskId = $dataDisk.ManagedDisk.Id
                $dataDiskName = $dataDisk.Name
                $dataSnapshotName = "$dataDiskName-snapshot-$TicketNumber-$timestamp"
                
                $dataSnapshotResult = [PSCustomObject]@{
                    DiskName = $dataDiskName
                    SnapshotName = $dataSnapshotName
                    LUN = $dataDisk.Lun
                    Created = $false
                    Skipped = $false
                    Error = ""
                }
                
                # Check if snapshot already exists
                $existingDataSnapshot = Get-AzSnapshot -ResourceGroupName $SnapshotResourceGroup -SnapshotName $dataSnapshotName -ErrorAction SilentlyContinue
                if ($existingDataSnapshot) {
                    Write-Warning "Data disk snapshot '$dataSnapshotName' already exists. Skipping creation."
                    $dataSnapshotResult.Skipped = $true
                    $skippedSnapshots++
                } else {
                    try {
                        $dataSnapshotConfig = New-AzSnapshotConfig -SourceUri $dataDiskId -Location $vm.Location -CreateOption Copy
                        $dataSnapshot = New-AzSnapshot -Snapshot $dataSnapshotConfig -SnapshotName $dataSnapshotName -ResourceGroupName $SnapshotResourceGroup
                        Write-Output "Data disk snapshot created: $dataSnapshotName (LUN: $($dataDisk.Lun))"
                        $dataSnapshotResult.Created = $true
                        $createdSnapshots++
                    }
                    catch {
                        $errorMessage = $_.Exception.Message
                        Write-Error "Failed to create data disk snapshot for ${dataDiskName} on ${CurrentVMName}: $errorMessage"
                        $dataSnapshotResult.Error = $errorMessage
                    }
                }
                
                $vmResult.DataSnapshots += $dataSnapshotResult
            }
        } else {
            Write-Output "No data disks found on $CurrentVMName"
        }
        
        # Determine overall VM status
        if ([string]::IsNullOrEmpty($vmResult.ErrorMessage)) {
            $vmResult.Status = "Success"
            $successfulVMs++
        }
        
        Write-Output "Snapshot creation completed for $CurrentVMName!"
    } else {
        Write-Error "VM not found: $CurrentVMName in resource group: $ResourceGroupName"
        $vmResult.Status = "VM Not Found"
        $vmResult.ErrorMessage = "VM not found in resource group $ResourceGroupName"
        $failedVMs++
    }
    
    $summaryReport += $vmResult
}

Write-Output ""
Write-Output "Snapshot Summary:"
if ($createdSnapshots -eq 0 -and $skippedSnapshots -eq 0) {
    Write-Output "No snapshots were created."
} else {
    foreach ($result in $summaryReport) {
        Write-Output "VM: $($result.VMName) | Status: $($result.Status)"
        
        if ($result.Status -eq "Success" -or $result.Status -eq "Failed") {
            # OS Disk Info
            if ($result.OSSnapshotCreated) {
                Write-Output "  OS Disk: $($result.OSSnapshotName.Split('-')[0]) | Snapshot ID: $($result.OSSnapshotName) | Status: Completed"
            } elseif ($result.OSSnapshotSkipped) {
                Write-Output "  OS Disk: $($result.OSSnapshotName.Split('-')[0]) | Snapshot ID: $($result.OSSnapshotName) | Status: Skipped"
            }
            
            # Data Disk Info
            foreach ($dataSnap in $result.DataSnapshots) {
                if ($dataSnap.Created) {
                    Write-Output "  Data Disk LUN $($dataSnap.LUN): $($dataSnap.DiskName) | Snapshot ID: $($dataSnap.SnapshotName) | Status: Completed"
                } elseif ($dataSnap.Skipped) {
                    Write-Output "  Data Disk LUN $($dataSnap.LUN): $($dataSnap.DiskName) | Snapshot ID: $($dataSnap.SnapshotName) | Status: Skipped"
                } else {
                    Write-Output "  Data Disk LUN $($dataSnap.LUN): $($dataSnap.DiskName) | Snapshot ID: N/A | Status: Failed"
                }
            }
        } else {
            Write-Output "  Error: $($result.ErrorMessage)"
        }
    }
}

if ($MultipleVMs) {
    Write-Output ""
    Write-Output "Operation Summary:"
    Write-Output "Ticket Number: $TicketNumber"
    Write-Output "Total VMs Processed: $totalVMs"
    Write-Output "Successful VMs: $successfulVMs"
    Write-Output "Failed VMs: $failedVMs" 
    Write-Output "Total Snapshots Created: $createdSnapshots"
    Write-Output "Total Snapshots Skipped: $skippedSnapshots"
}
