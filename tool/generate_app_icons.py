"""Regenerate platform launcher icons from assets/branding/app_icon_master.png.

Run with Python 3 on macOS. Uses the system's `sips` utility; no Python
packages are required.
"""

import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/branding/app_icon_master.png"


def resize(source: Path, destination: Path, size: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["sips", "-s", "format", "png", "-z", str(size), str(size),
         str(source), "--out", str(destination)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def ios_icons() -> dict[Path, int]:
    icon_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((icon_dir / "Contents.json").read_text())
    return {
        icon_dir / item["filename"]: round(
            float(item["size"].split("x")[0]) * int(item["scale"][0])
        )
        for item in contents["images"]
    }


def main() -> None:
    if not SOURCE.is_file():
        raise FileNotFoundError(SOURCE)

    destinations = ios_icons()
    destinations.update({
        ROOT / f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png": size
        for size in (16, 32, 64, 128, 256, 512, 1024)
    })
    destinations.update({
        ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png": size
        for density, size in (
            ("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
            ("xxhdpi", 144), ("xxxhdpi", 192),
        )
    })
    destinations.update({
        ROOT / "linux/app_icon.png": 256,
        ROOT / "web/favicon.png": 32,
        ROOT / "web/icons/Icon-192.png": 192,
        ROOT / "web/icons/Icon-512.png": 512,
        ROOT / "web/icons/Icon-maskable-192.png": 192,
        ROOT / "web/icons/Icon-maskable-512.png": 512,
    })

    with tempfile.TemporaryDirectory(prefix="loi-chat-icons-") as directory:
        cache_dir = Path(directory)
        sizes = set(destinations.values()) | {16, 32, 48, 256}
        for size in sizes:
            resize(SOURCE, cache_dir / f"{size}.png", size)
        for destination, size in destinations.items():
            shutil.copyfile(cache_dir / f"{size}.png", destination)

        ico_sizes = (16, 32, 48, 256)
        header = struct.pack("<HHH", 0, 1, len(ico_sizes))
        entries = bytearray()
        payloads = bytearray()
        offset = len(header) + len(ico_sizes) * 16
        for size in ico_sizes:
            png = (cache_dir / f"{size}.png").read_bytes()
            entries.extend(struct.pack(
                "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32,
                len(png), offset,
            ))
            payloads.extend(png)
            offset += len(png)
        (ROOT / "windows/runner/resources/app_icon.ico").write_bytes(
            header + entries + payloads
        )

    print(f"Updated {len(destinations)} PNG icons and the Windows ICO.")


if __name__ == "__main__":
    main()
