<#
	The sample scripts are not supported under any Microsoft standard support 
	program or service. The sample scripts are provided AS IS without warranty  
	of any kind. Microsoft further disclaims all implied warranties including,  
	without limitation, any implied warranties of merchantability or of fitness for 
	a particular purpose. The entire risk arising out of the use or performance of  
	the sample scripts and documentation remains with you. In no event shall 
	Microsoft, its authors, or anyone else involved in the creation, production, or 
	delivery of the scripts be liable for any damages whatsoever (including, 
	without limitation, damages for loss of business profits, business interruption, 
	loss of business information, or other pecuniary loss) arising out of the use 
	of or inability to use the sample scripts or documentation, even if Microsoft 
	has been advised of the possibility of such damages.
#>
<# 
    .DESCRIPTION
        Will remove all created html reports files and recreate them by crawling the folders
        you can manually tune the $maxSize to process files over 10485760(10MB)
        $TooBigLogPath will tell where to save non processed file list

        Note: any file with extension .html in the path where script is run, will be deleted.

        Put this script along with the Create-FileShareReport_ftc files set under the same folder
        example C:\scripts
        then CD into the path where folders with the csv are located, like d:\allreports
        and run like c:\scripts\Recreate-Rerports.ps1

        Author: Francesco Poli | fpoli@microsoft.com
		Release: 2017/06/04

    .PARAMETER $TooBigLogPath 
        where to save the ToBigToBeProcessed log files,if not specified is .\
        
    .PARAMETER $maxSize 
        max aggregate csv files size, above that size, the reports will not generated

    .EXAMPLE
        Recreate-Reports.ps1 -TooBigLogPath c:\log\
        Recreate-Reports.ps1 -maxSize 104857600

#>

[Cmdletbinding()]
Param (
     [Parameter(Mandatory=$false)][string] $TooBigLogPath= ".\",
     [Parameter(Mandatory=$false)][int] $maxSize=10485760
)
Write-host "RE-Generating HTML reports"
$logPath = ".\"
$maxSize=10485760

# first DELETE all the html files
Get-ChildItem -Filter *.html -Recurse | Remove-Item

# Recreate the HTML files
foreach($dir in (Get-ChildItem -Directory -Path .\ -Recurse)){
    #foreach($dir in (Get-ChildItem -Directory -Path $splitFolder.FullName)){
        $file = Get-ChildItem -File -Path $dir.FullName
        if ($file){
            $size=0
            foreach($f in $file) {
                $size += $f.length
            }
            if ($size -lt $maxSize){
                 & "$($PSScriptRoot)\Create-FileshareReport_ftc.ps1" -Path $($dir.fullname)
            }
            else{
                $notDone = "Not Done: $($dir.FullName)"
                $notDone | Out-File ($logPath+'ToBigToProcess.log') -Append
            }
        }
     #}
 }
 Write-host "File too big that were processed are listed here: $($logPath+'ToBigToProcess.log')"