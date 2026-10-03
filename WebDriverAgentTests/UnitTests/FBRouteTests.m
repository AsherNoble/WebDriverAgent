/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBRoute.h"
#import "FBTouchActionCommands.h"
#import "FBTrickGestureCommands.h"
#import "FBXCTestDaemonsProxy.h"

@interface FBTouchActionCommands (TimingTests)
+ (id)handleConfigureActionTiming:(id)request;
+ (id)handleGetActionTiming:(id)request;
+ (id)handlePerformW3CTouchActions:(id)request;
@end

@interface FBTimingApplicationMock : NSObject
@property BOOL fail;
@property BOOL raiseException;
@property NSUInteger calls;
@end
@implementation FBTimingApplicationMock
- (BOOL)fb_performW3CActions:(NSArray *)actions elementCache:(id)cache
                     timing:(NSMutableDictionary *)timing error:(NSError **)error
{
  self.calls++;
  if (self.raiseException) { [NSException raise:@"TimingTest" format:@"synthetic failure"]; }
  if (self.fail) {
    *error = [NSError errorWithDomain:@"TimingTest" code:1 userInfo:nil];
    return NO;
  }
  FBMarkActionTiming(timing, @"submitted_to_ios");
  FBMarkActionTiming(timing, @"ios_completion_callback");
  return YES;
}
@end

@interface FBTimingSessionMock : NSObject
@property NSString *identifier;
@property FBTimingApplicationMock *activeApplication;
@property id elementCache;
@end
@implementation FBTimingSessionMock
@end
@interface FBTimingRequestMock : NSObject
@property NSDictionary *arguments;
@property FBTimingSessionMock *session;
@end
@implementation FBTimingRequestMock
@end


@class RouteResponse;

@interface FBHandlerMock : NSObject
@property (nonatomic, assign) BOOL didCallSomeSelector;
@end

@implementation FBHandlerMock
- (id)someSelector:(id)arg
{
  self.didCallSomeSelector = YES;
  return nil;
};

@end

@interface FBRouteTests : XCTestCase
@end

@implementation FBRouteTests

- (void)testGetRoute
{
  FBRoute *route = [FBRoute GET:@"/"];
  XCTAssertEqualObjects(route.verb, @"GET");
}

- (void)testPostRoute
{
  FBRoute *route = [FBRoute POST:@"/"];
  XCTAssertEqualObjects(route.verb, @"POST");
}

- (void)testPutRoute
{
  FBRoute *route = [FBRoute PUT:@"/"];
  XCTAssertEqualObjects(route.verb, @"PUT");
}

- (void)testDeleteRoute
{
  FBRoute *route = [FBRoute DELETE:@"/"];
  XCTAssertEqualObjects(route.verb, @"DELETE");
}

- (void)testTargetAction
{
  FBHandlerMock *mock = [FBHandlerMock new];
  FBRoute *route = [[FBRoute new] respondWithTarget:mock action:@selector(someSelector:)];
  [route mountRequest:(id)NSObject.new intoResponse:(id)NSObject.new];
  XCTAssertTrue(mock.didCallSomeSelector);
}

- (void)testRespond
{
  XCTestExpectation *expectation = [self expectationWithDescription:@"Calling respond block works!"];
  FBRoute *route = [[FBRoute new] respondWithBlock:^id<FBResponsePayload>(FBRouteRequest *request) {
    [expectation fulfill];
    return nil;
  }];
  [route mountRequest:(id)NSObject.new intoResponse:(id)NSObject.new];
  [self waitForExpectationsWithTimeout:0.0 handler:nil];
}

- (void)testRouteWithSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/deactivateApp"] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID/deactivateApp");
}

- (void)testRouteWithSession
{
  FBRoute *route = [[FBRoute POST:@"deactivateApp"] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID/deactivateApp");
}

- (void)testRouteWithoutSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/deactivateApp"].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/deactivateApp");
}

- (void)testRouteWithoutSession
{
  FBRoute *route = [[FBRoute POST:@"deactivateApp"].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/deactivateApp");
}

- (void)testEmptyRouteWithSession
{
  FBRoute *route = [[FBRoute POST:@""] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID");
}

- (void)testEmptyRouteWithoutSession
{
  FBRoute *route = [[FBRoute POST:@""].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/");
}

- (void)testEmptyRouteWithSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/"] respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/session/:sessionID");
}

- (void)testEmptyRouteWithoutSessionWithSlash
{
  FBRoute *route = [[FBRoute POST:@"/"].withoutSession respondWithTarget:self action:@selector(dummyHandler:)];
  XCTAssertEqualObjects(route.path, @"/");
}

+ (id<FBResponsePayload>)dummyHandler:(FBRouteRequest *)request
{
  return nil;
}

- (void)testTimingCaptureIsolationFailureAndBoundedRetention
{
  FBTimingRequestMock *request = [FBTimingRequestMock new];
  request.session = [FBTimingSessionMock new];
  request.session.identifier = @"timing-test-session";
  request.session.activeApplication = [FBTimingApplicationMock new];
  request.arguments = @{@"enabled": @YES};
  [FBTouchActionCommands handleConfigureActionTiming:request];
  request.arguments = @{@"actions": @[]};
  id response = [FBTouchActionCommands handlePerformW3CTouchActions:request];
  XCTAssertEqualObjects([response valueForKey:@"dictionary"][@"value"], NSNull.null);
  NSDictionary *snapshot = [[FBTouchActionCommands handleGetActionTiming:request] valueForKey:@"dictionary"][@"value"];
  NSDictionary *record = snapshot[@"records"][0];
  XCTAssertEqualObjects(record[@"sequence"], @0);
  XCTAssertEqualObjects(record[@"outcome"], @"success");
  XCTAssertEqualObjects(record[@"missing_ios_callback"], @NO);
  XCTAssertLessThanOrEqual([record[@"request_entered"][@"monotonic_s"] doubleValue],
                           [record[@"submitted_to_ios"][@"monotonic_s"] doubleValue]);
  XCTAssertLessThanOrEqual([record[@"ios_completion_callback"][@"monotonic_s"] doubleValue],
                           [record[@"request_finished"][@"monotonic_s"] doubleValue]);
  request.session.activeApplication.fail = YES;
  [FBTouchActionCommands handlePerformW3CTouchActions:request];
  request.session.activeApplication.raiseException = YES;
  XCTAssertThrows([FBTouchActionCommands handlePerformW3CTouchActions:request]);
  snapshot = [[FBTouchActionCommands handleGetActionTiming:request] valueForKey:@"dictionary"][@"value"];
  XCTAssertEqualObjects(snapshot[@"records"][1][@"outcome"], @"error");
  XCTAssertEqualObjects(snapshot[@"records"][1][@"missing_ios_callback"], @YES);
  XCTAssertEqualObjects(snapshot[@"records"][2][@"outcome"], @"exception");
  request.session.activeApplication.raiseException = NO;
  request.session.activeApplication.fail = NO;
  for (NSUInteger i = 0; i < 254; i++) {
    [FBTouchActionCommands handlePerformW3CTouchActions:request];
  }
  snapshot = [[FBTouchActionCommands handleGetActionTiming:request] valueForKey:@"dictionary"][@"value"];
  XCTAssertEqual([snapshot[@"records"] count], 256u);
  XCTAssertEqualObjects(snapshot[@"dropped_records"], @1);
  request.session.identifier = @"different-session";
  snapshot = [[FBTouchActionCommands handleGetActionTiming:request] valueForKey:@"dictionary"][@"value"];
  XCTAssertEqual([snapshot[@"records"] count], 0u);
  XCTAssertEqualObjects(snapshot[@"enabled"], @NO);
  request.session.identifier = @"timing-test-session";
  request.arguments = @{@"enabled": @NO};
  [FBTouchActionCommands handleConfigureActionTiming:request];
  NSUInteger calls = request.session.activeApplication.calls;
  [FBTouchActionCommands handlePerformW3CTouchActions:request];
  XCTAssertEqual(request.session.activeApplication.calls, calls + 1);
  snapshot = [[FBTouchActionCommands handleGetActionTiming:request] valueForKey:@"dictionary"][@"value"];
  XCTAssertEqual([snapshot[@"records"] count], 256u);
  XCTAssertEqualObjects(snapshot[@"dropped_records"], @1);
}

@end

@interface FBGestureScheduleTests : XCTestCase
@end

@implementation FBGestureScheduleTests

- (NSDictionary *)gestureAt:(double)startMs durations:(NSArray<NSNumber *> *)durations
{
  NSMutableArray *waypoints = [NSMutableArray arrayWithObject:@{@"x": @100, @"y": @200}];
  for (NSUInteger i = 0; i < durations.count; i++) {
    [waypoints addObject:@{@"x": @(100 + 10 * (i + 1)), @"y": @(200 + 5 * (i + 1)), @"duration_ms": durations[i]}];
  }
  return @{@"start_ms": @(startMs), @"waypoints": waypoints};
}

- (void)testRouteIsRegistered
{
  NSArray<NSString *> *paths = [[FBTrickGestureCommands routes] valueForKey:@"path"];
  XCTAssertTrue([paths containsObject:@"/wda/perform_gesture_schedule"]);
}

- (void)testPlanKeepsEachGestureSeparateWithCumulativeOffsets
{
  NSString *error = nil;
  NSArray *plan = [FBTrickGestureCommands gestureSchedulePlanFromArguments:@{@"gestures": @[
    [self gestureAt:0 durations:@[@20, @30]],
    [self gestureAt:168 durations:@[@50]],
  ]} errorMessage:&error];
  XCTAssertNil(error);
  XCTAssertEqual(plan.count, 2);
  XCTAssertEqualWithAccuracy([plan[1][@"start_s"] doubleValue], 0.168, 1e-9);
  NSArray<NSNumber *> *offsets = plan[0][@"offsets_s"];
  XCTAssertEqualWithAccuracy(offsets[0].doubleValue, 0, 1e-9);
  XCTAssertEqualWithAccuracy(offsets[1].doubleValue, 0.020, 1e-9);
  XCTAssertEqualWithAccuracy(offsets[2].doubleValue, 0.050, 1e-9);
  XCTAssertTrue(CGPointEqualToPoint([plan[0][@"points"][2] CGPointValue], CGPointMake(120, 210)));
}

- (void)testPlanRejectsInvalidBodies
{
  NSArray *invalid = @[
    @{},
    @{@"gestures": @[]},
    @{@"gestures": @[@{@"waypoints": @[@{@"x": @1, @"y": @1}, @{@"x": @2, @"y": @2, @"duration_ms": @10}]}]},
    @{@"gestures": @[@{@"start_ms": @-1, @"waypoints": @[@{@"x": @1, @"y": @1}, @{@"x": @2, @"y": @2, @"duration_ms": @10}]}]},
    @{@"gestures": @[@{@"start_ms": @0, @"waypoints": @[@{@"x": @1, @"y": @1}]}]},
    @{@"gestures": @[@{@"start_ms": @0, @"waypoints": @[@{@"x": @1, @"y": @1}, @{@"x": @2, @"y": @2, @"duration_ms": @0}]}]},
    @{@"gestures": @[@{@"start_ms": @0, @"waypoints": @[@{@"x": @1, @"y": @1}, @{@"x": @2, @"duration_ms": @10}]}]},
  ];
  for (NSDictionary *body in invalid) {
    NSString *error = nil;
    XCTAssertNil([FBTrickGestureCommands gestureSchedulePlanFromArguments:body errorMessage:&error], @"%@", body);
    XCTAssertNotNil(error, @"%@", body);
  }
}

@end
