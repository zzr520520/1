GO_EASY_ON_ME = 1
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = One
One_FILES = Tweak.xm
One_CFLAGS = -fobjc-arc
One_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
One_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
