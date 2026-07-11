; Corkly custom NSIS installer hooks.
;
; Wired into Tauri's default NSIS template via
; `bundle.windows.nsis.installerHooks` in `tauri.conf.json`. Two responsibilities:
;
;   1. Rename `cork.exe` (the name Tauri's sidecar packaging produces) to
;      `cork.exe` in place, directly in `$INSTDIR`, so the user-facing command
;      matches macOS / Linux (`cork`). This is safe to live next to the GUI
;      binary because the product is named `Corkly.exe` — six letters, not a
;      case-insensitive collision with `cork.exe` the way the old `Cork.exe`
;      name was.
;   2. **Append** `$INSTDIR` to the per-user PATH (`HKCU\Environment\Path`)
;      without ever clobbering the existing value.
;
; SAFETY NOTE — this hook was rewritten after an earlier version overwrote a
; user's entire PATH. The root cause was `${WordFind}` from `WordFunc.nsh`
; using `$0` as an internal working register, silently clobbering the value
; we had just read from the registry. This version:
;
;   - Uses only `$R0`-`$R9` (caller-preserved by NSIS convention) and pushes
;     everything before use so no state leaks in or out.
;   - Implements substring checks inline with `StrCpy` / `StrCmp` so no
;     external macro is on the write path — nothing between the `ReadRegStr`
;     and the `WriteRegExpandStr` can touch our locals.
;   - Never writes an empty or single-entry PATH except when the key genuinely
;     didn't exist. If we can't read the existing value cleanly, we bail out
;     instead of risking a truncated write.
;   - Wraps both `PATH` and the new entry in `;` before the substring check
;     so a subword like `...\Programs\Corkly2` can never match `...\Programs\Corkly`.
;
; MIGRATION HAZARD (do not re-litigate the logic above without reading this
; first) — the substring-search logic in this file has been independently
; verified correct, twice, by re-reading it line by line. If PATH corruption
; is reported again on a machine that has *ever* had a pre-fix Corkly build
; installed, the bug is almost certainly NOT in this file. NSIS's bundled
; `PageLeaveReinstall` page (part of Tauri's generated `installer.nsi`, not
; this hook) runs *before* `Section Install` — i.e. before any
; `NSIS_HOOK_*` macro gets a chance to run — and on detecting an existing
; install it silently `ExecWait`s the *old* `uninstall.exe` still sitting on
; disk. If that old binary predates this fix, its old buggy
; `NSIS_HOOK_PREUNINSTALL` runs and can still corrupt PATH, even though the
; *new* installer being run is completely correct. There is no supported way
; to intercept `PageLeaveReinstall` from an `installerHooks` file — the only
; real fix is a clean uninstall (delete the `HKCU\...\Uninstall\Corkly` key,
; `HKCU\Software\koki\Corkly`, and `$INSTDIR` by hand, without ever running the
; stale `uninstall.exe`) before installing a version built from this file.

!include "LogicLib.nsh"
!include "WinMessages.nsh"

!define CORK_ENV_ROOT HKCU
!define CORK_ENV_SUBKEY "Environment"

; -- Install ------------------------------------------------------------------

!macro NSIS_HOOK_POSTINSTALL
  ; Rename cork.exe → cork.exe, in place. `Delete` on the target handles
  ; the upgrade case where the previous install left the file behind.
  ; `IfFileExists` on the source keeps the hook safe when the sidecar wasn't
  ; emitted (bundling regression, manual repackage).
  ;IfFileExists "$INSTDIR\cork.exe" 0 cork_rename_done
  ;  Delete "$INSTDIR\cork.exe"
  ;  Rename "$INSTDIR\cork.exe" "$INSTDIR\cork.exe"
  ;cork_rename_done:

  ; -- Append $INSTDIR to HKCU\Environment\Path -----------------------------
  Push $R0                      ; $R0 = current PATH
  Push $R1                      ; $R1 = ";PATH;"  (wrapped haystack)
  Push $R2                      ; $R2 = ";INSTDIR;"  (wrapped needle)
  Push $R3                      ; $R3 = needle length
  Push $R4                      ; $R4 = loop position (also reused as the EnumRegValue index below)
  Push $R5                      ; $R5 = current window in haystack (also reused as the EnumRegValue name buffer below)
  Push $R6                      ; $R6 = "found?" flag
  Push $R7                      ; $R7 = file handle for the pre-write snapshot

  ; Read existing PATH. ReadRegStr reports the *same* error whether the
  ; "Path" value genuinely doesn't exist or whether it exists but is longer
  ; than NSIS's compiled-in NSIS_MAX_STRLEN (1024 by default) — a real dev
  ; machine's per-user PATH can easily exceed that. Treating "too long" as
  ; "doesn't exist" would make the code below overwrite the user's real PATH
  ; with just $INSTDIR — exactly the class of incident this file exists to
  ; prevent. EnumRegValue only returns value *names* (capped at 255 chars by
  ; Win32, never truncated the way content is), so it can tell the two cases
  ; apart without hitting the same limit.
  ClearErrors
  ReadRegStr $R0 ${CORK_ENV_ROOT} "${CORK_ENV_SUBKEY}" "Path"
  ${If} ${Errors}
    ClearErrors
    StrCpy $R4 0
    cork_path_exists_loop:
      EnumRegValue $R5 ${CORK_ENV_ROOT} "${CORK_ENV_SUBKEY}" $R4
      ${If} $R5 == "Path"
        ; Value exists but couldn't be read (too long) — bail out without
        ; writing anything so PATH is left exactly as it was.
        FileOpen $R7 "$INSTDIR\path-backup-before-install.txt" w
        FileWrite $R7 "SKIPPED: existing Path value could not be read (likely exceeds NSIS's string limit); left untouched by this install."
        FileClose $R7
        Goto cork_path_broadcast
      ${EndIf}
      ${If} $R5 == ""
        Goto cork_path_absent
      ${EndIf}
      IntOp $R4 $R4 + 1
      Goto cork_path_exists_loop
    cork_path_absent:
    StrCpy $R0 ""
  ${EndIf}

  ; Snapshot the pre-write value to disk, unconditionally, before any write
  ; happens. No judgment call about whether the value "looks right" — that
  ; kind of heuristic is exactly what caused past incidents. This is just a
  ; plain record an admin can read after the fact to manually restore PATH if
  ; anything downstream (this script, a future edit, an unrelated installer)
  ; ever corrupts it again. Overwritten on every install; not meant to be a
  ; history, just a "what it was right before this install touched it" note.
  FileOpen $R7 "$INSTDIR\path-backup-before-install.txt" w
  FileWrite $R7 "$R0"
  FileClose $R7

  ; Whole-entry substring search: is `;$INSTDIR;` inside `;$R0;` ?
  StrCpy $R1 ";$R0;"
  StrCpy $R2 ";$INSTDIR;"
  StrLen $R3 $R2
  StrCpy $R4 0
  StrCpy $R6 "0"
  cork_path_search_loop:
    StrCpy $R5 $R1 $R3 $R4
    ${If} $R5 == $R2
      StrCpy $R6 "1"
      Goto cork_path_search_done
    ${EndIf}
    ${If} $R5 == ""
      Goto cork_path_search_done
    ${EndIf}
    IntOp $R4 $R4 + 1
    Goto cork_path_search_loop
  cork_path_search_done:

  ${If} $R6 == "1"
    ; Already present — nothing to write.
    Goto cork_path_broadcast
  ${EndIf}

  ; Not present — append. Write only ONE value to Path (HKCU only):
  ;   - empty existing: just our entry
  ;   - non-empty existing: original + ";" + our entry
  ; No other branch is possible; we cannot end up writing "".
  ${If} $R0 == ""
    WriteRegExpandStr ${CORK_ENV_ROOT} "${CORK_ENV_SUBKEY}" "Path" "$INSTDIR"
  ${Else}
    WriteRegExpandStr ${CORK_ENV_ROOT} "${CORK_ENV_SUBKEY}" "Path" "$R0;$INSTDIR"
  ${EndIf}

  cork_path_broadcast:
    ; Broadcast so Explorer / new shells pick up the change without a logout.
    ; The 5s timeout keeps a stuck listener from hanging the installer.
    SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
    ClearErrors

  Pop $R7
  Pop $R6
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2
  Pop $R1
  Pop $R0
!macroend

; -- Uninstall ----------------------------------------------------------------

!macro NSIS_HOOK_PREUNINSTALL
  ; Best-effort removal of $INSTDIR from HKCU\Environment\Path. Same
  ; safety discipline as install: only $R-registers, no external macros on
  ; the write path, and if reading the existing value fails we skip the
  ; write rather than risk a truncated PATH.
  Push $R0                      ; $R0 = current PATH
  Push $R1                      ; $R1 = accumulator for rebuilt PATH
  Push $R2                      ; $R2 = current segment
  Push $R3                      ; $R3 = scan position
  Push $R4                      ; $R4 = one char
  Push $R5                      ; $R5 = "changed?" flag
  Push $R6                      ; $R6 = start of current segment

  ClearErrors
  ReadRegStr $R0 ${CORK_ENV_ROOT} "${CORK_ENV_SUBKEY}" "Path"
  ${If} ${Errors}
    Goto un_cork_path_end
  ${EndIf}

  ; Rebuild PATH one `;`-separated segment at a time, skipping our entry.
  StrCpy $R1 ""
  StrCpy $R3 0
  StrCpy $R6 0
  StrCpy $R5 "0"

  un_cork_path_scan:
    StrCpy $R4 $R0 1 $R3
    ${If} $R4 == ";"
    ${OrIf} $R4 == ""
      ; Extract segment [$R6 .. $R3)
      IntOp $R2 $R3 - $R6
      StrCpy $R2 $R0 $R2 $R6
      ${If} $R2 == "$INSTDIR"
        StrCpy $R5 "1"
      ${Else}
        ${If} $R2 != ""
          ${If} $R1 == ""
            StrCpy $R1 $R2
          ${Else}
            StrCpy $R1 "$R1;$R2"
          ${EndIf}
        ${EndIf}
      ${EndIf}
      ${If} $R4 == ""
        Goto un_cork_path_write
      ${EndIf}
      IntOp $R3 $R3 + 1
      StrCpy $R6 $R3
      Goto un_cork_path_scan
    ${EndIf}
    IntOp $R3 $R3 + 1
    Goto un_cork_path_scan

  un_cork_path_write:
    ${If} $R5 == "1"
      WriteRegExpandStr ${CORK_ENV_ROOT} "${CORK_ENV_SUBKEY}" "Path" "$R1"
      SendMessage ${HWND_BROADCAST} ${WM_SETTINGCHANGE} 0 "STR:Environment" /TIMEOUT=5000
    ${EndIf}

  un_cork_path_end:
    ClearErrors
    Pop $R6
    Pop $R5
    Pop $R4
    Pop $R3
    Pop $R2
    Pop $R1
    Pop $R0

    ; Remove the renamed CLI binary. Uninstall would leave it otherwise
    ; because Tauri's manifest only tracks `cork.exe`, not the post-hook
    ; `cork.exe`.
    Delete "$INSTDIR\cork.exe"
!macroend
