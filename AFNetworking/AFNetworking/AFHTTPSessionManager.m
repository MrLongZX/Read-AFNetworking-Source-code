// AFHTTPSessionManager.m
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFHTTPSessionManager.h"

#import "AFURLRequestSerialization.h"
#import "AFURLResponseSerialization.h"

#import <Availability.h>
#import <TargetConditionals.h>
#import <Security/Security.h>

#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>

#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#elif TARGET_OS_WATCH
#import <WatchKit/WatchKit.h>
#endif

@interface AFHTTPSessionManager ()
@property (readwrite, nonatomic, strong) NSURL *baseURL;
@end

@implementation AFHTTPSessionManager
@dynamic responseSerializer;

+ (instancetype)manager {
    return [[[self class] alloc] initWithBaseURL:nil];
}

- (instancetype)init {
    return [self initWithBaseURL:nil];
}

- (instancetype)initWithBaseURL:(NSURL *)url {
    return [self initWithBaseURL:url sessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    return [self initWithBaseURL:nil sessionConfiguration:configuration];
}

// 根据 url、configuration 参数 初始化对象
- (instancetype)initWithBaseURL:(NSURL *)url
           sessionConfiguration:(NSURLSessionConfiguration *)configuration
{
    // 调用父类 AFURLSessionManager 初始化方法
    self = [super initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    // Ensure terminal slash for baseURL path, so that NSURL +URLWithString:relativeToURL: works as expected
    // 处理 url，确保 baseURL 路径的斜杠，以便 NSURL +URLWithString:relativeToURL: 正常工作
    if ([[url path] length] > 0 && ![[url absoluteString] hasSuffix:@"/"]) {
        url = [url URLByAppendingPathComponent:@""];
    }

    self.baseURL = url;

    // 默认 http 请求序列化对象
    self.requestSerializer = [AFHTTPRequestSerializer serializer];
    // 默认 json 结果序列化对象
    self.responseSerializer = [AFJSONResponseSerializer serializer];

    return self;
}

#pragma mark -
// 请求序列化对象 setter 方法
- (void)setRequestSerializer:(AFHTTPRequestSerializer <AFURLRequestSerialization> *)requestSerializer {
    // 使用断言
    NSParameterAssert(requestSerializer);

    _requestSerializer = requestSerializer;
}

// 响应结果序列化对象 setter 方法
- (void)setResponseSerializer:(AFHTTPResponseSerializer <AFURLResponseSerialization> *)responseSerializer {
    // 使用断言
    NSParameterAssert(responseSerializer);

    // 调用父类 setter 方法
    [super setResponseSerializer:responseSerializer];
}

// securityPolicy 的 setter getter 自己实现
@dynamic securityPolicy;

// 实现 securityPolicy 的 setter 方法
- (void)setSecurityPolicy:(AFSecurityPolicy *)securityPolicy {
    if (securityPolicy.SSLPinningMode != AFSSLPinningModeNone && ![self.baseURL.scheme isEqualToString:@"https"]) {
        // 不是 https， 并且 securityPolicy.SSLPinningMode 不是 AFSSLPinningModeNone，为无效安全策略，抛出异常，
        NSString *pinningMode = @"Unknown Pinning Mode";
        switch (securityPolicy.SSLPinningMode) {
            case AFSSLPinningModeNone:        pinningMode = @"AFSSLPinningModeNone"; break;
            case AFSSLPinningModeCertificate: pinningMode = @"AFSSLPinningModeCertificate"; break;
            case AFSSLPinningModePublicKey:   pinningMode = @"AFSSLPinningModePublicKey"; break;
        }
        NSString *reason = [NSString stringWithFormat:@"A security policy configured with `%@` can only be applied on a manager with a secure base URL (i.e. https)", pinningMode];
        @throw [NSException exceptionWithName:@"Invalid Security Policy" reason:reason userInfo:nil];
    }

    // 设置父类中暴露的安全策略对象
    [super setSecurityPolicy:securityPolicy];
}

#pragma mark -

- (NSURLSessionDataTask *)GET:(NSString *)URLString
                   parameters:(nullable id)parameters
                      headers:(nullable NSDictionary <NSString *, NSString *> *)headers
                     progress:(nullable void (^)(NSProgress * _Nonnull))downloadProgress
                      success:(nullable void (^)(NSURLSessionDataTask * _Nonnull, id _Nullable))success
                      failure:(nullable void (^)(NSURLSessionDataTask * _Nullable, NSError * _Nonnull))failure
{
    // 获取 dataTask 对象
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"GET"
                                                        URLString:URLString
                                                       parameters:parameters
                                                          headers:headers
                                                   uploadProgress:nil
                                                 downloadProgress:downloadProgress
                                                          success:success
                                                          failure:failure];
    // dataTask 开始执行
    [dataTask resume];
    
    return dataTask;
}

- (NSURLSessionDataTask *)HEAD:(NSString *)URLString
                    parameters:(nullable id)parameters
                       headers:(nullable NSDictionary<NSString *,NSString *> *)headers
                       success:(nullable void (^)(NSURLSessionDataTask * _Nonnull))success
                       failure:(nullable void (^)(NSURLSessionDataTask * _Nullable, NSError * _Nonnull))failure
{
    // 获取 dataTask 对象
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"HEAD" URLString:URLString parameters:parameters headers:headers uploadProgress:nil downloadProgress:nil success:^(NSURLSessionDataTask *task, __unused id responseObject) {
        // 成功，只返回 task 即可
        if (success) {
            success(task);
        }
    } failure:failure];
    
    // dataTask 开始执行
    [dataTask resume];
    
    return dataTask;
}

- (nullable NSURLSessionDataTask *)POST:(NSString *)URLString
                             parameters:(nullable id)parameters
                                headers:(nullable NSDictionary <NSString *, NSString *> *)headers
                               progress:(nullable void (^)(NSProgress *uploadProgress))uploadProgress
                                success:(nullable void (^)(NSURLSessionDataTask *task, id _Nullable responseObject))success
                                failure:(nullable void (^)(NSURLSessionDataTask * _Nullable task, NSError *error))failure
{
    // 获取 dataTask 对象
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"POST" URLString:URLString parameters:parameters headers:headers uploadProgress:uploadProgress downloadProgress:nil success:success failure:failure];
    
    // dataTask 开始执行
    [dataTask resume];
    
    return dataTask;
}

- (NSURLSessionDataTask *)POST:(NSString *)URLString
                    parameters:(nullable id)parameters
                       headers:(nullable NSDictionary<NSString *,NSString *> *)headers
     constructingBodyWithBlock:(nullable void (^)(id<AFMultipartFormData> _Nonnull))block
                      progress:(nullable void (^)(NSProgress * _Nonnull))uploadProgress
                       success:(nullable void (^)(NSURLSessionDataTask * _Nonnull, id _Nullable))success failure:(void (^)(NSURLSessionDataTask * _Nullable, NSError * _Nonnull))failure
{
    NSError *serializationError = nil;
    // 通过请求序列化对象处理，获得request
    NSMutableURLRequest *request = [self.requestSerializer multipartFormRequestWithMethod:@"POST" URLString:[[NSURL URLWithString:URLString relativeToURL:self.baseURL] absoluteString] parameters:parameters constructingBodyWithBlock:block error:&serializationError];
    // 将参数 headers setValue 到 request 中
    for (NSString *headerField in headers.keyEnumerator) {
        [request setValue:headers[headerField] forHTTPHeaderField:headerField];
    }
    // 序列化出错
    if (serializationError) {
        if (failure) {
            // 存在失败回调，则调用，在设置的 completionQueue 中，没有设置则默认在主队列中
            dispatch_async(self.completionQueue ?: dispatch_get_main_queue(), ^{
                failure(nil, serializationError);
            });
        }
        
        return nil;
    }
    
    // 创建 task 对象
    __block NSURLSessionDataTask *task = [self uploadTaskWithStreamedRequest:request progress:uploadProgress completionHandler:^(NSURLResponse * __unused response, id responseObject, NSError *error) {
        if (error) {
            // 失败
            if (failure) {
                failure(task, error);
            }
        } else {
            if (success) {
                // 成功
                success(task, responseObject);
            }
        }
    }];
    
    // 启动 task
    [task resume];
    
    return task;
}

- (NSURLSessionDataTask *)PUT:(NSString *)URLString
                   parameters:(nullable id)parameters
                      headers:(nullable NSDictionary<NSString *,NSString *> *)headers
                      success:(nullable void (^)(NSURLSessionDataTask *task, id responseObject))success
                      failure:(nullable void (^)(NSURLSessionDataTask *task, NSError *error))failure
{
    // 创建 dataTask 对象
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"PUT" URLString:URLString parameters:parameters headers:headers uploadProgress:nil downloadProgress:nil success:success failure:failure];
    
    // 启动 task
    [dataTask resume];
    
    return dataTask;
}

- (NSURLSessionDataTask *)PATCH:(NSString *)URLString
                     parameters:(nullable id)parameters
                        headers:(nullable NSDictionary<NSString *,NSString *> *)headers
                        success:(nullable void (^)(NSURLSessionDataTask *task, id responseObject))success
                        failure:(nullable void (^)(NSURLSessionDataTask *task, NSError *error))failure
{
    // 创建 dataTask 对象
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"PATCH" URLString:URLString parameters:parameters headers:headers uploadProgress:nil downloadProgress:nil success:success failure:failure];
    
    // 启动 task
    [dataTask resume];
    
    return dataTask;
}

- (NSURLSessionDataTask *)DELETE:(NSString *)URLString
                      parameters:(nullable id)parameters
                         headers:(nullable NSDictionary<NSString *,NSString *> *)headers
                         success:(nullable void (^)(NSURLSessionDataTask *task, id responseObject))success
                         failure:(nullable void (^)(NSURLSessionDataTask *task, NSError *error))failure
{
    // 创建 dataTask 对象
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"DELETE" URLString:URLString parameters:parameters headers:headers uploadProgress:nil downloadProgress:nil success:success failure:failure];
    
    // 启动 task
    [dataTask resume];
    
    return dataTask;
}


- (NSURLSessionDataTask *)dataTaskWithHTTPMethod:(NSString *)method
                                       URLString:(NSString *)URLString
                                      parameters:(nullable id)parameters
                                         headers:(nullable NSDictionary <NSString *, NSString *> *)headers
                                  uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgress
                                downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgress
                                         success:(nullable void (^)(NSURLSessionDataTask *task, id _Nullable responseObject))success
                                         failure:(nullable void (^)(NSURLSessionDataTask * _Nullable task, NSError *error))failure
{
    NSError *serializationError = nil;
    // 进行序列化，获得 request 对象
    NSMutableURLRequest *request = [self.requestSerializer requestWithMethod:method URLString:[[NSURL URLWithString:URLString relativeToURL:self.baseURL] absoluteString] parameters:parameters error:&serializationError];
    // 将参数 headers setValue 到 request 中
    for (NSString *headerField in headers.keyEnumerator) {
        [request setValue:headers[headerField] forHTTPHeaderField:headerField];
    }
    if (serializationError) {
        // 序列化出错
        if (failure) {
            // 在 self.completionQueue 或 主队列中 执行错误回调
            dispatch_async(self.completionQueue ?: dispatch_get_main_queue(), ^{
                failure(nil, serializationError);
            });
        }

        return nil;
    }

    __block NSURLSessionDataTask *dataTask = nil;
    // 创建 dataTask 对象
    dataTask = [self dataTaskWithRequest:request
                          uploadProgress:uploadProgress
                        downloadProgress:downloadProgress
                       completionHandler:^(NSURLResponse * __unused response, id responseObject, NSError *error) {
        if (error) {
            // 存在错误
            if (failure) {
                // 执行错误回调
                failure(dataTask, error);
            }
        } else {
            // 成功
            if (success) {
                // 执行成功回调
                success(dataTask, responseObject);
            }
        }
    }];

    return dataTask;
}

#pragma mark - NSObject

// 复写 description 方法
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, baseURL: %@, session: %@, operationQueue: %@>", NSStringFromClass([self class]), self, [self.baseURL absoluteString], self.session, self.operationQueue];
}

#pragma mark - NSSecureCoding

// 支持 NSSecureCoding 协议 用于数据归档编码解码
+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    NSURL *baseURL = [decoder decodeObjectOfClass:[NSURL class] forKey:NSStringFromSelector(@selector(baseURL))];
    NSURLSessionConfiguration *configuration = [decoder decodeObjectOfClass:[NSURLSessionConfiguration class] forKey:@"sessionConfiguration"];
    if (!configuration) {
        NSString *configurationIdentifier = [decoder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
        if (configurationIdentifier) {
            configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:configurationIdentifier];
        }
    }

    self = [self initWithBaseURL:baseURL sessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    self.requestSerializer = [decoder decodeObjectOfClass:[AFHTTPRequestSerializer class] forKey:NSStringFromSelector(@selector(requestSerializer))];
    self.responseSerializer = [decoder decodeObjectOfClass:[AFHTTPResponseSerializer class] forKey:NSStringFromSelector(@selector(responseSerializer))];
    AFSecurityPolicy *decodedPolicy = [decoder decodeObjectOfClass:[AFSecurityPolicy class] forKey:NSStringFromSelector(@selector(securityPolicy))];
    if (decodedPolicy) {
        self.securityPolicy = decodedPolicy;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:self.baseURL forKey:NSStringFromSelector(@selector(baseURL))];
    if ([self.session.configuration conformsToProtocol:@protocol(NSCoding)]) {
        [coder encodeObject:self.session.configuration forKey:@"sessionConfiguration"];
    } else {
        [coder encodeObject:self.session.configuration.identifier forKey:@"identifier"];
    }
    [coder encodeObject:self.requestSerializer forKey:NSStringFromSelector(@selector(requestSerializer))];
    [coder encodeObject:self.responseSerializer forKey:NSStringFromSelector(@selector(responseSerializer))];
    [coder encodeObject:self.securityPolicy forKey:NSStringFromSelector(@selector(securityPolicy))];
}

#pragma mark - NSCopying

// 支持 NSCopying 协议
- (instancetype)copyWithZone:(NSZone *)zone {
    AFHTTPSessionManager *HTTPClient = [[[self class] allocWithZone:zone] initWithBaseURL:self.baseURL sessionConfiguration:self.session.configuration];

    HTTPClient.requestSerializer = [self.requestSerializer copyWithZone:zone];
    HTTPClient.responseSerializer = [self.responseSerializer copyWithZone:zone];
    HTTPClient.securityPolicy = [self.securityPolicy copyWithZone:zone];
    return HTTPClient;
}

@end
