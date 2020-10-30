// AFURLResponseSerialization.m
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

#import "AFURLResponseSerialization.h"

#import <TargetConditionals.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#elif TARGET_OS_WATCH
#import <WatchKit/WatchKit.h>
#elif defined(__MAC_OS_X_VERSION_MIN_REQUIRED)
#import <Cocoa/Cocoa.h>
#endif

NSString * const AFURLResponseSerializationErrorDomain = @"com.alamofire.error.serialization.response";
NSString * const AFNetworkingOperationFailingURLResponseErrorKey = @"com.alamofire.serialization.response.error.response";
NSString * const AFNetworkingOperationFailingURLResponseDataErrorKey = @"com.alamofire.serialization.response.error.data";

// 该方法用于将一个NSError对象作为另一个NSError对象的附属NSError对象，并将其放到userInfo属性NSUnderlyingErrorKey键对应的值中
static NSError * AFErrorWithUnderlyingError(NSError *error, NSError *underlyingError) {
    if (!error) {
        // error为空的话就直接返回underlyingError
        return underlyingError;
    }

    if (!underlyingError || error.userInfo[NSUnderlyingErrorKey]) {
         // 如果underlyingError为空或者error中已经有附属underlyingError就直接返回error
        return error;
    }

    // 获取error的userInfo，并将underlyingError作为键NSUnderlyingErrorKey对应的值赋给error
    NSMutableDictionary *mutableUserInfo = [error.userInfo mutableCopy];
    mutableUserInfo[NSUnderlyingErrorKey] = underlyingError;

    return [[NSError alloc] initWithDomain:error.domain code:error.code userInfo:mutableUserInfo];
}

// 该方法用于判断error或者underlyingError是否为指定code和domain的error
static BOOL AFErrorOrUnderlyingErrorHasCodeInDomain(NSError *error, NSInteger code, NSString *domain) {
    if ([error.domain isEqualToString:domain] && error.code == code) {
        return YES;
    } else if (error.userInfo[NSUnderlyingErrorKey]) {
        return AFErrorOrUnderlyingErrorHasCodeInDomain(error.userInfo[NSUnderlyingErrorKey], code, domain);
    }

    return NO;
}

// 该方法用于过滤解析后的json数据中NSDictionary类型数据值为Null的键
id AFJSONObjectByRemovingKeysWithNullValues(id JSONObject, NSJSONReadingOptions readingOptions) {
    // 如果解析后的json数据是NSArray类型的
    if ([JSONObject isKindOfClass:[NSArray class]]) {
        // 遍历元素如果还是NSArray类型的就递归调用本方法直至元素不为NSArray类型
        NSMutableArray *mutableArray = [NSMutableArray arrayWithCapacity:[(NSArray *)JSONObject count]];
        for (id value in (NSArray *)JSONObject) {
            if (![value isEqual:[NSNull null]]) {
                [mutableArray addObject:AFJSONObjectByRemovingKeysWithNullValues(value, readingOptions)];
            }
        }

        // 根据传入参数的可变性来返回对应可变性的NSArray对象
        return (readingOptions & NSJSONReadingMutableContainers) ? mutableArray : [NSArray arrayWithArray:mutableArray];
    // 如果解析后的json数据是NSDictionary类型的
    } else if ([JSONObject isKindOfClass:[NSDictionary class]]) {
         // 遍历所有的key并取出对应的value
        NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionaryWithDictionary:JSONObject];
        for (id <NSCopying> key in [(NSDictionary *)JSONObject allKeys]) {
            id value = (NSDictionary *)JSONObject[key];
            // 如果value不存在或者是NSNull类型的对象，就将其移除
            if (!value || [value isEqual:[NSNull null]]) {
                [mutableDictionary removeObjectForKey:key];
            // 如果value是NSArray或者NSDictionary类型的对象就递归调用本方法直至元素不为NSArray或者NSDictionary类型的对象
            } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
                mutableDictionary[key] = AFJSONObjectByRemovingKeysWithNullValues(value, readingOptions);
            }
        }

        // 根据传入参数的可变性来返回对应可变性的NSDictionary对象
        return (readingOptions & NSJSONReadingMutableContainers) ? mutableDictionary : [NSDictionary dictionaryWithDictionary:mutableDictionary];
    }

    // 如果不是是NSArray或者NSDictionary类型的对象就直接返回
    return JSONObject;
}

@implementation AFHTTPResponseSerializer

+ (instancetype)serializer {
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    // 默认可接受状态码,200~299之间
    self.acceptableStatusCodes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 100)];
    // 默认可接受媒体类型
    self.acceptableContentTypes = nil;

    return self;
}

#pragma mark -
// 验证响应和数据
- (BOOL)validateResponse:(NSHTTPURLResponse *)response
                    data:(NSData *)data
                   error:(NSError * __autoreleasing *)error
{
    // 响应是否有效
    BOOL responseIsValid = YES;
    // 验证错误
    NSError *validationError = nil;

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        // 存在可接受媒体类型 &&  可接受媒体类型 与 响应的媒体类型不一致 && (响应的媒体类型不为空 或者 数据不为空)
        if (self.acceptableContentTypes && ![self.acceptableContentTypes containsObject:[response MIMEType]] &&
            !([response MIMEType] == nil && [data length] == 0)) {

            if ([data length] > 0 && [response URL]) {
                // 编辑 媒体类型 与 url 错误信息
                NSMutableDictionary *mutableUserInfo = [@{
                                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: unacceptable content-type: %@", @"AFNetworking", nil), [response MIMEType]],
                                                          NSURLErrorFailingURLErrorKey:[response URL],
                                                          AFNetworkingOperationFailingURLResponseErrorKey: response,
                                                        } mutableCopy];
                if (data) {
                    // 添加 错误数据 信息
                    mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
                }

                // 验证错误对象
                validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:mutableUserInfo], validationError);
            }
            // 响应无效
            responseIsValid = NO;
        }

        // 可接受状态码存在 && 响应的状态码不在可接受状态码范围内  && 响应url存在
        if (self.acceptableStatusCodes && ![self.acceptableStatusCodes containsIndex:(NSUInteger)response.statusCode] && [response URL]) {
            // 编辑 响应状态码 与 响应URL 错误信息
            NSMutableDictionary *mutableUserInfo = [@{
                                               NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: %@ (%ld)", @"AFNetworking", nil), [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], (long)response.statusCode],
                                               NSURLErrorFailingURLErrorKey:[response URL],
                                               AFNetworkingOperationFailingURLResponseErrorKey: response,
                                       } mutableCopy];

            if (data) {
                // 添加 错误数据 信息
                mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
            }

            // 验证错误对象
            validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorBadServerResponse userInfo:mutableUserInfo], validationError);

            // 响应无效
            responseIsValid = NO;
        }
    }

     // 如果传了NSError对象，并且响应无效，就赋值后返回错误信息
    if (error && !responseIsValid) {
        *error = validationError;
    }

    return responseIsValid;
}

#pragma mark - AFURLResponseSerialization
// 遵循的 AFURLResponseSerialization 协议方法
- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 通过 validateResponse:data:error 方法 验证响应和数据
    [self validateResponse:(NSHTTPURLResponse *)response data:data error:error];

    return data;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    // 如果一个类符合 NSSecureCoding 协议并在 + supportsSecureCoding 返回 YES，就声明了它可以处理本身实例的编码解码方式，以防止替换攻击
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [self init];
    if (!self) {
        return nil;
    }

    self.acceptableStatusCodes = [decoder decodeObjectOfClass:[NSIndexSet class] forKey:NSStringFromSelector(@selector(acceptableStatusCodes))];
    self.acceptableContentTypes = [decoder decodeObjectOfClass:[NSSet class] forKey:NSStringFromSelector(@selector(acceptableContentTypes))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.acceptableStatusCodes forKey:NSStringFromSelector(@selector(acceptableStatusCodes))];
    [coder encodeObject:self.acceptableContentTypes forKey:NSStringFromSelector(@selector(acceptableContentTypes))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFHTTPResponseSerializer *serializer = [[[self class] allocWithZone:zone] init];
    serializer.acceptableStatusCodes = [self.acceptableStatusCodes copyWithZone:zone];
    serializer.acceptableContentTypes = [self.acceptableContentTypes copyWithZone:zone];

    return serializer;
}

@end

#pragma mark -

@implementation AFJSONResponseSerializer

+ (instancetype)serializer {
    return [self serializerWithReadingOptions:(NSJSONReadingOptions)0];
}

// 设置json序列化读写选项
+ (instancetype)serializerWithReadingOptions:(NSJSONReadingOptions)readingOptions {
    AFJSONResponseSerializer *serializer = [[self alloc] init];
    serializer.readingOptions = readingOptions;

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    // 默认可接受媒体类型
    self.acceptableContentTypes = [NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

// 遵循 AFURLResponseSerialization 协议
- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 验证响应和数据的 可接受媒体类型 和 可接受状态码
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }

    // Workaround for behavior of Rails to return a single space for `head :ok` (a workaround for a bug in Safari), which is not interpreted as valid input by NSJSONSerialization.
    // See https://github.com/rails/rails/issues/1742
    // 判断数据是否为空格数据
    BOOL isSpace = [data isEqualToData:[NSData dataWithBytes:" " length:1]];
    
    // 数据为空 或 是空格数据
    if (data.length == 0 || isSpace) {
        return nil;
    }
    
    NSError *serializationError = nil;
    
    // 通过设置的读写选择对数据进行序列化
    id responseObject = [NSJSONSerialization JSONObjectWithData:data options:self.readingOptions error:&serializationError];

    if (!responseObject)
    {// 序列化失败
        if (error) {
            *error = AFErrorWithUnderlyingError(serializationError, *error);
        }
        return nil;
    }
    
    if (self.removesKeysWithNullValues) {
        // 移除响应数据中值为NSNull的key
        return AFJSONObjectByRemovingKeysWithNullValues(responseObject, self.readingOptions);
    }

    return responseObject;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.readingOptions = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(readingOptions))] unsignedIntegerValue];
    self.removesKeysWithNullValues = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(removesKeysWithNullValues))] boolValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:@(self.readingOptions) forKey:NSStringFromSelector(@selector(readingOptions))];
    [coder encodeObject:@(self.removesKeysWithNullValues) forKey:NSStringFromSelector(@selector(removesKeysWithNullValues))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFJSONResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.readingOptions = self.readingOptions;
    serializer.removesKeysWithNullValues = self.removesKeysWithNullValues;

    return serializer;
}

@end

#pragma mark -

@implementation AFXMLParserResponseSerializer

+ (instancetype)serializer {
    AFXMLParserResponseSerializer *serializer = [[self alloc] init];

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    // 默认可接受媒体类型
    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"application/xml", @"text/xml", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSHTTPURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 验证响应和数据的 可接受媒体类型 和 可接受状态码
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }
    
    // 返回NSXMLParser对象
    return [[NSXMLParser alloc] initWithData:data];
}

@end

#pragma mark -

#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED

@implementation AFXMLDocumentResponseSerializer

+ (instancetype)serializer {
    return [self serializerWithXMLDocumentOptions:0];
}

+ (instancetype)serializerWithXMLDocumentOptions:(NSUInteger)mask {
    AFXMLDocumentResponseSerializer *serializer = [[self alloc] init];
    serializer.options = mask;

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"application/xml", @"text/xml", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }

    NSError *serializationError = nil;
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithData:data options:self.options error:&serializationError];

    if (!document)
    {
        if (error) {
            *error = AFErrorWithUnderlyingError(serializationError, *error);
        }
        return nil;
    }
    
    return document;
}

#pragma mark - NSSecureCoding

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.options = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(options))] unsignedIntegerValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:@(self.options) forKey:NSStringFromSelector(@selector(options))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFXMLDocumentResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.options = self.options;

    return serializer;
}

@end

#endif

#pragma mark -

@implementation AFPropertyListResponseSerializer

+ (instancetype)serializer {
    return [self serializerWithFormat:NSPropertyListXMLFormat_v1_0 readOptions:0];
}

+ (instancetype)serializerWithFormat:(NSPropertyListFormat)format
                         readOptions:(NSPropertyListReadOptions)readOptions
{
    AFPropertyListResponseSerializer *serializer = [[self alloc] init];
    serializer.format = format;
    serializer.readOptions = readOptions;

    return serializer;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"application/x-plist", nil];

    return self;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }

    if (!data) {
        return nil;
    }
    
    NSError *serializationError = nil;
    
    id responseObject = [NSPropertyListSerialization propertyListWithData:data options:self.readOptions format:NULL error:&serializationError];
    
    if (!responseObject)
    {
        if (error) {
            *error = AFErrorWithUnderlyingError(serializationError, *error);
        }
        return nil;
    }

    return responseObject;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.format = (NSPropertyListFormat)[[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(format))] unsignedIntegerValue];
    self.readOptions = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(readOptions))] unsignedIntegerValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:@(self.format) forKey:NSStringFromSelector(@selector(format))];
    [coder encodeObject:@(self.readOptions) forKey:NSStringFromSelector(@selector(readOptions))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFPropertyListResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.format = self.format;
    serializer.readOptions = self.readOptions;

    return serializer;
}

@end

#pragma mark -

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

@interface UIImage (AFNetworkingSafeImageLoading)
+ (UIImage *)af_safeImageWithData:(NSData *)data;
@end

static NSLock* imageLock = nil;

@implementation UIImage (AFNetworkingSafeImageLoading)

// 通过加锁实现线程安全创建图片对象
+ (UIImage *)af_safeImageWithData:(NSData *)data {
    UIImage* image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageLock = [[NSLock alloc] init];
    });
    
    [imageLock lock];
    image = [UIImage imageWithData:data];
    [imageLock unlock];
    return image;
}

@end

// 生成对应缩放因子的图片
static UIImage * AFImageWithDataAtScale(NSData *data, CGFloat scale) {
    // 根据二进制数据安全生成图片对象
    UIImage *image = [UIImage af_safeImageWithData:data];
    if (image.images) {
        // 如果是gif图就直接返回图片对象
        return image;
    }
    
    // 生成对应缩放因子的图片
    return [[UIImage alloc] initWithCGImage:[image CGImage] scale:scale orientation:image.imageOrientation];
}


// 为什么要费这么大劲解压图片呢？
/*
 现在的网络图像PNG和JPG都是压缩格式，需要把它们解压转成bitmap后才能渲染到屏幕上.
 如果我们不解压图片,直接调用UIImage的imageWithData:方法把数据转成UIImage对象，再把UIImage赋给UIImageView，
 那在渲染之前底层会判断到UIImage对象未解压，没有bitmap数据，这时会在主线程对图片进行解压操作，再渲染到屏幕上。
 这个解压操作是比较耗时的，如果任由它在主线程做，可能会导致速度慢UI卡顿的问题。
 */
/*
 AFImageResponseSerializer除了把返回数据解析成UIImage外，还会把图像数据解压，这个处理是在子线程（AFNetworking专用的一条线程，详见AFURLSessionManager），处理后上层
 使用返回的UIImage在主线程渲染时就不需要做解压这步操作，主线程减轻了负担，减少了UI卡顿问题。
 
 具体实现上在AFInflatedImageFromResponseWithDataAtScale里，创建一个画布，把UIImage画在画布上，再把这个画布保存成UIImage返回给上层。
 只有JPG和PNG才会尝试去做解压操作，期间如果解压失败，或者遇到CMKY颜色格式的jpg，或者图像太大
 (解压后的bitmap太占内存，一个像素3-4字节，搞不好内存就爆掉了)，就直接返回未解压的图像。
 */
// 生成对应缩放因子的图片并进行解压
static UIImage * AFInflatedImageFromResponseWithDataAtScale(NSHTTPURLResponse *response, NSData *data, CGFloat scale) {
    if (!data || [data length] == 0) {
        return nil;
    }

    // 创建画布和图片数据提供者
    CGImageRef imageRef = NULL;
    CGDataProviderRef dataProvider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);

    if ([response.MIMEType isEqualToString:@"image/png"]) {
        // 如果是png格式直接解压
        imageRef = CGImageCreateWithPNGDataProvider(dataProvider,  NULL, true, kCGRenderingIntentDefault);
    } else if ([response.MIMEType isEqualToString:@"image/jpeg"]) {
        // 如果是jpg格式
        // 先进行解压
        imageRef = CGImageCreateWithJPEGDataProvider(dataProvider, NULL, true, kCGRenderingIntentDefault);

        if (imageRef) {
            // 如果解压成功
            // 获取色彩空间
            CGColorSpaceRef imageColorSpace = CGImageGetColorSpace(imageRef);
            // 获取色彩空间模式
            CGColorSpaceModel imageColorSpaceModel = CGColorSpaceGetModel(imageColorSpace);

            // CGImageCreateWithJPEGDataProvider does not properly handle CMKY, so fall back to AFImageWithDataAtScale
            // 如果jpg的色彩空间是CMKY而不是RGB的话，不进行解压
            if (imageColorSpaceModel == kCGColorSpaceModelCMYK) {
                CGImageRelease(imageRef);
                imageRef = NULL;
            }
        }
    }

    // 释放图片数据提供者
    CGDataProviderRelease(dataProvider);

    // 按照缩放因子生成对应的图片
    UIImage *image = AFImageWithDataAtScale(data, scale);
    if (!imageRef) {
        // 如果没有解压成功
        if (image.images || !image) {
            // 如果是gif图或者没有生成图片就直接返回
            return image;
        }

        imageRef = CGImageCreateCopy([image CGImage]);
        if (!imageRef) {
            // 如果没有生成图片画布就直接返回
            return nil;
        }
    }

    // 获取图片尺寸和一个像素占用的字节数
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);

    if (width * height > 1024 * 1024 || bitsPerComponent > 8) {
        // 如果图片太大或者一个像素占用的字节超过8就不解压了
        CGImageRelease(imageRef);

        return image;
    }

    // CGImageGetBytesPerRow() calculates incorrectly in iOS 5.0, so defer to CGBitmapContextCreate
    // 配置绘图上下文的参数
    size_t bytesPerRow = 0;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGColorSpaceModel colorSpaceModel = CGColorSpaceGetModel(colorSpace);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);

    if (colorSpaceModel == kCGColorSpaceModelRGB) {
        uint32_t alpha = (bitmapInfo & kCGBitmapAlphaInfoMask);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wassign-enum"
        if (alpha == kCGImageAlphaNone) {
            bitmapInfo &= ~kCGBitmapAlphaInfoMask;
            bitmapInfo |= kCGImageAlphaNoneSkipFirst;
        } else if (!(alpha == kCGImageAlphaNoneSkipFirst || alpha == kCGImageAlphaNoneSkipLast)) {
            bitmapInfo &= ~kCGBitmapAlphaInfoMask;
            bitmapInfo |= kCGImageAlphaPremultipliedFirst;
        }
#pragma clang diagnostic pop
    }

    // 生成绘图上下文
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, bitsPerComponent, bytesPerRow, colorSpace, bitmapInfo);

    // 释放色彩空间
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        // 如果没有成功生成绘图上下文就释放画布并直接返回
        CGImageRelease(imageRef);

        return image;
    }

    // 绘制图片
    CGContextDrawImage(context, CGRectMake(0.0f, 0.0f, width, height), imageRef);
    CGImageRef inflatedImageRef = CGBitmapContextCreateImage(context);

     // 释放绘图上下文
    CGContextRelease(context);

    // 生成图片
    UIImage *inflatedImage = [[UIImage alloc] initWithCGImage:inflatedImageRef scale:scale orientation:image.imageOrientation];

    // 释放画布
    CGImageRelease(inflatedImageRef);
    CGImageRelease(imageRef);

    return inflatedImage;
}
#endif


@implementation AFImageResponseSerializer

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    // 默认可接受媒体类型
    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"image/tiff", @"image/jpeg", @"image/gif", @"image/png", @"image/ico", @"image/x-icon", @"image/bmp", @"image/x-bmp", @"image/x-xbitmap", @"image/x-win-bitmap", nil];

#if TARGET_OS_IOS || TARGET_OS_TV
    // 图片的缩放因子
    self.imageScale = [[UIScreen mainScreen] scale];
    // 对响应图片自动解压
    self.automaticallyInflatesResponseImage = YES;
#elif TARGET_OS_WATCH
    self.imageScale = [[WKInterfaceDevice currentDevice] screenScale];
    self.automaticallyInflatesResponseImage = YES;
#endif

    return self;
}

#pragma mark - AFURLResponseSerializer

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    // 验证响应和数据的 可接受媒体类型 和 可接受状态码
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            return nil;
        }
    }

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
    // 在移动端需要手动解压
    if (self.automaticallyInflatesResponseImage) {
        // 图片自定解压
        // 生成对应缩放因子的图片并进行解压
        return AFInflatedImageFromResponseWithDataAtScale((NSHTTPURLResponse *)response, data, self.imageScale);
    } else {
        // 图片不自动解压
        // 获取图片
        return AFImageWithDataAtScale(data, self.imageScale);
    }
#else
    // 在MAC上可以直接调用系统方法解压
    // Ensure that the image is set to it's correct pixel width and height
    NSBitmapImageRep *bitimage = [[NSBitmapImageRep alloc] initWithData:data];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize([bitimage pixelsWide], [bitimage pixelsHigh])];
    [image addRepresentation:bitimage];

    return image;
#endif

    return nil;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

#if TARGET_OS_IOS  || TARGET_OS_TV || TARGET_OS_WATCH
    NSNumber *imageScale = [decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(imageScale))];
#if CGFLOAT_IS_DOUBLE
    self.imageScale = [imageScale doubleValue];
#else
    self.imageScale = [imageScale floatValue];
#endif

    self.automaticallyInflatesResponseImage = [decoder decodeBoolForKey:NSStringFromSelector(@selector(automaticallyInflatesResponseImage))];
#endif

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
    [coder encodeObject:@(self.imageScale) forKey:NSStringFromSelector(@selector(imageScale))];
    [coder encodeBool:self.automaticallyInflatesResponseImage forKey:NSStringFromSelector(@selector(automaticallyInflatesResponseImage))];
#endif
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFImageResponseSerializer *serializer = [super copyWithZone:zone];

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_WATCH
    serializer.imageScale = self.imageScale;
    serializer.automaticallyInflatesResponseImage = self.automaticallyInflatesResponseImage;
#endif

    return serializer;
}

@end

#pragma mark -

@interface AFCompoundResponseSerializer ()
@property (readwrite, nonatomic, copy) NSArray *responseSerializers;
@end

@implementation AFCompoundResponseSerializer

+ (instancetype)compoundSerializerWithResponseSerializers:(NSArray *)responseSerializers {
    AFCompoundResponseSerializer *serializer = [[self alloc] init];
    serializer.responseSerializers = responseSerializers;

    return serializer;
}

#pragma mark - AFURLResponseSerialization

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    for (id <AFURLResponseSerialization> serializer in self.responseSerializers) {
        if (![serializer isKindOfClass:[AFHTTPResponseSerializer class]]) {
            continue;
        }

        NSError *serializerError = nil;
        id responseObject = [serializer responseObjectForResponse:response data:data error:&serializerError];
        if (responseObject) {
            if (error) {
                *error = AFErrorWithUnderlyingError(serializerError, *error);
            }

            return responseObject;
        }
    }

    return [super responseObjectForResponse:response data:data error:error];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    NSSet *classes = [NSSet setWithArray:@[[NSArray class], [AFHTTPResponseSerializer <AFURLResponseSerialization> class]]];
    self.responseSerializers = [decoder decodeObjectOfClasses:classes forKey:NSStringFromSelector(@selector(responseSerializers))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:self.responseSerializers forKey:NSStringFromSelector(@selector(responseSerializers))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFCompoundResponseSerializer *serializer = [super copyWithZone:zone];
    serializer.responseSerializers = self.responseSerializers;

    return serializer;
}

@end
