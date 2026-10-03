/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBTrickGestureCommands.h"

#import <UIKit/UIKit.h>

#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBRunLoopSpinner.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCTRunnerDaemonSession.h"
#import "XCUIDevice.h"
#import "XCUIApplication.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"

@implementation FBTrickGestureCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[[FBRoute POST:@"/wda/perform_trick_gestures"] withoutSession] respondWithTarget:self action:@selector(handlePerformTrickGestures:)],
    [[[FBRoute POST:@"/wda/perform_gesture_schedule"] withoutSession] respondWithTarget:self action:@selector(handlePerformGestureSchedule:)],
  ];
}

#pragma mark - Gesture schedule

/*
 Sequential touch contacts must not share one XCSynthesizedEventRecord: extra
 paths run as parallel tracks and hover moves emit touches, so True Skate joins
 the gestures into one chain. Separate HTTP requests avoid that but each returns
 ~0.3 s after its gesture ends. This endpoint builds one record per gesture and
 submits each at its scheduled time from the main run loop without waiting for
 earlier records to complete.
 */
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)gestureSchedulePlanFromArguments:(NSDictionary *)arguments
                                                                         errorMessage:(NSString **)errorMessage
{
  id gestures = arguments[@"gestures"];
  if (![gestures isKindOfClass:NSArray.class] || [gestures count] == 0) {
    if (errorMessage) { *errorMessage = @"'gestures' must be a non-empty array"; }
    return nil;
  }
  NSMutableArray<NSDictionary<NSString *, id> *> *plan = [NSMutableArray array];
  for (NSUInteger gestureIndex = 0; gestureIndex < [gestures count]; gestureIndex++) {
    id gesture = gestures[gestureIndex];
    id start = [gesture isKindOfClass:NSDictionary.class] ? gesture[@"start_ms"] : nil;
    id waypoints = [gesture isKindOfClass:NSDictionary.class] ? gesture[@"waypoints"] : nil;
    if (![start isKindOfClass:NSNumber.class] || [start doubleValue] < 0) {
      if (errorMessage) { *errorMessage = [NSString stringWithFormat:@"Gesture %lu needs a non-negative 'start_ms'", (unsigned long)gestureIndex]; }
      return nil;
    }
    if (![waypoints isKindOfClass:NSArray.class] || [waypoints count] < 2) {
      if (errorMessage) { *errorMessage = [NSString stringWithFormat:@"Gesture %lu must have at least 2 waypoints", (unsigned long)gestureIndex]; }
      return nil;
    }
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    double offset = 0;
    for (NSUInteger waypointIndex = 0; waypointIndex < [waypoints count]; waypointIndex++) {
      NSString *problem = [self errorDescriptionForWaypoint:waypoints[waypointIndex]
                                              waypointIndex:waypointIndex
                                               gestureIndex:gestureIndex
                                          isFirstWaypoint:waypointIndex == 0];
      if (nil != problem) {
        if (errorMessage) { *errorMessage = problem; }
        return nil;
      }
      NSDictionary *waypoint = waypoints[waypointIndex];
      if (waypointIndex > 0) {
        double duration = [waypoint[@"duration_ms"] doubleValue];
        if (duration <= 0) {
          if (errorMessage) { *errorMessage = [NSString stringWithFormat:@"Gesture %lu waypoint %lu needs a positive 'duration_ms'", (unsigned long)gestureIndex, (unsigned long)waypointIndex]; }
          return nil;
        }
        offset += duration / 1000.0;
      }
      [points addObject:[NSValue valueWithCGPoint:CGPointMake([waypoint[@"x"] doubleValue], [waypoint[@"y"] doubleValue])]];
      [offsets addObject:@(offset)];
    }
    [plan addObject:@{@"start_s": @([start doubleValue] / 1000.0), @"points": points.copy, @"offsets_s": offsets.copy}];
  }
  return plan.copy;
}

+ (id<FBResponsePayload>)handlePerformGestureSchedule:(FBRouteRequest *)request
{
  NSString *problem = nil;
  NSArray<NSDictionary<NSString *, id> *> *plan = [self gestureSchedulePlanFromArguments:request.arguments errorMessage:&problem];
  if (nil == plan) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:problem traceback:nil]);
  }

  NSMutableArray<XCSynthesizedEventRecord *> *records = [NSMutableArray array];
  double lastEnd = 0;
  for (NSDictionary<NSString *, id> *entry in plan) {
    NSArray<NSValue *> *points = entry[@"points"];
    NSArray<NSNumber *> *offsets = entry[@"offsets_s"];
    XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:points.firstObject.CGPointValue offset:0.0];
    for (NSUInteger i = 1; i < points.count; i++) {
      [path moveToPoint:points[i].CGPointValue atOffset:offsets[i].doubleValue];
    }
    [path liftUpAtOffset:offsets.lastObject.doubleValue];
    XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"ScheduledGesture"
                                                                  interfaceOrientation:UIInterfaceOrientationPortrait];
    [record addPointerEventPath:path];
    [records addObject:record];
    lastEnd = MAX(lastEnd, [entry[@"start_s"] doubleValue] + offsets.lastObject.doubleValue);
  }

  id eventSynthesizer = [XCUIDevice.sharedDevice eventSynthesizer];
  NSMutableArray<NSMutableDictionary *> *timings = [NSMutableArray array];
  __block NSUInteger completed = 0;
  NSObject *lock = [NSObject new];
  // Small lead so the first submission is not late relative to the base time.
  NSTimeInterval base = NSProcessInfo.processInfo.systemUptime + 0.02;
  NSTimeInterval baseEpoch = NSDate.date.timeIntervalSince1970 + 0.02;
  for (NSUInteger i = 0; i < records.count; i++) {
    NSMutableDictionary *timing = [@{@"index": @(i), @"scheduled_s": plan[i][@"start_s"]} mutableCopy];
    [timings addObject:timing];
    XCSynthesizedEventRecord *record = records[i];
    double delay = base + [plan[i][@"start_s"] doubleValue] - NSProcessInfo.processInfo.systemUptime;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      @synchronized (lock) { timing[@"submitted_s"] = @(NSProcessInfo.processInfo.systemUptime - base); }
      [eventSynthesizer synthesizeEvent:record completion:(id)^(BOOL result, NSError *invokeError) {
        @synchronized (lock) {
          timing[@"completed_s"] = @(NSProcessInfo.processInfo.systemUptime - base);
          timing[@"result"] = @(result);
          if (nil != invokeError) { timing[@"error"] = invokeError.localizedDescription; }
          completed++;
        }
      }];
    });
  }
  BOOL finished = [[[[FBRunLoopSpinner new] timeout:lastEnd + 10.0] interval:0.005] spinUntilTrue:^BOOL{
    @synchronized (lock) { return completed == records.count; }
  }];
  NSArray *report;
  @synchronized (lock) { report = [[NSArray alloc] initWithArray:timings copyItems:YES]; }
  return FBResponseWithObject(@{
    @"complete": @(finished),
    @"base_monotonic_s": @(base),
    @"base_epoch_s": @(baseEpoch),
    @"gestures": report,
  });
}

#pragma mark - Commands

+ (nullable NSString *)errorDescriptionForWaypoint:(id)waypoint
                                      waypointIndex:(NSUInteger)waypointIndex
                                       gestureIndex:(NSUInteger)gestureIndex
                                  isFirstWaypoint:(BOOL)isFirstWaypoint
{
  if (![waypoint isKindOfClass:NSDictionary.class]) {
    return [NSString stringWithFormat:@"Gesture %lu waypoint %lu must be an object",
            (unsigned long)gestureIndex,
            (unsigned long)waypointIndex];
  }

  NSDictionary *waypointDictionary = (NSDictionary *)waypoint;
  if (nil == waypointDictionary[@"x"] || nil == waypointDictionary[@"y"]) {
    return [NSString stringWithFormat:@"Gesture %lu waypoint %lu must include 'x' and 'y'",
            (unsigned long)gestureIndex,
            (unsigned long)waypointIndex];
  }

  if (!isFirstWaypoint && nil == waypointDictionary[@"duration_ms"]) {
    return [NSString stringWithFormat:@"Gesture %lu waypoint %lu must include 'duration_ms'",
            (unsigned long)gestureIndex,
            (unsigned long)waypointIndex];
  }

  return nil;
}

+ (id<FBResponsePayload>)handlePerformTrickGestures:(FBRouteRequest *)request
{
  id gestures = request.arguments[@"gestures"];
  if (![gestures isKindOfClass:NSArray.class] || [gestures count] == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'gestures' must be a non-empty array"
                                                                        traceback:nil]);
  }

  double delayS = 0;
  id delayMs = request.arguments[@"delay_ms"];
  if (nil != delayMs && ![delayMs isKindOfClass:NSNull.class]) {
    delayS = [delayMs doubleValue] / 1000.0;
  }

  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc]
                                           initWithName:@"TrickGesture"
                                           interfaceOrientation:UIInterfaceOrientationPortrait];

  // All gestures share ONE XCPointerEventPath so they execute as a single
  // sequential finger contact. After each liftUp, a hover moveToPoint
  // repositions without generating a UITouch event, then pressDownAtOffset
  // starts the next contact.
  XCPointerEventPath *path = nil;
  double tCursor = 0.0;

  for (NSUInteger gestureIndex = 0; gestureIndex < [gestures count]; gestureIndex++) {
    id gesture = gestures[gestureIndex];
    if (![gesture isKindOfClass:NSDictionary.class]) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
        [NSString stringWithFormat:@"Gesture %lu must be an object", (unsigned long)gestureIndex]
        traceback:nil]);
    }

    id waypoints = ((NSDictionary *)gesture)[@"waypoints"];
    if (![waypoints isKindOfClass:NSArray.class] || [waypoints count] < 2) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
        [NSString stringWithFormat:@"Gesture %lu must have at least 2 waypoints", (unsigned long)gestureIndex]
        traceback:nil]);
    }

    NSString *validationError = [self errorDescriptionForWaypoint:waypoints[0]
                                                     waypointIndex:0
                                                      gestureIndex:gestureIndex
                                                 isFirstWaypoint:YES];
    if (nil != validationError) {
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:validationError
                                                                          traceback:nil]);
    }

    NSDictionary *originDict = (NSDictionary *)waypoints[0];
    CGPoint origin = CGPointMake([originDict[@"x"] doubleValue], [originDict[@"y"] doubleValue]);

    if (gestureIndex == 0) {
      // First gesture: create the single path. initForTouchAtPoint:offset:
      // implicitly presses down at offset=0 — no separate pressDownAtOffset needed.
      path = [[XCPointerEventPath alloc] initForTouchAtPoint:origin offset:0.0];
    } else {
      // Subsequent gestures: hover-move to new start position then press.
      // The move after liftUp is a hover (finger lifted), invisible to UITouch handlers.
      [path moveToPoint:origin atOffset:tCursor];
      [path pressDownAtOffset:tCursor];
    }

    for (NSUInteger waypointIndex = 1; waypointIndex < [waypoints count]; waypointIndex++) {
      validationError = [self errorDescriptionForWaypoint:waypoints[waypointIndex]
                                            waypointIndex:waypointIndex
                                             gestureIndex:gestureIndex
                                        isFirstWaypoint:NO];
      if (nil != validationError) {
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:validationError
                                                                            traceback:nil]);
      }

      NSDictionary *waypoint = (NSDictionary *)waypoints[waypointIndex];
      tCursor += [waypoint[@"duration_ms"] doubleValue] / 1000.0;
      [path moveToPoint:CGPointMake([waypoint[@"x"] doubleValue], [waypoint[@"y"] doubleValue])
               atOffset:tCursor];
    }

    [path liftUpAtOffset:tCursor];

    if (gestureIndex < [gestures count] - 1) {
      tCursor += delayS;
      if (tCursor < 0) {
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:
          [NSString stringWithFormat:@"delay_ms=%.0f causes gesture %lu to start before t=0",
           delayS * 1000.0, (unsigned long)(gestureIndex + 1)]
          traceback:nil]);
      }
    }
  }

  [eventRecord addPointerEventPath:path];

  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:eventRecord error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

@end
