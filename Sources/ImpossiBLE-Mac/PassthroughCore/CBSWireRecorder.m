#import "include/CBSWireRecorder.h"
#import <unistd.h>

NSString *const CBSWireDirectionFromClient = @"fromClient";
NSString *const CBSWireDirectionToClient = @"toClient";

@implementation CBSWireRecorder {
    NSString *_directory;
    NSString *_filePrefix;
    dispatch_queue_t _queue;
    NSISO8601DateFormatter *_dateFormatter;
    NSFileHandle *_fileHandle;
    unsigned long long _trailerOffset;
    NSUInteger _seq;
}

- (instancetype)initWithDirectory:(NSString *)directory filePrefix:(NSString *)filePrefix {
    self = [super init];
    if (self) {
        _directory = [directory copy];
        _filePrefix = [filePrefix copy];
        _queue = dispatch_queue_create("impossible.wire.record", DISPATCH_QUEUE_SERIAL);
        _dateFormatter = [[NSISO8601DateFormatter alloc] init];
        _dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    }
    return self;
}

- (void)dealloc {
    [_fileHandle closeAndReturnError:NULL];
}

- (void)recordMessage:(NSDictionary<NSString *, id> *)message direction:(NSString *)direction {
    NSDate *date = [NSDate date];
    NSDictionary *snapshot = [message copy];
    dispatch_async(_queue, ^{
        [self appendMessage:snapshot direction:direction date:date];
    });
}

- (void)finish {
    dispatch_async(_queue, ^{
        [self->_fileHandle closeAndReturnError:NULL];
        self->_fileHandle = nil;
    });
}

// Base64 payloads are opaque in a trace; add their hex form alongside.
// Descriptor replies carry the raw bytes in `valueB64` (`value` is then a
// decoded JSON value); everything else carries them in `value`.
- (NSString *)hexValueForMessage:(NSDictionary *)message {
    id b64 = message[@"valueB64"] ?: message[@"value"];
    if (![b64 isKindOfClass:[NSString class]] || [(NSString *)b64 length] == 0) {
        return nil;
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (data.length == 0) {
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

- (BOOL)openFileIfNeeded {
    if (_fileHandle) {
        return YES;
    }
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:_directory
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        NSLog(@"ImpossiBLE-Recorder: recording disabled, cannot create %@: %@", _directory, error);
        return NO;
    }
    NSDateFormatter *nameFormatter = [[NSDateFormatter alloc] init];
    nameFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    nameFormatter.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    NSString *name = [NSString stringWithFormat:@"%@-%@-%d-%p.json",
                      _filePrefix, [nameFormatter stringFromDate:[NSDate date]], getpid(), self];
    NSString *path = [_directory stringByAppendingPathComponent:name];

    // An empty array; entries are spliced in before the "\n]\n" trailer.
    NSData *initial = [@"[\n]\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (![initial writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"ImpossiBLE-Recorder: recording disabled, cannot write %@: %@", path, error);
        return NO;
    }
    _fileHandle = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:path] error:&error];
    if (!_fileHandle) {
        NSLog(@"ImpossiBLE-Recorder: recording disabled, cannot open %@: %@", path, error);
        return NO;
    }
    _trailerOffset = 1;
    _seq = 0;
    NSLog(@"ImpossiBLE-Recorder: recording traffic to %@", path);
    void (^handler)(NSString *) = self.fileOpenedHandler;
    if (handler) {
        handler(path);
    }
    return YES;
}

- (void)appendMessage:(NSDictionary *)message direction:(NSString *)direction date:(NSDate *)date {
    if (![self openFileIfNeeded]) {
        return;
    }
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"seq"] = @(_seq);
    entry[@"timestamp"] = [_dateFormatter stringFromDate:date];
    entry[@"direction"] = direction;
    entry[@"type"] = [message[@"type"] isKindOfClass:[NSString class]] ? message[@"type"] : [NSNull null];
    // Every message should already be wire-safe; keep the entry valid if not.
    entry[@"message"] = [NSJSONSerialization isValidJSONObject:message] ? message : [message description];
    NSString *hex = [self hexValueForMessage:message];
    if (hex) {
        entry[@"valueHex"] = hex;
    }

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry
                                                   options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                     error:&error];
    if (!json) {
        NSLog(@"ImpossiBLE-Recorder: entry dropped seq=%lu: %@", (unsigned long)_seq, error);
        return;
    }
    NSMutableData *chunk = [NSMutableData dataWithData:[(_seq == 0 ? @"\n  " : @",\n  ") dataUsingEncoding:NSUTF8StringEncoding]];
    [chunk appendData:json];
    NSData *trailer = [@"\n]\n" dataUsingEncoding:NSUTF8StringEncoding];

    unsigned long long entryEnd = 0;
    if (![_fileHandle seekToOffset:_trailerOffset error:&error] ||
        ![_fileHandle writeData:chunk error:&error] ||
        ![_fileHandle getOffset:&entryEnd error:&error] ||
        ![_fileHandle writeData:trailer error:&error]) {
        NSLog(@"ImpossiBLE-Recorder: recording stopped, write failed: %@", error);
        [_fileHandle closeAndReturnError:NULL];
        _fileHandle = nil;
        return;
    }
    _trailerOffset = entryEnd;
    _seq++;
}

@end
