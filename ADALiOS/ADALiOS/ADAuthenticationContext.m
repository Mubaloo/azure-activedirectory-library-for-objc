// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.

#import "ADALiOS.h"
#import "ADAuthenticationContext.h"
#import "ADAuthenticationResult.h"
#import "ADAuthenticationResult+Internal.h"
#import "ADOAuth2Constants.h"
#import "ADAuthenticationBroker.h"
#import "ADAuthenticationSettings.h"
#import "NSURL+ADExtensions.h"
#import "NSDictionary+ADExtensions.h"
#import "ADWebRequest.h"
#import "ADWebResponse.h"
#import "ADInstanceDiscovery.h"
#import "ADTokenCacheStoreItem.h"
#import "ADTokenCacheStoreKey.h"
#import "ADUserInformation.h"
#import "ADWorkPlaceJoin.h"
#import "ADPkeyAuthHelper.h"
#import "ADWorkPlaceJoinConstants.h"
#import "ADKeyChainHelper.h"
#import "ADBrokerKeyHelper.h"
#import "ADClientMetrics.h"
#import "NSString+ADHelperMethods.h"
#import "ADHelpers.h"
#import "ADOAuth2Constants.h"

#import "ADAuthenticationContext+Internal.h"

#import <objc/runtime.h>



typedef BOOL (*applicationOpenURLPtr)(id, SEL, UIApplication*, NSURL*, NSString*, id);
IMP __original_ApplicationOpenURL = NULL;

BOOL __swizzle_ApplicationOpenURL(id self, SEL _cmd, UIApplication* application, NSURL* url, NSString* sourceApplication, id annotation)
{
    if (![ADAuthenticationContext isResponseFromBroker:sourceApplication response:url])
    {
        if (__original_ApplicationOpenURL)
            return ((applicationOpenURLPtr)__original_ApplicationOpenURL)(self, _cmd, application, url, sourceApplication, annotation);
        else
            return NO;
    }
    
    [ADAuthenticationContext handleBrokerResponse:url];
    return YES;
}

typedef void(^ADAuthorizationCodeCallback)(NSString*, ADAuthenticationError*);

@implementation ADAuthenticationContext

+ (void) load
{
    __block id observer = nil;
    
    observer = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                 object:nil
                                                                  queue:nil
                                                             usingBlock:^(NSNotification* notification)
                {
                    // We don't want to swizzle multiple times so remove the observer
                    [[NSNotificationCenter defaultCenter] removeObserver:observer name:UIApplicationDidFinishLaunchingNotification object:nil];
                    
                    SEL sel = @selector(application:openURL:sourceApplication:annotation:);
                    
                    // Dig out the app delegate (if there is one)
                    __strong id appDelegate = [[UIApplication sharedApplication] delegate];
                    if ([appDelegate respondsToSelector:sel])
                    {
                        Method m = class_getInstanceMethod([appDelegate class], sel);
                        __original_ApplicationOpenURL = method_getImplementation(m);
                        method_setImplementation(m, (IMP)__swizzle_ApplicationOpenURL);
                    }
                    else
                    {
                        NSString* typeEncoding = [NSString stringWithFormat:@"%s%s%s%s%s%s%s", @encode(BOOL), @encode(id), @encode(SEL), @encode(UIApplication*), @encode(NSURL*), @encode(NSString*), @encode(id)];
                        class_addMethod([appDelegate class], sel, (IMP)__swizzle_ApplicationOpenURL, [typeEncoding UTF8String]);
                        
                        // UIApplication caches whether or not the delegate responds to certain selectors. Clearing out the delegate and resetting it gaurantees that gets updated
                        [[UIApplication sharedApplication] setDelegate:nil];
                        // UIApplication employs dark magic to assume ownership of the app delegate when it gets the app delegate at launch, it won't do that for setDelegate calls so we
                        // have to add a retain here to make sure it doesn't turn into a zombie
                        [[UIApplication sharedApplication] setDelegate:(__bridge id)CFRetain((__bridge CFTypeRef)appDelegate)];
                    }
                    
                }];
    
}

- (id)init
{
    //Ensure that the appropriate init function is called. This will cause the runtime to throw.
    [super doesNotRecognizeSelector:_cmd];
    return nil;
}

- (id)initWithAuthority:(NSString*) authority
      validateAuthority:(BOOL)bValidate
        tokenCacheStore:(id<ADTokenCacheStoring>)tokenCache
                  error:(ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    NSString* extractedAuthority = [ADInstanceDiscovery canonicalizeAuthority:authority];
    RETURN_ON_INVALID_ARGUMENT(!extractedAuthority, authority, nil);
    
    self = [super init];
    if (self)
    {
        _authority = extractedAuthority;
        _validateAuthority = bValidate;
        _tokenCacheStore = tokenCache;
    }
    return self;
}


+(ADAuthenticationContext*) authenticationContextWithAuthority: (NSString*) authority
                                                         error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    return [self authenticationContextWithAuthority: authority
                                  validateAuthority: YES
                                    tokenCacheStore: [ADAuthenticationSettings sharedInstance].defaultTokenCacheStore
                                              error: error];
}

+(ADAuthenticationContext*) authenticationContextWithAuthority: (NSString*) authority
                                             validateAuthority: (BOOL) bValidate
                                                         error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY
    return [self authenticationContextWithAuthority: authority
                                  validateAuthority: bValidate
                                    tokenCacheStore: [ADAuthenticationSettings sharedInstance].defaultTokenCacheStore
                                              error: error];
}

+(ADAuthenticationContext*) authenticationContextWithAuthority: (NSString*) authority
                                               tokenCacheStore: (id<ADTokenCacheStoring>) tokenCache
                                                         error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    return [self authenticationContextWithAuthority:authority
                                  validateAuthority:YES
                                    tokenCacheStore:tokenCache
                                              error:error];
}

+(ADAuthenticationContext*) authenticationContextWithAuthority: (NSString*) authority
                                             validateAuthority: (BOOL)bValidate
                                               tokenCacheStore: (id<ADTokenCacheStoring>)tokenCache
                                                         error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    RETURN_NIL_ON_NIL_EMPTY_ARGUMENT(authority);
    
    return [[self alloc] initWithAuthority: authority
                         validateAuthority: bValidate
                           tokenCacheStore: tokenCache
                                     error: error];
}

+ (BOOL)isResponseFromBroker:(NSString*)sourceApplication
                    response:(NSURL*)response
{
    return //sourceApplication && [NSString adSame:sourceApplication toString:brokerAppIdentifier];
    response &&
    [NSString adSame:sourceApplication toString:@"com.microsoft.azureauthenticator"];
}

+ (void)handleBrokerResponse:(NSURL*)response
{
    [ADAuthenticationContext internalHandleBrokerResponse:response];
}

- (void)acquireTokenForAssertion:(NSString*)assertion
                   assertionType:(ADAssertionType)assertionType
                        resource:(NSString*)resource
                        clientId:(NSString*)clientId
                          userId:(NSString*)userId
                 completionBlock:(ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    return [self internalAcquireTokenForAssertion:assertion
                                         clientId:clientId
                                      redirectUri:nil
                                         resource:resource
                                    assertionType:assertionType
                                           userId:userId
                                            scope:nil
                                validateAuthority:self.validateAuthority
                                    correlationId:[self getCorrelationId]
                                  completionBlock:completionBlock];
    
}


- (void)acquireTokenWithResource:(NSString*)resource
                        clientId:(NSString*)clientId
                     redirectUri:(NSURL*)redirectUri
                 completionBlock:(ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    return [self internalAcquireTokenWithResource:resource
                                         clientId:clientId
                                      redirectUri:redirectUri
                                   promptBehavior:AD_PROMPT_AUTO
                                           silent:NO
                                           userId:nil
                                            scope:nil
                             extraQueryParameters:nil
                                validateAuthority:self.validateAuthority
                                    correlationId:[self getCorrelationId]
                                  completionBlock:completionBlock];
}

-(void) acquireTokenWithResource: (NSString*) resource
                        clientId: (NSString*) clientId
                     redirectUri: (NSURL*) redirectUri
                          userId: (NSString*) userId
                 completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    [self internalAcquireTokenWithResource:resource
                                  clientId:clientId
                               redirectUri:redirectUri
                            promptBehavior:AD_PROMPT_AUTO
                                    silent:NO
                                    userId:userId
                                     scope:nil
                      extraQueryParameters:nil
                         validateAuthority:self.validateAuthority
                             correlationId:[self getCorrelationId]
                           completionBlock:completionBlock];
}


-(void) acquireTokenWithResource: (NSString*) resource
                        clientId: (NSString*)clientId
                     redirectUri: (NSURL*) redirectUri
                          userId: (NSString*) userId
            extraQueryParameters: (NSString*) queryParams
                 completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    [self internalAcquireTokenWithResource:resource
                                  clientId:clientId
                               redirectUri:redirectUri
                            promptBehavior:AD_PROMPT_AUTO
                                    silent:NO
                                    userId:userId
                                     scope:nil
                      extraQueryParameters:queryParams
                         validateAuthority:self.validateAuthority
                             correlationId:[self getCorrelationId]
                           completionBlock:completionBlock];
}

-(void) acquireTokenSilentWithResource: (NSString*) resource
                              clientId: (NSString*) clientId
                           redirectUri: (NSURL*) redirectUri
                       completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    return [self internalAcquireTokenWithResource:resource
                                         clientId:clientId
                                      redirectUri:redirectUri
                                   promptBehavior:AD_PROMPT_AUTO
                                           silent:YES
                                           userId:nil
                                            scope:nil
                             extraQueryParameters:nil
                                validateAuthority:self.validateAuthority
                                    correlationId:[self getCorrelationId]
                                  completionBlock:completionBlock];
}

-(void) acquireTokenSilentWithResource: (NSString*) resource
                              clientId: (NSString*) clientId
                           redirectUri: (NSURL*) redirectUri
                                userId: (NSString*) userId
                       completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    return [self internalAcquireTokenWithResource:resource
                                         clientId:clientId
                                      redirectUri:redirectUri
                                   promptBehavior:AD_PROMPT_AUTO
                                           silent:YES
                                           userId:userId
                                            scope:nil
                             extraQueryParameters:nil
                                validateAuthority:self.validateAuthority
                                    correlationId:[self getCorrelationId]
                                  completionBlock:completionBlock];
}

- (void)acquireTokenWithResource:(NSString*)resource
                        clientId:(NSString*)clientId
                     redirectUri:(NSURL*)redirectUri
                  promptBehavior:(ADPromptBehavior)promptBehavior
                          userId:(NSString*)userId
            extraQueryParameters:(NSString*)queryParams
                 completionBlock:(ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    THROW_ON_NIL_ARGUMENT(completionBlock);//The only argument that throws
    [self internalAcquireTokenWithResource:resource
                                  clientId:clientId
                               redirectUri:redirectUri
                            promptBehavior:promptBehavior
                                    silent:NO
                                    userId:userId
                                     scope:nil
                      extraQueryParameters:queryParams
                         validateAuthority:self.validateAuthority
                             correlationId:[self getCorrelationId]
                           completionBlock:completionBlock];
}

-(void) acquireTokenByRefreshToken: (NSString*)refreshToken
                          clientId: (NSString*)clientId
                       redirectUri: (NSString*)redirectUri
                   completionBlock: (ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    [self internalAcquireTokenByRefreshToken:refreshToken
                                    clientId:clientId
                                 redirectUri:redirectUri
                                    resource:nil
                                      userId:nil
                                   cacheItem:nil
                           validateAuthority:self.validateAuthority
                               correlationId:[self getCorrelationId]
                             completionBlock:completionBlock];
}

-(void) acquireTokenByRefreshToken:(NSString*)refreshToken
                          clientId:(NSString*)clientId
                       redirectUri:(NSString*)redirectUri
                          resource:(NSString*)resource
                   completionBlock:(ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    [self internalAcquireTokenByRefreshToken:refreshToken
                                    clientId:clientId
                                 redirectUri:redirectUri
                                    resource:resource
                                      userId:nil
                                   cacheItem:nil
                           validateAuthority:self.validateAuthority
                               correlationId:[self getCorrelationId]
                             completionBlock:completionBlock];
}

@end

