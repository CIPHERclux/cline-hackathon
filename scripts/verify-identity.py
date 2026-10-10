"""Check presentation branding and renamed Xcode references without launching the app."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
app = root / "Chalk"

assert (root / "Chalk.xcodeproj/project.pbxproj").is_file()
assert (app / "ChalkApp.swift").is_file()
assert (app / "Chalk.entitlements").is_file()
assert (app / "ChalkAnalytics.swift").is_file()
assert (root / "LICENSE").read_bytes() == (app / "LICENSE.txt").read_bytes()

for file in app.glob("*.swift"):
    # Only this persisted key is retained to honor existing installation preferences.
    content = file.read_text().replace('"isClickyCursorEnabled"', '"legacyPreference"')
    assert not re.search(r"clicky|farza", content, re.I), file
    assert "HeyChalk" not in content, file

for file in [app / "Info.plist", app / "Chalk.entitlements"]:
    with file.open("rb") as handle:
        plistlib.load(handle)

scheme = ET.parse(root / "Chalk.xcodeproj/xcshareddata/xcschemes/Chalk.xcscheme")
for reference in scheme.findall(".//BuildableReference"):
    assert reference.attrib["ReferencedContainer"] == "container:Chalk.xcodeproj"
    assert reference.attrib["BlueprintName"] in {"Chalk", "ChalkTests", "ChalkUITests"}
    assert "Clicky" not in reference.attrib["BuildableName"]

icons = app / "Assets.xcassets/AppIcon.appiconset"
for image in json.loads((icons / "Contents.json").read_text())["images"]:
    assert (icons / image["filename"]).read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
assert (app / "ChalkIntroduction.mp4").stat().st_size > 1000
assert "stream.mux.com" not in (app / "CompanionManager.swift").read_text()
assert "ChalkIntroduction" in (app / "CompanionManager.swift").read_text()
assert "@testable import Chalk" in (root / "ChalkTests/ChalkTests.swift").read_text()
assert 'SCHEME="Chalk"' in (root / "scripts/release.sh").read_text()
assert 'APP_NAME="Chalk"' in (root / "scripts/release.sh").read_text()
assert not list(app.rglob("*steve*"))
assert not list(app.rglob("*codex*"))
renderer = (app / "AnnotationRenderer.swift").read_text()
assert "ChalkBeacon().path(in: pen.bounds).cgPath" in renderer
assert "let triangle = CGMutablePath()" not in renderer
assert "NSColor(DS.Colors.paper).cgColor" in renderer
roles = (app / "AnnotationColorRoles.swift").read_text()
assert "srgbRed:" not in roles
assert "DS.Colors.overlayBeacon" in roles
assert "DS.Colors.learnerInk" in roles
assert "AnnotationColorRole.learner.color" in (app / "DrawChordPanel.swift").read_text()
assert "AnnotationColorRole.learner.color" in (app / "LearnerDrawingImages.swift").read_text()
assert "NSColor(WhiteboardView.chalkColor)" in (app / "LatexLineView.swift").read_text()
for name in ["WalkthroughController.swift", "WhiteboardPanel.swift", "FigureRenderer.swift", "GuideCards.swift"]:
    assert (app / name).is_file(), name
turns = (app / "TeachingTurnController.swift").read_text()
assert "walkthroughController.start(goal: transcript" in turns
assert "task intent goes to the sole rolling planner" in turns
controller = (app / "WalkthroughController.swift").read_text()
assert "RollingGuidePlan.parse" in controller
assert "Rolling candidate validated locally" in controller
assert "UserDefaults.standard.bool(forKey: Self.adaptiveGuidanceDefaultsKey)" not in controller
assert "Use legacy guidance" not in controller
assert "annotationController.handle(action)" in turns
for file in app.glob("*.swift"):
    assert not re.search(r"#(?:3380FF|2563EB|60A5FA|5C9DFF)", file.read_text(), re.I), file
print("PASS: branding, project/scheme/test references, icons, local introduction and license")