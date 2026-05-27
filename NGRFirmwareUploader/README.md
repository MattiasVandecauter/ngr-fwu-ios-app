# NGR Firmware Uploader iOS App

Small SwiftUI/CoreBluetooth app that mirrors the BLE SMP firmware upload flow from
`tools/ble_fw_upgrade/ble_fw_upgrade.py`.

## What it does

1. Scans for an NGR/BRC target by name prefix.
2. Connects and discovers the FWU, capability, and SMP characteristics.
3. Sends `{"fwuMode": true}` to enter firmware update mode.
4. Uploads the ST image with Zephyr SMP image upload packets.
5. Waits for `readyForInfo`.
6. Uploads the nRF image with Zephyr SMP image upload packets.
7. Waits for `uploadSuccess`.

The app exposes the same practical tuning knobs as the Python uploader:

- SMP window size
- SMP payload size
- retry count
- write with/without BLE response

## Xcode setup

Open `NGRFirmwareUploader.xcodeproj` in Xcode.

Before running on a phone:

- Select the `NGRFirmwareUploader` target.
- Set your Apple Development Team under Signing & Capabilities.
- Keep the run destination set to a real iPhone; BLE firmware upload cannot be
  tested meaningfully in the simulator.

This was not built here; it needs Xcode and a real iPhone for BLE testing.
