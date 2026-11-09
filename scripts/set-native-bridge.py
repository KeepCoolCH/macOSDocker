#!/usr/bin/env python3
import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["enable", "disable"])
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
enabled = args.mode == "enable"
path = root / "macOSDocker/macOSDocker.entitlements"
entitlements = plistlib.loads(path.read_bytes())
if enabled:
    entitlements["com.apple.vm.networking"] = True
else:
    entitlements.pop("com.apple.vm.networking", None)
info_path = root / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["MacOSDockerNativeBridgeEnabled"] = enabled
path.write_bytes(plistlib.dumps(entitlements))
info_path.write_bytes(plistlib.dumps(info))
print("Native Bridge aktiviert. Apple-Freigabe und passendes Profil erforderlich." if enabled else "Nur NAT aktiviert. VM Networking ist aus den Entitlements entfernt.")
