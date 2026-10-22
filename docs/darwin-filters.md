# Stock Darwin FIR filter presets (HiBy RS6 firmware 1.80)

Offline RE of HiBy's stock firmware 1.80 (the EDL dump zip, sha256 `34b6a8826eda215e36551807608923bd6fe40cc329e403b65ef9fcb610480d59`)
and a copy of `/data/vendor/misc` from a running stock unit. Nothing was run on the device for this note.
The filters themselves ship in the `firmware` branch (`darwin/`).

Method: `system_a.bin` of the dump is a raw ext4 (reassembled 3 GiB image sha256 `f63403422f5f8e72e041a54994f59b8df7f3a42f7fcf123b0479e5b53abebb46`), `debugfs rdump /system`, `unzip` on the APK, androguard 4
for dex disassembly and `resources.arsc` / binary XML. No jadx/apktool/aapt available, so code facts below come from dalvik bytecode
(class and method names are quoted so they can be re-found).

## 1. Provenance

All assets live in one APK:

- `/system/priv-app/Settings/Settings.apk` (sha256 `f0429f2543f5141ee4ed07bff3607f9bd83a5752217068d1b6904a22a7fc9820`), package `com.android.settings`
- inside the APK: `assets/*.flt` (1024 bytes each) plus `assets/filter.json` (sha256 `d9975f8125da3a39176797b1654186f47469ca7077e4231ba7aa15b935e004c1`)

`1.flt`, `2.flt`, `3.flt` in `/data/vendor/misc` are byte-identical to `assets/1.flt`, `assets/2.flt`, `assets/3.flt` of that same APK.
The capture does not only contain 1/2/3: it holds 11 `.flt`, exactly the 11 entries of `filter.json` (all dated 2026-08-06 02:34,
`system:system`, mode 0777), and every one matches the APK asset of the same name.

`1.flt` and `2.flt` are the same bytes, so "Darwin Default" and "Darwin 1" run the identical FIR (they differ only in the DSD filter, see 2.4).
`nyquist-60-slow-rolloff-normal.flt` and `nyquist-30-slow-rolloff-minphase.flt` are also identical to each other (neither used by the UI).

### sha256 of every .flt (APK asset; "dev" = also present in captured /data/vendor/misc with the same hash)

| file | sha256 | in filter.json | dev |
|---|---|---|---|
| 1.flt | 60c4b0c2248f902eb0c83308b27d6ae4d83f68ad79b08525ce6ae48c45e20edc | yes | yes |
| 2.flt | 60c4b0c2248f902eb0c83308b27d6ae4d83f68ad79b08525ce6ae48c45e20edc | yes | yes |
| 3.flt | 75e8835dc43e613d764fb91be80781e76401399d1e0c0146a7146a8a2dad16f0 | yes | yes |
| raised-cosine-254-rolloff-normal.flt | e1d16f959fd3a52da976e36e40a3647a44d3b322ccfcd35b8d96c6dc9bfc4315 | yes | yes |
| raised-cosine-254-rolloff-square.flt | 6d1a2097289cf911afec2339f75d9624ad8b43bd0653e317df4a6d55a63de214 | yes | yes |
| raised-cosine-254-rolloff-999-square.flt | f37d829d433b888a1f2809457705bd95833f6ab829fe299b5a41f07553dbc7f4 | yes | yes |
| raised-cosine-254-fast-rolloff-normal.flt | 1edfd4aedd6ceb283edb0bd8aa5dc4678a6d775046f1054be93eed36b333c902 | yes | yes |
| raised-cosine-254-fast-rolloff-square.flt | d7b0c6aa1efc4ad45c8db8816bfc01b37f9daaf06b3435ecbd627846ddc7756c | yes | yes |
| raised-cosine-254-slow-rolloff-normal.flt | 5e447caa6d45de2cf50ab223bf670eec4e8e65ebfec297dcaa2d50a7785ee168 | yes | yes |
| raised-cosine-254-slow-rolloff-square.flt | d1ad37eb4549f251a25d4ac41ade087a20d4fca6035f1da9c25807344fdd2b67 | yes | yes |
| nyquist-30-rolloff-minphase.flt | e007a7e57301066d98b122ad7dd051ef909f483a78b51952a3bbe07adb66bf09 | yes | yes |
| 4.flt | d244f6aa0570e96c7747d14ff570f2ea9f88adc7efd798737dfcd12db5ffb2cd | no | no |
| bass-boost.flt | 3733bdb277c9ca57d15fe922dd0680c6383a8cd1255893df085ebaba30c0c183 | no | no |
| inverse-sinc-lowpass-254-min-phase.flt | 329a29fc5584bc6c788284ab9b5de8dd32d63bd3c8f717fb6cba58d55aacd27d | no | no |
| inverse-sinc-lowpass-254-normal.flt | 92adb306f53c66f3f0e344681cd3c64dda7eec00c218909cfc3595114bcfd9a2 | no | no |
| nyquist-30-slow-rolloff-minphase.flt | df607f8cd15b8cb5cef9b638c740b563d448d218e45438d9049dea75c1665eba | no | no |
| nyquist-60-rolloff-nonnegative.flt | 06f5180211f63566fecbb24d34bedd2cf0ced1294685efdd453e21d478ed8a12 | no | no |
| nyquist-60-rolloff-normal.flt | 1ea3c25132fd11bc808e504463683f35951827012a9ca142d2695d6dae0b734d | no | no |
| nyquist-60-slow-rolloff-normal.flt | df607f8cd15b8cb5cef9b638c740b563d448d218e45438d9049dea75c1665eba | no | no |
| nyquist-62-fast-rolloff-nonnegative.flt | 8d9069c43dc5f7b146e803a22dc4741ddac6000297d46f005dbf1e86f749bee0 | no | no |
| nyquist-62-fast-rolloff-normal.flt | eb86584fff4c3a8f28d4fede13f826b75cab09fb11c27521adc7d5e1325b428c | no | no |
| nyquist-62-slow-rolloff-nonnegative.flt | 9ea45079577a608512eeef0ea2908197652c74398ea26bf04db0ccb3cd465ae2 | no | no |

The 11 "no" rows are APK assets that stock never lists and never copies (the copy loop is driven only by `filter.json`).

File format sanity (little-endian int32 x256): symmetric linear-phase kernels peak at tap 127 (e.g. `1.flt` peak 930712756, sum 2147509284, about 2^31, so DC gain about 1.0 in Q31);
`nyquist-30-rolloff-minphase.flt` peaks at tap 2 (minimum phase, sum 2173219488).

## 2. How stock exposes them

### 2.1 Screens and labels

- Settings > Audio > "Darwin Controller" (`com.android.settings.audio.DarwinSettings`, `res/xml/darwin_settings.xml`, title `string/darwin_settings`).
  It holds the row `key=darwin_filter`, title `@string/fir_rolloff` (0x7f12066c), summary shows the current selection. Tapping fires intent
  `android.settings.DARWIN_FILTER`, which resolves to `com.android.settings.audio.FilterActivity` (manifest; its label is also `fir_rolloff`).
- `fir_rolloff` per language (the only localised strings involved; there is no `ko` entry, Korean falls back to default English):
  - default / en: "Low-pass antialiasing filter setting"
  - ja: "アンチエイリアスフィルタ"
  - zh-rCN: "数字滤波器模式"; zh-rTW and zh-rHK: "數字濾波器模式" (all = "Digital filter mode")
- `darwin_settings`: en "Darwin Controller", ja "Darwinコントローラー", zh-rCN "Darwin 控制器", zh-rTW/zh-rHK "Darwin 控製器".
- Sibling rows on that screen (not covered here): a `dsd_filter` ListPreference (`dsd_filter_title` "DSD Filter" / zh "DSD 滤波器"), NOS,
  bass boost, a harmonic controller and tuning presets.
- The per-filter names are not in resources. They are hard-coded English `title` strings in `assets/filter.json` ("Darwin Default", "Darwin 1" ... "Darwin 10"), identical in every locale.

### 2.2 The list in `FilterActivity`

Layout: `ListView`; each row is a CheckBox (checked = current selection, text = title) plus an ImageView (frequency-response plot) plus a TextView.
Order = order of `filter.json`, filtered to entries whose file exists in `/data/vendor/misc/`. Row i uses icon array
`mDigitalFilterIconArr[i]` = `darwin_default, darwin_1 ... darwin_10` (drawables in `res/drawable-xxhdpi-v4/`, 1120x380 magnitude-response plots; the plot is tied to list position, not to the file name).
If the user supplied their own `/sdcard/filter/filter.json` (Settings.Global `isFromUserCopyInSdCard` = "yes"), the plots are hidden and the title text is shown instead.
There is no "off" / "none" / bypass entry. (`darwin_none.png` is a blank grid image and is not in the icon array.)

| # | stock label (filter.json `title`) | file | icon drawable | filter.json `desc` (never displayed, see 3) |
|---|---|---|---|---|
| 1 (default) | Darwin Default | 1.flt | darwin_default | "" |
| 2 | Darwin 1 | 2.flt (same bytes as 1.flt) | darwin_1 | "" |
| 3 | Darwin 2 | 3.flt | darwin_2 | "" |
| 4 | Darwin 3 | raised-cosine-254-rolloff-normal.flt | darwin_3 | Darwin 4 - Raised-Cosine Rolloff Normal |
| 5 | Darwin 4 | raised-cosine-254-rolloff-square.flt | darwin_4 | Darwin 5 - Raised-Cosine Rolloff Square |
| 6 | Darwin 5 | raised-cosine-254-rolloff-999-square.flt | darwin_5 | Darwin 6 - Raised-Cosine Rolloff 0.999 Square |
| 7 | Darwin 6 | raised-cosine-254-fast-rolloff-normal.flt | darwin_6 | Darwin 7 - Raised-Cosine Rolloff 0.01 Square |
| 8 | Darwin 7 | raised-cosine-254-fast-rolloff-square.flt | darwin_7 | Darwin 8 - Raised-Cosine Rolloff 0.01 Square |
| 9 | Darwin 8 | raised-cosine-254-slow-rolloff-normal.flt | darwin_8 | Darwin 9 - Raised-Cosine Rolloff 0.5 Square |
| 10 | Darwin 9 | raised-cosine-254-slow-rolloff-square.flt | darwin_9 | Darwin 10 - Raised-Cosine Rolloff 0.5 Square |
| 11 | Darwin 10 | nyquist-30-rolloff-minphase.flt | darwin_10 | Darwin 18 - Nyquist 30 Rolloff Min Phase |

The `desc` numbering is off by one from `title` and partly copy-pasted (both fast entries say "0.01 Square", both slow ones "0.5 Square"), so treat
the file names, not the descs, as authoritative.

Preset tuning profiles (`res/raw/darwin_presets.json`, key `digital_filter`) reference these titles ("Darwin Default" for QDC Anole V14, FIDUE Artemis, Softears RS10;
"Darwin 1" for UM MASON FuSang; "Darwin 10" for UM MEST MKII and DUNU ZEN PRO; "Darwin 8" for DITA Dream XLS) and apply them through the same path (2.3).

### 2.3 What selecting one does

`FilterActivity$1.onItemClick(pos)` calls `setDigitalFilter(valueList[pos])`, where the value is the full path `/data/vendor/misc/<file>.flt`. `setDigitalFilter` does three things:

1. `Settings.Global.putString(resolver, "vendor.audio.hw.vendor_funcfilter_path ", "<path>")` (the key really has a trailing space; this is the persisted selection that the UI reads back).
2. `SystemProperties.set("vendor.audio.hw.vendor_func", "filter_path <path>")`
3. `SystemProperties.set("vendor.audio.hiby.hw.darwin.filter_path", "filter_path <path>")`

(`DarwinSettings.setDigitalFilter` does 1 and 2 only, not 3.) The adapter then refreshes the checkbox.
Example value: `filter_path /data/vendor/misc/raised-cosine-254-rolloff-normal.flt`.

### 2.4 Default and first-run population

- Default = first list entry (`valueList[0]` = `/data/vendor/misc/1.flt`, "Darwin Default"). `FilterActivity.initSelectValue` reads Global `vendor.audio.hw.vendor_funcfilter_path `;
  if null it falls back to Global `vendor.audio.hw.vendor_func` (stripping `filter_path `); if still null, or the stored path is not in the list, it applies entry 0 via `setDigitalFilter`.
  `DarwinSettings.resetDarwinDefaultValue` also resets to entry 0 (and the DSD filter to `mdsd`).
- Population (`DarwinSettings.initDigitalFilterData`, run in `onCreate` of the Darwin Controller screen): `copyRawToFile()` copies every asset named in `filter.json` into `<filesDir>/filter/`;
  `startCheckFileAndCopy()` takes `/sdcard/filter/filter.json` if the user made one, else copies the APK `assets/filter.json` to `<filesDir>/filter_sd/filter.json`;
  then `copyFile`/`copyFiletoSystem` does a plain FileChannel copy of each listed .flt into `/data/vendor/misc/` (creating the dir if absent). This explains the 2026-08-06 02:34 timestamps on all 11 files.
  `initShowData` adds a list row only if the file exists in `/data/vendor/misc/` afterwards.
- Fallback if the title list is empty: resource arrays `digital_filter_list_preference` / `digital_filter_value_list_preference` (0x7f030061 / 0x7f030064),
  an ES9038-style set with no files: Sharp Roll-off (`sharp_roll_off`), Slow Roll-off, Short Delay Sharp Roll-off, Short Delay Slow Roll-off, Super Sharp Roll-off, Super Slow Roll-off, Low Dispersion Short Delay. Not reached on a normal RS6 since `filter.json` is bundled.
- Separate DSD filter list (`array/dsd_filter_title` = "Darwin Default" / "Darwin 1", values `mdsd` / `dsd`; set via property `vendor.audio.hw.vendor_func` = `dsd_mode <mdsd|dsd>` and Global `dsd_filter`).
  Its two titles share names with the first two PCM filters (presets set both from one `digital_filter` name: "Darwin Default" -> `mdsd`, "Darwin 1" -> `dsd`), but it is a different control. Other `vendor_func` verbs seen: `nos_enable on|off`.

## 3. Metadata

- Grouping: all 11 sit under the single "Darwin Controller" screen, row "Low-pass antialiasing filter setting" (zh "Digital filter mode"). No further grouping or headings.
- The only metadata in `filter.json` is `title`, `desc`, `path`. The code (`FilterActivity.initShowData`, `DarwinSettings.initShowData` / `copyRawToFile` / `copyFile`) reads only `title` and `path`; `desc` is never shown. `path` is `/mnt/sdcard/filter/<file>`, only its basename is used (target is always `/data/vendor/misc/<basename>`).
- Visual metadata: one magnitude-response PNG per list position (`darwin_default`, `darwin_1` to `darwin_10`).
- Filename vocabulary (names and desc): raised-cosine with 254 taps; `fast` / `slow` rolloff (desc says 0.01 / 0.5); `normal` vs `square`; `rolloff-999-square` (0.999); `nyquist-30-...-minphase` = minimum-phase.

## 4. Open items

- `vendor.audio.hiby.hw.darwin.filter_path` is set only by `FilterActivity.setDigitalFilter`; the HAL-side consumer is closed code and was not examined for this note.

## On Nura
- `firmware-hiby-rs6` installs stock's `filter.json` (unchanged) and the 11 `.flt` it lists to
  `/usr/share/hiby-rs6/darwin/`, extracted from a stock dump by
  `tools/make-firmware-tarball.sh` (Settings.apk in system_b). The 11 unlisted assets are not
  shipped: stock never offered them. `1.flt` (Darwin Default) and `2.flt` equal the kernel's
  built-in set 0 (sharp_roll_off), `3.flt` equals set 1, so the boot default already matches stock.
- The hm100 driver's "Digital Filter" has a last item "custom" (kernel series): the FIR Custom set,
  which a FIR Custom write selects. Stock's indices 0-6 keep their meaning.
- `darwinctl` (`userspace/darwinctl` on the main branch):
  - `darwinctl` / `darwinctl status`: active filter and NOS.
  - `darwinctl list [--porcelain]`: built-in filters, then Darwin filters in filter.json order with
    stock titles (works without the DAC too).
  - `darwinctl set <filter>`: a built-in name (`sharp_roll_off`, `slow-roll-off`, ...), a Darwin
    title or file name (`"Darwin 3"`, `darwin-10`, `raised-cosine-254-rolloff-normal`), a `.flt`
    path, or `custom` (the last Darwin filter again).
  - `darwinctl nos on|off`.
  - `darwinctl restore`: run by `darwinctl-restore.service` at sound.target after alsa-restore.
  - Own filters: `~/.local/share/hiby-rs6/darwin/*.flt`, optionally with a filter.json in stock's
    format (like stock's `/sdcard/filter`); they come first.
  - State: `/var/lib/hiby-rs6/darwin/{filter.flt,name}` (group audio, setgid). alsactl keeps the
    Digital Filter index across reboots, darwinctl the custom taps.
- RS6 DAC settings page: "Digital filter" lists the built-ins plus "Darwin filter"; with that one
  active, a "Darwin filter" combo lists the stock Darwin filters; "Load a Darwin filter file"
  takes any .flt. All of it goes through darwinctl, so it is kept for the next boot. The quick
  setting shows the active Darwin filter's name.
