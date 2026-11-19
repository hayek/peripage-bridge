# PeriPage Bridge

Print to a **PeriPage P81** A4 thermal printer from any Mac app **over Bluetooth**, without the USB cable.

The official PeriPage macOS driver only prints over USB, and the PeriPage app only runs on iPhone/iPad. PeriPage Bridge connects the two: macOS uses the official driver to render each page, and a small background helper sends the result to the printer over Bluetooth LE.

```
Any app ─▶ File › Print ─▶ "PeriPage P81 (Bluetooth)"
              │  macOS printing (CUPS) + official PeriPage P81 driver
              ▼
        socket://127.0.0.1:9181
              │  PeriPage Bridge (background helper)
              ▼
        Bluetooth LE ─▶ PeriPage P81
```

## Install

1. Download **PeriPage-Bridge.zip** from the [latest release](../../releases/latest), unzip it, and open **PeriPage Bridge**.
2. Click **Set Up**. The app will:
   - copy itself to `~/Applications`
   - download and install the official PeriPage P81 driver from the manufacturer (it asks for your Mac password once). The installer runs only if Xiamen iLeadtek has signed it and Apple has notarized it.
   - ask for Bluetooth access
   - add the printer **PeriPage P81 (Bluetooth)**
   - start a background helper at login
3. Turn the printer on, disconnect the PeriPage iPhone app (the printer accepts only one Bluetooth connection at a time), and print from any app.

An A4 page takes about 25 seconds. Open the app again to **Repair** or **Uninstall**.

Requires macOS 13 or later, on Apple Silicon or Intel.

## Tips

- Set the paper size to **A4 (210×297 mm)** in the print dialog (this is the default).
- If content is clipped, enable **Scale to fit paper size**.
- Use **Printer Features** in the print dialog to change darkness, or switch the paper type between roll ("Stock") and folded ("Perforated").
- Logs: `~/Library/Logs/PeriPageBridge.log`

## Build from source

```sh
scripts/build.sh                               # ad-hoc signed, for your own Mac
SIGN_ID="Developer ID Application: …" scripts/build.sh
NOTARY_PROFILE=<profile> scripts/notarize.sh   # or ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
```

Set `BUNDLE_DRIVER=1` to embed the driver for offline installs. It's proprietary to the manufacturer, so don't redistribute builds that include it.

## How it works

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the Bluetooth protocol notes: the GATT services, credit-based flow control, and why the setup commands must be acknowledged before the image is sent.

## Notes

- Only the PeriPage P81 has been tested. Other PeriPage A4 models that use the same `FF00` Bluetooth service may also work with their own driver.
- The driver's **SD** variant (203×203 dpi) is used on purpose. Over Bluetooth, the HD/UHD variants (203×300 dpi) print pages stretched vertically by about 1.48×.
- This is an independent project, not affiliated with PeriPage or Xiamen iLeadtek.

## License

MIT, see [LICENSE](LICENSE). This license covers the code in this repository only. The PeriPage driver is © Xiamen iLeadtek and is downloaded from the manufacturer at install time.
