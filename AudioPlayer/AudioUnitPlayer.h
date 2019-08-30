//
//  AudioUnitPlayer.h
//  AudioPlayer
//
//  Created by David Wang on 2019/8/30.
//  Copyright © 2019 David Wang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioUnitPlayer : NSObject
- (id)initWithURL:(NSURL *)inURL;
- (void)play;
- (void)pause;
@property (nonatomic, assign, readonly, getter=isStopped) BOOL stopped;
@end

NS_ASSUME_NONNULL_END
