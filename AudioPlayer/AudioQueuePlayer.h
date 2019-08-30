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

@class AudioQueuePlayer;

@protocol AudioQueuePlayerDelegate <NSObject>

- (void)audioQueuePlayerDidStart:(AudioQueuePlayer *)player;
- (void)audioQueuePlayerDidStop:(AudioQueuePlayer *)player;
- (void)audioQueuePlayerDidPause:(AudioQueuePlayer *)player;
- (void)audioQueuePlayerDidResume:(AudioQueuePlayer *)player;
- (void)audioQueuePlayer:(AudioQueuePlayer *)player isPlaying:(BOOL)isPlaying atTime:(NSInteger)time;

@end

@interface AudioQueuePlayer : NSObject <NSURLSessionDataDelegate>

- (id)initWithURL:(NSURL *)inURL;
- (double)framePerSecond;

@property (nonatomic, readonly, getter=isStopped) BOOL stopped;
@property (nonatomic, weak) id<AudioQueuePlayerDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
