# Decode Alpha — Install Guide

## Install Steps

1. Open `Decode-0.1.0.dmg`
2. Drag **Decode** to **Applications**
3. Open **Terminal** and run:
   ```
   xattr -cr /Applications/Decode.app
   ```
4. Launch **Decode** from Applications
5. Enter your invite code when prompted

## Why Step 3 Is Needed

Decode is signed with an Apple Development certificate (not Developer ID) because we are not enrolled in the Apple Developer Program. macOS Gatekeeper blocks apps without Developer ID or notarization. The `xattr -cr` command removes the quarantine flag so the app can launch.

This is expected for alpha testing and will be resolved before public release.

## Permissions

On first launch after activation, macOS will prompt for:

- **Accessibility** — required for text capture (Selection Mode)
- **Input Monitoring** — required for global hotkeys
- **Screen Recording** — required for Screenshot Mode

Grant all three in **System Settings > Privacy & Security**, then restart Decode.

## Troubleshooting

**"The application 'Decode' can't be opened"**
- You skipped step 3. Open Terminal and run `xattr -cr /Applications/Decode.app`

**Activation fails or shows "Connection failed"**
- Verify your internet connection
- Check backend health: https://decode-production-9eba.up.railway.app/health
- Retry — the backend may be cold-starting (takes 5–15 seconds)

**App stuck on "Verifying account..."**
- Check internet connection and retry
- If persists, quit Decode (Cmd+Q) and relaunch

**Hotkeys don't work after granting permissions**
- Restart Decode after granting Accessibility and Input Monitoring
