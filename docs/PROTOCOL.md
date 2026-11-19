# PeriPage P81 Bluetooth protocol notes

These notes were observed on a PeriPage P81 (model ALD-P810), which advertises over Bluetooth LE as `PPG_P81_XXXX`.

## GATT

| Service | Characteristic | Properties | Use |
|---|---|---|---|
| `FF00` | `FF01` | notify | status (`4f 4b` = "OK", `aa` = page finished, `ff 01` = paper out) |
| `FF00` | `FF02` | write, write without response | **print data** |
| `FF00` | `FF03` | notify | flow control (see below) |
| `49535343-FE7D-…` | ISSC/Microchip transparent UART | | not used |

## Flow control (`FF03`)

- `02 LL HH`: maximum packet size, little-endian (`f0 00` = 240 bytes).
- `01 NN`: credit, meaning *NN more packets may be sent*. The printer sends one right after connecting and then keeps granting credits as it drains its buffer (usually `01 06`).

Send one packet (≤ max size) per credit with *write without response*.

## Print stream

The Bluetooth link takes the same byte stream the official macOS driver (`rastertolabel`) sends over USB:

```
10 ff fe 01  10 ff 10 03 01 …  1b 40 …  1b 61 01     setup (wake, init, align)
1d 76 30 00 wL wH hL hH <w*h bytes>                   ESC/POS raster image, one per page
1b 4a 00  10 ff fe 45                                 feed + end of page
```

Two timing rules matter:

1. **Wait after the setup commands.** Send everything before the first `1d 76 30`, then wait until the printer answers with two `OK`s on `FF01` (about 0.5–2 s). Image bytes sent before then are partly dropped, which shifts every row sideways.
2. **Between pages**, wait for `aa` ("page finished") before sending the next page.

## Resolution

The printer feeds paper at 203 dpi over Bluetooth, so render at 203×203 dpi (the driver's `PPG P81 SD` PPD). An A4 page is 1680 dots (210 bytes) wide and about 2347 rows tall, roughly 490 KB uncompressed. At 240-byte packets that takes about 23 s.
