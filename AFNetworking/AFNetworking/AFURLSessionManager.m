// AFURLSessionManager.m
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

#import "AFURLSessionManager.h"
#import <objc/runtime.h>

// 创建队列
static dispatch_queue_t url_session_manager_processing_queue() {
    static dispatch_queue_t af_url_session_manager_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_processing_queue = dispatch_queue_create("com.alamofire.networking.session.manager.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_url_session_manager_processing_queue;
}

// 创建group
static dispatch_group_t url_session_manager_completion_group() {
    static dispatch_group_t af_url_session_manager_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_completion_group = dispatch_group_create();
    });

    return af_url_session_manager_completion_group;
}

NSString * const AFNetworkingTaskDidResumeNotification = @"com.alamofire.networking.task.resume";
NSString * const AFNetworkingTaskDidCompleteNotification = @"com.alamofire.networking.task.complete";
NSString * const AFNetworkingTaskDidSuspendNotification = @"com.alamofire.networking.task.suspend";
NSString * const AFURLSessionDidInvalidateNotification = @"com.alamofire.networking.session.invalidate";
NSString * const AFURLSessionDownloadTaskDidMoveFileSuccessfullyNotification = @"com.alamofire.networking.session.download.file-manager-succeed";
NSString * const AFURLSessionDownloadTaskDidFailToMoveFileNotification = @"com.alamofire.networking.session.download.file-manager-error";

NSString * const AFNetworkingTaskDidCompleteSerializedResponseKey = @"com.alamofire.networking.task.complete.serializedresponse";
NSString * const AFNetworkingTaskDidCompleteResponseSerializerKey = @"com.alamofire.networking.task.complete.responseserializer";
NSString * const AFNetworkingTaskDidCompleteResponseDataKey = @"com.alamofire.networking.complete.finish.responsedata";
NSString * const AFNetworkingTaskDidCompleteErrorKey = @"com.alamofire.networking.task.complete.error";
NSString * const AFNetworkingTaskDidCompleteAssetPathKey = @"com.alamofire.networking.task.complete.assetpath";
NSString * const AFNetworkingTaskDidCompleteSessionTaskMetrics = @"com.alamofire.networking.complete.sessiontaskmetrics";

static NSString * const AFURLSessionManagerLockName = @"com.alamofire.networking.session.manager.lock";

typedef void (^AFURLSessionDidBecomeInvalidBlock)(NSURLSession *session, NSError *error);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);

typedef NSURLRequest * (^AFURLSessionTaskWillPerformHTTPRedirectionBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request);
typedef NSURLSessionAuthChallengeDisposition (^AFURLSessionTaskDidReceiveAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential);
typedef id (^AFURLSessionTaskAuthenticationChallengeBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLAuthenticationChallenge *challenge, void (^completionHandler)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential));
typedef void (^AFURLSessionDidFinishEventsForBackgroundURLSessionBlock)(NSURLSession *session);

typedef NSInputStream * (^AFURLSessionTaskNeedNewBodyStreamBlock)(NSURLSession *session, NSURLSessionTask *task);
typedef void (^AFURLSessionTaskDidSendBodyDataBlock)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend);
typedef void (^AFURLSessionTaskDidCompleteBlock)(NSURLSession *session, NSURLSessionTask *task, NSError *error);
#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
typedef void (^AFURLSessionTaskDidFinishCollectingMetricsBlock)(NSURLSession *session, NSURLSessionTask *task, NSURLSessionTaskMetrics * metrics) AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10));
#endif

typedef NSURLSessionResponseDisposition (^AFURLSessionDataTaskDidReceiveResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response);
typedef void (^AFURLSessionDataTaskDidBecomeDownloadTaskBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask);
typedef void (^AFURLSessionDataTaskDidReceiveDataBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data);
typedef NSCachedURLResponse * (^AFURLSessionDataTaskWillCacheResponseBlock)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse);

typedef NSURL * (^AFURLSessionDownloadTaskDidFinishDownloadingBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location);
typedef void (^AFURLSessionDownloadTaskDidWriteDataBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
typedef void (^AFURLSessionDownloadTaskDidResumeBlock)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes);
typedef void (^AFURLSessionTaskProgressBlock)(NSProgress *);

typedef void (^AFURLSessionTaskCompletionHandler)(NSURLResponse *response, id responseObject, NSError *error);

#pragma mark -

// 遵循 NSURLSession 的三个代理
// 本类主要用来处理任务的 下载进度 和 上传进度
@interface AFURLSessionManagerTaskDelegate : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
- (instancetype)initWithTask:(NSURLSessionTask *)task;
@property (nonatomic, weak) AFURLSessionManager *manager;
@property (nonatomic, strong) NSMutableData *mutableData;
@property (nonatomic, strong) NSProgress *uploadProgress;
@property (nonatomic, strong) NSProgress *downloadProgress;
@property (nonatomic, copy) NSURL *downloadFileURL;
#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
@property (nonatomic, strong) NSURLSessionTaskMetrics *sessionTaskMetrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10));
#endif
// downloadTask完成下载block，用于获取下载文件目标地址
@property (nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
// 上传进度block
@property (nonatomic, copy) AFURLSessionTaskProgressBlock uploadProgressBlock;
// 下载进度block
@property (nonatomic, copy) AFURLSessionTaskProgressBlock downloadProgressBlock;
// 完成进度block
@property (nonatomic, copy) AFURLSessionTaskCompletionHandler completionHandler;
@end

@implementation AFURLSessionManagerTaskDelegate

// 创建 taskDelegate 对象
- (instancetype)initWithTask:(NSURLSessionTask *)task {
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _mutableData = [NSMutableData data];
    // 上传进度
    _uploadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    // 下载进度
    _downloadProgress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
    
    __weak __typeof__(task) weakTask = task;
    for (NSProgress *progress in @[ _uploadProgress, _downloadProgress ])
    {
        progress.totalUnitCount = NSURLSessionTransferSizeUnknown;
        // 可以取消
        progress.cancellable = YES;
        // 取消回调
        progress.cancellationHandler = ^{
            // task 取消
            [weakTask cancel];
        };
        // 可以暂停
        progress.pausable = YES;
        // 暂停回调
        progress.pausingHandler = ^{
            // task 暂停
            [weakTask suspend];
        };
#if AF_CAN_USE_AT_AVAILABLE
        if (@available(macOS 10.11, *))
#else
        if ([progress respondsToSelector:@selector(setResumingHandler:)])
#endif
        {
            // 恢复回调
            progress.resumingHandler = ^{
                // task 恢复
                [weakTask resume];
            };
        }
        
        // 添加观察者 fractionCompleted : 某个任务已完成单元量占总单元量的比例
        [progress addObserver:self
                   forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
    }
    return self;
}

- (void)dealloc {
    // 移除观察者
    [self.downloadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
    [self.uploadProgress removeObserver:self forKeyPath:NSStringFromSelector(@selector(fractionCompleted))];
}

#pragma mark - NSProgress Tracking

// 观察者调用方法
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
   if ([object isEqual:self.downloadProgress]) {
        if (self.downloadProgressBlock) {
            // 调用下载进度回调,回调下载进度条对象
            self.downloadProgressBlock(object);
        }
    }
    else if ([object isEqual:self.uploadProgress]) {
        if (self.uploadProgressBlock) {
            // 调用上传进度回调,回调上传进度条对象
            self.uploadProgressBlock(object);
        }
    }
}

static const void * const AuthenticationChallengeErrorKey = &AuthenticationChallengeErrorKey;

#pragma mark - NSURLSessionTaskDelegate

// session 完成任务
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    // 通过关联对象方式,获取授权失败信息,如果存在,则使用授权失败信息,否则使用代理方法返回的error
    error = objc_getAssociatedObject(task, AuthenticationChallengeErrorKey) ?: error;
    // 当前 AFURLSessionManager 对象
    __strong AFURLSessionManager *manager = self.manager;

    __block id responseObject = nil;

    // 新建 userInfo 字典对象,用于保存一些信息,给通知传递信息使用
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    // 保存响应序列化对象
    userInfo[AFNetworkingTaskDidCompleteResponseSerializerKey] = manager.responseSerializer;

    //Performance Improvement from #2672
    NSData *data = nil;
    if (self.mutableData) {
        // 如果 self.mutableData 不为空,则将数据 copy 给临时变量 data
        data = [self.mutableData copy];
        //We no longer need the reference, so nil it out to gain back some memory.
        // 设置为nil,释放获取一些内存
        self.mutableData = nil;
    }

#if AF_CAN_USE_AT_AVAILABLE && AF_CAN_INCLUDE_SESSION_TASK_METRICS
    if (@available(iOS 10, macOS 10.12, watchOS 3, tvOS 10, *)) {
        if (self.sessionTaskMetrics) {
            // 保存task指标
            userInfo[AFNetworkingTaskDidCompleteSessionTaskMetrics] = self.sessionTaskMetrics;
        }
    }
#endif

    if (self.downloadFileURL) {
        // 保存下载文件路径
        userInfo[AFNetworkingTaskDidCompleteAssetPathKey] = self.downloadFileURL;
    } else if (data) {
        // 保存响应数据
        userInfo[AFNetworkingTaskDidCompleteResponseDataKey] = data;
    }

    if (error) {
        // 请求存在 error
        // 保存错误信息
        userInfo[AFNetworkingTaskDidCompleteErrorKey] = error;

        // 如果开发者没有提供 completionGroup、completionQueue,则使用默认创建的 group 与 主队列
        // 使用 dispatch_group_async,应该是留给开发者使用 dispatch_group_notify 的方式,来监听 completionGroup 中所有任务的完成
        dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
            if (self.completionHandler) {
                // 调用完成回调
                self.completionHandler(task.response, responseObject, error);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                // 主线程 发送 task 完成通知,
                // 在 AFNetworkActivityIndicatorManager、UIActivityIndicatorView+AFNetworking、UIRefreshControl+AFNetworking 中有注册此通知来使用
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
            });
        });
    } else {
        // 请求成功
        dispatch_async(url_session_manager_processing_queue(), ^{
            NSError *serializationError = nil;
            // 使用响应序列化对象,对返回内容进行序列化
            responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:data error:&serializationError];

            if (self.downloadFileURL) {
                // 如果存在 downloadFileURL(下载文件地址),则返回文件下载地址
                responseObject = self.downloadFileURL;
            }

            if (responseObject) {
                // 保存序列化结果对象
                userInfo[AFNetworkingTaskDidCompleteSerializedResponseKey] = responseObject;
            }

            if (serializationError) {
                // 保存序列化error
                userInfo[AFNetworkingTaskDidCompleteErrorKey] = serializationError;
            }

            // 如果开发者没有提供 completionGroup、completionQueue,则使用默认创建的 group 与 主队列
            // 使用 dispatch_group_async,应该是留给开发者使用 dispatch_group_notify 的方式,来监听 completionGroup 中所有任务的完成
            dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                if (self.completionHandler) {
                    // 调用完成回调
                    self.completionHandler(task.response, responseObject, serializationError);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    // 主线程 发送 task 完成通知,
                    // 在 AFNetworkActivityIndicatorManager、UIActivityIndicatorView+AFNetworking、UIRefreshControl+AFNetworking 中有注册此通知来使用
                    [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
                });
            });
        });
    }
}

#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
// 完成 task 指标收集
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10)) {
    // 保存 task 指标
    self.sessionTaskMetrics = metrics;
}
#endif

#pragma mark - NSURLSessionDataDelegate

// dataTask 接受到服务器数据
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(__unused NSURLSession *)session
          dataTask:(__unused NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    // 更新下载进度条总下载量
    self.downloadProgress.totalUnitCount = dataTask.countOfBytesExpectedToReceive;
    // 更新下载进度条已完成下载量
    self.downloadProgress.completedUnitCount = dataTask.countOfBytesReceived;

    // 保存本次下载返回的数据
    [self.mutableData appendData:data];
}

// task 上传数据
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend{
    // 更新上传进度条总上传量
    self.uploadProgress.totalUnitCount = task.countOfBytesExpectedToSend;
    // 更新上传进度条已完成上传量
    self.uploadProgress.completedUnitCount = task.countOfBytesSent;
}

#pragma mark - NSURLSessionDownloadDelegate

// session downloadTask 下载数据中
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite{
    // 更新下载进度条总下载量
    self.downloadProgress.totalUnitCount = totalBytesExpectedToWrite;
    // 更新下载进度条已完成下载量
    self.downloadProgress.completedUnitCount = totalBytesWritten;
}

// session 下载任务恢复
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes{
    // 更新下载进度条总下载量
    self.downloadProgress.totalUnitCount = expectedTotalBytes;
    // 更新下载进度条已完成下载量
    self.downloadProgress.completedUnitCount = fileOffset;
}

// session 完成下载
// 此代理方法在 AFURLSessionManager 中的同名代理方法中被调用
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    // 下载文件地址置空
    self.downloadFileURL = nil;

    if (self.downloadTaskDidFinishDownloading) {
        // 调用downloadTaskDidFinishDownloading,获取文件下载目标地址
        self.downloadFileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (self.downloadFileURL) {
            NSError *fileManagerError = nil;

            // 处理下载文件路径
            if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:self.downloadFileURL error:&fileManagerError]) {
                // 发送移动下载文件失败通知
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:fileManagerError.userInfo];
            } else {
                // 发送移动下载文件成功通知
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidMoveFileSuccessfullyNotification object:downloadTask userInfo:nil];
            }
        }
    }
}

@end

#pragma mark -

/**
 *  A workaround for issues related to key-value observing the `state` of an `NSURLSessionTask`.
 *
 *  See:
 *  - https://github.com/AFNetworking/AFNetworking/issues/1477
 *  - https://github.com/AFNetworking/AFNetworking/issues/2638
 *  - https://github.com/AFNetworking/AFNetworking/pull/2702
 */

// 方法交互
static inline void af_swizzleSelector(Class theClass, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(theClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(theClass, swizzledSelector);
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

// 给类对象添加方法
static inline BOOL af_addMethod(Class theClass, SEL selector, Method method) {
    return class_addMethod(theClass, selector,  method_getImplementation(method),  method_getTypeEncoding(method));
}

static NSString * const AFNSURLSessionTaskDidResumeNotification  = @"com.alamofire.networking.nsurlsessiontask.resume";
static NSString * const AFNSURLSessionTaskDidSuspendNotification = @"com.alamofire.networking.nsurlsessiontask.suspend";

@interface _AFURLSessionTaskSwizzling : NSObject

@end

// 本类实现对 NSURLSessionTask 及其父类 的 resume 和 suspend 方法进行方法交换的功能
@implementation _AFURLSessionTaskSwizzling

+ (void)load {
    /**
     WARNING: Trouble Ahead
     https://github.com/AFNetworking/AFNetworking/pull/2702
     */

    // 存在 NSURLSessionTask 类
    if (NSClassFromString(@"NSURLSessionTask")) {
        /**
         iOS 7 and iOS 8 differ in NSURLSessionTask implementation, which makes the next bit of code a bit tricky.
         Many Unit Tests have been built to validate as much of this behavior has possible.
         Here is what we know:
            - NSURLSessionTasks are implemented with class clusters, meaning the class you request from the API isn't actually the type of class you will get back.
            - Simply referencing `[NSURLSessionTask class]` will not work. You need to ask an `NSURLSession` to actually create an object, and grab the class from there.
            - On iOS 7, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `__NSCFURLSessionTask`.
            - On iOS 8, `localDataTask` is a `__NSCFLocalDataTask`, which inherits from `__NSCFLocalSessionTask`, which inherits from `NSURLSessionTask`.
            - On iOS 7, `__NSCFLocalSessionTask` and `__NSCFURLSessionTask` are the only two classes that have their own implementations of `resume` and `suspend`, and `__NSCFLocalSessionTask` DOES NOT CALL SUPER. This means both classes need to be swizzled.
            - On iOS 8, `NSURLSessionTask` is the only class that implements `resume` and `suspend`. This means this is the only class that needs to be swizzled.
            - Because `NSURLSessionTask` is not involved in the class hierarchy for every version of iOS, its easier to add the swizzled methods to a dummy class and manage them there.
        
         Some Assumptions:
            - No implementations of `resume` or `suspend` call super. If this were to change in a future version of iOS, we'd need to handle it.
            - No background task classes override `resume` or `suspend`
         
         The current solution:
            1) Grab an instance of `__NSCFLocalDataTask` by asking an instance of `NSURLSession` for a data task.
            2) Grab a pointer to the original implementation of `af_resume`
            3) Check to see if the current class has an implementation of resume. If so, continue to step 4.
            4) Grab the super class of the current class.
            5) Grab a pointer for the current class to the current implementation of `resume`.
            6) Grab a pointer for the super class to the current implementation of `resume`.
            7) If the current class implementation of `resume` is not equal to the super class implementation of `resume` AND the current implementation of `resume` is not equal to the original implementation of `af_resume`, THEN swizzle the methods
            8) Set the current class to the super class, and repeat steps 3-8
         */
        // 创建临时 configuration
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        // 创建 session
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
// 预编译指令，避免发生编译器警告
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull"
        // 创建 dataTask
        NSURLSessionDataTask *localDataTask = [session dataTaskWithURL:nil];
#pragma clang diagnostic pop
        // 获取 af_resume 的 imp
        IMP originalAFResumeIMP = method_getImplementation(class_getInstanceMethod([self class], @selector(af_resume)));
        Class currentClass = [localDataTask class];
        
        // currentClass 类 存在 resume 方法的实现
        while (class_getInstanceMethod(currentClass, @selector(resume))) {
            // 获取父类
            Class superClass = [currentClass superclass];
            IMP classResumeIMP = method_getImplementation(class_getInstanceMethod(currentClass, @selector(resume)));
            IMP superclassResumeIMP = method_getImplementation(class_getInstanceMethod(superClass, @selector(resume)));
            // 当 currentClass 父类 与 currentClass 类的 resume 方法实现不同，并且与 af_resume 的方法实现不同
            if (classResumeIMP != superclassResumeIMP &&
                originalAFResumeIMP != classResumeIMP) {
                // 对 currentClass 的 resume 与 suspend 方法进行方法交互
                [self swizzleResumeAndSuspendMethodForClass:currentClass];
            }
            // 当前类变为当前类的父类
            currentClass = [currentClass superclass];
        }
        
        // task 取消
        [localDataTask cancel];
        // session 完成并失效
        [session finishTasksAndInvalidate];
    }
}

+ (void)swizzleResumeAndSuspendMethodForClass:(Class)theClass {
    // self 对象的 af_resume 方法
    Method afResumeMethod = class_getInstanceMethod(self, @selector(af_resume));
    // self 对象的 af_suspend 方法
    Method afSuspendMethod = class_getInstanceMethod(self, @selector(af_suspend));

    // 给 theClass 添加 af_resume 方法
    if (af_addMethod(theClass, @selector(af_resume), afResumeMethod)) {
        // theClass 类对象进行方法交互
        af_swizzleSelector(theClass, @selector(resume), @selector(af_resume));
    }

    // 给 theClass 添加 af_suspend 方法
    if (af_addMethod(theClass, @selector(af_suspend), afSuspendMethod)) {
        // theClass 类对象进行方法交互
        af_swizzleSelector(theClass, @selector(suspend), @selector(af_suspend));
    }
}

// 这个方法是不会被调用到的
- (NSURLSessionTaskState)state {
    NSAssert(NO, @"State method should never be called in the actual dummy class");
    return NSURLSessionTaskStateCanceling;
}

- (void)af_resume {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    // 由于该方法添加到 NSURLSessionDataTask 类及其父类中，并进行了方法交互，所以当本需要执行 resume 方法时，会执行该方法，self 是 NSURLSessionDataTask 对象或其父类对象，
    // 所以 [self state] 执行的是 NSURLSessionDataTask 对象或其父类对象中的 state 方法
    NSURLSessionTaskState state = [self state];
    // 调用原始恢复方法，task 的 state 将变为 running
    [self af_resume];
    
    // state 为调用原始恢复方法前获取，所以不是 running
    if (state != NSURLSessionTaskStateRunning) {
        // 发送恢复通知
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidResumeNotification object:self];
    }
}

- (void)af_suspend {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    // 由于该方法添加到 NSURLSessionDataTask 类及其父类中，并进行了方法交互，所以当本需要执行 suspend 方法时，会执行该方法，self 是 NSURLSessionDataTask 对象或其父类对象，
    // 所以 [self state] 执行的是 NSURLSessionDataTask 对象或其父类对象中的 state 方法
    NSURLSessionTaskState state = [self state];
    // 调用原始暂停方法，task 的 state 将变为 suspended
    [self af_suspend];
    
    // state 为调用原始暂停方法前获取，所以不是 suspended
    if (state != NSURLSessionTaskStateSuspended) {
        // 发送暂停通知
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidSuspendNotification object:self];
    }
}
@end

#pragma mark -

@interface AFURLSessionManager ()
@property (readwrite, nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (readwrite, nonatomic, strong) NSOperationQueue *operationQueue;
@property (readwrite, nonatomic, strong) NSURLSession *session;
@property (readwrite, nonatomic, strong) NSMutableDictionary *mutableTaskDelegatesKeyedByTaskIdentifier;
@property (readonly, nonatomic, copy) NSString *taskDescriptionForSessionTasks;
@property (readwrite, nonatomic, strong) NSLock *lock;
@property (readwrite, nonatomic, copy) AFURLSessionDidBecomeInvalidBlock sessionDidBecomeInvalid;
@property (readwrite, nonatomic, copy) AFURLSessionDidReceiveAuthenticationChallengeBlock sessionDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionDidFinishEventsForBackgroundURLSessionBlock didFinishEventsForBackgroundURLSession AF_API_UNAVAILABLE(macos);
@property (readwrite, nonatomic, copy) AFURLSessionTaskWillPerformHTTPRedirectionBlock taskWillPerformHTTPRedirection;
@property (readwrite, nonatomic, copy) AFURLSessionTaskAuthenticationChallengeBlock authenticationChallengeHandler;
@property (readwrite, nonatomic, copy) AFURLSessionTaskNeedNewBodyStreamBlock taskNeedNewBodyStream;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidSendBodyDataBlock taskDidSendBodyData;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidCompleteBlock taskDidComplete;
#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidFinishCollectingMetricsBlock taskDidFinishCollectingMetrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10));
#endif
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveResponseBlock dataTaskDidReceiveResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidBecomeDownloadTaskBlock dataTaskDidBecomeDownloadTask;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveDataBlock dataTaskDidReceiveData;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskWillCacheResponseBlock dataTaskWillCacheResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidWriteDataBlock downloadTaskDidWriteData;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidResumeBlock downloadTaskDidResume;
@end

@implementation AFURLSessionManager

- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }

    // configuration 参数为nil，则创建默认configuration
    if (!configuration) {
        configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }

    self.sessionConfiguration = configuration;

    // 创建队列，最大并发数为1，用于创建 NSURLSession 对象
    self.operationQueue = [[NSOperationQueue alloc] init];
    self.operationQueue.maxConcurrentOperationCount = 1;

    // json结果序列化对象
    self.responseSerializer = [AFJSONResponseSerializer serializer];
    // 安全策略对象
    self.securityPolicy = [AFSecurityPolicy defaultPolicy];

#if !TARGET_OS_WATCH
    // 网络可用性管理者
    self.reachabilityManager = [AFNetworkReachabilityManager sharedManager];
#endif

    self.mutableTaskDelegatesKeyedByTaskIdentifier = [[NSMutableDictionary alloc] init];

    // lock锁
    self.lock = [[NSLock alloc] init];
    self.lock.name = AFURLSessionManagerLockName;

    // 从 session 中异步获取所有未完成的 task ,
    // 在 completionHandler 回调中，为了防止进入前台时，通过 session id 恢复的 task 导致一些崩溃问题，所以这里将之前的task进行遍历，并将回调都置nil。
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        // dataTask
        for (NSURLSessionDataTask *task in dataTasks) {
            [self addDelegateForDataTask:task uploadProgress:nil downloadProgress:nil completionHandler:nil];
        }

        // uploadTask
        for (NSURLSessionUploadTask *uploadTask in uploadTasks) {
            [self addDelegateForUploadTask:uploadTask progress:nil completionHandler:nil];
        }

        // downloadTask
        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            [self addDelegateForDownloadTask:downloadTask progress:nil destination:nil completionHandler:nil];
        }
    }];

    return self;
}

- (void)dealloc {
    //  移除所有通知
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -

- (NSURLSession *)session {
    // 使用 @synchronized 锁
    @synchronized (self) {
        if (!_session) {
            // 创建 NSURLSession 对象，参数为 configuration、 self、最大并发数为1的队列，通过 _session 创建的所有 task 的代理方法 或 block 完成回调都将在 self.operationQueue 执行
            _session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];
        }
    }
    return _session;
}

#pragma mark -


- (NSString *)taskDescriptionForSessionTasks {
    // 返回 self 对象内存地址
    return [NSString stringWithFormat:@"%p", self];
}

// task 恢复执行的通知方法
- (void)taskDidResume:(NSNotification *)notification {
    NSURLSessionTask *task = notification.object;
    if ([task respondsToSelector:@selector(taskDescription)]) {
        // task 可以调用 taskDescription 方法
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            // task.taskDescription 是本 AFURLSessionManager 对象的内存地址，
            // task.taskDescription 在 addDelegateForDataTask 方法中设置的，目的是为保证 task 是本 AFURLSessionManager 对象中创建的
            dispatch_async(dispatch_get_main_queue(), ^{
                // 主线程发送通知
                // 在 AFNetworkActivityIndicatorManager、UIActivityIndicatorView+AFNetworking、UIRefreshControl+AFNetworking 中有注册此通知来使用
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidResumeNotification object:task];
            });
        }
    }
}

// task 暂停执行的通知方法
- (void)taskDidSuspend:(NSNotification *)notification {
    NSURLSessionTask *task = notification.object;
    if ([task respondsToSelector:@selector(taskDescription)]) {
        // task 可以调用 taskDescription 方法
        if ([task.taskDescription isEqualToString:self.taskDescriptionForSessionTasks]) {
            // task.taskDescription 是本 AFURLSessionManager 对象的内存地址，
            // task.taskDescription 在 addDelegateForDataTask 方法中设置的，目的是为保证 task 是本 AFURLSessionManager 对象中创建的
            dispatch_async(dispatch_get_main_queue(), ^{
                // 主线程发送通知
                // 在 AFNetworkActivityIndicatorManager、UIActivityIndicatorView+AFNetworking、UIRefreshControl+AFNetworking 中有注册此通知来使用
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidSuspendNotification object:task];
            });
        }
    }
}

#pragma mark -

// 根据 task 获取对应的 taskDelegate 对象
- (AFURLSessionManagerTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    // 使用断言 判断是否为nil
    NSParameterAssert(task);

    AFURLSessionManagerTaskDelegate *delegate = nil;
    // 加锁
    [self.lock lock];
    // 根据 task.taskIdentifier 从字典中取出 taskDelegate 对象
    delegate = self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)];
    // 开锁
    [self.lock unlock];

    return delegate;
}

- (void)setDelegate:(AFURLSessionManagerTaskDelegate *)delegate
            forTask:(NSURLSessionTask *)task
{
    // 使用断言 判断是否为nil
    NSParameterAssert(task);
    NSParameterAssert(delegate);

    // 加锁
    [self.lock lock];
    // task id 作 key，task delegate 作 value，存入字典
    self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)] = delegate;
    // 对 task 添加通知
    [self addNotificationObserverForTask:task];
    // 开锁
    [self.lock unlock];
}

- (void)addDelegateForDataTask:(NSURLSessionDataTask *)dataTask
                uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
              downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
             completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 创建 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] initWithTask:dataTask];
    // 设置 delegate 对象的 AFURLSessionManager *manager 属性
    delegate.manager = self;
    // 设置完成回调
    delegate.completionHandler = completionHandler;

    // 内存地址 作为 taskDescription
    dataTask.taskDescription = self.taskDescriptionForSessionTasks;
    // 将 taskDelegate 存储起来， 并对 dataTask 添加暂停、恢复通知
    [self setDelegate:delegate forTask:dataTask];

    // 设置上传回调
    delegate.uploadProgressBlock = uploadProgressBlock;
    // 设置下载回调
    delegate.downloadProgressBlock = downloadProgressBlock;
}

- (void)addDelegateForUploadTask:(NSURLSessionUploadTask *)uploadTask
                        progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
               completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 创建 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] initWithTask:uploadTask];
    // 设置 delegate 对象的 AFURLSessionManager *manager 属性
    delegate.manager = self;
    // 设置完成回调
    delegate.completionHandler = completionHandler;

    // 内存地址 作为 taskDescription
    uploadTask.taskDescription = self.taskDescriptionForSessionTasks;

    // 将 taskDelegate 存储起来， 并对 uploadTask 添加暂停、恢复通知
    [self setDelegate:delegate forTask:uploadTask];

    // 设置上传回调
    delegate.uploadProgressBlock = uploadProgressBlock;
}

- (void)addDelegateForDownloadTask:(NSURLSessionDownloadTask *)downloadTask
                          progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                       destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                 completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    // 创建 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] initWithTask:downloadTask];
    // 设置 delegate 对象的 AFURLSessionManager *manager 属性
    delegate.manager = self;
    // 设置完成回调
    delegate.completionHandler = completionHandler;

    if (destination) {
        // 获取下载文件目标地址block
        delegate.downloadTaskDidFinishDownloading = ^NSURL * (NSURLSession * __unused session, NSURLSessionDownloadTask *task, NSURL *location) {
            return destination(location, task.response);
        };
    }

    // 内存地址 作为 taskDescription
    downloadTask.taskDescription = self.taskDescriptionForSessionTasks;

    // 将 taskDelegate 存储起来， 并对 downloadTask 添加暂停、恢复通知
    [self setDelegate:delegate forTask:downloadTask];
    
    // 设置下载回调
    delegate.downloadProgressBlock = downloadProgressBlock;
}

- (void)removeDelegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    // 加锁
    [self.lock lock];
    // 移除 task 的两个通知
    [self removeNotificationObserverForTask:task];
    // 从字典中，将 task 与对应的 taskDelegate 键值对移除
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeObjectForKey:@(task.taskIdentifier)];
    // 解锁
    [self.lock unlock];
}

#pragma mark -

- (NSArray *)tasksForKeyPath:(NSString *)keyPath {
    __block NSArray *tasks = nil;
    // 创建一个信号量为 0 的信号
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    // 异步获取当前 session 所有未完成的 task
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(dataTasks))]) {
            // dataTasks 方法调用该方法
            tasks = dataTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(uploadTasks))]) {
            // uploadTasks 方法调用该方法
            tasks = uploadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(downloadTasks))]) {
            // downloadTasks 方法调用该方法
            tasks = downloadTasks;
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(tasks))]) {
            // tasks 方法调用该方法
            // 利用 valueForKeyPath 合并数组并保留重复值
            tasks = [@[dataTasks, uploadTasks, downloadTasks] valueForKeyPath:@"@unionOfArrays.self"];
        }

        // semaphore 的信号量加1，semaphore 的信号量为1了，实现解锁
        dispatch_semaphore_signal(semaphore);
    }];

    // semaphore 的信号量需要减1，因为信号量为0，所以实现加锁
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    return tasks;
}

// 获取当前 sessionManager 中的所有 task
- (NSArray *)tasks {
    // _cmd 代表当前方法的 selector
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

// 获取当前 sessionManager 中的 dataTask
- (NSArray *)dataTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

// 获取当前 sessionManager 中的 uploadTask
- (NSArray *)uploadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

// 获取当前 sessionManager 中的 downloadTask
- (NSArray *)downloadTasks {
    return [self tasksForKeyPath:NSStringFromSelector(_cmd)];
}

#pragma mark -
// 使 session 失效
- (void)invalidateSessionCancelingTasks:(BOOL)cancelPendingTasks resetSession:(BOOL)resetSession {
    if (cancelPendingTasks) {
        // 使 self.session 立即失效
        [self.session invalidateAndCancel];
    } else {
        // 使 self.session 等待未完成的task完成后失效
        [self.session finishTasksAndInvalidate];
    }
    if (resetSession) {
        // 重置 self.session，设置 self.session 为 nil
        self.session = nil;
    }
}

#pragma mark -

// 响应结果序列化对象 setter 方法
- (void)setResponseSerializer:(id <AFURLResponseSerialization>)responseSerializer {
    // 使用断言
    NSParameterAssert(responseSerializer);

    _responseSerializer = responseSerializer;
}

#pragma mark -
- (void)addNotificationObserverForTask:(NSURLSessionTask *)task {
    // 添加 task 恢复通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidResume:) name:AFNSURLSessionTaskDidResumeNotification object:task];
    // 添加 task 暂停通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(taskDidSuspend:) name:AFNSURLSessionTaskDidSuspendNotification object:task];
}

- (void)removeNotificationObserverForTask:(NSURLSessionTask *)task {
    // 移除暂停通知
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidSuspendNotification object:task];
    // 移除恢复通知
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AFNSURLSessionTaskDidResumeNotification object:task];
}

#pragma mark -
// 下面 通过6种系统方法，来分别创建 dataTask、uploadTask、downloadTask

// dataTask，通过 AFHTTPSessionManager 传的 request 生成 dataTask，并将 dataTask 加入到 taskDelegate 中
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                               uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                             downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                            completionHandler:(nullable void (^)(NSURLResponse *response, id _Nullable responseObject,  NSError * _Nullable error))completionHandler {

    // 根据 request 创建 dataTask 对象
    NSURLSessionDataTask *dataTask = [self.session dataTaskWithRequest:request];

    // 添加到 taskDelegate 对象
    [self addDelegateForDataTask:dataTask uploadProgress:uploadProgressBlock downloadProgress:downloadProgressBlock completionHandler:completionHandler];

    // 返回 dataTask 对象
    return dataTask;
}

#pragma mark -

// uploadTask，此方法没有被 AFHTTPSessionManager 调用，用户可以直接使用
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 根据 request 与 fileURL 创建 uploadTask 对象
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithRequest:request fromFile:fileURL];
    
    if (uploadTask) {
        // uploadTask 不为 nil
        // 添加到 taskDelegate 对象
        [self addDelegateForUploadTask:uploadTask
                              progress:uploadProgressBlock
                     completionHandler:completionHandler];
    }

    return uploadTask;
}

// uploadTask，此方法没有被 AFHTTPSessionManager 调用，用户可以直接使用
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                         progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 根据 request 与 bodyData 创建 uploadTask 对象
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithRequest:request fromData:bodyData];
    
    // 添加到 taskDelegate 对象
    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

// uploadTask，通过 AFHTTPSessionManager 传的 request 生成 uploadTask，并将 uploadTask 加入到 taskDelegate 中
- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request
                                                 progress:(void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                                        completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    // 根据 request 创建 uploadTask 对象
    NSURLSessionUploadTask *uploadTask = [self.session uploadTaskWithStreamedRequest:request];

    // 添加到 taskDelegate 对象
    [self addDelegateForUploadTask:uploadTask progress:uploadProgressBlock completionHandler:completionHandler];

    return uploadTask;
}

#pragma mark -

// downloadTask，此方法没有被 AFHTTPSessionManager 调用，用户可以直接使用
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                             progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                          destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                    completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    // 根据 request 创建 downloadTask 对象
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithRequest:request];
    
    // 添加到 taskDelegate 对象
    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

// downloadTask，此方法没有被 AFHTTPSessionManager 调用，用户可以直接使用
- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData
                                                progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                                             destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                                       completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    // 根据 resumeData 创建 downloadTask 对象
    NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithResumeData:resumeData];

    // 添加到 taskDelegate 对象
    [self addDelegateForDownloadTask:downloadTask progress:downloadProgressBlock destination:destination completionHandler:completionHandler];

    return downloadTask;
}

#pragma mark -
// 根据 task 获取对应的上传进度条
- (NSProgress *)uploadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] uploadProgress];
}

// 根据 task 获取对应的下载进度条
- (NSProgress *)downloadProgressForTask:(NSURLSessionTask *)task {
    return [[self delegateForTask:task] downloadProgress];
}

#pragma mark -
//  设置当 session 无效时的block，在 URLSession:didBecomeInvalidWithError: 中被调用
- (void)setSessionDidBecomeInvalidBlock:(void (^)(NSURLSession *session, NSError *error))block {
    self.sessionDidBecomeInvalid = block;
}

// 设置当 session 接收到验证请求时的block，在 URLSession:didReceiveChallenge:completionHandler: 中被调用
- (void)setSessionDidReceiveAuthenticationChallengeBlock:(NSURLSessionAuthChallengeDisposition (^)(NSURLSession *session, NSURLAuthenticationChallenge *challenge, NSURLCredential * __autoreleasing *credential))block {
    self.sessionDidReceiveAuthenticationChallenge = block;
}

#if !TARGET_OS_OSX
// 设置当 session 所有的任务都发送出去以后的block,在 URLSessionDidFinishEventsForBackgroundURLSession: 中被调用
- (void)setDidFinishEventsForBackgroundURLSessionBlock:(void (^)(NSURLSession *session))block {
    self.didFinishEventsForBackgroundURLSession = block;
}
#endif

#pragma mark -
// 下面12个设置block的方法,每个block与一个代理方法对应,通过这些block使开发者知道执行了那个代理方法与代理方法的参数值

// 设置当 task 请求需要一个新的 bodystream 的block,在 URLSession:task:needNewBodyStream: 中被调用
- (void)setTaskNeedNewBodyStreamBlock:(NSInputStream * (^)(NSURLSession *session, NSURLSessionTask *task))block {
    self.taskNeedNewBodyStream = block;
}

// 设置当 task 将要重定向block，在 URLSession:willPerformHTTPRedirection:newRequest:completionHandler: 中被调用
- (void)setTaskWillPerformHTTPRedirectionBlock:(NSURLRequest * (^)(NSURLSession *session, NSURLSessionTask *task, NSURLResponse *response, NSURLRequest *request))block {
    self.taskWillPerformHTTPRedirection = block;
}

// 设置获取上传进度 的block，在 URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend: 中被调用
- (void)setTaskDidSendBodyDataBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend))block {
    self.taskDidSendBodyData = block;
}

// 设置task完成block，在 URLSession:task:didCompleteWithError: 中被调用
- (void)setTaskDidCompleteBlock:(void (^)(NSURLSession *session, NSURLSessionTask *task, NSError *error))block {
    self.taskDidComplete = block;
}

#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
// 设置完成收集指标block，在 URLSession:task:didFinishCollectingMetrics: 被调用
- (void)setTaskDidFinishCollectingMetricsBlock:(void (^)(NSURLSession * _Nonnull, NSURLSessionTask * _Nonnull, NSURLSessionTaskMetrics * _Nullable))block AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10)) {
    self.taskDidFinishCollectingMetrics = block;
}
#endif

#pragma mark -
// 设置任务接收到响应block，在 URLSession:dataTask:didReceiveResponse:completionHandler: 中被调用
- (void)setDataTaskDidReceiveResponseBlock:(NSURLSessionResponseDisposition (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response))block {
    self.dataTaskDidReceiveResponse = block;
}

// 设置dataTask转换为downLoadTask block，在 URLSession:dataTask:didBecomeDownloadTask: 中被调用
- (void)setDataTaskDidBecomeDownloadTaskBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask))block {
    self.dataTaskDidBecomeDownloadTask = block;
}

// 设置dataTask接收到数据block, 在 URLSession:dataTask:didReceiveData: 中被调用
- (void)setDataTaskDidReceiveDataBlock:(void (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data))block {
    self.dataTaskDidReceiveData = block;
}

// 设置dataTask将要缓存响应数据block,在 URLSession:dataTask:willCacheResponse:completionHandler: 中被调用
- (void)setDataTaskWillCacheResponseBlock:(NSCachedURLResponse * (^)(NSURLSession *session, NSURLSessionDataTask *dataTask, NSCachedURLResponse *proposedResponse))block {
    self.dataTaskWillCacheResponse = block;
}

#pragma mark -
// 设置downloadTask完成下载block，用于获取下载文件目标地址，在 URLSession:downloadTask:didFinishDownloadingToURL: 中被调用
- (void)setDownloadTaskDidFinishDownloadingBlock:(NSURL * (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, NSURL *location))block {
    self.downloadTaskDidFinishDownloading = block;
}

// 设置downloadTask下载数据block，用于跟踪下载进度，在 URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite: 中被调用
- (void)setDownloadTaskDidWriteDataBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite))block {
    self.downloadTaskDidWriteData = block;
}

// 设置downloadTask恢复block，在 URLSession:downloadTask:didResumeAtOffset:expectedTotalBytes: 中被调用
- (void)setDownloadTaskDidResumeBlock:(void (^)(NSURLSession *session, NSURLSessionDownloadTask *downloadTask, int64_t fileOffset, int64_t expectedTotalBytes))block {
    self.downloadTaskDidResume = block;
}

#pragma mark - NSObject
// 复写description方法
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, session: %@, operationQueue: %@>", NSStringFromClass([self class]), self, self.session, self.operationQueue];
}

// 复写respondsToSelector方法
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(URLSession:didReceiveChallenge:completionHandler:)) {
        return self.sessionDidReceiveAuthenticationChallenge != nil;
    } else if (selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)) {
        return self.taskWillPerformHTTPRedirection != nil;
    } else if (selector == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:)) {
        return self.dataTaskDidReceiveResponse != nil;
    } else if (selector == @selector(URLSession:dataTask:willCacheResponse:completionHandler:)) {
        return self.dataTaskWillCacheResponse != nil;
    }
#if !TARGET_OS_OSX
    else if (selector == @selector(URLSessionDidFinishEventsForBackgroundURLSession:)) {
        return self.didFinishEventsForBackgroundURLSession != nil;
    }
#endif

    return [[self class] instancesRespondToSelector:selector];
}

#pragma mark - NSURLSessionDelegate

// session 将要无效
- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error
{
    if (self.sessionDidBecomeInvalid) {
        // 调用session失效block
        self.sessionDidBecomeInvalid(session, error);
    }

    // 发送 session 失效通知
    [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDidInvalidateNotification object:session];
}

// session 接受认证挑战
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    // 使用断言，self.sessionDidReceiveAuthenticationChallenge 不能为nil
    NSAssert(self.sessionDidReceiveAuthenticationChallenge != nil, @"`respondsToSelector:` implementation forces `URLSession:didReceiveChallenge:completionHandler:` to be called only if `self.sessionDidReceiveAuthenticationChallenge` is not nil");

    NSURLCredential *credential = nil;

    // 使用指定凭据（credential）
    // NSURLSessionAuthChallengeUseCredential = 0,
    // 默认的处理方式,如果有提供凭据也会被忽略，如果没有实现 URLSessionDelegate 处理认证的方法则会使用这种方式
    // NSURLSessionAuthChallengePerformDefaultHandling = 1,
    // 取消本次认证,如果有提供凭据也会被忽略，会取消当前的 URLSessionTask 请求
    // NSURLSessionAuthChallengeCancelAuthenticationChallenge = 2,
    // 拒绝认证挑战，并且进行下一个认证挑战，如果有提供凭据也会被忽略；大多数情况不会使用这种方式，无法为某个认证提供凭据，则通常应返回 performDefaultHandling
    // NSURLSessionAuthChallengeRejectProtectionSpace = 3,
    
    // 获得挑战意向 disposition 与 证书 credential
    NSURLSessionAuthChallengeDisposition disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

#pragma mark - NSURLSessionTaskDelegate
// 将要重定向
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    // 重定向请求
    NSURLRequest *redirectRequest = request;

    if (self.taskWillPerformHTTPRedirection) {
        // 执行重定向 block
        redirectRequest = self.taskWillPerformHTTPRedirection(session, task, response, request);
    }

    if (completionHandler) {
        // 返回重定向请求
        completionHandler(redirectRequest);
    }
}
// challenge 学习链接:
// iOS Authentication Challenge : https://juejin.im/post/6844904056767381518
// task接受认证挑战
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    BOOL evaluateServerTrust = NO;
    // 会话验证挑战意向为默认:忽略证书
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    NSURLCredential *credential = nil;

    // self.authenticationChallengeHandler 是通过.h文件362行的set方法设置的
    if (self.authenticationChallengeHandler) {
        // 存在 认证挑战处理block 则执行 获取返回结果
        id result = self.authenticationChallengeHandler(session, task, challenge, completionHandler);
        if (result == nil) {
            // result 为 nil, 则return
            return;
        } else if ([result isKindOfClass:NSError.class]) {
            // result 为 NSError 类型对象，则对 task 通过关联对象方式，关联上 result 对象
            // 此关联的 result 错误类型对象，在 AFURLSessionManagerTaskDelegate 的 - (void)URLSession:task:didCompleteWithError:代理方法中，被获取并使用
            objc_setAssociatedObject(task, AuthenticationChallengeErrorKey, result, OBJC_ASSOCIATION_RETAIN);
            // 设置会话验证挑战意向为：取消本次请求
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        } else if ([result isKindOfClass:NSURLCredential.class]) {
            // result 为 NSURLCredential 类型对象（验证凭据 或叫 认证证书）
            // 则将 result 赋值给 credential
            credential = result;
            // 设置会话验证挑战意向为：使用指定证书
            disposition = NSURLSessionAuthChallengeUseCredential;
        } else if ([result isKindOfClass:NSNumber.class]) {
            // result 为 NSNumber 类型对象
            disposition = [result integerValue];
            // 使用断言，进行判断
            NSAssert(disposition == NSURLSessionAuthChallengePerformDefaultHandling || disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge || disposition == NSURLSessionAuthChallengeRejectProtectionSpace, @"");
            // 判断，设置 evaluateServerTrust 的值
            evaluateServerTrust = disposition == NSURLSessionAuthChallengePerformDefaultHandling && [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
        } else {
            @throw [NSException exceptionWithName:@"Invalid Return Value" reason:@"The return value from the authentication challenge handler must be nil, an NSError, an NSURLCredential or an NSNumber." userInfo:nil];
        }
    } else {
        // 挑战保护空间的认证方法 是否等于 服务器信任
        evaluateServerTrust = [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
    }

    if (evaluateServerTrust) {
        // 挑战保护空间的认证方法是服务器信任的
        if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
            // 在指定的安全策略下，服务器信任被认可
            // 设置会话验证挑战意向为：使用指定证书
            disposition = NSURLSessionAuthChallengeUseCredential;
            // 设置认证证书
            credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        } else {
            // 在指定的安全策略下，服务器信任不被认可
            //
            // 此关联的 错误类型对象，在 AFURLSessionManagerTaskDelegate 的 - (void)URLSession:task:didCompleteWithError:代理方法中，被获取并使用
            objc_setAssociatedObject(task, AuthenticationChallengeErrorKey,
                                     [self serverTrustErrorForServerTrust:challenge.protectionSpace.serverTrust url:task.currentRequest.URL],
                                     OBJC_ASSOCIATION_RETAIN);
            // 设置会话验证挑战意向为：取消本次请求
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
    // 补充:
    /*
     //session 范围内的认证质询:
     // 客户端证书认证
     // NSURLAuthenticationMethodClientCertificate

     // 协商使用 Kerberos 还是 NTLM 认证
     // NSURLAuthenticationMethodNegotiate

     // NTLM 认证
     // NSURLAuthenticationMethodNTLM

     // 服务器信任认证（证书验证）
     // NSURLAuthenticationMethodServerTrust

     //  任务特定的认证质询:
     // 使用某种协议的默认认证方法
     // NSURLAuthenticationMethodDefault

     // HTML Form 认证，使用 URLSession 发送请求时不会发出此类型认证质询
     // NSURLAuthenticationMethodHTMLForm

     // HTTP Basic 认证
     // NSURLAuthenticationMethodHTTPBasic

     // HTTP Digest 认证
     // NSURLAuthenticationMethodHTTPDigest
     
     NSURLCredential对象初始化方法,分别用于不同类型的认证挑战类型:
     // 用于服务器信任认证挑战(认证质询)，当 challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust 时使用
     // 从 challenge.protectionSpace.serverTrust 中获取 SecTrust 实例
     // 使用该方法初始化 URLCredential 实例之前，需要对 SecTrust 实例进行评估
     + (NSURLCredential *)credentialForTrust:(SecTrustRef)trust;
     
     // 用于客户端证书认证质询，当 challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate 时使用
     // identity: 私钥和和证书的组合
     // certArray: 大多数情况下传 nil
     // persistence: 该参数会被忽略，传 .forSession 会比较合适
     + (NSURLCredential *)credentialWithIdentity:(SecIdentityRef)identity certificates:(nullable NSArray *)certArray persistence:(NSURLCredentialPersistence)persistence;
     
     // 使用给定的持久性设置、用户名和密码创建 URLCredential 实例
     + (NSURLCredential *)credentialWithUser:(NSString *)user password:(NSString *)password persistence:(NSURLCredentialPersistence)persistence;
     */
}

- (nonnull NSError *)serverTrustErrorForServerTrust:(nullable SecTrustRef)serverTrust url:(nullable NSURL *)url
{
    // 获取 com.apple.CFNetwork bundle
    NSBundle *CFNetworkBundle = [NSBundle bundleWithIdentifier:@"com.apple.CFNetwork"];
    NSString *defaultValue = @"The certificate for this server is invalid. You might be connecting to a server that is pretending to be “%@” which could put your confidential information at risk.";
    NSString *descriptionFormat = NSLocalizedStringWithDefaultValue(@"Err-1202.w", nil, CFNetworkBundle, defaultValue, @"") ?: defaultValue;
    NSString *localizedDescription = [descriptionFormat componentsSeparatedByString:@"%@"].count <= 2 ? [NSString localizedStringWithFormat:descriptionFormat, url.host] : descriptionFormat;
    // 错误信息
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: localizedDescription
    } mutableCopy];

    if (serverTrust) {
        // 添加 服务器信任 键值对
        userInfo[NSURLErrorFailingURLPeerTrustErrorKey] = (__bridge id)serverTrust;
    }

    if (url) {
        // 添加 URL 键值对
        userInfo[NSURLErrorFailingURLErrorKey] = url;

        if (url.absoluteString) {
            userInfo[NSURLErrorFailingURLStringErrorKey] = url.absoluteString;
        }
    }
    
    // 返回错误对象
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorServerCertificateUntrusted userInfo:userInfo];
}

// task是通过uploadTaskWithStreamedRequest:创建,需要新的数据流主体
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    NSInputStream *inputStream = nil;

    if (self.taskNeedNewBodyStream) {
        // 执行任务需要新 BodyStream 的 block，获取输入流
        inputStream = self.taskNeedNewBodyStream(session, task);
    } else if (task.originalRequest.HTTPBodyStream && [task.originalRequest.HTTPBodyStream conformsToProtocol:@protocol(NSCopying)]) {
        // 获取请求中的BodyStream
        inputStream = [task.originalRequest.HTTPBodyStream copy];
    }

    if (completionHandler) {
        // 返回新的数据流
        completionHandler(inputStream);
    }
}

// task 上传数据
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{

    // 总上传数据量
    int64_t totalUnitCount = totalBytesExpectedToSend;
    if (totalUnitCount == NSURLSessionTransferSizeUnknown) {
        // 总上传数据量为未知时，从请求头从获取上传数据内容长度
        NSString *contentLength = [task.originalRequest valueForHTTPHeaderField:@"Content-Length"];
        if (contentLength) {
            // 上传数据内容长度 赋值给 总上传数据量
            totalUnitCount = (int64_t) [contentLength longLongValue];
        }
    }
    
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    
    if (delegate) {
        // 调用 delegate 中的同名代理方法
        [delegate URLSession:session task:task didSendBodyData:bytesSent totalBytesSent:totalBytesSent totalBytesExpectedToSend:totalBytesExpectedToSend];
    }

    if (self.taskDidSendBodyData) {
        // 执行获取上传进度 block
        self.taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalUnitCount);
    }
}

// 任务完成
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];

    // delegate may be nil when completing a task in the background
    if (delegate) {
        // 调用 delegate 中的同名代理方法
        [delegate URLSession:session task:task didCompleteWithError:error];
        // 移除 task 的恢复、暂停通知，移除在字典中的缓存的与 taskDelegate 对象的键值对数据
        [self removeDelegateForTask:task];
    }

    if (self.taskDidComplete) {
        // 调用任务完成block
        self.taskDidComplete(session, task, error);
    }
}

#if AF_CAN_INCLUDE_SESSION_TASK_METRICS
// 完成 task 指标收集
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didFinishCollectingMetrics:(NSURLSessionTaskMetrics *)metrics AF_API_AVAILABLE(ios(10), macosx(10.12), watchos(3), tvos(10))
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    // Metrics may fire after URLSession:task:didCompleteWithError: is called, delegate may be nil
    if (delegate) {
        // 调用 delegate 中的同名代理方法
        [delegate URLSession:session task:task didFinishCollectingMetrics:metrics];
    }

    if (self.taskDidFinishCollectingMetrics) {
        // 执行完成收集指标block
        self.taskDidFinishCollectingMetrics(session, task, metrics);
    }
}
#endif

#pragma mark - NSURLSessionDataDelegate

// dataTask 接收到响应，默认情况下是不会接收返回数据,如果需要接收应该主动告诉系统
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    // 响应意向对象，决定dataTask如何继续执行，继续？取消？转变为Download？
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
    
    // NSURLSessionResponseCancel = 0,                                      /* Cancel the load, this is the same as -[task cancel] */
    // NSURLSessionResponseAllow = 1,                                       /* Allow the load to continue */
    // NSURLSessionResponseBecomeDownload = 2,                              /* Turn this request into a download */
    // NSURLSessionResponseBecomeStream                                     /* Turn this task into a stream task */

    if (self.dataTaskDidReceiveResponse) {
        // 执行任务接收到响应block
        disposition = self.dataTaskDidReceiveResponse(session, dataTask, response);
    }

    if (completionHandler) {
        // 返回对响应意向的对象
        completionHandler(disposition);
    }
}

// dataTask 转换为 downLoadTask
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    if (delegate) {
        // 移除 dataTask 的恢复、暂停通知，移除在字典中的缓存的与 taskDelegate 对象的键值对数据
        [self removeDelegateForTask:dataTask];
        // 对新的 downloadTask，添加恢复、暂停通知，在字典中添加新的 taskDelegate 与 downloadTask.taskIdentifier 键值对数据
        [self setDelegate:delegate forTask:downloadTask];
    }

    if (self.dataTaskDidBecomeDownloadTask) {
        // 执行dataTask转换为downLoadTask block
        self.dataTaskDidBecomeDownloadTask(session, dataTask, downloadTask);
    }
}

// dataTask 接收到服务器数据
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    // 调用 delegate 中的同名代理方法
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];

    if (self.dataTaskDidReceiveData) {
        // 执行dataTask接收到数据block
        self.dataTaskDidReceiveData(session, dataTask, data);
    }
}

// dataTask 将要缓存响应数据
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    // 一个对请求响应数据的封装对象
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.dataTaskWillCacheResponse) {
        // 调用dataTask将要缓存响应数据block,在此可以通过block返回nil,实现不缓存数据
        cachedResponse = self.dataTaskWillCacheResponse(session, dataTask, proposedResponse);
    }

    if (completionHandler) {
        // 返回需要缓存的数据
        completionHandler(cachedResponse);
    }
}

#if !TARGET_OS_OSX
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (self.didFinishEventsForBackgroundURLSession) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 执行所有任务完成block
            self.didFinishEventsForBackgroundURLSession(session);
        });
    }
}
#endif

#pragma mark - NSURLSessionDownloadDelegate

// downloadTask 完成下载
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    if (self.downloadTaskDidFinishDownloading) {
        // 调用downloadTaskDidFinishDownloading,获取文件下载目标地址
        NSURL *fileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (fileURL) {
            // 设置 taskDelegate 文件下载目标地址
            delegate.downloadFileURL = fileURL;
            NSError *error = nil;
            
            // 移动下载文件路径
            if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&error]) {
                // 发送移动下载文件失败通知
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:error.userInfo];
            } else {
                // 发送移动下载文件成功通知
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidMoveFileSuccessfullyNotification object:downloadTask userInfo:nil];
            }

            return;
        }
    }

    if (delegate) {
        // 调用 delegate 中的同名代理方法
        [delegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    }
}

// downloadTask 下载数据中
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    
    if (delegate) {
        // 调用 delegate 中的同名代理方法
        [delegate URLSession:session downloadTask:downloadTask didWriteData:bytesWritten totalBytesWritten:totalBytesWritten totalBytesExpectedToWrite:totalBytesExpectedToWrite];
    }

    if (self.downloadTaskDidWriteData) {
        // 调用downloadTask下载数据block
        self.downloadTaskDidWriteData(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}

// 下载任务恢复
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    // 获取 task 对应的 taskDelegate 对象
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    
    if (delegate) {
        // 调用 delegate 中的同名代理方法
        [delegate URLSession:session downloadTask:downloadTask didResumeAtOffset:fileOffset expectedTotalBytes:expectedTotalBytes];
    }

    if (self.downloadTaskDidResume) {
        // 调用downloadTask恢复block
        self.downloadTaskDidResume(session, downloadTask, fileOffset, expectedTotalBytes);
    }
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    NSURLSessionConfiguration *configuration = [decoder decodeObjectOfClass:[NSURLSessionConfiguration class] forKey:@"sessionConfiguration"];

    self = [self initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.session.configuration forKey:@"sessionConfiguration"];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithSessionConfiguration:self.session.configuration];
}

@end
