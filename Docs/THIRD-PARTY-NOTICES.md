# Third-party notices

This project is MIT licensed (see `LICENSE`). MIT covers the PowerShell
scripts, the launchers, the XAML icons, and the documentation.

It does not cover the Microsoft material below.

## Microsoft User State Migration Tool (USMT)

`scanstate.exe`, `loadstate.exe`, `UsmtUtils.exe`, `mighost.exe`, their DLLs,
and the `DLManifests\` and `ReplacementManifests*\` folders are part of the
Windows Assessment and Deployment Kit. They are Microsoft's, and they are not
in this repository.

The ADK is licensed under Microsoft's own terms, which include a
"Distributable Code" section listing exactly which files may be redistributed.
The licence text ships as `License Terms.rtf` in the ADK install folder.

Microsoft's own deployment products require the administrator to install the
ADK rather than bundling USMT, which is a reasonable guide to the intent.
Install the ADK's User State Migration Tool feature and point UTW at the
`amd64` folder.

## Modified USMT Config Files\MigUser.xml

A modified copy of Microsoft's `MigUser.xml`, shipped with USMT.

The modifications are the point of the file: components were added for Chrome,
Firefox, Outlook mail profiles, the Downloads folder, file associations, and
printers, none of which stock USMT migrates. That is why the file lives in a
folder named for the fact that it is modified.

Microsoft's terms apply to this file. It is not MIT licensed and it is not
redistributable on this project's authority.

## Modified USMT Config Files\Config.xml

Produced by running `scanstate.exe /genconfig` and then setting three
components to `migrate="no"`. The structure and the component list are
Microsoft's output. Microsoft's terms apply.

## Modified USMT Config Files\MigratePublicFolders.xml, ExcludeOneDriveFolders.xml

Written for this project against Microsoft's published USMT XML schema. These
are original work and are MIT licensed with the rest of the project.

## Documentation links

The documentation links to Microsoft Learn pages for ScanState syntax,
LoadState syntax, and USMT return codes. Those pages are Microsoft's and are
linked, not reproduced.
