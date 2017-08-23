# FileShareReportFilter

Used to filter the File Share inventory report to return only hard failure items that will not migrate (need a fix) from the Fast Track File Inventory Report in a SharePoint\OneDrive migration.

Only Filter-Report shall be used.
Scripts are incomplete as I haven't included here the Create-FileShareReport_ftc.ps1 as it contains part of the code that was not written by me.
Due to that missing scripts, the HTML reports are not generated, (suggest to comment with # line 635 to avoid error in execution in the final stage) anyway you can use this script to reduce size of the final reports and to consolidate the reports in cases multiple splitted csv are generated(for reports having more than 1040000 entries)

Just run the script from PowerShell, by either:

.\Filter-Reports.ps1 -Path C:\folderWhereFilesAreStored
or
just copy the file in the same folder where the files are located and run .\Filter-Reports.ps1
