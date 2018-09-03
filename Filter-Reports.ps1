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
		The script puorpose is used to process the File Share Inventory report produced by the FastTrack File migration inventory tool
        Script will process all the files generated by the tool, and extract only the ones with a non auto-remediate error
        for instance:
        Folders : path longer than 350 chars
        Files: path longer than 350 chars or size greater than 2Gb
        Note: Not stripping out fields from the csv, only removing rows.
        
        If multiple files of same type are present, the script will pick them all, and consolidate in a single one after filtering
		
		Author: Francesco Poli | fpoli@microsoft.com
		Release: 2017/05/24
        2017/05/25: v1
        2017/05/26: v2 : use disks to buffer the report generation
        2017/05/27-30 : 
            $tunebuffering parameter
            modified output to include the -verbose output
            added -path parameter to force a directory, try process the local folder
		2017/11/15 : fixed the new column names with 350 chars
        2018/08/31: added the invalid file\folder invalid character and names in filtered report.
                    addded the -GenerateHTML parameter to trigger the reports generation(internal FTC only, usally to not be used)
 
        Contributors: 
        

	.PARAMETER $Path
        Files to be processed location, no path run from local folder
	.PARAMETER $MergeOnly
        Only consolidate the files but do not filter
    .PARAMETER $TuneBuffering
        Number of found errors that trigger a temp file creation, this should be a balance between memory and disks.
        if local discs are good, 2000 will make it pretty quick, increasing the value will make the RAM being used more
        aggressively, but something will be lost in performances anyway, due to how the array append happen in memory.
        Tested on an Azure f8s machine (8 cores, 16Gb ram) on a 770Mb file:
        value 2000: 0.2-0.5s per file creation, ram used per Pshell process ~5-6gb stable
        value 10000: 8s per file creation, ram used per Pshell process ~6Gb 
	.PARAMETER $Verbose
        Verbopse paramerter is suggested for additional on screen logging

    .EXAMPLE
        .\Filter-Reports.ps1 
        .\Filter-Reports.ps1 -Path C:\folderWhereFilesAreStored -verbose
        .\Filter-Reports.ps1 -MergeOnly
        .\Filter-Reports.ps1 -TuneBuffering 5000
        .\Filter-Reports.ps1 -SplitOnly 
#>
[Cmdletbinding()]
Param (
    [Parameter(Mandatory=$false)][String] $Path = $pwd,
    [Parameter(Mandatory=$false)][Switch] $MergeOnly,
    [Parameter(Mandatory=$false)][Switch] $SplitOnly,
    [Parameter(Mandatory=$false)][int] $TuneBuffering = 2000,
    [parameter(Mandatory=$false)][switch] $GenerateHTML
)

begin{
    $errorStyle = $ErrorActionPreference
    $ErrorActionPreference = "silentlycontinue"
    # runPath: where the fileshare, files and folders reports are located
    if ($Path -ne $pwd)
    {
        if ( -not(Test-Path $Path) ) 
        {
            Write-Host -ForegroundColor Black -BackgroundColor Red "Invalid path: $Path"
            exit
        }
        Else
        {
            if ($Path.EndsWith('\')){$Path = $Path.Remove($Path.Length-1,1)}
        }
    }

    [string] $Script:RunPath = $Path.ToString()
    # savePath: subfolder where the filtered and consolidated files will be stored
    if ( -not ($SplitOnly) ){
        [string] $Script:savePath = $Script:RunPath + '\filteredReports'
    }
    Write-Verbose "savePath start script: $Script:savePath "
    #used to rename merged report if already present
    $Script:ticks = (get-date).ticks #used to rename merged report if already present
 

<#
FilterReport function
    Process the incoming csv file, and export it to a filtered version
    based on the file content types:
        FileShare
        File
        FOlder
    The resulting file will contains:
    FileShare: only FileShare with: Files or Folder where path is longer than 350 chars or file bigger than 2GB (any of this conditions)
    File: only files that have path longer than 350 chars or file is bigger than 2gb
    Folders: only folders that have path longer than 350 chars

    Reports created in a subfolder where the script is executed, named \filteredReports
    For file and folders, is multiple files present, a cache temp folder will be created to store temp files,
    it start with _ and will be deleted after cache files merging
#>
    Function FilterReport{
    [Cmdletbinding()]
    param(
        [Parameter(Mandatory=$true)][string] $inventory,
        [Parameter(Mandatory=$true)]
        [ValidateSet("FileShareInventory","FileInventory","FolderInventory")][string] $type

        )

        $errors=0 #errors found
        $result=@() #resultant csv
        Write-Verbose "Importing CSV file"
        $readTime = Measure-Command -Expression {$entries = Import-Csv $Inventory}
        Write-Verbose ("File read Time {0}h:{1}m:{2}s" -f $readTime.Hours,$readTime.Minutes,$readTime.Seconds) 
    
        # Create temp folders to save partial files, required for improved performances
        # folder will be removed at the end
        if ( -not (Test-Path ($Script:savePath+'\_'+$inventory.split('\')[-1]) ) )
        {
            New-Item -ItemType Directory ($Script:savePath+'\_'+$inventory.split('\')[-1])
        }
        $bufferDir=$Script:savePath+'\_'+$inventory.split('\')[-1]
        $buffered=0 #keep track about if files need to be merged
    
        #time tracking
        $startDate = get-date
        $processDate = $startDate

        switch ($type)
        {
            "FileShareInventory"{
                #FileshareInventory is unlikely to have multiple files, quick processing
                foreach($entry in $entries)
                {
                    $error = [int]$entry.File_IsCrossed350CharsCount + [int]$entry.FileCountGreaterThanThresholdMB + [int]$entry.Folder_IsCrossed350CharsCount + [int]$entry.InvalidFileTypeCount  + [int]$entry.'File_InvalidCharactersCount(Auto-Remediated)' + [int]$entry.'InvalidFolderNamesCount(Auto-Remediated)' 
                    if ( ($error) -gt 0) 
                    {
                        $errors++
                        $result += $entry
                    }
                } 
            }

            "FolderInventory"{
                #folders and files require lot of processing for big file servers
                $done=0 #tracker for current progressions
                $count=0  #Splitter for file temp files
                Write-verbose "Start filtering folders: $($entries.count)"
                Write-Verbose  "Processed |  Errors |  Time"
                Write-Verbose  "============================"
            
                foreach($entry in $entries)
                {
                    $done++
                    if ( ($entry.IsCrossed350Chars -eq "TRUE") -or 
                         ($entry.'HasInvalidFolderNames(Auto-remediated)' -eq "TRUE") -or 
                         ($entry.'HasInvalidCharacters(Auto-remediated)' -eq "TRUE")  ) 
                    {
                        $count++
                        $errors++
                   
                        $result += $entry
                        # each $TuneBuffering errors, flush to temp file and reset array
                        # reset counter, calculate time taken for $TuneBuffering errs
                        if ($count -ge $TuneBuffering)
                        {
                            $tt = (Get-Date).Subtract($startDate)
                            #keeping the cache file name unique
                            $result | Export-Csv -Path ($bufferDir+'\FolderInventory'+(get-date).ticks+'.csv') -NoTypeInformation -Encoding UTF8
                            $result = @() 
                            $buffered++
                            $count=0
                            Write-Verbose  ("$($done) | $($errors) | Time for {0} errors: {1}h:{2}m:{3}s:{4}ms" -f $($TuneBuffering),$tt.Hours,$tt.Minutes,$tt.Seconds,$tt.Milliseconds) 
                            $startDate = Get-Date
                        }
                    }
                }
            }

            "FileInventory"{
                #folders and files require lot of processing for big file servers
                $done=0 #tracker for current progressions
                $count=0  #Splitter for file temp files
                Write-Verbose "Start filtering files: $($entries.count)"
                Write-Verbose  "Processed |  Errors |  Time"
                Write-Verbose  "============================"
            
                foreach($entry in $entries)
                {
                    $done++
                    if ( ($entry.IsCrossed350Chars -eq "TRUE") -or  ($entry.'Greater than 2GB' -eq "TRUE")   -or  ($entry.'IsInvalidFileType' -eq "TRUE") -or ($entry.'HasInvalidCharacters(Auto-remediated)' -eq "TRUE") ) 
                    {
                        $count++
                        $errors++
                   
                        $result += $entry
                        # each $TuneBuffering errors, flush to temp file and reset array
                        # reset counter, calculate time taken for $TuneBuffering errs
                        if ($count -ge $TuneBuffering)
                        {
                            $tt=(Get-Date).Subtract($startDate)
                            #keeping the cache file name unique
                            $result | Export-Csv -Path ($bufferDir+'\FileInventory'+(get-date).ticks+'.csv') -NoTypeInformation -Encoding UTF8
                            $result=@() 
                            $buffered++
                            $count=0
                            Write-Verbose  ("$($done) | $($errors) | Time for {0} errors: {1}h:{2}m:{3}s:{4}ms" -f $($TuneBuffering),$tt.Hours,$tt.Minutes,$tt.Seconds,$tt.Milliseconds) 
                            $startDate=get-date
                        }
                    }
                } 
            }       
            default {Write-Host -ForegroundColor Black -BackgroundColor Red "Invalid report type: $type"}
        }
        $endProcess=(Get-Date).Subtract($processDate)
    
        Write-Host -ForegroundColor Green "End filtering, processing took: " `
                                          ("{0}h:{1}m:{2}s:{3}ms" -f $endProcess.Hours,$endProcess.Minutes,$endProcess.Seconds,$endProcess.Milliseconds)
        write-host -ForegroundColor red "Problematic items in $inventory : "$errors
    
        #Save filtered items to a file, check $result value as it may be null and all bufferized
        if ($result) {
            $result | export-csv -Path ($Script:savePath+'\'+$inventory.split('\')[-1]) `
                                 -NoTypeInformation -Encoding UTF8 -Append
        }
        # if data were bufferized, consolidate all files into a single one and delete the temp files
        if ( $buffered -gt 0)
        {
            $files=(get-childItem $bufferDir )
            Write-Verbose "Files to merge: $($Files.count)" 
            $mergeCount=0
            foreach($f in $files)
            {    
                #result is kept from previous processing cycle, because it may contain no flushed data
                $append = Import-Csv -Path $f.FullName
                if ($append){
                    #$result += $append
                    $append | export-csv -Path ($Script:savePath+'\'+$inventory.split('\')[-1]) `
                                         -NoTypeInformation -Encoding UTF8 -Append
                }
                Write-Verbose  "$($mergeCount++) Merged: $($f.FullName)"
            }
            #$result | export-csv  -Path ($Script:savePath+'\'+$inventory.split('\')[-1]) -NoTypeInformation -Encoding UTF8 -Append
            #delete temporary folder and files
        
        }
        Write-Host -ForegroundColor Green "File $inventory done."
        #cleanup the caching folder, if any
        Remove-Item -Path $bufferDir -Recurse -ErrorAction silentlycontinue
        #forcing garbage collection to try to free up some resources
        $result = $null
        $entries = $null
        $count = $null
        $append=$null
        [System.GC]::Collect()
    }

<#
MergeReports function
    receive a list of files of specific scope (fileshare, file or folders) and  consolidate them
    in a single file, per type
    Output will be positioned into a \consolidate folder    
#>
    Function MergeReports{
    [Cmdletbinding()]
    param( 
        [Parameter(Mandatory=$true)][array] $filesList,
        [Parameter(Mandatory=$true)]
        [ValidateSet("FileShareInventory","FileInventory","FolderInventory")][string] $type
    )
        $merged=@()
        $append=@()
        if ( $filesList ) {
            write-host "Merging: "$filesList.Count
            #if foldere already exist, rename and create a new one
            if ( (Test-Path $Script:savePath+'\merged\'+$type+'.csv') )
            { 
                Rename-Item -Path $Script:savePath+'\merged\'+$type+'.csv' `
                            -NewName $Script:savePath+'\merged\'+$Script:ticks+'_'+$type+'.csv'
            }
            if ($filesList.Count -eq 1){
                copy-item -Path $filesList[0].FullName `
                          -Destination ($Script:savePath+'\merged\'+$type+'.csv')
            }
            else{
                foreach($f in $filesList)
                {   
                    $append = Import-Csv -Path $f.FullName
                    if ($append){
                        #$consolidated += $append
                        $append | export-csv  -Path ($Script:savePath+'\merged\'+$type+'.csv') `
                                              -NoTypeInformation -Encoding UTF8 -Append
                    }
                    write-Verbose "File processed: $($f.FullName)"
                }
            }
            #$consolidated | export-csv -Path ($Script:savePath+'\consolidated\'+$type+'.csv') -NoTypeInformation -Encoding UTF8
            Write-Host -ForegroundColor green "File ready: " ($Script:savePath+'\merged\'+$type+'.csv')
        }
        $merged=$null
        $append=$null
    }


<#
SplitReport function
    Function pick main set FileShareInventory,FileInventory and FoldersInventory and split them
    per users or teams: Assuming the last folder in the path is the users folder or team folder
#>
    function SplitReport{
    [Cmdletbinding()]
    param(
        [Parameter(Mandatory=$True)][string]$FileShareInventory="",
        [Parameter(Mandatory=$True)][string]$FileInventory="",
        [Parameter(Mandatory=$True)][string]$FolderInventory="",
        [Parameter(Mandatory=$True)][string]$outputFolder
    )


        <#
            # v parse the FileShareReport and create a folder for each FileShare 
            # v using the fileshare due to the consolidated view it hold -> help bypassing checks when processing files and folders reports
            # v note: expect to have the same entries for UNCPath in all 3 files, files,fileshare and folders
            #         - shall be good as long as i expect the call coming from a contelled fucntion and not a manual invocation
            # v note2: what about when report was run against 2 different servers and them have the same folders
            #         - wil have them in same folder, better if customer run 1 report per file server
            # note2.1: create a folder path based on server name and last folder? shall include also middle tier folders?
            #          - keep first part of the path as main folder name, deeper path structure for the future
            # note3: add a script parameter to input where the split shall occour, or create the full directory forest structure?
            #        -same as comment above
            # note4: adding the check if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory} in files and folder processing,
            #        prior tu flush the buffer, is something that make my heath bleed 'cause is so damn heavy, anyway for a report i had entries 
            #        that were not in the flieshareinventory, reason still to be investigated, meanwhile cry:on
        #>
        if (Test-Path $FileShareInventory) {
            $fileshare = Import-Csv $FileShareInventory
            forEach($fs in $fileshare)
            {
                $splitted = $fs.UNCPath.split('\')
                if ( $splitted[0].Contains(':') ){ 
                    $server= $outputFolder+'\'+$splitted[0].Chars(0) #assuming path like D: and picking up D
                }
                else{ 
                    $server = $outputFolder+'\'+$splitted[2] #accounting for \\
                }
                $localFolder = $splitted[-1]
                if ( -not(Test-Path ($server) ) ){ New-Item ($server) -ItemType Directory}

                if ( -not(Test-Path ("$server\$localFolder")) ) 
                {
                    New-Item ("$server\$localFolder") -ItemType Directory
                }
                $fs | Export-csv -Path "$server\$localFolder\FileShareInventory.csv" -NoTypeInformation -Encoding UTF8
            }
        }
 

        <#
            Neither Folders or Files are guaranteed to be sorted, and just in case they are not, playing
            safe by flushing items to disk each 2000 items or when file\folder change
        #>
        if (Test-Path $FolderInventory) {
            $folders = Import-Csv $FolderInventory
            Write-Host -ForegroundColor Cyan "Creating folders reports, $($folders.count) items to process"
            $Count = 0
            [string]$last= ""
            [string]$current= ""
            $buffer=@()
            $Error.Clear()
            forEach($fold in $folders)
            {
                $splitted = $fold.UNCPath.split('\')
                if ( $splitted[0].Contains(':') ){ 
                    $server= $outputFolder+'\'+$splitted[0].Chars(0) #assuming path like D: and picking up D
                }
                else{ 
                    $server = $outputFolder+'\'+$splitted[2] #accounting for \\
                }
                $localFolder = $splitted[-1]
                $current = "$server\$localFolder"
    
                if ($current -ne $last)
                {
                    if($buffer)
                    {
                        Write-Verbose "Flushing $($buffer.Count) folders to disk"
                        #if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory}
                        $buffer | Export-csv -Path "$last\FolderInventory.csv" -NoTypeInformation -Encoding UTF8 -Append -ErrorAction SilentlyContinue -ErrorVariable ev
                        if ($ev){ 
                            if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory} 
                            $buffer | Export-csv -Path "$last\FolderInventory.csv" -NoTypeInformation -Encoding UTF8 -Append 
                        } 
                        $count+=$buffer.Count
                        $buffer=@()
                        Write-Verbose "---------------------------> Tried to flush $($count) so far"
                    }
                }
                if($buffer.count -ge 2000)
                {
                    Write-Verbose "Flushing $($buffer.Count) files to disk"
                    #if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory}
                    $buffer | Export-csv -Path "$last\FolderInventory.csv" -NoTypeInformation -Encoding UTF8 -Append -ErrorAction SilentlyContinue -ErrorVariable ev
                    if ($ev){ 
                            if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory} 
                            $buffer | Export-csv -Path "$last\FolderInventory.csv" -NoTypeInformation -Encoding UTF8 -Append 
                        } 
                    $count+=$buffer.Count
                    $buffer=@()
                    Write-Verbose "---------------------------> Tried to flush $($count) so far"
                }
                $last=$current
                $buffer+=$fold
            }
            Write-Verbose "Flushing last $($buffer.Count) folders to disk"
            $count+=$buffer.Count
            if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory}
            $buffer | Export-csv -Path "$last\FolderInventory.csv" -NoTypeInformation -Encoding UTF8 -Append
            write-host -ForegroundColor Yellow "Tried to flush $($count) folder entries"
            $folders = $null
            $buffer = $null
        }

        <#
            Neither Folders or Files are guaranteed to be sorted, and just in case they are not, playing
            safe by flushing items to disk each 2000 items or when file\folder change 
        #>
        if (Test-Path $FileInventory) {
            $files = Import-Csv $FileInventory
            Write-Host -ForegroundColor Cyan "Creating Files reports, $($files.Count) items to process"
            $Count = 0
            [string]$last= ""
            [string]$current= ""
            $buffer=@()
            forEach($file in $files)
            {
                $splitted = $file.UNCPath.split('\')
                if ( $splitted[0].Contains(':') ){ 
                    $server= $outputFolder+'\'+$splitted[0].Chars(0) #assuming path like D: and picking up D
                }
                else{ 
                    $server = $outputFolder+'\'+$splitted[2] #accounting for \\
                }
                $localFolder = $splitted[-1]
                $current = "$server\$localFolder"
    
                if ($current -ne $last)
                {
                    if($buffer){
                        Write-Verbose "Flushing $($buffer.Count) files to disk"
                        #if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory}
                        $buffer | Export-csv -Path "$last\FileInventory.csv" -NoTypeInformation -Encoding UTF8 -Append -ErrorAction SilentlyContinue -ErrorVariable ev
                        if ($ev){ 
                            if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory} 
                            $buffer | Export-csv -Path "$last\FileInventory.csv" -NoTypeInformation -Encoding UTF8 -Append 
                        } 
                        $count+=$buffer.Count
                        $buffer=@()
                        write-verbose "---------------------------> Tried to flush $($count) so far"
                    }
                }
                if($buffer.count -ge 2000)
                {
                    Write-Verbose "Flushing $($buffer.Count) files to disk"
                    #if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory}
                    $buffer | Export-csv -Path "$last\FileInventory.csv" -NoTypeInformation -Encoding UTF8 -Append -ErrorAction SilentlyContinue -ErrorVariable ev
                    if ($ev){ 
                        if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory} 
                        $buffer | Export-csv -Path "$last\FileInventory.csv" -NoTypeInformation -Encoding UTF8 -Append 
                        $ev = $null 
                    }
                    $count+=$buffer.Count
                    $buffer=@()
                    Write-Verbose "---------------------------> Tried to flush $($count) so far"
                }
                $last=$current
                $buffer+=$file
            }
            Write-Verbose "Flushing last $($buffer.Count) files to disk"
            $count+=$buffer.Count
            if ( -not(Test-Path ("$last")) ){New-Item ("$last") -ItemType Directory}
            $buffer | Export-csv -Path "$last\FileInventory.csv" -NoTypeInformation -Encoding UTF8 -Append
            write-host -ForegroundColor Yellow "Tried to flush $($count) file entries"
            $files=$null
            $buffer=$null
        }
    }
}


Process{

#region Process Fileshare,File,Folder report

if ( ( $MergeOnly -eq $false) -and ($SplitOnly -eq $false)  )
{
    if ( -not (Test-Path $Script:savePath) )
    {
        New-Item -ItemType Directory $Script:savePath
    }
   
    <#
        Picks all the CSV from local folder, and process them based on the potential content
    #>
    $files = get-childItem $Script:RunPath -File -Filter *.csv
    $SkipMerge = $false
    if ( $files.count -le 3) {$SkipMerge = $true}
    foreach ($file in $files)
    {
        $type=""
        Write-Verbose $File.FullName
        switch -Wildcard ($file.name)
            {
                "*FileShareInventory*" 
                { 
                    Write-Host -ForegroundColor Yellow "Processing file"$file.name
                    $time= Measure-Command -Expression { FilterReport $File.FullName 'FileShareInventory' } 
                    Write-Host -ForegroundColor Green ("Processing Time {0}h:{1}m:{2}s" -f $time.Hours,$time.Minutes,$time.Seconds) 
                }
                "*FileInventory*"  
                { 
                    Write-Host -ForegroundColor Yellow "Processing file"$file.name
                    $time= Measure-Command -Expression { FilterReport $File.FullName 'FileInventory' }  
                    Write-Host -ForegroundColor Green ("Processing Time {0}h:{1}m:{2}s" -f $time.Hours,$time.Minutes,$time.Seconds)
                }
                "*FolderInventory*" 
                { 
                    Write-Host -ForegroundColor Yellow "Processing file"$file.name
                    $time=Measure-Command -Expression { FilterReport $File.FullName 'FolderInventory'  } 
                    Write-Host -ForegroundColor Green ("Processing Time {0}:{1}:{2}" -f $time.Hours,$time.Minutes,$time.Seconds) 
                }
                default:{}
            }
        }
} 
#endregion 

#region Merging multiple FileShare,Files,Folders
if ( ( $SkipMerge -eq $false) -and ( $SplitOnly -eq $false) ) 
{
    #consolidate
    #create consolidation folder to separate the files
    if ( -not (Test-Path ($Script:savePath+'\merged') ) )
    {
        New-Item -ItemType Directory ($Script:savePath+'\merged')
    }
    # Now repeat the filtering, this time pick up the generated reports
    # and create a sigle file per type by merging files together

    $mergedFiles = get-childItem $Script:savePath -File -Filter *FileShareInventory*.csv
    if ($mergedFiles)
    {
        Write-Host -ForegroundColor Blue "Merging FileShareinventory"
        MergeReports $mergedFiles "FileShareInventory"
    }

    $mergedFiles = get-childItem $Script:savePath -File -Filter *FileInventory*.csv
    if ($mergedFiles)
    {
        Write-Host -ForegroundColor Cyan "Merging Fileinventory"
        MergeReports $mergedFiles "FileInventory"
    }

    $mergedFiles = get-childItem $Script:savePath -File -Filter *FolderInventory*.csv
    if ($mergedFiles)
    {
        Write-Host -ForegroundColor yellow "Merging Folderinventory" 
        MergeReports $mergedFiles "FolderInventory"
    }
}
#endregion

#region Split reports in folders per user or team
<#
if ( ( $MergeOnly -eq $false ) -or ( $SplitOnly -eq $true ) ) {
    if (Test-Path ($Script:savePath+'\merged\') ){
        $mergedPath = $Script:savePath+'\merged\'
        SplitReport -FileShareInventory ($mergedPath+'FileShareInventory.csv') `
                    -FileInventory ($mergedPath+'FileInventory.csv') `
                    -FolderInventory ($mergedPath+'FolderInventory.csv') `
                    -outputFolder $mergedPath
    }
    else{
        if ( -not( $Script:savePath )){
            SplitReport -FileShareInventory ($Script:RunPath+'\'+'FileShareInventory.csv') `
                        -FileInventory ($Script:RunPath+'\'+'FileInventory.csv') `
                        -FolderInventory ($Script:RunPath+'\'+'FolderInventory.csv') `
                        -outputFolder $Script:RunPath
            }
        else{
            SplitReport -FileShareInventory ($Script:savePath+'\'+'FileShareInventory.csv') `
                        -FileInventory ($Script:savePath+'\'+'FileInventory.csv') `
                        -FolderInventory ($Script:savePath+'\'+'FolderInventory.csv') `
                        -outputFolder $Script:savePath
        }
}
#>
if (Test-Path ($Script:savePath+'\merged\') ){
        $splitPath = $Script:savePath+'\merged\'
}
 else{
    if ( -not( $Script:savePath )){
        $splitPath = $Script:RunPath+'\'
    }
    else{
        $splitPath = $Script:savePath+'\'
    }

}
SplitReport -FileShareInventory ($splitPath+'*FileShareInventory*.csv') `
            -FileInventory ($splitPath+'*FileInventory*.csv') `
            -FolderInventory ($splitPath+'*FolderInventory*.csv') `
            -outputFolder $splitPath

if ($GenerateHTML){
    Write-host "Generating HTML reports in SplitPath: $splitPath"

    foreach($splitFolder in (Get-ChildItem -Directory -Path $splitPath)){
    Write-Verbose "Splitfolder: $splitFolder"
        foreach($dir in (Get-ChildItem -Directory -Path $splitFolder.FullName)){
            Write-Verbose "report folder $dir.FullName"
            $file = Get-ChildItem -File -Path $dir.FullName
            $size=0
            foreach($f in $file) {
                $size += $f.length
            }
            if ($size -lt 10485760){
                 & "$($PSScriptRoot)\Create-FileshareReport_ftc.ps1" -Path $($dir.fullname)
            }
            else{
                $notDone = "Not Done: $($dir.FullName)"
                $notDone | Out-File ($splitPath+'\ToBigToProcess.log') -Append
            }
         }
     }
     Write-host "File too big that were NOT processed (if any) are listed here: ($($splitPath)ToBigToProcess.log)"
 }
#endregion

$ErrorActionPreference = $errorStyle
[System.GC]::Collect()


} 