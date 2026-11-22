include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ccplusprefs

ccplusprefs_FILES = CCPRootListController.m
ccplusprefs_FRAMEWORKS = UIKit
ccplusprefs_PRIVATE_FRAMEWORKS = Preferences
ccplusprefs_INSTALL_PATH = /Library/PreferenceBundles
ccplusprefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-error

include $(THEOS_MAKE_PATH)/bundle.mk
