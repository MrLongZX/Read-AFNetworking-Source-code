// AFSecurityPolicy.m
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

#import "AFSecurityPolicy.h"

#import <AssertMacros.h>

#if !TARGET_OS_IOS && !TARGET_OS_WATCH && !TARGET_OS_TV
// 将公钥转化成NSData
static NSData * AFSecKeyGetData(SecKeyRef key) {
    CFDataRef data = NULL;
    
    // 将公钥转化成NSData
    // __Require_noErr_Quiet():如果SecItemExport()函数返回值存在错误,将跳到下面_out处继续执行
    __Require_noErr_Quiet(SecItemExport(key, kSecFormatUnknown, kSecItemPemArmour, NULL, &data), _out);

    // 返回data数据
    return (__bridge_transfer NSData *)data;

_out:
    if (data) {
        // 释放data指针
        CFRelease(data);
    }

    // 返回nil
    return nil;
}
#endif

// 比对两个公钥是否相同
static BOOL AFSecKeyIsEqualToKey(SecKeyRef key1, SecKeyRef key2) {
#if TARGET_OS_IOS || TARGET_OS_WATCH || TARGET_OS_TV
    return [(__bridge id)key1 isEqual:(__bridge id)key2];
#else
    return [AFSecKeyGetData(key1) isEqual:AFSecKeyGetData(key2)];
#endif
}

// 根据cer数据获取其公钥
static id AFPublicKeyForCertificate(NSData *certificate) {
    id allowedPublicKey = nil;
    SecCertificateRef allowedCertificate;
    SecPolicyRef policy = nil;
    SecTrustRef allowedTrust = nil;
    SecTrustResultType result;

    // 通过一个cer文件数据,创建一个SecCertificateRef
    allowedCertificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificate);
    // 如果allowedCertificate为NULL,将跳到下面_out处继续执行
    __Require_Quiet(allowedCertificate != NULL, _out);

    // 创建一个默认的符合 X509 标准的 SecPolicyRef
    policy = SecPolicyCreateBasicX509();
    // 通过默认的SecPolicyRef policy 和 证书(SecCertificateRef allowedCertificate) 创建一个信任SecTrustRef。
    // __Require_noErr_Quiet():如果SecTrustCreateWithCertificates()函数返回值存在错误,将跳到下面_out处继续执行
    __Require_noErr_Quiet(SecTrustCreateWithCertificates(allowedCertificate, policy, &allowedTrust), _out);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // 对SecTrustRef allowedTrust进行信任评估
    // __Require_noErr_Quiet():如果SecTrustEvaluate()函数返回值存在错误,将跳到下面_out处继续执行
    __Require_noErr_Quiet(SecTrustEvaluate(allowedTrust, &result), _out);
#pragma clang diagnostic pop
    // 从SecTrustRef allowedTrust中获取公钥
    allowedPublicKey = (__bridge_transfer id)SecTrustCopyPublicKey(allowedTrust);

_out:
    if (allowedTrust) {
        // 释放allowedTrust指针
        CFRelease(allowedTrust);
    }

    if (policy) {
        // 释放policy指针
        CFRelease(policy);
    }

    if (allowedCertificate) {
        // 释放allowedCertificate指针
        CFRelease(allowedCertificate);
    }

    // 返回公钥
    return allowedPublicKey;
}

// 判断serverTrust是否可以被信任
// 每一个 SecTrustRef 的对象都是包含多个 SecCertificateRef 和 SecPolicyRef。其中 SecCertificateRef 可以使用 DER文件 进行表示，并且其中存储着公钥信息
static BOOL AFServerTrustIsValid(SecTrustRef serverTrust) {
    // 默认无效
    BOOL isValid = NO;
    // 枚举类型, 用来存储结果
    SecTrustResultType result;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // 对SecTrustRef serverTrust进行信任评估
    // __Require_noErr_Quiet():如果SecTrustEvaluate()函数返回值存在错误,将跳到下面_out处继续执行
    __Require_noErr_Quiet(SecTrustEvaluate(serverTrust, &result), _out);
#pragma clang diagnostic pop

    //kSecTrustResultUnspecified:由非开发者证书校验通过
    //kSecTrustResultProceed:由开发者证书校验通过
    isValid = (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);

_out:
    // 返回NO
    return isValid;
}

// 取出serverTrust中的所有证书
static NSArray * AFCertificateTrustChainForServerTrust(SecTrustRef serverTrust) {
    // 获取SecTrustRef serverTrust证书评估链中cer文件的数量
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];

    for (CFIndex i = 0; i < certificateCount; i++) {
        // 获取 SecTrustRef serverTrust 中第i位置的cer文件
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        // 保存cer文件到数组
        [trustChain addObject:(__bridge_transfer NSData *)SecCertificateCopyData(certificate)];
    }

    // 返回SecTrustRef serverTrust中的所有cer文件
    return [NSArray arrayWithArray:trustChain];
}

// 获取serverTrust中所有证书对应的公钥
static NSArray * AFPublicKeyTrustChainForServerTrust(SecTrustRef serverTrust) {
    // 创建一个默认的符合 X509 标准的 SecPolicyRef
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    // 获取SecTrustRef serverTrust证书评估链中cer文件的数量
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];
    for (CFIndex i = 0; i < certificateCount; i++) {
        // 获取 SecTrustRef serverTrust 中第i位置的cer文件
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);

        // 创建一个包含 certificate 的数组
        SecCertificateRef someCertificates[] = {certificate};
        CFArrayRef certificates = CFArrayCreate(NULL, (const void **)someCertificates, 1, NULL);

        SecTrustRef trust;
        
        // 通过默认的SecPolicyRef policy 和 证书数组(CFArrayRef certificates) 创建一个信任SecTrustRef trust。
        // __Require_noErr_Quiet():如果SecTrustCreateWithCertificates()函数返回值存在错误,将跳到下面_out处继续执行
        __Require_noErr_Quiet(SecTrustCreateWithCertificates(certificates, policy, &trust), _out);
        SecTrustResultType result;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // 对SecTrustRef trust进行信任评估
        // __Require_noErr_Quiet():如果SecTrustEvaluate()函数返回值存在错误,将跳到下面_out处继续执行
        __Require_noErr_Quiet(SecTrustEvaluate(trust, &result), _out);
#pragma clang diagnostic pop
        // 从SecTrustRef trust中获取公钥,并添加到数组
        [trustChain addObject:(__bridge_transfer id)SecTrustCopyPublicKey(trust)];

    _out:
        if (trust) {
            // 释放trust指针
            CFRelease(trust);
        }

        if (certificates) {
            // 释放certificates指针
            CFRelease(certificates);
        }

        continue;
    }
    // 释放policy指针
    CFRelease(policy);

    // 返回SecTrustRef serverTrust中的所有公钥
    return [NSArray arrayWithArray:trustChain];
}

#pragma mark -
// 本类是阻止中间人攻击及其它漏洞的工具。主要作用就是验证 HTTPS 请求的证书是否有效,保证请求安全.
@interface AFSecurityPolicy()
@property (readwrite, nonatomic, assign) AFSSLPinningMode SSLPinningMode;
@property (readwrite, nonatomic, strong) NSSet *pinnedPublicKeys;
@end

@implementation AFSecurityPolicy

// 获取工程中所有cer文件数据
+ (NSSet *)certificatesInBundle:(NSBundle *)bundle {
    // 所有cer文件路径
    NSArray *paths = [bundle pathsForResourcesOfType:@"cer" inDirectory:@"."];

    NSMutableSet *certificates = [NSMutableSet setWithCapacity:[paths count]];
    for (NSString *path in paths) {
        // cer文件数据
        NSData *certificateData = [NSData dataWithContentsOfFile:path];
        // 保存到集合中
        [certificates addObject:certificateData];
    }

    return [NSSet setWithSet:certificates];
}

// 默认初始化方法
+ (instancetype)defaultPolicy {
    AFSecurityPolicy *securityPolicy = [[self alloc] init];
    // SSLPinningMode 为默认模式
    securityPolicy.SSLPinningMode = AFSSLPinningModeNone;

    return securityPolicy;
}

// 初始化方法
+ (instancetype)policyWithPinningMode:(AFSSLPinningMode)pinningMode {
    // 获取工程中所有cer文件数据
    NSSet <NSData *> *defaultPinnedCertificates = [self certificatesInBundle:[NSBundle mainBundle]];
    return [self policyWithPinningMode:pinningMode withPinnedCertificates:defaultPinnedCertificates];
}

// 初始化方法
+ (instancetype)policyWithPinningMode:(AFSSLPinningMode)pinningMode withPinnedCertificates:(NSSet *)pinnedCertificates {
    // 初始化
    AFSecurityPolicy *securityPolicy = [[self alloc] init];
    // 设置 SSLPinningMode
    securityPolicy.SSLPinningMode = pinningMode;
    // 保存cer文件数据,根据cer文件数据获取对应的公钥并保存
    [securityPolicy setPinnedCertificates:pinnedCertificates];

    return securityPolicy;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.validatesDomainName = YES;

    return self;
}

// 保存cer文件数据,根据cer文件数据获取对应的公钥并保存
- (void)setPinnedCertificates:(NSSet *)pinnedCertificates {
    // 保存cer文件数据
    _pinnedCertificates = pinnedCertificates;

    if (self.pinnedCertificates) {
        NSMutableSet *mutablePinnedPublicKeys = [NSMutableSet setWithCapacity:[self.pinnedCertificates count]];
        for (NSData *certificate in self.pinnedCertificates) {
            // 根据cer文件数据获取对应的公钥
            id publicKey = AFPublicKeyForCertificate(certificate);
            if (!publicKey) {
                continue;
            }
            // 保存公钥到集合
            [mutablePinnedPublicKeys addObject:publicKey];
        }
        // 保存公钥集合 到 pinnedPublicKeys
        self.pinnedPublicKeys = [NSSet setWithSet:mutablePinnedPublicKeys];
    } else {
        self.pinnedPublicKeys = nil;
    }
}

#pragma mark -

- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust
                  forDomain:(NSString *)domain
{
    // 不能隐式地信任自己签发的证书
    // 没有提供证书或者不验证证书，并且还设置 allowInvalidCertificates 为真，满足上面的所有条件，说明这次的验证是不安全的，会直接返回 NO
    if (domain && self.allowInvalidCertificates && self.validatesDomainName && (self.SSLPinningMode == AFSSLPinningModeNone || [self.pinnedCertificates count] == 0)) {
        // https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/NetworkingTopics/Articles/OverridingSSLChainValidationCorrectly.html
        //  According to the docs, you should only trust your provided certs for evaluation.
        //  Pinned certificates are added to the trust. Without pinned certificates,
        //  there is nothing to evaluate against.
        //
        //  From Apple Docs:
        //          "Do not implicitly trust self-signed certificates as anchors (kSecTrustOptionImplicitAnchors).
        //           Instead, add your own (self-signed) CA certificate to the list of trusted anchors."
        NSLog(@"In order to validate a domain name for self signed certificates, you MUST use pinning.");
        return NO;
    }

    NSMutableArray *policies = [NSMutableArray array];
    if (self.validatesDomainName) {
        // 如果需要验证域名,数组添加一个以域名为参数创建的用于SSL评估证书链的策略对象
        [policies addObject:(__bridge_transfer id)SecPolicyCreateSSL(true, (__bridge CFStringRef)domain)];
    } else {
        // 数组添加默认的X509策略对象
        [policies addObject:(__bridge_transfer id)SecPolicyCreateBasicX509()];
    }

    // 为SecTrustRef serverTrust设置需要验证的策略policies
    SecTrustSetPolicies(serverTrust, (__bridge CFArrayRef)policies);

    if (self.SSLPinningMode == AFSSLPinningModeNone) {
        // 如果只根据系统信任列表中的证书进行验证,即mode为AFSSLPinningModeNone, self.allowInvalidCertificates = YES(允许失效的cer) 或 serverTrust可以被信任 是 则返回YES
        return self.allowInvalidCertificates || AFServerTrustIsValid(serverTrust);
    } else if (!self.allowInvalidCertificates && !AFServerTrustIsValid(serverTrust)) {
        // self.SSLPinningMode 为 AFSSLPinningModePublicKey、AFSSLPinningModeCertificate模式时,如果 不允许失效的cer 并且 serverTrust不被信任,则返回NO
        return NO;
    }

    switch (self.SSLPinningMode) {
        case AFSSLPinningModeCertificate: {
            // 验证cer文件
            NSMutableArray *pinnedCertificates = [NSMutableArray array];
            // 遍历cer文件数据集合
            for (NSData *certificateData in self.pinnedCertificates) {
                // 数组 添加 通过一个cer文件数据创建的一个SecCertificateRef对象
                [pinnedCertificates addObject:(__bridge_transfer id)SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData)];
            }
            // 设置serverTrust的锚点证书来验证serverTrust
            // 由于没有继续调用SecTrustSetAnchorCertificatesOnly() 函数,所以只会信任pinnedCertificates中的证书签发的证书
            SecTrustSetAnchorCertificates(serverTrust, (__bridge CFArrayRef)pinnedCertificates);

            if (!AFServerTrustIsValid(serverTrust)) {
                // serverTrust不被信任,返回NO
                return NO;
            }

            // obtain the chain after being validated, which *should* contain the pinned certificate in the last position (if it's the Root CA)
            // 取出serverTrust中的证书信任链
            NSArray *serverCertificates = AFCertificateTrustChainForServerTrust(serverTrust);
            
            // 倒序遍历
            for (NSData *trustChainCertificate in [serverCertificates reverseObjectEnumerator]) {
                if ([self.pinnedCertificates containsObject:trustChainCertificate]) {
                    // 开发者工程本地cer文件数据集合包含证书信任链中的某个证书数据,则返回YES
                    return YES;
                }
            }
            
            return NO;
        }
        case AFSSLPinningModePublicKey: {
            // 验证公钥
            NSUInteger trustedPublicKeyCount = 0;
            // 取出serverTrust中所有证书对应的公钥
            NSArray *publicKeys = AFPublicKeyTrustChainForServerTrust(serverTrust);

            for (id trustChainPublicKey in publicKeys) {
                for (id pinnedPublicKey in self.pinnedPublicKeys) {
                    // serverTrust中所有证书对应的公钥 与 开发者工程本地cer文件对应公钥 有一样的,则计数加1
                    if (AFSecKeyIsEqualToKey((__bridge SecKeyRef)trustChainPublicKey, (__bridge SecKeyRef)pinnedPublicKey)) {
                        trustedPublicKeyCount += 1;
                    }
                }
            }
            // 公钥一致的数量大于0,则为YES
            return trustedPublicKeyCount > 0;
        }
            
        default:
            return NO;
    }
    
    return NO;
}

#pragma mark - NSKeyValueObserving

+ (NSSet *)keyPathsForValuesAffectingPinnedPublicKeys {
    return [NSSet setWithObject:@"pinnedCertificates"];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {

    self = [self init];
    if (!self) {
        return nil;
    }

    self.SSLPinningMode = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(SSLPinningMode))] unsignedIntegerValue];
    self.allowInvalidCertificates = [decoder decodeBoolForKey:NSStringFromSelector(@selector(allowInvalidCertificates))];
    self.validatesDomainName = [decoder decodeBoolForKey:NSStringFromSelector(@selector(validatesDomainName))];
    self.pinnedCertificates = [decoder decodeObjectOfClass:[NSSet class] forKey:NSStringFromSelector(@selector(pinnedCertificates))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:[NSNumber numberWithUnsignedInteger:self.SSLPinningMode] forKey:NSStringFromSelector(@selector(SSLPinningMode))];
    [coder encodeBool:self.allowInvalidCertificates forKey:NSStringFromSelector(@selector(allowInvalidCertificates))];
    [coder encodeBool:self.validatesDomainName forKey:NSStringFromSelector(@selector(validatesDomainName))];
    [coder encodeObject:self.pinnedCertificates forKey:NSStringFromSelector(@selector(pinnedCertificates))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFSecurityPolicy *securityPolicy = [[[self class] allocWithZone:zone] init];
    securityPolicy.SSLPinningMode = self.SSLPinningMode;
    securityPolicy.allowInvalidCertificates = self.allowInvalidCertificates;
    securityPolicy.validatesDomainName = self.validatesDomainName;
    securityPolicy.pinnedCertificates = [self.pinnedCertificates copyWithZone:zone];

    return securityPolicy;
}

@end
