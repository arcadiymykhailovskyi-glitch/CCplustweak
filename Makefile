TARGET := iphone:clang:latest:15.0
ARCHS = arm64
# palera1n rootless (по умолчанию). Для rootful (-f) закомментируй следующую строку:
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CCPlus
CCPlus_FILES = Tweak.x CXShared.m CXPickerController.m
CCPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
CCPlus_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
