/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#if !TARGET_OS_TV
#import <CoreLocation/CoreLocation.h>
#endif

#import "XCSynthesizedEventRecord.h"

NS_ASSUME_NONNULL_BEGIN

/** Diagnostic stamps are observation boundaries, not physical contact times. */
NS_INLINE void FBMarkActionTiming(NSMutableDictionary * _Nullable timing, NSString *name)
{
  if (nil == timing) { return; }
  NSTimeInterval monotonic = NSProcessInfo.processInfo.systemUptime;
  NSTimeInterval epoch = NSDate.date.timeIntervalSince1970;
  @synchronized (timing) {
    timing[name] = @{@"monotonic_s": @(monotonic), @"epoch_s": @(epoch)};
  }
}

@protocol XCTestManager_ManagerInterface;
@class FBScreenRecordingRequest, FBScreenRecordingPromise;

@interface FBXCTestDaemonsProxy : NSObject

+ (id<XCTestManager_ManagerInterface>)testRunnerProxy;

+ (BOOL)synthesizeEventWithRecord:(XCSynthesizedEventRecord *)record
                            error:(NSError *__autoreleasing*)error;

+ (BOOL)synthesizeEventWithRecord:(XCSynthesizedEventRecord *)record
                           timing:(nullable NSMutableDictionary *)timing
                            error:(NSError *__autoreleasing*)error;

+ (BOOL)openURL:(NSURL *)url usingApplication:(NSString *)bundleId error:(NSError **)error;
+ (BOOL)openDefaultApplicationForURL:(NSURL *)url error:(NSError **)error;

+ (nullable FBScreenRecordingPromise *)startScreenRecordingWithRequest:(FBScreenRecordingRequest *)request
                                                                 error:(NSError **)error;
+ (BOOL)stopScreenRecordingWithUUID:(NSUUID *)uuid
                              error:(NSError **)error;

#if !TARGET_OS_TV
+ (BOOL)setSimulatedLocation:(CLLocation *)location error:(NSError **)error;
+ (nullable CLLocation *)getSimulatedLocation:(NSError **)error;
+ (BOOL)clearSimulatedLocation:(NSError **)error;
#endif

@end

NS_ASSUME_NONNULL_END
