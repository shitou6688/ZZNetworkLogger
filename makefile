# ZZNetworkLogger - Theos 项目

TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = ZZ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZZNetworkLogger

ZZNetworkLogger_FILES = Tweak.m
ZZNetworkLogger_CFLAGS = -fobjc-arc
ZZNetworkLogger_FRAMEWORKS = UIKit Foundation CFNetwork

include $(THEOS_MAKE_PATH)/tweak.mk
