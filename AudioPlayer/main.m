//
//  main.m
//  AudioPlayer
//
//  Created by David Wang on 2019/8/28.
//  Copyright © 2019 David Wang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioQueuePlayer.h"

int main(int argc, const char * argv[]) {
	@autoreleasepool {
		NSString *URL = @"http://zonble.net/MIDI/orz.mp3";
		URL = @"http://zonble.net/MIDI/orz-rock.mp3";
//		URL = @"http://zonble.net/MIDI/zk3.mp3";
//		URL = @"http://zonble.net/MIDI/Cooker.mp3";
//		URL = @"http://www.evidenceaudio.com/wp-content/uploads/2014/10/lyricslap.mp3";
		AudioQueuePlayer *player = [[AudioQueuePlayer alloc] initWithURL:[NSURL URLWithString:URL]];
		while (!player.stopped) {
			[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		}
	}
	return 0;
}
