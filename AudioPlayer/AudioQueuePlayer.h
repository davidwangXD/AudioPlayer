//
//  AudioQueuePlayer.h
//  AudioPlayer
//
//  Created by David Wang on 2019/8/28.
//  Copyright © 2019 David Wang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioQueuePlayer : NSObject <NSURLSessionDataDelegate>

- (id)initWithURL:(NSURL *)inURL;
- (double)framePerSecond;

@property (readonly, getter=isStopped) BOOL stopped;

@end

NS_ASSUME_NONNULL_END
