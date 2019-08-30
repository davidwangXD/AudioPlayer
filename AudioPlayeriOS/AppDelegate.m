//
//  AppDelegate.m
//  AudioPlayeriOS
//
//  Created by David Wang on 2019/8/30.
//  Copyright © 2019 David Wang. All rights reserved.
//

#import "AppDelegate.h"
#import "AudioQueuePlayer.h"
#import "AudioUnitPlayer.h"

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// Override point for customization after application launch.

	NSString *URL = @"http://zonble.net/MIDI/orz.mp3";
	URL = @"http://zonble.net/MIDI/orz-rock.mp3";
	//		URL = @"http://zonble.net/MIDI/zk3.mp3";
	//		URL = @"http://zonble.net/MIDI/Cooker.mp3";
	//		URL = @"http://www.evidenceaudio.com/wp-content/uploads/2014/10/lyricslap.mp3";
//	AudioQueuePlayer *player = [[AudioQueuePlayer alloc] initWithURL:[NSURL URLWithString:URL]];
	AudioUnitPlayer *player = [[AudioUnitPlayer alloc] initWithURL:[NSURL URLWithString:URL]];
	
	return YES;
}


#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
	// Called when a new scene session is being created.
	// Use this method to select a configuration to create the new scene with.
	return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
	// Called when the user discards a scene session.
	// If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
	// Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end
