<# 
   This script will pick a folder structure where each folder represent a team\share
   and process each separately, doing the the filtered reports generation and html reports
   construction
#>

#[Cmdletbinding()]

Write-host "Filtering folders"

# pick each folder, if fileshareinventory csv exist, run the filter-reports against it in full mode (filter and generate reports)
foreach($dir in (Get-ChildItem -Directory -Path .\ -Recurse)){
    $file = Get-ChildItem -File -Path $dir.FullName -Filter *FileShareInventory*
    if ($file){
            & "$($PSScriptRoot)\Filter-Reports.ps1" -Path "$($dir.fullname)" -Verbose       
    }
 }
 #Write-host "File too big that were processed are listed here: $($logPath+'ToBigToProcess.log')"