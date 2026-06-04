PROJ = QPHelper.xcodeproj
SCHEME = QPHelper
CONFIG = Release
BUILD_DIR = ./build

# 不签名（个人本地工具无需签名/公证）
NO_SIGN = CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

# 自动检测当前架构
ARCH = $(shell uname -m)
INSTALL_DIR = /Applications

.PHONY: all x86_64 arm64 install uninstall clean

all: x86_64 arm64

x86_64:
	xcodebuild -project $(PROJ) -scheme $(SCHEME) -configuration $(CONFIG) \
		ARCHS="x86_64" \
		CONFIGURATION_BUILD_DIR=$(BUILD_DIR)/x86_64 \
		VALID_ARCHS="x86_64" \
		$(NO_SIGN) \
		clean build
	ditto -c -k --sequesterRsrc --keepParent $(BUILD_DIR)/x86_64/QPHelper.app $(BUILD_DIR)/QPHelper-x86_64.zip

arm64:
	xcodebuild -project $(PROJ) -scheme $(SCHEME) -configuration $(CONFIG) \
		ARCHS="arm64" \
		CONFIGURATION_BUILD_DIR=$(BUILD_DIR)/arm64 \
		VALID_ARCHS="arm64" \
		$(NO_SIGN) \
		clean build
	ditto -c -k --sequesterRsrc --keepParent $(BUILD_DIR)/arm64/QPHelper.app $(BUILD_DIR)/QPHelper-arm64.zip

install: $(ARCH)
	cp -R $(BUILD_DIR)/$(ARCH)/QPHelper.app $(INSTALL_DIR)/

uninstall:
	rm -rf $(INSTALL_DIR)/QPHelper.app

clean:
	rm -rf $(BUILD_DIR)
