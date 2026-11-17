# Light Media for iPhone 3.13

- Downloads: save direct video and music files on this iPhone, view progress, pause/resume, retry, play offline and delete individual downloads. Start from film details, episode hold menus, or a UPnP file's hold menu.
- Settings → Add server (UPnP): enter a NAS hostname/IP or full device-description URL. Saved connections can be renamed, reconnected and removed. Enable Media Server/DLNA on the NAS and allow iOS Local Network access.
- My Music and My Videos: browse saved servers and their folders, search loaded folder entries, load further pages, play files and download them. Music supports background audio and lock-screen play/pause.
- Updated home-screen icon with the clean Light branding and a smaller, centred play dot.

Downloads support direct HTTP/HTTPS files, including MKV, MP4, MP3 and FLAC. Live TV, HLS/DASH playlists and protected streams are not downloaded. Downloads are stored on the iPhone; files are not written to the NAS. iOS controls background scheduling and cancels background transfers when the user force-quits the app; interrupted entries can be retried after reopening.

UPnP connections use an entered address. Automatic SSDP network discovery is not enabled because it requires Apple's restricted multicast entitlement. A bare Synology address tries its common port 50001 description endpoint; other servers may need their full device-description URL. File filtering uses the server's UPnP audio/video classes and MIME types; all folders remain available for navigation.

## Validation

The GitHub compile job runs executable fixture checks for device-description parsing, SOAP/DIDL XML, escaped object IDs, media filtering, resource selection, pagination (including unknown totals), malformed/unsafe XML, and rejecting invalid downloads before compiling the iOS app.

Before release, test on iPhone: add the NAS, browse nested music/video folders and more than one page, play both types, download a film and episode, pause/resume, lock the screen during a download, relaunch, play with Wi-Fi disabled, cancel/delete a download, and check the new icon. Real NAS compatibility and iPhone background behaviour require device testing.
