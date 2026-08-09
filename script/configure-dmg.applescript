on run arguments
  if (count of arguments) is not 1 then error "usage: configure-dmg.applescript MOUNT_PATH"
  set mountPath to item 1 of arguments
  set targetFolder to POSIX file mountPath as alias

  tell application "Finder"
    open targetFolder
    repeat 20 times
      delay 0.2
      try
        if (target of front window as alias) is targetFolder then exit repeat
      end try
    end repeat
    if not ((target of front window as alias) is targetFolder) then error "Finder did not open " & mountPath
    set layoutWindow to front window
    set current view of layoutWindow to icon view
    set toolbar visible of layoutWindow to false
    set statusbar visible of layoutWindow to false
    set pathbar visible of layoutWindow to false
    set sidebar width of layoutWindow to 0
    set bounds of layoutWindow to {100, 100, 760, 530}
    set arrangement of icon view options of layoutWindow to not arranged
    set icon size of icon view options of layoutWindow to 128
    set text size of icon view options of layoutWindow to 14
    set background picture of icon view options of layoutWindow to file "Waves.png" of folder ".background" of targetFolder
    set position of item "Waves.app" of targetFolder to {170, 250}
    set position of item "Applications" of targetFolder to {490, 250}
    update targetFolder without registering applications
    delay 1
    close layoutWindow
  end tell
end run
