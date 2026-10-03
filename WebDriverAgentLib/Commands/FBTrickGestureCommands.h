/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import "FBCommandHandler.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBTrickGestureCommands : NSObject <FBCommandHandler>

/**
 Validate a /wda/perform_gesture_schedule body.

 Each returned entry has `start_s` (NSNumber), `points` (NSArray of CGPoint NSValues)
 and `offsets_s` (NSArray of NSNumber, seconds from the gesture's touch-down).
 Returns nil and sets errorMessage when the body is invalid.
 */
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)gestureSchedulePlanFromArguments:(NSDictionary *)arguments
                                                                         errorMessage:(NSString *_Nullable *_Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END
