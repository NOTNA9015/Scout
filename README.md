# Scout

A small add-on for a working **spoti.pw** IPA (tested base: `spoti.pw-0.51.0.ipa`, Spotify 9.1.90).
Scout is injected next to spoti.pw the same way spoti.pw is injected into Spotify. It changes
nothing of Spotify's or spoti.pw's own screens; it adds one button and one menu.

## Using it

- **Open:** the Scout button (✦🔍) in Your Library's header, or shake the phone anywhere.
- **Import a song:** find it → Download → name → artists → cover → lyrics → Import.
- **Import an album:** search as often as you like and tick songs from any result → Done →
  a name for each song → lyrics for each song → "N songs have no lyrics — generate?" →
  artists for each song → album name, artists, cover and order → Import.

**Artist trackers:** type “Frank Ocean tracker” (also “franck ocean tracker”), “Ye tracker”,
or “Kendrick tracker” to browse their songs, or choose a tracker in the source menu and search
by song, era, version, or quality. For example, “Ye tracker Donda” or “Kendrick tracker demo”.
Once loaded, tracker results filter as you type. Clearing the search restores that tracker,
and subsequent searches stay in it until you choose another source.
Scout reads the public Released and Unreleased tabs, keeps version and quality labels, and
supports direct audio links, Pillowcase/Pillows, and Imgur audio shares. Unavailable entries
and links to videos or articles are skipped. The tracker name above the results opens its
original page. Indexes are cached for ten minutes; missing tabs are reported and retried.
The built-in sources are [Frank Ocean Tracker](https://franktracker.net/),
[Ye Tracker](https://yetracker.net/), and the sheet linked by the
[Kendrick Lamar Tracker](https://linktr.ee/kendricktracker).

Track lengths appear in search results, the selection basket, setup, album order, saving, and
the imported-song list. Scout reads Archive and tracker lengths and checks the audio when a
source omits them. Unreadable lengths are labeled “Length unavailable”.

**File converter:** open Scout → File converter → Choose audio files, select the songs in
Files (including earlier Scout imports), then tap Convert for Spotify. It writes new AAC
`.m4a` copies in Spotify → Scout and keeps the originals. It retains readable names, artists,
covers and lyrics. New imports also check the file's actual audio format: real MP3 stays MP3,
while other formats become AAC at 44.1 kHz (up to 256 kb/s stereo). This avoids mislabeled
downloads and ALAC files that some Spotify local-file scanners skip.

**Automatic conversion:** downloaded audio is checked and converted before the setup screens
open; there is no separate conversion step. This includes Ogg/Opus files served with an MP3
filename or content type (such as “Done” on Frank Ocean Tracker). If a tracker file cannot be
downloaded or converted, Scout tries its available mirrors. Real MP3 and compatible AAC are
kept without re-encoding.

**Previews:** a player opens under the song, showing download progress and conversion status,
then play/pause, seeking, and elapsed/total time. Scrolling the song out of view stops the
preview, removes the player, and resets it to the beginning.

Conversion preserves embedded Ogg/Opus and FLAC covers and writes the chosen image as a
standard PNG/JPEG cover tag in the output. Blank artist or lyric fields are omitted so they
cannot cause the exporter to discard the cover. Scout reads the output back to verify the
cover was embedded before reporting success.

**Quick setup everything** (first name page) picks every detail for you and imports straight away:
names without download tags or "(feat. …)" (in the catalog's spelling when it matches), the featured
artists added, the file's or a catalog cover, the album's name and cover, and lyrics as below.

On the lyrics step, **Quick setup lyrics** uses the recommended lyrics for every song you haven't chosen
for yourself and generates lyrics from the audio for the rest, then moves on. Songs still being
listened to are decided while saving.

Every step lists all suggestions (the source, the file's own tags, cleaned-up names, Apple
Music and Deezer catalog matches) and has its own search. Lyrics come from LRCLIB, the source
or the file; or are pasted, imported, or generated on the iPhone. Line-timed lyrics can get
real per-word timing measured from the audio ("Time each word"); when their line times belong
to a version of another length (a longer intro, a cut verse), the words are timed without them.

**Generated lyrics are pieced together.** Scout listens to the song on the iPhone, then looks
for every line of every lyric it found (LRCLIB, the source, the file's tags) in what was sung,
in any order and as often as it was sung. Each stretch of the song takes the written line it
matches, with its spelling and the measured word times. Lines the recognizer missed or misheard
between placed lines (or just before the first and after the last) are filled in from the
lyric they belong to, and passages no lyric has stay as heard. Leaks, demos and edits whose
verses moved, repeat, were cut or added, or that run longer or shorter than the lyrics online
still get the right words in the right places. When the version is arranged differently from
every lyric found, the pieced-together lyrics are recommended (and used by Quick setup);
otherwise the best whole lyric is. Lyrics of other songs that share a line or two aren't used,
and sung spellings ("gonna"/"going", "'cause"/"because", "you're"/"your") count as the same word.

Songs are tagged (title, artists, album, number, cover, lyrics) and saved to
**Files → On My iPhone → Spotify → Scout**, with an `.lrc` beside each. Turn on Spotify's
Settings → Local Files to see them.

**Playlists:** importing an album ends at Done and records the album as waiting. To make the
playlists, open Your Library → Local Files and tap **Compile pending playlists (N)** at the bottom, or use
the same row in Scout's menu.
Scout then turns on Spotify's Documents scanning, finds each song's exact `spotify:local:` URI
(checked against Spotify's own answer for which file it plays), creates a normal playlist named
after the album, adds the songs in order and reads it back, then says what was made or why not.
Scout reaches Spotify's services through the transport `EsperantoServiceImpl
provideEsperantoTransport` hands out, the same one spoti.pw uses. A create Spotify never confirmed
is only repeated on the next tap, after you've been told to check Your Library, so you don't get
duplicate playlists.

**Shown as albums:** inside Spotify, the playlists Scout made read as albums. In list rows,
"Playlist • <you>" becomes "Album • <artists>", and the album's cover replaces Spotify's
picture, both in rows and on the playlist's own page. Only the display changes. In Spotify the
playlist is still a playlist, and its stored cover isn't set: setting that needs Spotify's
signed-in image upload, which Scout doesn't use.

**Edit imports** (Scout's menu) has a Songs tab and an Albums tab. For a song you can change its
name, artists, lyrics and (for single songs) album, track number and cover. For an album you can
change its name, artists and cover, and reorder its songs. Every change is written back into the
files' tags, the `.lrc` and spoti.pw's lyrics. Spotify knows a local file by its tags, so after
editing an album that is already in Spotify, tap Compile pending playlists to add the edited
songs, then remove the old entries in Spotify. The playlist keeps its original name and order.

## Build

Xcode with the iOS 26+ SDK, XcodeGen and cyan (`uv tool install "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw"`).

    python3 scripts/package.py ~/Downloads/spoti.pw-0.51.0.ipa
    # → out/Scout-spotipw-0.51.0-unsigned.ipa, sign it like the spoti.pw IPA

## Test

    xcodegen generate
    xcodebuild -project Scout.xcodeproj -scheme ScoutHarness -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' test

`ScoutHarness` stands in for Spotify: a Your Library page with Spotify's header id, and offline
fixtures for downloads, catalog and lyrics. It does not prove behaviour inside Spotify.

## Not verified on a phone yet

- The header button's placement in the real Your Library (shake always works as a fallback).
- That spoti.pw shows Scout's lyrics. They are written into spoti.pw's own folder
  (`Application Support/spoti.pw/Lyrics/<sha256 of the spotify:local: URI>.lrc`, the format read
  from its compiled code) as well as into the file's tags and an `.lrc` beside it.
- spoti.pw 0.51.0 contains integrity checks; how it reacts to a second injected library is unknown.
- The playlist step's calls into Spotify (tested against a fake that answers like Spotify), and
  that the Local Files page is recognised (by its page URI, class name, title or header view).
  Scout keeps a short log of the pages it saw in Files → Spotify → "Scout pages.txt" for fixing this.

- Showing the playlists as albums. Scout changes Spotify's UIKit labels and image views; rows
  that Spotify draws some other way (SwiftUI, for example) stay as playlists.

## Licences

spoti.pw is © Vojtěch Škopek under PolyForm Strict 1.0.0 (personal, noncommercial use; no
changes or redistribution). Scout contains none of its code and does not modify it; keep the
combined IPA to yourself. `vendor/spoti.pw` (git-ignored) is a reference checkout only.
