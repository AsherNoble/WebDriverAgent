/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTouchActionCommands.h"

#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIApplication+FBTouchAction.h"

#ifndef WDA_TIMING_BUILD_REVISION
#define WDA_TIMING_BUILD_REVISION unversioned
#endif
#define FB_TIMING_STRING_IMPL(x) #x
#define FB_TIMING_STRING(x) FB_TIMING_STRING_IMPL(x)

// Guarded by the class lock. Request-local records also have their own lock.
static NSString *timingSession;
static NSMutableArray *timingRecords;
static NSUInteger timingSequence;
static NSUInteger timingDropped;
static BOOL timingEnabled = NO;
static const NSUInteger timingCapacity = 256;

@implementation FBTouchActionCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/wda/actionTiming"] respondWithTarget:self action:@selector(handleGetActionTiming:)],
    [[FBRoute POST:@"/wda/actionTiming"] respondWithTarget:self action:@selector(handleConfigureActionTiming:)],
    [[FBRoute POST:@"/actions"] respondWithTarget:self action:@selector(handlePerformW3CTouchActions:)],
  ];
}

#pragma mark - Commands

+ (id<FBResponsePayload>)handleConfigureActionTiming:(FBRouteRequest *)request
{
  id enabled = request.arguments[@"enabled"];
  if (![enabled isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID()) {
    return FBResponseWithUnknownErrorFormat(@"enabled must be a JSON boolean");
  }
  @synchronized (self) {
    timingEnabled = [enabled boolValue];
    if (timingEnabled) {
      timingSession = request.session.identifier;
      timingRecords = [NSMutableArray array];
      timingSequence = 0;
      timingDropped = 0;
    }
  }
  return [self handleGetActionTiming:request];
}

+ (id<FBResponsePayload>)handleGetActionTiming:(FBRouteRequest *)request
{
  @synchronized (self) {
    BOOL sameSession = [timingSession isEqualToString:request.session.identifier];
    NSMutableArray *records = [NSMutableArray array];
    if (sameSession) {
      for (NSMutableDictionary *record in timingRecords) {
        @synchronized (record) { [records addObject:[record copy]]; }
      }
    }
    return FBResponseWithObject(@{
      @"schema_version": @1,
      @"build_revision": @FB_TIMING_STRING(WDA_TIMING_BUILD_REVISION),
      @"enabled": @(sameSession && timingEnabled),
      @"capacity": @(timingCapacity),
      @"dropped_records": @(sameSession ? timingDropped : 0),
      @"records": records,
    });
  }
}

+ (id<FBResponsePayload>)handlePerformW3CTouchActions:(FBRouteRequest *)request
{
  NSMutableDictionary *timing = nil;
  @synchronized (self) {
    if (timingEnabled && [timingSession isEqualToString:request.session.identifier]) {
      NSUInteger sequence = timingSequence++;
      if (timingRecords.count < timingCapacity) {
        timing = [@{@"sequence": @(sequence), @"session_id": request.session.identifier,
                    @"outcome": @"in_progress"} mutableCopy];
        FBMarkActionTiming(timing, @"request_entered");
        [timingRecords addObject:timing];
      } else {
        timingDropped++;
      }
    }
  }
  @try {
    XCUIApplication *application = request.session.activeApplication;
    NSArray *actions = (NSArray *)request.arguments[@"actions"];
    NSError *error = nil;
    BOOL success = [application fb_performW3CActions:actions
                                      elementCache:request.session.elementCache timing:timing error:&error];
    if (nil != timing) {
      @synchronized (timing) {
        timing[@"outcome"] = success ? @"success" : @"error";
        if (nil != error) { timing[@"error"] = error.localizedDescription; }
      }
    }
    if (!success) { return FBResponseWithUnknownError(error); }
    return FBResponseWithOK();
  } @catch (NSException *exception) {
    if (nil != timing) {
      @synchronized (timing) {
        timing[@"outcome"] = @"exception";
        timing[@"error"] = exception.reason ?: exception.name;
      }
    }
    @throw;
  } @finally {
    FBMarkActionTiming(timing, @"request_finished");
    if (nil != timing) {
      @synchronized (timing) {
        timing[@"missing_ios_callback"] = @(nil == timing[@"ios_completion_callback"]);
      }
    }
  }
}

@end
