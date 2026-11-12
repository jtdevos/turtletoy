.PHONY: run test app showcase clean

run:
	swift run -c release TurtleToy

test:
	swift test

app:
	swift build -c release
	@BIN_PATH=$$(swift build -c release --show-bin-path); \
	mkdir -p TurtleToy.app/Contents/MacOS TurtleToy.app/Contents/Resources; \
	cp "$$BIN_PATH/TurtleToy" TurtleToy.app/Contents/MacOS/TurtleToy; \
	chmod +x TurtleToy.app/Contents/MacOS/TurtleToy; \
	printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'    <key>CFBundleDevelopmentRegion</key><string>en</string>' \
	'    <key>CFBundleExecutable</key><string>TurtleToy</string>' \
	'    <key>CFBundleIdentifier</key><string>com.jim.TurtleToy</string>' \
	'    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>' \
	'    <key>CFBundleName</key><string>TurtleToy</string>' \
	'    <key>CFBundleDisplayName</key><string>TurtleToy</string>' \
	'    <key>CFBundlePackageType</key><string>APPL</string>' \
	'    <key>CFBundleShortVersionString</key><string>1.0.0</string>' \
	'    <key>CFBundleVersion</key><string>1</string>' \
	'    <key>LSMinimumSystemVersion</key><string>14.0</string>' \
	'    <key>NSHighResolutionCapable</key><true/>' \
	'</dict>' \
	'</plist>' > TurtleToy.app/Contents/Info.plist
	@echo "✅ Packaged TurtleToy.app — run 'open TurtleToy.app' to launch!"

showcase:
	swift run -c release TurtleToy --render-showcase ./showcase_renders

clean:
	rm -rf .build TurtleToy.app
