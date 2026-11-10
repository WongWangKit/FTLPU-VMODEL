param([Parameter(Mandatory=$true)][int]$RootPid)
$ErrorActionPreference = 'Stop'
$all = @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name)
$ids = [System.Collections.Generic.HashSet[int]]::new()
[void]$ids.Add($RootPid)
do {
    $added = $false
    foreach ($entry in $all) {
        if ($ids.Contains([int]$entry.ParentProcessId) -and $ids.Add([int]$entry.ProcessId)) { $added = $true }
    }
} while ($added)
$owned = @($all | Where-Object {$ids.Contains([int]$_.ProcessId)} | ForEach-Object {
    $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $p) {
        [pscustomobject]@{pid=$_.ProcessId;ppid=$_.ParentProcessId;name=$_.Name;cpu_seconds=$p.CPU;working_set_bytes=$p.WorkingSet64;private_bytes=$p.PrivateMemorySize64}
    }
})
$os = Get-CimInstance Win32_OperatingSystem
@{checked_at=(Get-Date -Format o);root_pid=$RootPid;processes=$owned;physical_free_kib=$os.FreePhysicalMemory;physical_total_kib=$os.TotalVisibleMemorySize;commit_free_kib=$os.FreeVirtualMemory;commit_limit_kib=$os.TotalVirtualMemorySize;system_drive_free_bytes=(Get-PSDrive C).Free} | ConvertTo-Json -Depth 4 -Compress
