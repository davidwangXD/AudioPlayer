//
//  AudioQueuePlayer.m
//  AudioPlayer
//
//  Created by David Wang on 2019/8/28.
//  Copyright © 2019 David Wang. All rights reserved.
//

#import "AudioQueuePlayer.h"

#pragma mark - AudioQueuePlayer
static void APAudioFileStreamPropertyListener(void * inCliendData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags);
static void APAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions);
static void APAudioQueueOutputCallback(void * inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);
static void APAudioQueueRunningListener(void * inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID);

typedef struct {
	size_t length;
	void *data;
} APPacketData;

@implementation AudioQueuePlayer {
	NSURLSessionDataTask *dataTask;
	struct {
		BOOL stopped;
		BOOL loaded;
	} playerStatus;

	AudioFileStreamID audiofileStreamID;
	AudioQueueRef outputQueue;

	AudioStreamBasicDescription streamDescription;
	APPacketData *packetData;
	size_t packetCount;
	size_t maxPacketCount;
	size_t readHead;
}

- (void)dealloc {
	AudioQueueReset(outputQueue);
	AudioQueueDispose(outputQueue, true);
	AudioFileStreamClose(audiofileStreamID);

	for (size_t index = 0; index < packetCount; index++) {
		void *data = packetData[index].data;
		if (data) {
			free(data);
			packetData[index].data = nil;
			packetData[index].length = 0;
		}
	}
	free(packetData);
	
	[dataTask cancel];
	dataTask = nil;
}

- (id)initWithURL:(NSURL *)inURL {
	self = [super init];
	if (self) {
		playerStatus.stopped = NO;
		packetCount = 0;
		maxPacketCount = 20480;
		packetData = (APPacketData *)calloc(maxPacketCount, sizeof(APPacketData));
		
		// First step: create audio parser, assign callback, create http connection,
		// start downloading file.
		AudioFileStreamOpen((__bridge void * _Nullable)(self), APAudioFileStreamPropertyListener, APAudioFileStreamPacketsCallback, kAudioFileMP3Type, &audiofileStreamID);

		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[[NSOperationQueue alloc] init]];
		dataTask = [session dataTaskWithURL:inURL];
		[dataTask resume];
	}
	return self;
}

- (double)framePerSecond {
	if (streamDescription.mFramesPerPacket) {
		return streamDescription.mSampleRate / streamDescription.mFramesPerPacket;
	}
	
	return 44100.0/1152.0;
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
	if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
		if ([(NSHTTPURLResponse *)response statusCode] != 200) {
			NSLog(@"HTTP code:%ld", [(NSHTTPURLResponse *)response statusCode]);
			[dataTask cancel];
			playerStatus.stopped = YES;
		}
	}
	completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
	// Step two: got partial file and give it to audio parser
	// to get pockets from data stream.
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		__strong typeof(weakSelf) strongSelf = weakSelf;
		AudioFileStreamParseBytes(strongSelf->audiofileStreamID, (UInt32)[data length], [data bytes], 0);
	});
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	if (error) {
		NSLog(@"Failed to load data: %@", [error localizedDescription]);
		playerStatus.stopped = YES;
	} else {
		NSLog(@"Complete loading data");
		playerStatus.loaded = YES;
	}
}


#pragma mark - Audio parser and audio queue callbacks
- (void)_enqueueDataWithPacketsCount:(size_t)inPacketCount {
	NSLog(@"%s", __PRETTY_FUNCTION__);
	if (!outputQueue) {
		return;
	}
	
	if (readHead == packetCount) {
		// Step six: already finished playing all packet, ends playing file.
		if (playerStatus.loaded) {
			AudioQueueStop(outputQueue, false);
			return;
		}
	}

	if (readHead + inPacketCount >= packetCount) {
		inPacketCount = packetCount - readHead;
	}

	UInt32 totalSize = 0;
	UInt32 index;

	for (index = 0; index< inPacketCount; index++) {
		totalSize += packetData[index + (UInt32)readHead].length;
	}

	OSStatus status = 0;
	AudioQueueBufferRef buffer;
	status = AudioQueueAllocateBuffer(outputQueue, totalSize, &buffer);
	assert(status == noErr);
	buffer->mAudioDataByteSize = totalSize;
	buffer->mUserData = (__bridge void * _Nullable)(self);

	AudioStreamPacketDescription *packetDescs = calloc(inPacketCount, sizeof(AudioStreamPacketDescription));

	totalSize = 0;
	for (index = 0; index < inPacketCount; index++) {
		size_t readIndex = index + readHead;
		memcpy(buffer->mAudioData + totalSize, packetData[readIndex].data, packetData[readIndex].length);
		AudioStreamPacketDescription description;
		description.mStartOffset = totalSize;
		description.mDataByteSize = (UInt32)packetData[readIndex].length;
		description.mVariableFramesInPacket = 0;
		totalSize += packetData[readIndex].length;
		memcpy(&(packetDescs[index]), &description, sizeof(AudioStreamPacketDescription));
	}
	status = AudioQueueEnqueueBuffer(outputQueue, buffer, (UInt32)inPacketCount, packetDescs);
	free(packetDescs);
	readHead += inPacketCount;
}

- (void)_createAudioQueueWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription {
	memcpy(&streamDescription, audioStreamBasicDescription, sizeof(AudioStreamBasicDescription));
	OSStatus status = AudioQueueNewOutput(audioStreamBasicDescription, APAudioQueueOutputCallback, (__bridge void * _Nullable)(self), CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &outputQueue);
	assert(status == noErr);
	
	UInt32 trueValue = 1;
	AudioQueueSetProperty(outputQueue, kAudioQueueProperty_EnableTimePitch, &trueValue, sizeof(trueValue));
	UInt32 timePitchAlgorithm = kAudioQueueTimePitchAlgorithm_Spectral;
	AudioQueueSetProperty(outputQueue, kAudioQueueProperty_TimePitchAlgorithm, &timePitchAlgorithm, sizeof(timePitchAlgorithm));
	status = AudioQueueSetParameter(outputQueue, kAudioQueueParam_Pitch, 300.0);
	
	status = AudioQueueAddPropertyListener(outputQueue, kAudioQueueProperty_IsRunning, APAudioQueueRunningListener, (__bridge void * _Nullable)(self));
	AudioQueuePrime(outputQueue, 0, NULL);
	AudioQueueStart(outputQueue, NULL);
}

- (void)_storePacketsWithNumberOfBytes:(UInt32)inNumberBytes numberOfPackets:(UInt32)inNumberPackets inputData:(const void *)inInputData packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions {
	for (int i = 0; i < inNumberPackets; i++) {
		SInt64 packetStart = inPacketDescriptions[i].mStartOffset;
		UInt32 packetSize = inPacketDescriptions[i].mDataByteSize;
		assert(packetSize > 0);
		packetData[packetCount].length = (size_t)packetSize;
		packetData[packetCount].data = malloc(packetSize);
		memcpy(packetData[packetCount].data, inInputData + packetStart, packetSize);
		packetCount++;
	}
	
	// Step five: Cause the packets which has been parsed is enough, buffering content is big enough.
	// Thus, starts playing.
	
	if (readHead == 0 & packetCount > (int)([self framePerSecond] * 3)) {
		AudioQueueStart(outputQueue, NULL);
		[self _enqueueDataWithPacketsCount:(int)([self framePerSecond] * 2)];
	}
}

- (void)_audioQueueDidStart {
	NSLog(@"Audio Queue did start");
}

- (void)_audioQueueDidStop {
	NSLog(@"Audio Queue did stop");
	playerStatus.stopped = YES;
}

#pragma mark - Properties

- (BOOL)isStopped {
	return playerStatus.stopped;
}

@end

void APAudioFileStreamPropertyListener(void * inCliendData, AudioFileStreamID inAudioFileStream, AudioFileStreamPropertyID inPropertyID, UInt32 * ioFlags) {
	AudioQueuePlayer *self = (__bridge AudioQueuePlayer *)inCliendData;
	if (inPropertyID == kAudioFileStreamProperty_DataFormat) {
		UInt32 dataSize = 0;
		OSStatus status = 0;
		AudioStreamBasicDescription audioStreamDescription;
		Boolean writable = false;
		status = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &writable);
		status = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &audioStreamDescription);

		NSLog(@"mSampleRate: %f", audioStreamDescription.mSampleRate);
		NSLog(@"mFormatID: %u", audioStreamDescription.mFormatID);
		NSLog(@"mFormateFlags: %u", audioStreamDescription.mFormatFlags);
		NSLog(@"mBytesPerPacket: %u", audioStreamDescription.mBytesPerPacket);
		NSLog(@"mFramesPerPacket: %u", audioStreamDescription.mFramesPerPacket);
		NSLog(@"mBytesPerFrame: %u", audioStreamDescription.mBytesPerFrame);
		NSLog(@"mChannelsPerFrame: %u", audioStreamDescription.mChannelsPerFrame);
		NSLog(@"mBitsPerchannel: %u", audioStreamDescription.mBitsPerChannel);
		NSLog(@"mReserved: %u", audioStreamDescription.mReserved);

		// Step three: audio parser has parsed audio format successfully,
		// accordingly to the file format, we can create audio queue and track if audio queue
		// is currently executing.

		[self _createAudioQueueWithAudioStreamDescription:&audioStreamDescription];
	}
}

void APAudioFileStreamPacketsCallback(void * inClientData, UInt32 inNumberBytes, UInt32 inNumberPackets, const void * inInputData, AudioStreamPacketDescription *inPacketDescriptions) {
	
	// Step four: Audio Parser has parsed packets successfully, we then need to store these data.
	
	AudioQueuePlayer *self = (__bridge AudioQueuePlayer *)inClientData;
	[self _storePacketsWithNumberOfBytes:inNumberBytes numberOfPackets:inNumberPackets inputData:inInputData packetDescriptions:inPacketDescriptions];
}

static void APAudioQueueOutputCallback(void * inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
	AudioQueueFreeBuffer(inAQ, inBuffer);
	AudioQueuePlayer *self = (__bridge AudioQueuePlayer *)inUserData;
	[self _enqueueDataWithPacketsCount:(int)([self framePerSecond] * 5)];
}

static void APAudioQueueRunningListener(void * inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID) {
	AudioQueuePlayer *self = (__bridge AudioQueuePlayer *)inUserData;
	UInt32 dataSize;
	OSStatus status = 0;
	status = AudioQueueGetPropertySize(inAQ, inID, &dataSize);
	if (inID == kAudioQueueProperty_IsRunning) {
		UInt32 running;
		status = AudioQueueGetProperty(inAQ, inID, &running, &dataSize);
		running ? [self _audioQueueDidStart] : [self _audioQueueDidStop];
	}
}
