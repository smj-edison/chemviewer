; Per-user installer (no administrator rights needed).
; Built by packaging/package.zig, which defines VERSION, EXE, INSPECT, LICENSE, NOTICES, ICON and OUT.
Unicode true
!include MUI2.nsh
Name "chemviewer"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\Programs\chemviewer"
InstallDirRegKey HKCU "Software\chemviewer" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
!define UNINST "Software\Microsoft\Windows\CurrentVersion\Uninstall\chemviewer"
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\chemviewer.exe"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; Offers chemviewer under "Open with"; never takes over the default.
!macro OpenWith EXT
  WriteRegStr HKCU "Software\Classes\Applications\chemviewer.exe\SupportedTypes" "${EXT}" ""
  WriteRegNone HKCU "Software\Classes\${EXT}\OpenWithProgids" "chemviewer.file"
!macroend
!macro unOpenWith EXT
  DeleteRegValue HKCU "Software\Classes\${EXT}\OpenWithProgids" "chemviewer.file"
!macroend
!macro EachType M
  !insertmacro ${M} ".xyz"
  !insertmacro ${M} ".extxyz"
  !insertmacro ${M} ".gjf"
  !insertmacro ${M} ".traj"
  !insertmacro ${M} ".log"
  !insertmacro ${M} ".out"
  !insertmacro ${M} ".inp"
!macroend

Section
  SetOutPath "$INSTDIR"
  File "/oname=chemviewer.exe" "${EXE}"
  File "/oname=chemviewer-inspect.exe" "${INSPECT}"
  File "/oname=LICENSE.txt" "${LICENSE}"
  File "/oname=THIRD-PARTY-NOTICES.txt" "${NOTICES}"
  CreateShortcut "$SMPROGRAMS\chemviewer.lnk" "$INSTDIR\chemviewer.exe"
  WriteRegStr HKCU "Software\chemviewer" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Classes\chemviewer.file\DefaultIcon" "" "$INSTDIR\chemviewer.exe,0"
  WriteRegStr HKCU "Software\Classes\chemviewer.file\shell\open\command" "" '"$INSTDIR\chemviewer.exe" "%1"'
  WriteRegStr HKCU "Software\Classes\Applications\chemviewer.exe\shell\open\command" "" '"$INSTDIR\chemviewer.exe" "%1"'
  !insertmacro EachType OpenWith
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${UNINST}" "DisplayName" "chemviewer"
  WriteRegStr HKCU "${UNINST}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST}" "DisplayIcon" "$INSTDIR\chemviewer.exe"
  WriteRegStr HKCU "${UNINST}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${UNINST}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\chemviewer.exe"
  Delete "$INSTDIR\chemviewer-inspect.exe"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\THIRD-PARTY-NOTICES.txt"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\chemviewer.lnk"
  !insertmacro EachType unOpenWith
  DeleteRegKey HKCU "Software\Classes\chemviewer.file"
  DeleteRegKey HKCU "Software\Classes\Applications\chemviewer.exe"
  DeleteRegKey HKCU "${UNINST}"
  DeleteRegKey HKCU "Software\chemviewer"
SectionEnd
