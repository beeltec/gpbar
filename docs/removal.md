# Removing GPBar

1. Disconnect and wait for cleanup to finish.
2. Open Diagnostics and choose Remove helper.
3. Turn off Launch GPBar at login, if enabled.
4. Quit GPBar and move the application to Trash.

If network cleanup needs attention, use Recover network before removing the helper.
Do not delete a recovery journal while cleanup is unresolved.
The helper uses `/Library/Application Support/GPBar` for private session bundles and journals.
Empty staging directories may remain after normal use; they contain no credentials.

Connection preferences remain in the current user's `com.beeltec.GPBar` preferences domain.
Removing the application does not erase the saved address or browser choice.

If you explicitly made GPBar the handler for `globalprotectcallback:`, restore your preferred VPN application's handler when removing GPBar.
The application does not change that handler merely by choosing the in-app or default-browser mode.
