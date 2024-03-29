//
//  AudioUnitPlayer.m
//  AudioPlayer
//
//  Created by David Wang on 2019/8/30.
//  Copyright © 2019 David Wang. All rights reserved.
//

#import "AudioUnitPlayer.h"

static void AUAudioFileStreamPropertyListener(void * inClientData,
									   AudioFileStreamID inAudioFileStream,
									   AudioFileStreamPropertyID inPropertyID,
									   UInt32 * ioFlags);

static void AUAudioFileStreamPacketsCallback(void* inClientData,
									  UInt32 inNumberBytes,
									  UInt32 inNumberPackets,
									  const void* inInputData,
									  AudioStreamPacketDescription* inPacketDescriptions);

static OSStatus AUPlayerAURenderCallback(void *userData,
								  AudioUnitRenderActionFlags *ioActionFlags,
								  const AudioTimeStamp *inTimeStamp,
								  UInt32 inBusNumber,
								  UInt32 inNumberFrames,
								  AudioBufferList *ioData);

static OSStatus AUPlayerConverterFiller(AudioConverterRef inAudioConverter,
								 UInt32* ioNumberDataPackets,
								 AudioBufferList* ioData,
								 AudioStreamPacketDescription** outDataPacketDescription,
								 void* inUserData);

static const OSStatus AUAudioConverterCallbackErr_NoData = 'kknd';

@interface AudioUnitPlayer() <NSURLSessionDataDelegate>
{
	NSURLSessionDataTask *dataTask;
	struct {
		BOOL stopped;
		BOOL loaded;
	} playerStatus;
	
	AUGraph audioGraph;
	AudioUnit mixerUnit;
	AudioUnit EQUnit;
	AudioUnit outputUnit;
	
	AudioFileStreamID audioFileStreamID;
	AudioStreamBasicDescription streamDescription;
	AudioConverterRef converter;
	AudioBufferList *renderBufferList;
	UInt32 renderBufferSize;
	
	NSMutableArray *packets;
	size_t readHead;
}
- (double)packetsPerSecond;
@end

AudioStreamBasicDescription KKSignedIntLinearPCMStreamDescription()
{
	AudioStreamBasicDescription destFormat;
	bzero(&destFormat, sizeof(AudioStreamBasicDescription));
	destFormat.mSampleRate = 44100.0;
	destFormat.mFormatID = kAudioFormatLinearPCM;
	destFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
	destFormat.mFramesPerPacket = 1;
	destFormat.mBytesPerPacket = 4;
	destFormat.mBytesPerFrame = 4;
	destFormat.mChannelsPerFrame = 2;
	destFormat.mBitsPerChannel = 16;
	destFormat.mReserved = 0;
	return destFormat;
}

@implementation AudioUnitPlayer

- (void)dealloc
{
	AUGraphUninitialize(audioGraph);
	AUGraphClose(audioGraph);
	DisposeAUGraph(audioGraph);
	
	AudioFileStreamClose(audioFileStreamID);
	AudioConverterDispose(converter);
	free(renderBufferList->mBuffers[0].mData);
	free(renderBufferList);
	renderBufferList = NULL;
	
	[dataTask cancel];
	dataTask = nil;
}

- (void)buildOutputUnit
{
	// 建立 AudioGraph
	OSStatus status = NewAUGraph(&audioGraph);
	NSAssert(noErr == status, @"We need to create a new audio graph. %d", (int)status);
	status = AUGraphOpen(audioGraph);
	NSAssert(noErr == status, @"We need to open the audio graph. %d", (int)status);
	
	// 建立 mixer node
	AudioComponentDescription mixerUnitDescription;
	mixerUnitDescription.componentType = kAudioUnitType_Mixer;
	mixerUnitDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer;
	mixerUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	mixerUnitDescription.componentFlags = 0;
	mixerUnitDescription.componentFlagsMask = 0;
	AUNode mixerNode;
	status = AUGraphAddNode(audioGraph, &mixerUnitDescription, &mixerNode);
	NSAssert(noErr == status, @"We need to add the mixer node. %d", (int)status);
	
	// 建立 EQ node
	AudioComponentDescription EQUnitDescription;
	EQUnitDescription.componentType = kAudioUnitType_Effect;
	EQUnitDescription.componentSubType = kAudioUnitSubType_AUiPodEQ;
	EQUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	EQUnitDescription.componentFlags = 0;
	EQUnitDescription.componentFlagsMask = 0;
	AUNode EQNode;
	status = AUGraphAddNode(audioGraph, &EQUnitDescription, &EQNode);
	NSAssert(noErr == status, @"We need to add the EQ effect node. %d", (int)status);
	
	// 建立 remote IO node
	AudioComponentDescription outputUnitDescription;
	bzero(&outputUnitDescription, sizeof(AudioComponentDescription));
	outputUnitDescription.componentType = kAudioUnitType_Output;
	outputUnitDescription.componentSubType = kAudioUnitSubType_RemoteIO;
	outputUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	outputUnitDescription.componentFlags = 0;
	outputUnitDescription.componentFlagsMask = 0;
	AUNode outputNode;
	status = AUGraphAddNode(audioGraph, &outputUnitDescription, &outputNode);
	NSAssert(noErr == status, @"We need to add an output node to the audio graph. %d", (int)status);
	
	// 將 mixer node 連接到 EQ node
	status = AUGraphConnectNodeInput(audioGraph, mixerNode, 0, EQNode, 0);
	NSAssert(noErr == status, @"We need to connect the node within the audio graph. %d", (int)status);
	
	// 將 EQ node 連接到 Remote IO
	status = AUGraphConnectNodeInput(audioGraph, EQNode, 0, outputNode, 0);
	NSAssert(noErr == status, @"We need to connect the node within the audio graph. %d", (int)status);
	
	
	// 拿出 Remote IO 的 Audio Unit
	status = AUGraphNodeInfo(audioGraph, outputNode, &outputUnitDescription, &outputUnit);
	NSAssert(noErr == status, @"We need to get the audio unit of the output node. %d", (int)status);
	// 拿出 EQ node 的 Audio Unit
	status = AUGraphNodeInfo(audioGraph, EQNode, &EQUnitDescription, &EQUnit);
	NSAssert(noErr == status, @"We need to get the audio unit of the output node. %d", (int)status);
	// 拿出 mixer node 的 Audio Unit
	status = AUGraphNodeInfo(audioGraph, mixerNode, &mixerUnitDescription, &mixerUnit);
	NSAssert(noErr == status, @"We need to get the audio unit of the output node. %d", (int)status);
	
	// 設定 mixer node 的輸入輸出格式
	AudioStreamBasicDescription audioFormat = KKSignedIntLinearPCMStreamDescription();
	status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat));
	NSAssert(noErr == status, @"We need to set input format of the mixer node. %d", (int)status);
	status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioFormat, sizeof(audioFormat));
	NSAssert(noErr == status, @"We need to set output format of the mixer node. %d", (int)status);
	
	// 設定 EQ node 的輸入輸出格式
	status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat));
	NSAssert(noErr == status, @"We need to set input format of the mixer node. %d", (int)status);
	status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioFormat, sizeof(audioFormat));
	NSAssert(noErr == status, @"We need to set output format of the mixer node. %d", (int)status);
	
	// 設定 Remote IO node 的輸入格式
	status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioFormat, sizeof(audioFormat));
	NSAssert(noErr == status, @"We need to set input format of the mixer node. %d", (int)status);
	
	// 設定 maxFPS
	UInt32 maxFPS = 4096;
	status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
	NSAssert(noErr == status, @"We need to set the maximum FPS to the mixer node. %d", (int)status);
	status = AudioUnitSetProperty(EQUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
	NSAssert(noErr == status, @"We need to set the maximum FPS to the EQ effect node. %d", (int)status);
	status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
	NSAssert(noErr == status, @"We need to set the maximum FPS to the output node. %d", (int)status);
	
	// 設定 render callback
	AURenderCallbackStruct callbackStruct;
	callbackStruct.inputProcRefCon = (__bridge void *)(self);
	callbackStruct.inputProc = AUPlayerAURenderCallback;
	status = AUGraphSetNodeInputCallback(audioGraph, mixerNode, 0, &callbackStruct);
	NSAssert(noErr == status, @"Must be no error.");
	
	status = AUGraphInitialize(audioGraph);
	NSAssert(noErr == status, @"Must be no error.");
	
	// 建立 converter 要使用的 buffer list
	UInt32 bufferSize = 4096 * 4;
	renderBufferSize = bufferSize;
	renderBufferList = (AudioBufferList *)calloc(1, sizeof(UInt32) + sizeof(AudioBuffer));
	renderBufferList->mNumberBuffers = 1;
	renderBufferList->mBuffers[0].mNumberChannels = 2;
	renderBufferList->mBuffers[0].mDataByteSize = bufferSize;
	renderBufferList->mBuffers[0].mData = calloc(1, bufferSize);
	
	CAShow(audioGraph);
}

- (id)initWithURL:(NSURL *)inURL {
	self = [super init];
	if (self) {
		[self buildOutputUnit];
		
		playerStatus.stopped = NO;
		packets = [[NSMutableArray alloc] init];
		
		// 第一步：建立 Audio Parser，指定 callback，以及建立 HTTP 連線，
		// 開始下載檔案
		AudioFileStreamOpen((__bridge void *)self,
							AUAudioFileStreamPropertyListener,
							AUAudioFileStreamPacketsCallback,
							kAudioFileMP3Type, &audioFileStreamID);
		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[[NSOperationQueue alloc] init]];
		dataTask = [session dataTaskWithURL:inURL];
		[dataTask resume];
		playerStatus.stopped = YES;
	}
	return self;
}

- (double)packetsPerSecond
{
	if (streamDescription.mFramesPerPacket) {
		return  streamDescription.mSampleRate / streamDescription.mFramesPerPacket;
	}
	return 44100.0/1152.0;
}

- (void)play
{
	if (!playerStatus.stopped) {
		return;
	}
	OSStatus status = AUGraphStart(audioGraph);
	NSAssert(noErr == status, @"AUGraphStart, error: %ld", (signed long)status);
	status = AudioOutputUnitStart(outputUnit);
	NSAssert(noErr == status, @"AudioOutputUnitStart, error: %ld", (signed long)status);
	playerStatus.stopped = NO;
}

- (void)pause
{
	OSStatus status = AUGraphStop(audioGraph);
	NSAssert(noErr == status, @"AUGraphStop, error: %ld", (signed long)status);
	status = AudioOutputUnitStop(outputUnit);
	NSAssert(noErr == status, @"AudioOutputUnitStop, error: %ld", (signed long) status);
}

- (CFArrayRef)iPodEQPresentsArray
{
	CFArrayRef array;
	UInt32 size = sizeof(array);
	AudioUnitGetProperty(EQUnit, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0, &array, &size);
	return array;
}

- (void)selectEQPresent:(NSInteger)value
{
	AUPreset *aPresent = (AUPreset *)CFArrayGetValueAtIndex(self.iPodEQPresentsArray, value);
	AudioUnitSetProperty(EQUnit, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, aPresent, sizeof(aPresent));
}

#pragma mark - NSURLSessionDataDelegate

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
	
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		__strong typeof(weakSelf) strongSelf = weakSelf;
		// 第二部：抓到了部分檔案，就交由 Audio Parser 開始 parse 出 data
		// stream 中的 packet。
		AudioFileStreamParseBytes(strongSelf->audioFileStreamID, (UInt32)[data length], [data bytes], 0);
	});
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	if (error) {
		NSLog(@"Failed to load data: %@", [error localizedDescription]);
		[self pause];
	}
	else {
		NSLog(@"Complete loading data");
		playerStatus.loaded = YES;
	}
}

#pragma mark - Audio Parser and Audio Queue callbacks

- (void)_createAudioQueueWithAudioStreamDescription:(AudioStreamBasicDescription *)audioStreamBasicDescription
{
	memcpy(&streamDescription, audioStreamBasicDescription, sizeof(AudioStreamBasicDescription));
	AudioStreamBasicDescription destFormat = KKSignedIntLinearPCMStreamDescription();
	AudioConverterNew(&streamDescription, &destFormat, &converter);
}

- (void)_storePacketsWithNumberOfBytes:(UInt32)inNumberBytes
					   numberOfPackets:(UInt32)inNumberPackets
							 inputData:(const void *)inInputData
					packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
{
	for (int i = 0; i < inNumberPackets; i++) {
		SInt64 packetStart = inPacketDescriptions[i].mStartOffset;
		UInt32 packetSize = inPacketDescriptions[i].mDataByteSize;
		assert(packetSize > 0);
		NSData *packet = [NSData dataWithBytes:inInputData + packetStart length:packetSize];
		[packets addObject:packet];
	}
	
	// 第五部，因為 parse 出來的 packets 夠多，緩衝內容夠大，因此開始播放
	if (readHead == 0 && [packets count] > (int)([self packetsPerSecond] * 3)) {
		if (playerStatus.stopped) {
			[self play];
		}
	}
}

#pragma mark - Properties

- (BOOL)isStopped
{
	return playerStatus.stopped;
}

- (OSStatus)callbackWithNumberOfFrames:(UInt32)inNumberOfFrames
								ioData:(AudioBufferList *)inIoData
							 busNumber:(UInt32)inBusNumber
{
	@synchronized (self) {
		if (readHead < [packets count]) {
			UInt32 packetSize = inNumberOfFrames;
			//第七部：Remote IO node 的 render callback 中，呼叫 converter 將 packet 轉成 LPCM
			OSStatus status =
			AudioConverterFillComplexBuffer(converter,
											AUPlayerConverterFiller,
											(__bridge void *)(self),
											&packetSize, renderBufferList, NULL);
			if (noErr !=  status && AUAudioConverterCallbackErr_NoData != status) {
				[self pause];
				return -1;
			}
			else if (!packetSize) {
				inIoData->mNumberBuffers = 0;
			}
			else {
				// 在這邊改變 renderBufferList->mBuffers[0].mData
				// 可以產生各種效果
				inIoData->mNumberBuffers = 1;
				inIoData->mBuffers[0].mNumberChannels = 2;
				inIoData->mBuffers[0].mDataByteSize = renderBufferList->mBuffers[0].mDataByteSize;
				inIoData->mBuffers[0].mData = renderBufferList->mBuffers[0].mData;
				renderBufferList->mBuffers[0].mDataByteSize = renderBufferSize;
			}
		}
		else {
			inIoData->mNumberBuffers = 0;
			return -1;
		}
	}
	return noErr;
}

- (OSStatus)_fillConverterBufferWithBufferList:(AudioBufferList *)ioData
							 packetDescription:(AudioStreamPacketDescription** )outDataPacketDescription
{
	static AudioStreamPacketDescription aspdesc;
	
	if (readHead >= [packets count]) {
		return AUAudioConverterCallbackErr_NoData;
	}
	
	ioData->mNumberBuffers = 1;
	NSData *packet = packets[readHead];
	void const *data = [packet bytes];
	UInt32 length = (UInt32)[packet length];
	ioData->mBuffers[0].mData = (void *)data;
	ioData->mBuffers[0].mDataByteSize = length;
	
	*outDataPacketDescription = &aspdesc;
	aspdesc.mDataByteSize = length;
	aspdesc.mStartOffset = 0;
	aspdesc.mVariableFramesInPacket = 1;
	
	readHead++;
	return 0;
}

@end

#pragma mark - C Callbacks

void AUAudioFileStreamPropertyListener(void * inClientData,
									   AudioFileStreamID inAudioFileStream,
									   AudioFileStreamPropertyID inPropertyID,
									   UInt32 * ioFlags)
{
	AudioUnitPlayer *self = (__bridge AudioUnitPlayer *)inClientData;
	if (inPropertyID == kAudioFileStreamProperty_DataFormat) {
		UInt32 dataSize = 0;
		OSStatus status = 0;
		AudioStreamBasicDescription audioStreamDescription;
		Boolean writable = false;
		status = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &writable);
		status = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &dataSize, &audioStreamDescription);
		
		NSLog(@"mSampleRate: %f", audioStreamDescription.mSampleRate);
		NSLog(@"mFormatID: %u", audioStreamDescription.mFormatID);
		NSLog(@"mFormatFlags: %u", audioStreamDescription.mFormatFlags);
		NSLog(@"mBytesPerPacket: %u", audioStreamDescription.mBytesPerPacket);
		NSLog(@"mFramesPerPacket: %u", audioStreamDescription.mFramesPerPacket);
		NSLog(@"mBytesPerFrame: %u", audioStreamDescription.mBytesPerFrame);
		NSLog(@"mChannelsPerFrame: %u", audioStreamDescription.mChannelsPerFrame);
		NSLog(@"mBitsPerChannel: %u", audioStreamDescription.mBitsPerChannel);
		NSLog(@"mReserved: %u", audioStreamDescription.mReserved);
		
		// 第三步：Audio Parser 成功 parse 出 audio 檔案格式，我們根據
		// 檔案格式資訊，建立 converter
		
		[self _createAudioQueueWithAudioStreamDescription:&audioStreamDescription];
	}
}

void AUAudioFileStreamPacketsCallback(void* inClientData,
									  UInt32 inNumberBytes,
									  UInt32 inNumberPackets,
									  const void* inInputData,
									  AudioStreamPacketDescription* inPacketDescriptions)
{
	// 第四部：Audio Parser 成功 parse 出 packets，我們將這些資料儲存起來
	AudioUnitPlayer *self = (__bridge AudioUnitPlayer *)inClientData;
	[self _storePacketsWithNumberOfBytes:inNumberPackets
						 numberOfPackets:inNumberPackets
							   inputData:inInputData
					  packetDescriptions:inPacketDescriptions];
	
}

OSStatus AUPlayerAURenderCallback(void *userData,
								  AudioUnitRenderActionFlags *ioActionFlags,
								  const AudioTimeStamp *inTimeStamp,
								  UInt32 inBusNumber,
								  UInt32 inNumberFrames,
								  AudioBufferList *ioData)
{
	// 第六部： Remote IO node 的 render callback
	AudioUnitPlayer *self = (__bridge AudioUnitPlayer *)userData;
	OSStatus status = [self callbackWithNumberOfFrames:inNumberFrames
												ioData:ioData
											 busNumber:inBusNumber];
	if (status != noErr) {
		ioData->mNumberBuffers = 0;
		*ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
	}
	return status;
}

OSStatus AUPlayerConverterFiller(AudioConverterRef inAudioConverter,
								 UInt32* ioNumberDataPackets,
								 AudioBufferList* ioData,
								 AudioStreamPacketDescription** outDataPacketDescription,
								 void* inUserData)
{
	// 第八部： AudioConverterFillcomplexBuffer 的 callback
	AudioUnitPlayer *self = (__bridge AudioUnitPlayer *)inUserData;
	*ioNumberDataPackets = 0;
	OSStatus result = [self _fillConverterBufferWithBufferList:ioData
											 packetDescription:outDataPacketDescription];
	if (result == noErr) {
		*ioNumberDataPackets = 1;
	}
	return result;
}
