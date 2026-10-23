# Gallery → PDF (iOS)
Native SwiftUI port of the Android app. No Mac needed: GitHub builds the .ipa for you.
See the chat instructions (GitHub upload -> Actions -> download GalleryToPDF.ipa -> Sideloadly).
Output files appear in: Files app > On My iPhone > Gallery → PDF > GalleryToPDF

## Supported sites
E-Hentai, ExHentai (needs cookies), nHentai, HentaiFox, HentaiEra, Hitomi.la, e621 (post or pool), Rule34.xyz (image posts).
ExHentai: paste your cookies in the field that appears, e.g. `ipb_member_id=...; ipb_pass_hash=...; igneous=...`

## Video downloads (yt-dlp)
Any link that is not one of the gallery sites is handled by yt-dlp, which runs inside the app (embedded Python 3.13).
yt-dlp finds the stream URLs; Swift downloads them (direct files, or HLS/m3u8 segments incl. AES-128), converts MPEG-TS to MP4 itself,
and merges video + audio into one MP4 with AVFoundation (no re-encoding). Output: Files > Gallery → PDF > GalleryToPDF > name.mp4
Limits: H.264/AAC only (iOS can't mux VP9/AV1/Opus), no MKV, no DASH-fragment streams, no live streams. YouTube is not expected to work yet.
The build workflow downloads Python-Apple-support, yt-dlp and the CA bundle on the macOS runner and embeds them into the .app before packaging.
