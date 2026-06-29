# ZZNetworkLogger - 转转网络请求抓包 dylib
# 注入到转转 App，自动拦截 API 请求并上传到服务器
# Theos 项目文件

TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = ZZ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZZNetworkLogger

ZZNetworkLogger_FILES = Tweak.m
ZZNetworkLogger_CFLAGS = -fobjc-arc
ZZNetworkLogger_LDFLAGS = -lsqlite3
ZZNetworkLogger_FRAMEWORKS = UIKit Foundation CFNetwork
ZZNetworkLogger_PRIVATE_FRAMEWORKS = AppSupport

include $(THEOS_MAKE_PATH)/tweak.mk
