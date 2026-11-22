TARGET := iphone:clang:latest:15.0
# arm64 для A9–A11 (iPhone 6s–X), arm64e для A12 и новее (iPhone XS и новее, джейлбрейки вроде Dopamine)
ARCHS = arm64 arm64e
# rootless: palera1n (по умолчанию), Dopamine. Для rootful (palera1n -f) workflow собирает отдельный пакет.
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CCPlus
CCPlus_FILES = Tweak.x CXShared.m CXPickerController.m
CCPlus_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-error
CCPlus_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += ccplusprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
