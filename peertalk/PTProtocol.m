#import "PTProtocol.h"
#import "PTPrivate.h"
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

static const uint32_t PTProtocolVersion1 = 1;

NSString * const PTProtocolErrorDomain = @"PTProtocolError";

// This is what we send as the header for each frame.
typedef struct _PTFrame {
  // The version of the frame and protocol.
  uint32_t version;

  // Type of frame
  uint32_t type;

  // Unless zero, a tag is retained in frames that are responses to previous
  // frames. Applications can use this to build transactions or request-response
  // logic.
  uint32_t tag;

  // If payloadSize is larger than zero, *payloadSize* number of bytes are
  // following, constituting application-specific data.
  uint32_t payloadSize;

} PTFrame;


@interface PTProtocol () {
  uint32_t nextFrameTag_;
  @public
  dispatch_queue_t _Nullable queue_;
}
- (dispatch_data_t)createDispatchDataWithFrameOfType:(uint32_t)type frameTag:(uint32_t)frameTag payload:(dispatch_data_t)payload;
@end

/// same as `dispatch_data_get_size`, but won't crash when data is nil, returning 0 instead
static inline size_t _pt_dispatch_data_get_size(dispatch_data_t _Nullable data)
{
  return (data == nil) ? 0 : dispatch_data_get_size(data);
}

static void _release_queue_local_protocol(void *objcobj) {
  if (objcobj) {
    PTProtocol *protocol = (__bridge_transfer id)objcobj;
    protocol->queue_ = NULL;
  }
}


@interface RQueueLocalIOFrameProtocol : PTProtocol
@end
@implementation RQueueLocalIOFrameProtocol
- (void)setQueue:(nullable dispatch_queue_t)queue {
}
@end


@implementation PTProtocol


+ (PTProtocol*)sharedProtocolForQueue:(dispatch_queue_t)queue {
  static const char currentQueueFrameProtocolKey;
  PTProtocol *currentQueueFrameProtocol = (__bridge PTProtocol*)dispatch_queue_get_specific(queue, &currentQueueFrameProtocolKey);
  if (!currentQueueFrameProtocol) {
    currentQueueFrameProtocol = [[RQueueLocalIOFrameProtocol alloc] initWithDispatchQueue:NULL];
    currentQueueFrameProtocol->queue_ = queue; // reference, no retain, since we would create cyclic references
    dispatch_queue_set_specific(queue, &currentQueueFrameProtocolKey, (__bridge_retained void*)currentQueueFrameProtocol, &_release_queue_local_protocol);
    return (__bridge PTProtocol*)dispatch_queue_get_specific(queue, &currentQueueFrameProtocolKey); // to avoid race conds
  } else {
    return currentQueueFrameProtocol;
  }
}


- (id)initWithDispatchQueue:(nullable dispatch_queue_t)queue {
  self = [super init];
  if (self) {
    queue_ = queue;
  }
  return self;
}

- (id)init {
  return [self initWithDispatchQueue:dispatch_get_main_queue()];
}

- (nullable dispatch_queue_t)queue {
  return queue_;
}

- (void)setQueue:(nullable dispatch_queue_t)queue {
  queue_ = queue;
}


- (uint32_t)newTag {
  return ++nextFrameTag_;
}


#pragma mark -
#pragma mark Creating frames


- (dispatch_data_t)createDispatchDataWithFrameOfType:(uint32_t)type frameTag:(uint32_t)frameTag payload:(dispatch_data_t)payload {
  PTFrame *frame = CFAllocatorAllocate(kCFAllocatorDefault, sizeof(PTFrame), 0);
  frame->version = htonl(PTProtocolVersion1);
  frame->type = htonl(type);
  frame->tag = htonl(frameTag);
  
  if (payload) {
    size_t payloadSize = _pt_dispatch_data_get_size(payload);
    assert(payloadSize <= UINT32_MAX);
    frame->payloadSize = htonl((uint32_t)payloadSize);
  } else {
    frame->payloadSize = 0;
  }
  
  dispatch_data_t frameData = dispatch_data_create((const void*)frame, sizeof(PTFrame), queue_, ^{
    CFAllocatorDeallocate(kCFAllocatorDefault, (void*)frame);
  });
  
  if (payload && frame->payloadSize != 0) {
    // chain frame + payload
    dispatch_data_t data = dispatch_data_create_concat(frameData, payload);
    frameData = data;
  }
  
  return frameData;
}


#pragma mark -
#pragma mark Sending frames


- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload overChannel:(dispatch_io_t)channel callback:(void(^)(NSError*))callback {
  dispatch_data_t frame = [self createDispatchDataWithFrameOfType:frameType frameTag:tag payload:payload];
  dispatch_io_write(channel, 0, frame, queue_, ^(bool done, dispatch_data_t data, int _errno) {
    if (done && callback) {
      callback(_errno == 0 ? nil : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:_errno userInfo:nil]);
    }
  });
}


#pragma mark -
#pragma mark Receiving frames


- (void)readFrameOverChannel:(dispatch_io_t)channel callback:(void(^)(NSError * _Nullable error, uint32_t frameType, uint32_t frameTag, uint32_t payloadSize))callback {
  __block dispatch_data_t allData = NULL;
  
  dispatch_io_read(channel, 0, sizeof(PTFrame), queue_, ^(bool done, dispatch_data_t data, int error) {
    size_t dataSize = _pt_dispatch_data_get_size(data);
    
    if (dataSize) {
      if (!allData) {
        allData = data;
      } else {
        allData = dispatch_data_create_concat(allData, data);
      }
    }
    
    if (done) {
      if (error != 0) {
        callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], 0, 0, 0);
        return;
      }
      
      if (dataSize == 0) {
        callback(nil, PTFrameTypeEndOfStream, 0, 0);
        return;
      }
      
      if (!allData || _pt_dispatch_data_get_size(allData) < sizeof(PTFrame)) {
        callback([[NSError alloc] initWithDomain:PTProtocolErrorDomain code:0 userInfo:nil], 0, 0, 0);
        return;
      }
      
      PTFrame *frame = NULL;
      size_t size = 0;
      
      PT_PRECISE_LIFETIME dispatch_data_t contiguousData = dispatch_data_create_map(allData, (const void **)&frame, &size); // precise lifetime guarantees bytes in frame will stay valid till the end of scope
      if (!contiguousData) {
        callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil], 0, 0, 0);
        return;
      }
      
      frame->version = ntohl(frame->version);
      if (frame->version != PTProtocolVersion1) {
        callback([[NSError alloc] initWithDomain:PTProtocolErrorDomain code:0 userInfo:nil], 0, 0, 0);
      } else {
        frame->type = ntohl(frame->type);
        frame->tag = ntohl(frame->tag);
        frame->payloadSize = ntohl(frame->payloadSize);
        callback(nil, frame->type, frame->tag, frame->payloadSize);
      }
    }
  });
}


- (void)readPayloadOfSize:(size_t)payloadSize overChannel:(dispatch_io_t)channel callback:(void(^)(NSError * _Nullable error, dispatch_data_t _Nullable contiguousData, const uint8_t * _Nullable buffer, size_t bufferSize))callback {
  __block dispatch_data_t allData = NULL;
  dispatch_io_read(channel, 0, payloadSize, queue_, ^(bool done, dispatch_data_t data, int error) {
    size_t dataSize = _pt_dispatch_data_get_size(data);
    
    if (dataSize) {
      if (!allData) {
        allData = data;
      } else {
        allData = dispatch_data_create_concat(allData, data);
      }
    }
    
    if (done) {
      if (error != 0) {
        callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], NULL, NULL, 0);
        return;
      }
      
      if (dataSize == 0) {
        callback(nil, NULL, NULL, 0);
        return;
      }
      
      uint8_t *buffer = NULL;
      size_t bufferSize = 0;
      PT_PRECISE_LIFETIME dispatch_data_t contiguousData = NULL;
      
      if (allData) {
        contiguousData = dispatch_data_create_map(allData, (const void **)&buffer, &bufferSize);
        if (!contiguousData) {
          callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil], NULL, NULL, 0);
          return;
        }
      }
      
      callback(nil, contiguousData, buffer, bufferSize);
    }
  });
}


- (void)readAndDiscardDataOfSize:(size_t)size overChannel:(dispatch_io_t)channel callback:(void(^)(NSError*, BOOL))callback {
  dispatch_io_read(channel, 0, size, queue_, ^(bool done, dispatch_data_t data, int error) {
    if (done && callback) {
      size_t dataSize = _pt_dispatch_data_get_size(data);
      callback(error == 0 ? nil : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], dataSize == 0);
    }
  });
}


- (void)readFramesOverChannel:(dispatch_io_t)channel onFrame:(void(^)(NSError*, uint32_t, uint32_t, uint32_t, dispatch_block_t))onFrame {
  [self readFrameOverChannel:channel callback:^(NSError *error, uint32_t type, uint32_t tag, uint32_t payloadSize) {
    onFrame(error, type, tag, payloadSize, ^{
      if (type != PTFrameTypeEndOfStream) {
        [self readFramesOverChannel:channel onFrame:onFrame];
      }
    });
  }];
}


@end


@interface _PTDispatchData : NSObject {
  dispatch_data_t dispatchData_;
}
@end
@implementation _PTDispatchData
- (id)initWithDispatchData:(dispatch_data_t)dispatchData {
  self = [super init];
  if (self) {
    dispatchData_ = dispatchData;
  }
  return self;
}
@end

@implementation NSData (PTProtocol)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-getter-return-value"

- (dispatch_data_t)createReferencingDispatchData {
  // Note: The queue is used to submit the destructor. Since we only perform an
  // atomic release of self, it doesn't really matter which queue is used, thus
  // we use the current calling queue.
  return dispatch_data_create((const void*)self.bytes, self.length, dispatch_get_main_queue(), ^{
    // trick to have the block capture the data, thus retain/releasing
    [self length];
  });
}

#pragma clang diagnostic pop

+ (nullable NSData *)dataWithContentsOfDispatchData:(dispatch_data_t)data {
  if (!data) {
    return nil;
  }
  uint8_t *buffer = NULL;
  size_t bufferSize = 0;
  PT_PRECISE_LIFETIME dispatch_data_t contiguousData = dispatch_data_create_map(data, (const void **)&buffer, &bufferSize);
  if (!contiguousData) {
    return nil;
  }
  
  _PTDispatchData *dispatchDataRef = [[_PTDispatchData alloc] initWithDispatchData:contiguousData];
  NSData *newData = [NSData dataWithBytesNoCopy:(void*)buffer length:bufferSize freeWhenDone:NO];
  static const bool kDispatchDataRefKey;
  objc_setAssociatedObject(newData, (const void * _Nonnull)kDispatchDataRefKey, dispatchDataRef, OBJC_ASSOCIATION_RETAIN);
  
  return newData;
}

// Decode *data* as a peroperty list-encoded dictionary. Returns nil on failure.
+ (nullable NSDictionary *)dictionaryWithContentsOfData:(NSData *)data {
	if (!data) {
		return nil;
	}
	return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
}

@end


@implementation NSDictionary (PTProtocol)

- (nullable dispatch_data_t)createReferencingDispatchData {
  NSError *error = nil;
  NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:self format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
  if (!plistData) {
    NSLog(@"Failed to serialize property list: %@", error);
    return nil;
  } else {
    return [plistData createReferencingDispatchData];
  }
}
@end

NS_ASSUME_NONNULL_END
