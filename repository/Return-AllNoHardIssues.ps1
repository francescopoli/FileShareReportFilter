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
        Take in input the FileShareInventoryLog and generate a csv with all the file shares
        that have no hard failures
        Will create a file in the same path from where the script is called, named noIssuesFileShare.csv

		Author: Francesco Poli | fpoli@microsoft.com
		Release: 2017/06/08

    .PARAMETER $FileShareInventoryLog 
        path for the FileShareInventory file

    .EXAMPLE
        Return-AllNoHardIssues -FileShareInventoryLog c:\folder\fileshareinventory.csv
#>
Param (
    [Parameter(Mandatory=$true)][string] $FileShareInventoryLog
)

$noIssue = Import-Csv $FileShareInventoryLog
$noIssue=$noIssue |where{($_.File_IsCrossed256CharsCount -eq 0) -and ($_.Folder_IsCrossed256CharsCount -eq 0) -and ($_.FileCountGreaterThanThresholdMB -eq 0)}
$noIssue | Export-Csv .\noIssuesFileShare.csv -NoTypeInformation