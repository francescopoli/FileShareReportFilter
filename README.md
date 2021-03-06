# FileShareReportFilter

Used to filter the File Share inventory report to return problematic issues that will not be migrated, and items that may require a review by the owners (Files and Folders with invalid characters or names) <br>

The script is inteded for parsing the FileShare Inventory tool from FTC to reduce the amount of data in the reports, it also allow processing the full set of files generated during file server analysis (files generated by the tool are capped at 1040000 lines, after that limit a new sequential file is generated)

### Usage
Most of the times you will need to use only the one of this ways:<br>
<code>.\Filter-Reports.ps1  </code><br>
<code>.\Filter-Reports.ps1 -Path C:\folderWhereFilesAreStored -verbose </code><br>

The <code>-verbose</code> is always a suggested parameter if you have a set of files to process, in that specific case each file can take quite a bit of time to be imported and processes, so keeping the verbosity high will help you monitor the execution progresses.<br>

There are multiple parameters present, them can be investigated it the script initial help commment, but most of the time, you will not be in need to use them.<br>

If you do not specify the <code>-path</code> parameter, the script will try to locate the csv files in the same folder from where it's being run.